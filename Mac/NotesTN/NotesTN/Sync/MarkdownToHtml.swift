import Foundation

/// Minimal Markdown -> HTML converter for notes pulled from Joplin Cloud (notes there
/// are stored as Markdown; our editor works in HTML — see Note.body doc comment).
/// Not a full CommonMark implementation — covers headings, bold/italic, inline code,
/// code fences, links, images, lists (incl. checkboxes), blockquotes, horizontal rules
/// and tables, matching what Mac/EditorBundle's ProseMirror schema + CSS actually render.
///
/// Port of Android App's MarkdownToHtml.kt — keep both in sync.
enum MarkdownToHtml {

    private static let boldRegex = try! NSRegularExpression(pattern: "\\*\\*(.+?)\\*\\*|__(.+?)__")
    // Joplin's highlight syntax (rendered as <mark> in the editor — see HtmlToMarkdown.swift's
    // "mark" case, which already emits this on the way out; this was the missing return path).
    private static let highlightRegex = try! NSRegularExpression(pattern: "==(.+?)==")
    // Same gap as highlight above — HtmlToMarkdown.swift's "s"/"del"/"strike" case already
    // emits ~~text~~ on save; this was the missing return path for the load side.
    private static let strikethroughRegex = try! NSRegularExpression(pattern: "~~(.+?)~~")
    // Underscore emphasis only counts at a word boundary, per CommonMark: an
    // underscore inside a word is literal, so "hello_here_stuff" and "snake_case_name"
    // stay as typed instead of turning "_here_" into italics. Asterisks keep working
    // mid-word ("foo*bar*baz"), which CommonMark also allows.
    private static let italicRegex = try! NSRegularExpression(
        pattern: "(?<!\\*)\\*(?!\\*)(.+?)\\*(?!\\*)|(?<![A-Za-z0-9_])_(.+?)_(?![A-Za-z0-9_])"
    )

