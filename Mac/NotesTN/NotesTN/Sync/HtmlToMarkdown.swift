import Foundation

/// Reverse of MarkdownToHtml.swift: converts the editor's ProseMirror-produced HTML
/// body back into Joplin-compatible Markdown for push sync. Port of Android App's
/// HtmlToMarkdown.kt — keep both in sync. See that file's doc comment for the general
/// approach and known limitations (strikethrough/sub/sup/highlight/toggle blocks encode
/// losslessly for other Joplin clients but don't round-trip back through our own
/// simplified MarkdownToHtml renderer; nested lists likewise).
enum HtmlToMarkdown {

    private typealias HtmlNode = MiniHtmlParser.HtmlNode

    private static let resourceUrlRegex = try! NSRegularExpression(
        pattern: #"^file://.*/([0-9a-fA-F]{32})\.[^./]+$"#
    )

    static func convert(_ html: String) -> String {
        let nodes = MiniHtmlParser.parse(html)
        let blocks = elements(nodes).map { renderBlock($0) }.joined(separator: "\n\n")
        return blocks.trimmingCharacters(in: .whitespacesAndNewlines) + "\n"
    }

    private static func renderBlock(_ el: HtmlNode) -> String {
        switch el.tag {
        case "p":
            return renderInline(el)

        case "h1", "h2", "h3", "h4", "h5", "h6":
            let level = Int(el.tag.dropFirst())!
            return String(repeating: "#", count: level) + " " + renderInline(el)

        case "pre":
            let code = elements(el.children).first(where: { $0.tag == "code" }).map { plainText($0) } ?? plainText(el)
            return "```\n\(code)\n```"

        case "blockquote":
            let inner = elements(el.children).map { renderBlock($0) }.joined(separator: "\n\n")
            return inner.components(separatedBy: "\n").map { $0.isEmpty ? ">" : "> \($0)" }.joined(separator: "\n")

        case "hr":
            return "---"

        case "ul":
            return el.attributes["data-is-checklist"] == "true" ? renderChecklist(el) : renderBulletList(el)

        case "ol":
            return renderOrderedList(el)

        case "table":
            // A manually-resized table (any cell carrying data-colwidth, written by
            // prosemirror-tables' column resizing) is passed through as raw HTML so
            // its column widths survive the round-trip — Markdown pipe tables have no
            // way to express them. Default equal-width tables still emit clean
            // Markdown that other Joplin clients render natively.
            return hasColumnWidths(el) ? serialize(el) : renderTable(el)

        case "div" where el.attributes["class"]?.contains("pm-attachment") == true:
            // File attachment card → Joplin's own format for a non-image resource,
            // a plain link to it. Other Joplin clients can then open the file too.
            let id = el.attributes["data-resource-id"] ?? ""
            let title = el.attributes["data-title"] ?? "Attachment"
            return "[\(escapeMarkdown(title))](:/\(id))"

        case "details":
            return serialize(el) // no Markdown equivalent — pass through as raw HTML

        default:
            return renderInline(el)
        }
    }

    private static func renderBulletList(_ ul: HtmlNode) -> String {
        elements(ul.children).filter { $0.tag == "li" }.map { renderListItem($0, marker: "-") }.joined(separator: "\n")
    }

    private static func renderOrderedList(_ ol: HtmlNode) -> String {
        let start = Int(ol.attributes["start"] ?? "") ?? 1
        return elements(ol.children).filter { $0.tag == "li" }.enumerated().map { index, li in
            renderListItem(li, marker: "\(start + index).")
        }.joined(separator: "\n")
    }

    private static func renderChecklist(_ ul: HtmlNode) -> String {
        elements(ul.children).filter { $0.tag == "li" }.map { li in
            let checked = firstDescendant(li, tag: "input")?.attributes["checked"] != nil
            let marker = checked ? "[x]" : "[ ]"
            let contentHost = elements(li.children).first(where: { $0.tag == "div" }) ?? li
            return "- \(marker) \(renderListItemContent(contentHost))"
        }.joined(separator: "\n")
    }

    /// A list item's first block is its own text; any further blocks (nested lists,
    /// extra paragraphs) are rendered below it, indented — real Joplin/CommonMark
    /// renderers understand nested indented lists even though MarkdownToHtml.swift's
    /// simple line-based parser doesn't reconstruct the nesting on pull.
    private static func renderListItem(_ li: HtmlNode, marker: String) -> String {
        let first = "\(marker) \(renderListItemContent(li))"
        let rest = elements(li.children).dropFirst().map { child in
            renderBlock(child).components(separatedBy: "\n").map { "  \($0)" }.joined(separator: "\n")
        }.joined(separator: "\n")
        return rest.isEmpty ? first : "\(first)\n\(rest)"
    }

    private static func renderListItemContent(_ host: HtmlNode) -> String {
        let firstBlock = elements(host.children).first(where: { $0.tag == "p" }) ?? host
        return renderInline(firstBlock)
    }

