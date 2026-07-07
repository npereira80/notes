package com.ikuteam.notestn.data.joplin

/**
 * Minimal Markdown -> HTML converter for notes pulled from Joplin Cloud (notes there
 * are stored as Markdown; our editor works in HTML — see Note.body doc comment).
 * Not a full CommonMark implementation — covers headings, bold/italic, inline code,
 * code fences, links, images, lists (incl. checkboxes), blockquotes, and paragraphs,
 * matching what Mac/EditorBundle's ProseMirror schema + CSS actually render.
 */
object MarkdownToHtml {

    private val boldRegex = Regex("\\*\\*(.+?)\\*\\*|__(.+?)__")
    private val italicRegex = Regex("(?<!\\*)\\*(?!\\*)(.+?)\\*(?!\\*)|(?<!_)_(?!_)(.+?)_(?!_)")
    private val inlineCodeRegex = Regex("`([^`]+)`")
    private val imageRegex = Regex("!\\[([^\\]]*)]\\(([^)]+)\\)")
    private val linkRegex = Regex("\\[([^\\]]+)]\\(([^)]+)\\)")
    private val headingRegex = Regex("^(#{1,6})\\s+(.*)$")
    private val checklistRegex = Regex("^([-*])\\s+\\[( |x|X)]\\s+(.*)$")
    private val bulletRegex = Regex("^([-*])\\s+(.*)$")
    private val orderedRegex = Regex("^(\\d+)\\.\\s+(.*)$")
    private val blockquoteRegex = Regex("^>\\s?(.*)$")
    // Matches "---", "***", "___" but also spaced variants like "* * *" or "- - -",
    // which is what was making horizontal rules disappear (or get misread as a
    // bulleted list item, since "* * *" also matches a "* " bullet prefix).
    private val hrRegex = Regex("^([-*_])(\\s*\\1){2,}\\s*$")

    fun convert(markdown: String): String {
        val lines = stripFrontmatter(markdown.replace("\r\n", "\n")).split("\n")
        val html = StringBuilder()

        var i = 0
        while (i < lines.size) {
            val line = lines[i]

            when {
                line.isBlank() -> i++

                line.trimStart().startsWith("```") -> {
                    val codeLines = mutableListOf<String>()
                    i++
                    while (i < lines.size && !lines[i].trimStart().startsWith("```")) {
                        codeLines.add(lines[i])
                        i++
                    }
                    i++ // skip closing fence
                    html.append("<pre><code>").append(escapeHtml(codeLines.joinToString("\n"))).append("</code></pre>\n")
                }

                hrRegex.matches(line.trim()) -> {
                    html.append("<hr>\n")
                    i++
                }

                isTableStart(lines, i) -> {
                    html.append("<table>\n<tr>")
                    splitTableRow(line).forEach { cell -> html.append("<th>").append(inline(cell)).append("</th>") }
                    html.append("</tr>\n")
                    i += 2 // header row + separator row
                    while (i < lines.size && lines[i].contains('|') && lines[i].isNotBlank()) {
                        html.append("<tr>")
                        splitTableRow(lines[i]).forEach { cell -> html.append("<td>").append(inline(cell)).append("</td>") }
                        html.append("</tr>\n")
                        i++
                    }
                    html.append("</table>\n")
                }

                headingRegex.matches(line) -> {
                    val match = headingRegex.find(line)!!
                    val level = match.groupValues[1].length
                    html.append("<h$level>").append(inline(match.groupValues[2])).append("</h$level>\n")
                    i++
                }

                blockquoteRegex.matches(line) -> {
                    val quoteLines = mutableListOf<String>()
                    while (i < lines.size && blockquoteRegex.matches(lines[i])) {
                        quoteLines.add(blockquoteRegex.find(lines[i])!!.groupValues[1])
                        i++
                    }
                    html.append("<blockquote><p>").append(inline(quoteLines.joinToString(" "))).append("</p></blockquote>\n")
                }

                checklistRegex.matches(line) -> {
                    html.append("<ul data-is-checklist=\"true\">\n")
                    while (i < lines.size && checklistRegex.matches(lines[i])) {
                        val match = checklistRegex.find(lines[i])!!
                        val checked = match.groupValues[2].lowercase() == "x"
                        val text = inline(match.groupValues[3])
                        if (checked) {
                            html.append("<li class=\"checked\"><input type=\"checkbox\" checked><div>").append(text).append("</div></li>\n")
                        } else {
                            html.append("<li><input type=\"checkbox\"><div>").append(text).append("</div></li>\n")
                        }
                        i++
                    }
                    html.append("</ul>\n")
                }

                bulletRegex.matches(line) -> {
                    html.append("<ul>\n")
                    while (i < lines.size && bulletRegex.matches(lines[i])) {
                        html.append("<li>").append(inline(bulletRegex.find(lines[i])!!.groupValues[2])).append("</li>\n")
                        i++
                    }
                    html.append("</ul>\n")
                }

                orderedRegex.matches(line) -> {
                    html.append("<ol>\n")
                    while (i < lines.size && orderedRegex.matches(lines[i])) {
                        html.append("<li>").append(inline(orderedRegex.find(lines[i])!!.groupValues[2])).append("</li>\n")
                        i++
                    }
                    html.append("</ol>\n")
                }

                else -> {
                    val paragraphLines = mutableListOf<String>()
                    while (i < lines.size && lines[i].isNotBlank() &&
                        !headingRegex.matches(lines[i]) && !bulletRegex.matches(lines[i]) &&
                        !orderedRegex.matches(lines[i]) && !blockquoteRegex.matches(lines[i]) &&
                        !lines[i].trimStart().startsWith("```") && !hrRegex.matches(lines[i].trim()) &&
                        !isTableStart(lines, i)
                    ) {
                        paragraphLines.add(lines[i])
                        i++
                    }
                    html.append("<p>").append(inline(paragraphLines.joinToString(" "))).append("</p>\n")
                }
            }
        }

        return html.toString().trim()
    }