    // Undoes HtmlToMarkdown.escapeMarkdown. Our own notes write a literal underscore
    // as "\_" so other Markdown renderers don't italicize it; without this the
    // backslashes would show up as text when the note is read back.
    private static let unescapeRegex = try! NSRegularExpression(pattern: #"\\([\\*_`\[\]])"#)
    private static let inlineCodeRegex = try! NSRegularExpression(pattern: "`([^`]+)`")
    private static let imageRegex = try! NSRegularExpression(pattern: "!\\[([^\\]]*)\\]\\(([^)]+)\\)")
    private static let linkRegex = try! NSRegularExpression(pattern: "\\[([^\\]]+)\\]\\(([^)]+)\\)")
    // [name](:/32-char-id) — Joplin's link to a non-image resource, i.e. an attachment.
    private static let attachmentLinkRegex = try! NSRegularExpression(
        pattern: "\\[([^\\]]*)\\]\\(:/([0-9a-fA-F]{32})\\)"
    )
    private static let headingRegex = try! NSRegularExpression(pattern: "^(#{1,6})\\s+(.*)$")
    private static let checklistRegex = try! NSRegularExpression(pattern: "^([-*])\\s+\\[( |x|X)\\]\\s+(.*)$")
    private static let bulletRegex = try! NSRegularExpression(pattern: "^([-*])\\s+(.*)$")
    private static let orderedRegex = try! NSRegularExpression(pattern: "^(\\d+)\\.\\s+(.*)$")
    private static let blockquoteRegex = try! NSRegularExpression(pattern: "^>\\s?(.*)$")
    // Matches "---", "***", "___" but also spaced variants like "* * *" or "- - -".
    private static let hrRegex = try! NSRegularExpression(pattern: "^([-*_])(\\s*\\1){2,}\\s*$")

    static func convert(_ markdown: String) -> String {
        let lines = stripFrontmatter(markdown.replacingOccurrences(of: "\r\n", with: "\n")).components(separatedBy: "\n")
        var html = ""

        var i = 0
        while i < lines.count {
            let line = lines[i]

            if line.trimmingCharacters(in: .whitespaces).isEmpty {
                i += 1

            } else if let m = firstMatch(attachmentLinkRegex, line.trimmingCharacters(in: .whitespaces)) {
                // A line that is just [name](:/id) is Joplin's non-image attachment
                // (images use the ![...] form) — render it as an attachment card.
                // Handled here rather than inline because the card is a block: nesting
                // a <div> inside a <p> would make the browser split the paragraph.
                // size/mime aren't in the Markdown; JoplinSyncEngine fills them in
                // from the resources table.
                // escapeAttribute, not escapeHtml: this value goes inside an attribute,
                // where an unescaped quote in a filename would end it early. And
                // unescapeMarkdown first, because the filename never passes through
                // inline() (which unescapes as its last step) — without it a file
                // called "team_icon.png" comes back as "team\_icon.png".
                html += "<div class=\"pm-attachment\" data-resource-id=\"\(m.groups[1])\" data-title=\"\(escapeAttribute(unescapeMarkdown(m.groups[0])))\" data-size=\"0\" data-mime=\"\"></div>\n"
                i += 1

            } else if line.trimmingCharacters(in: .whitespaces).lowercased().hasPrefix("<table") {
                // Raw HTML table passthrough. HtmlToMarkdown emits a manually-resized
                // table as raw HTML (pipe tables can't express column widths), so it
                // has to come back unescaped — otherwise escapeHtml would turn it into
                // literal "&lt;table&gt;" text in the note.
                var htmlLines: [String] = []
                while i < lines.count {
                    htmlLines.append(lines[i])
                    let closed = lines[i].lowercased().contains("</table>")
                    i += 1
                    if closed { break }
                }
                html += htmlLines.joined(separator: "\n") + "\n"

            } else if line.trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                var codeLines: [String] = []
                i += 1
                while i < lines.count && !lines[i].trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                    codeLines.append(lines[i])
                    i += 1
                }
                i += 1 // skip closing fence
                html += "<pre><code>" + escapeHtml(codeLines.joined(separator: "\n")) + "</code></pre>\n"

            } else if matches(hrRegex, line.trimmingCharacters(in: .whitespaces)) {
                html += "<hr>\n"
                i += 1

            } else if isTableStart(lines, i) {
                html += "<table>\n<tr>"
                for cell in splitTableRow(line) { html += "<th>" + inline(cell) + "</th>" }
                html += "</tr>\n"
                i += 2 // header row + separator row
                while i < lines.count && lines[i].contains("|") && !lines[i].trimmingCharacters(in: .whitespaces).isEmpty {
                    html += "<tr>"
                    for cell in splitTableRow(lines[i]) { html += "<td>" + inline(cell) + "</td>" }
                    html += "</tr>\n"
                    i += 1
                }
                html += "</table>\n"

            } else if let match = firstMatch(headingRegex, line) {
                let level = match.groups[0].count
                html += "<h\(level)>" + inline(match.groups[1]) + "</h\(level)>\n"
                i += 1

            } else if matches(blockquoteRegex, line) {
                var quoteLines: [String] = []
                while i < lines.count, let m = firstMatch(blockquoteRegex, lines[i]) {
                    quoteLines.append(m.groups[0])
                    i += 1
                }
                html += "<blockquote><p>" + inline(quoteLines.joined(separator: " ")) + "</p></blockquote>\n"

            } else if parseListLine(line) != nil {
                // One combined branch for bullet / ordered / checklist lists, gathering
                // the whole run of (possibly indented) list lines and reconstructing
                // nesting from their indentation — see renderListBlock. Previously each
                // list type had its own branch whose regex was anchored at column 0, so
                // an indented sub-bullet ("  - child") wasn't recognized as a list item
                // at all: it fell through to the paragraph branch and rendered as literal
                // "- child" text (and several sub-items merged into one "- a  - b"
                // paragraph). This is the nested-list round-trip bug.
                var items: [ListLine] = []
                while i < lines.count,
                      !lines[i].trimmingCharacters(in: .whitespaces).isEmpty,
                      let pl = parseListLine(lines[i]) {
                    items.append(pl)
                    i += 1
                }
                html += renderListBlock(items) + "\n"

            } else {
                var paragraphLines: [String] = []
                while i < lines.count && !lines[i].trimmingCharacters(in: .whitespaces).isEmpty &&
                    !matches(headingRegex, lines[i]) && parseListLine(lines[i]) == nil &&
                    !matches(blockquoteRegex, lines[i]) &&
                    !lines[i].trimmingCharacters(in: .whitespaces).hasPrefix("```") &&
                    !lines[i].trimmingCharacters(in: .whitespaces).lowercased().hasPrefix("<table") &&
                    firstMatch(attachmentLinkRegex, lines[i].trimmingCharacters(in: .whitespaces)) == nil &&
                    !matches(hrRegex, lines[i].trimmingCharacters(in: .whitespaces)) &&
                    !isTableStart(lines, i) {
                    paragraphLines.append(lines[i])
                    i += 1
                }
                html += "<p>" + inline(paragraphLines.joined(separator: " ")) + "</p>\n"
            }
        }