    /// True if any cell in the table carries an explicit column width — i.e. the user
    /// resized a column (see prosemirror-tables' data-colwidth). Used to decide
    /// between raw-HTML passthrough (preserves widths) and a Markdown pipe table.
    private static func hasColumnWidths(_ table: HtmlNode) -> Bool {
        func search(_ node: HtmlNode) -> Bool {
            if let value = node.attributes["data-colwidth"], !value.isEmpty { return true }
            return node.children.contains(where: search)
        }
        return search(table)
    }

    private static func renderTable(_ table: HtmlNode) -> String {
        let rows = allDescendants(table, tag: "tr")
        guard let firstRow = rows.first else { return "" }
        let header = elements(firstRow.children).map { renderInline($0) }
        let separator = header.map { _ in "---" }
        let body = rows.dropFirst().map { row in elements(row.children).map { renderInline($0) } }

        func rowLine(_ cells: [String]) -> String { "| \(cells.joined(separator: " | ")) |" }
        var lines = [rowLine(header), rowLine(separator)]
        lines.append(contentsOf: body.map(rowLine))
        return lines.joined(separator: "\n")
    }

    /// Inline formatting within a block: images, links, bold, italic, code, etc. Spans
    /// with no Markdown meaning (e.g. the heading arrow/content wrapper spans ProseMirror
    /// emits) are unwrapped, not dropped, so their text content isn't lost.
    private static func renderInline(_ el: HtmlNode) -> String {
        el.children.map { renderInlineNode($0) }.joined()
    }

    private static func renderInlineNode(_ node: HtmlNode) -> String {
        if node.tag == "#text" { return escapeMarkdown(node.text) }
        return renderInlineElement(node)
    }

    private static func renderInlineElement(_ el: HtmlNode) -> String {
        switch el.tag {
        case "strong", "b": return "**\(renderInline(el))**"
        case "em", "i": return "*\(renderInline(el))*"
        case "code": return "`\(plainText(el))`"
        case "s", "del", "strike": return "~~\(renderInline(el))~~"
        case "sub": return "<sub>\(renderInline(el))</sub>"
        case "sup": return "<sup>\(renderInline(el))</sup>"
        case "mark": return "==\(renderInline(el))=="
        case "a": return "[\(renderInline(el))](\(el.attributes["href"] ?? ""))"
        case "img": return "![\(el.attributes["alt"] ?? "")](\(resourceLink(el)))"
        case "br": return "\n"
        default: return renderInline(el) // e.g. the heading wrapper spans — unwrap, keep text
        }
    }

    /// Local images are stored as file:// URLs into the resources directory (see
    /// EditorView.handleImagePick / JoplinSyncEngine.rewriteResourceLinks) — convert
    /// back to Joplin's `:/resourceId` syntax so other Joplin clients can resolve the
    /// image. Falls back to the raw src for anything that isn't a local resource.
    private static func resourceLink(_ img: HtmlNode) -> String {
        if let id = img.attributes["data-resource-id"], !id.isEmpty { return ":/\(id)" }
        let src = img.attributes["src"] ?? ""
        let range = NSRange(src.startIndex..<src.endIndex, in: src)
        if let match = resourceUrlRegex.firstMatch(in: src, range: range), let idRange = Range(match.range(at: 1), in: src) {
            return ":/\(src[idRange])"
        }
        return src
    }

    private static func escapeMarkdown(_ text: String) -> String {
        text
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "*", with: "\\*")
            .replacingOccurrences(of: "_", with: "\\_")
            .replacingOccurrences(of: "`", with: "\\`")
            .replacingOccurrences(of: "[", with: "\\[")
            .replacingOccurrences(of: "]", with: "\\]")
    }

    // MARK: - Node tree helpers

    private static func elements(_ nodes: [HtmlNode]) -> [HtmlNode] { nodes.filter { $0.tag != "#text" } }

    private static func plainText(_ node: HtmlNode) -> String {
        if node.tag == "#text" { return node.text }
        return node.children.map { plainText($0) }.joined()
    }

    private static func firstDescendant(_ node: HtmlNode, tag: String) -> HtmlNode? {
        for child in node.children {
            if child.tag == tag { return child }
            if let found = firstDescendant(child, tag: tag) { return found }
        }
        return nil
    }

    private static func allDescendants(_ node: HtmlNode, tag: String) -> [HtmlNode] {
        var result: [HtmlNode] = []
        for child in node.children {
            if child.tag == tag { result.append(child) }
            result.append(contentsOf: allDescendants(child, tag: tag))
        }
        return result
    }

    /// Re-serializes a node back to an HTML string — only used for `<details>`
    /// passthrough, since Markdown has no toggle-block equivalent.
    private static func serialize(_ node: HtmlNode) -> String {
        if node.tag == "#text" { return node.text }
        let attrs = node.attributes.map { key, value in value.isEmpty ? " \(key)" : " \(key)=\"\(value)\"" }.joined()
        let inner = node.children.map { serialize($0) }.joined()
        return "<\(node.tag)\(attrs)>\(inner)</\(node.tag)>"
    }
}