    /**
     * Strips a leading YAML frontmatter block (e.g. from notes imported from other
     * apps/exports) — a "---" line, some metadata lines, then a closing "---" line —
     * which would otherwise render as a literal paragraph of "date: ..." text at the
     * top of the note. Only touches text that actually opens AND closes with "---";
     * leaves everything alone otherwise, to avoid eating real content on a false
     * positive (e.g. a note that legitimately starts with a horizontal rule).
     */
    private fun stripFrontmatter(markdown: String): String {
        val lines = markdown.split("\n")
        if (lines.firstOrNull()?.trim() != "---") return markdown
        val closingIndex = lines.drop(1).indexOfFirst { it.trim() == "---" }
        if (closingIndex == -1) return markdown
        // +1 to account for the drop(1) offset, +1 again since indices are inclusive.
        return lines.subList(closingIndex + 2, lines.size).joinToString("\n")
    }

    /** Inline formatting within a line/paragraph: images, links, bold, italic, code. */
    private fun inline(text: String): String {
        var result = escapeHtml(text)
        result = imageRegex.replace(result) { m -> "<img src=\"${m.groupValues[2]}\" alt=\"${m.groupValues[1]}\">" }
        result = linkRegex.replace(result) { m -> "<a href=\"${m.groupValues[2]}\">${m.groupValues[1]}</a>" }
        result = boldRegex.replace(result) { m -> "<strong>${m.groupValues[1].ifEmpty { m.groupValues[2] }}</strong>" }
        result = italicRegex.replace(result) { m -> "<em>${m.groupValues[1].ifEmpty { m.groupValues[2] }}</em>" }
        result = inlineCodeRegex.replace(result) { m -> "<code>${m.groupValues[1]}</code>" }
        return result
    }

    /** A table's header row followed by a separator row of only |, -, :, and spaces
     * (e.g. "| --- | :---: |"). GFM doesn't require leading/trailing pipes on rows. */
    private fun isTableStart(lines: List<String>, index: Int): Boolean {
        val line = lines[index]
        if (!line.contains('|')) return false
        if (index + 1 >= lines.size) return false
        return isTableSeparator(lines[index + 1])
    }

    private fun isTableSeparator(line: String): Boolean {
        val trimmed = line.trim()
        if (!trimmed.contains('|') || !trimmed.contains('-')) return false
        return trimmed.all { it == '|' || it == '-' || it == ':' || it == ' ' }
    }

    private fun splitTableRow(line: String): List<String> {
        var trimmed = line.trim()
        if (trimmed.startsWith("|")) trimmed = trimmed.substring(1)
        if (trimmed.endsWith("|")) trimmed = trimmed.substring(0, trimmed.length - 1)
        return trimmed.split("|").map { it.trim() }
    }

    // Some Joplin clients (and browser-based Markdown editors) write a raw inline
    // "<br>" tag into the Markdown source for a line break within a paragraph —
    // valid Markdown (raw inline HTML passes through untouched), which every
    // Joplin client renders as an actual break. escapeHtml below escapes ALL
    // "<"/">" unconditionally though, so without this it turns into literal
    // "&lt;br&gt;" and shows up on screen as the text "<br>" instead of breaking
    // the line — this regex restores it to a real (unescaped) <br> afterward, which
    // the editor's `hard_break` schema node (parseDOM: [{ tag: 'br' }]) understands.
    private val brRegex = Regex("&lt;br\\s*/?&gt;", RegexOption.IGNORE_CASE)

    private fun escapeHtml(text: String): String {
        val escaped = text
            // Some Joplin clients write a literal "&nbsp;" entity into the Markdown source
            // to preserve an otherwise-empty line (a plain blank line would just be a
            // paragraph separator). Decode it to a real non-breaking space *before*
            // escaping "&", otherwise it becomes "&amp;nbsp;" and shows up as literal
            // "&nbsp;" text instead of rendering as blank space.
            .replace("&nbsp;", "\u00A0")
            .replace("&", "&amp;")
            .replace("<", "&lt;")
            .replace(">", "&gt;")
        return brRegex.replace(escaped, "<br>")
    }
}