        return html.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Lists (nesting-aware)

    private enum ListKind { case bullet, ordered, checklist }
    private struct ListLine {
        let indent: Int
        let kind: ListKind
        let checked: Bool
        let text: String
    }

    /// Leading-whitespace width of a line (tab counts as 4). Used only to compare
    /// nesting depth between list items — the absolute value doesn't matter, only the
    /// relative ordering, so any consistent indent width (our own 2 spaces, Joplin
    /// desktop's 4, a tab) reconstructs the same nesting.
    private static func indentWidth(_ line: String) -> Int {
        var width = 0
        for ch in line {
            if ch == " " { width += 1 }
            else if ch == "\t" { width += 4 }
            else { break }
        }
        return width
    }

    /// Parses one line as a list item (allowing leading indentation), or nil if it
    /// isn't one. Checklist is tried first because "- [ ] x" also matches the plain
    /// bullet pattern.
    private static func parseListLine(_ line: String) -> ListLine? {
        let stripped = String(line.drop(while: { $0 == " " || $0 == "\t" }))
        let indent = indentWidth(line)
        if let m = firstMatch(checklistRegex, stripped) {
            return ListLine(indent: indent, kind: .checklist, checked: m.groups[1].lowercased() == "x", text: m.groups[2])
        }
        if let m = firstMatch(bulletRegex, stripped) {
            return ListLine(indent: indent, kind: .bullet, checked: false, text: m.groups[1])
        }
        if let m = firstMatch(orderedRegex, stripped) {
            return ListLine(indent: indent, kind: .ordered, checked: false, text: m.groups[1])
        }
        return nil
    }

    private static func listOpenTag(_ kind: ListKind) -> String {
        switch kind {
        case .checklist: return "<ul data-is-checklist=\"true\">"
        case .ordered:   return "<ol>"
        case .bullet:    return "<ul>"
        }
    }

    private static func listCloseTag(_ kind: ListKind) -> String {
        kind == .ordered ? "</ol>" : "</ul>"
    }

    private static func renderListItem(_ item: ListLine, child: String) -> String {
        let inner = inline(item.text)
        switch item.kind {
        case .checklist:
            // Class must be "md-checkbox" (checked: "md-checkbox checked") — that's what
            // schema.ts's task_list_item.parseDOM matches on; getting it wrong makes
            // ProseMirror parse these as plain list items.
            let cls = item.checked ? "md-checkbox checked" : "md-checkbox"
            let chk = item.checked ? " checked" : ""
            return "<li class=\"\(cls)\"><input type=\"checkbox\"\(chk)><div>\(inner)\(child)</div></li>"
        default:
            return "<li>\(inner)\(child)</li>"
        }
    }

