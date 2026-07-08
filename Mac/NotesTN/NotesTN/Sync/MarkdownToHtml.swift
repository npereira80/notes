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
    private static let italicRegex = try! NSRegularExpression(pattern: "(?<!\\*)\\*(?!\\*)(.+?)\\*(?!\\*)|(?<!_)_(?!_)(.+?)_(?!_)")
    private static let inlineCodeRegex = try! NSRegularExpression(pattern: "`([^`]+)`")
    private static let imageRegex = try! NSRegularExpression(pattern: "!\\[([^\\]]*)\\]\\(([^)]+)\\)")
    private static let linkRegex = try! NSRegularExpression(pattern: "\\[([^\\]]+)\\]\\(([^)]+)\\)")
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

            } else if matches(checklistRegex, line) {
                html += "<ul data-is-checklist=\"true\">\n"
                while i < lines.count, let m = firstMatch(checklistRegex, lines[i]) {
                    let checked = m.groups[1].lowercased() == "x"
                    let text = inline(m.groups[2])
                    if checked {
                        html += "<li class=\"checked\"><input type=\"checkbox\" checked><div>" + text + "</div></li>\n"
                    } else {
                        html += "<li><input type=\"checkbox\"><div>" + text + "</div></li>\n"
                    }
                    i += 1
                }
                html += "</ul>\n"

            } else if matches(bulletRegex, line) {
                html += "<ul>\n"
                while i < lines.count, let m = firstMatch(bulletRegex, lines[i]) {
                    html += "<li>" + inline(m.groups[1]) + "</li>\n"
                    i += 1
                }
                html += "</ul>\n"

            } else if matches(orderedRegex, line) {
                html += "<ol>\n"
                while i < lines.count, let m = firstMatch(orderedRegex, lines[i]) {
                    html += "<li>" + inline(m.groups[1]) + "</li>\n"
                    i += 1
                }
                html += "</ol>\n"

            } else {
                var paragraphLines: [String] = []
                while i < lines.count && !lines[i].trimmingCharacters(in: .whitespaces).isEmpty &&
                    !matches(headingRegex, lines[i]) && !matches(bulletRegex, lines[i]) &&
                    !matches(orderedRegex, lines[i]) && !matches(blockquoteRegex, lines[i]) &&
                    !lines[i].trimmingCharacters(in: .whitespaces).hasPrefix("```") &&
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