    /// Rebuilds nested `<ul>/<ol>` HTML from a run of list lines, using each line's
    /// indentation to decide nesting: an item indented deeper than the one before it
    /// becomes a child list of it; a shallower item pops back out. A change of kind at
    /// the same indent starts a sibling list (e.g. a bullet after a checklist item).
    private static func renderListBlock(_ items: [ListLine]) -> String {
        var pos = 0

        func build(_ levelIndent: Int) -> String {
            var out = ""
            while pos < items.count && items[pos].indent >= levelIndent {
                let curIndent = items[pos].indent
                let curKind = items[pos].kind
                out += listOpenTag(curKind)
                while pos < items.count && items[pos].indent == curIndent && items[pos].kind == curKind {
                    let item = items[pos]
                    pos += 1
                    var child = ""
                    if pos < items.count && items[pos].indent > curIndent {
                        child = build(items[pos].indent)
                    }
                    out += renderListItem(item, child: child)
                }
                out += listCloseTag(curKind)
            }
            return out
        }

        // Seed with the block's MINIMUM indent, not the first item's: build()'s outer
        // loop only keeps items whose indent >= levelIndent, so if a later item in the
        // run is shallower than the first (e.g. a loose list split by a blank line, or
        // a stray indented item before a top-level one), seeding from the first item's
        // indent would silently drop it. The minimum guarantees every item is emitted.
        let minIndent = items.map { $0.indent }.min() ?? 0
        return build(minIndent)
    }

    /// Strips a leading YAML frontmatter block (e.g. from notes imported from other
    /// apps/exports) — a "---" line, some metadata lines, then a closing "---" line —
    /// which would otherwise render as a literal paragraph of "date: ..." text at the
    /// top of the note. Only touches text that actually opens AND closes with "---";
    /// leaves everything alone otherwise, to avoid eating real content on a false
    /// positive (e.g. a note that legitimately starts with a horizontal rule).
    private static func stripFrontmatter(_ markdown: String) -> String {
        var lines = markdown.components(separatedBy: "\n")
        guard lines.first?.trimmingCharacters(in: .whitespaces) == "---" else { return markdown }
        guard let closingIndex = lines.dropFirst().firstIndex(where: {
            $0.trimmingCharacters(in: .whitespaces) == "---"
        }) else { return markdown }
        lines.removeSubrange(0...closingIndex)
        return lines.joined(separator: "\n")
    }

    /// Inline formatting within a line/paragraph: images, links, bold, italic, code.
    private static func inline(_ text: String) -> String {
        var result = escapeHtml(text)
        result = replaceAll(imageRegex, result) { g in "<img src=\"\(g[1])\" alt=\"\(g[0])\">" }
        result = replaceAll(linkRegex, result) { g in "<a href=\"\(g[1])\">\(g[0])</a>" }
        result = replaceAll(boldRegex, result) { g in "<strong>\(g[0].isEmpty ? g[1] : g[0])</strong>" }
        result = replaceAll(highlightRegex, result) { g in "<mark>\(g[0])</mark>" }
        result = replaceAll(strikethroughRegex, result) { g in "<s>\(g[0])</s>" }
        result = replaceAll(italicRegex, result) { g in "<em>\(g[0].isEmpty ? g[1] : g[0])</em>" }
        result = replaceAll(inlineCodeRegex, result) { g in "<code>\(g[0])</code>" }
        // Last: turn "\_" back into "_" and so on. Must run after the emphasis passes
        // above, otherwise an escaped "\*" would be unescaped to "*" and then wrongly
        // parsed as emphasis.
        result = replaceAll(unescapeRegex, result) { g in g[0] }
        return result
    }

    /// A table's header row followed by a separator row of only |, -, :, and spaces
    /// (e.g. "| --- | :---: |"). GFM doesn't require leading/trailing pipes on rows.
    private static func isTableStart(_ lines: [String], _ index: Int) -> Bool {
        let line = lines[index]
        guard line.contains("|") else { return false }
        guard index + 1 < lines.count else { return false }
        return isTableSeparator(lines[index + 1])
    }

    private static func isTableSeparator(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.contains("|"), trimmed.contains("-") else { return false }
        return trimmed.allSatisfy { $0 == "|" || $0 == "-" || $0 == ":" || $0 == " " }
    }

    private static func splitTableRow(_ line: String) -> [String] {
        var trimmed = line.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("|") { trimmed.removeFirst() }
        if trimmed.hasSuffix("|") { trimmed.removeLast() }
        return trimmed.components(separatedBy: "|").map { $0.trimmingCharacters(in: .whitespaces) }
    }

    // Some Joplin clients (and browser-based Markdown editors) write a raw inline
    // "<br>" tag into the Markdown source for a line break within a paragraph —
    // valid Markdown (raw inline HTML passes through untouched), which every
    // Joplin client renders as an actual break. Our escapeHtml below escapes ALL
    // "<"/">" unconditionally though, so without this it turns into literal
    // "&lt;br&gt;" and shows up on screen as the text "<br>" instead of breaking
    // the line — this regex restores it to a real (unescaped) <br> afterward, which
    // the editor's `hard_break` schema node (parseDOM: [{ tag: 'br' }]) understands.
    private static let brRegex = try! NSRegularExpression(pattern: "&lt;br\\s*/?&gt;", options: [.caseInsensitive])

    /// Escapes a value going into an HTML attribute. escapeHtml below is for text
    /// content and leaves quotes alone, which would end an attribute early.
    /// Undoes HtmlToMarkdown.escapeMarkdown on a value that doesn't go through inline()
    /// — inline() does this itself as its last step, but block-level values like an
    /// attachment card's filename never reach it. Mirrors Android's MarkdownToHtml.
    private static func unescapeMarkdown(_ text: String) -> String {
        replaceAll(unescapeRegex, text) { g in g[0] }
    }

    private static func escapeAttribute(_ value: String) -> String {
        value
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }

    private static func escapeHtml(_ text: String) -> String {
        // Some Joplin clients write a literal "&nbsp;" entity into the Markdown source
        // to preserve an otherwise-empty line (a plain blank line would just be a
        // paragraph separator). Decode it to a plain space *before* escaping "&",
        // otherwise it becomes "&amp;nbsp;" and shows up as literal "&nbsp;" text
        // instead of rendering as blank space.
        let escaped = text.replacingOccurrences(of: "&nbsp;", with: " ")
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
        return replaceAll(brRegex, escaped) { _ in "<br>" }
    }

    // MARK: - NSRegularExpression helpers

    /// Kotlin's Regex.matches() requires the WHOLE string to match, which NSRegularExpression
    /// doesn't do by default — anchor at both ends ourselves via matching range == full range.
    private static func matches(_ regex: NSRegularExpression, _ line: String) -> Bool {
        let range = NSRange(line.startIndex..<line.endIndex, in: line)
        guard let match = regex.firstMatch(in: line, range: range) else { return false }
        return match.range == range
    }

    private struct MatchGroups {
        let groups: [String]
    }

    /// Returns capture groups (index 0-based, skipping the whole-match group 0) as
    /// empty strings instead of nil for unmatched alternation branches, mirroring
    /// Kotlin's MatchResult.groupValues.
    private static func firstMatch(_ regex: NSRegularExpression, _ line: String) -> MatchGroups? {
        let range = NSRange(line.startIndex..<line.endIndex, in: line)
        guard let match = regex.firstMatch(in: line, range: range), match.range == range else { return nil }
        var groups: [String] = []
        for g in 1..<match.numberOfRanges {
            if let r = Range(match.range(at: g), in: line) {
                groups.append(String(line[r]))
            } else {
                groups.append("")
            }
        }
        return MatchGroups(groups: groups)
    }

    private static func replaceAll(_ regex: NSRegularExpression, _ text: String, _ transform: ([String]) -> String) -> String {
        let nsText = text as NSString
        let fullRange = NSRange(location: 0, length: nsText.length)
        let matchesFound = regex.matches(in: text, range: fullRange)
        guard !matchesFound.isEmpty else { return text }

        var result = ""
        var lastEnd = 0
        for match in matchesFound {
            result += nsText.substring(with: NSRange(location: lastEnd, length: match.range.location - lastEnd))
            var groups: [String] = []
            for g in 1..<match.numberOfRanges {
                let r = match.range(at: g)
                groups.append(r.location == NSNotFound ? "" : nsText.substring(with: r))
            }
            result += transform(groups)
            lastEnd = match.range.location + match.range.length
        }
        result += nsText.substring(with: NSRange(location: lastEnd, length: nsText.length - lastEnd))
        return result
    }
}
