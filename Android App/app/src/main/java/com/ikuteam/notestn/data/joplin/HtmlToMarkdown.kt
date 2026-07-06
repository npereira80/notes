package com.ikuteam.notestn.data.joplin

import org.jsoup.Jsoup
import org.jsoup.nodes.Element
import org.jsoup.nodes.Node
import org.jsoup.nodes.TextNode

/**
 * Reverse of MarkdownToHtml.kt: converts the editor's ProseMirror-produced HTML body
 * back into Joplin-compatible Markdown for push sync. Covers the same ground
 * MarkdownToHtml already round-trips (headings, bold/italic/code, links, images, lists
 * incl. checkboxes, blockquotes, horizontal rules, tables) plus best-effort encoding
 * for strikethrough/sub/sup/highlight/toggle blocks that the toolbar can produce but
 * MarkdownToHtml doesn't parse back yet — those stay correct for other Joplin clients,
 * they just won't re-render with formatting the next time *this* app pulls them.
 *
 * Uses Jsoup for real DOM parsing/traversal — a regex approach (like MarkdownToHtml's
 * line-based one, which works because Markdown is already line-oriented) isn't a good
 * fit for reversing nested HTML like lists and tables.
 */
object HtmlToMarkdown {

    private val resourceUrlRegex = Regex("""^https://appassets\.androidplatform\.net/resources/([0-9a-fA-F]{32})\.[^./]+$""")

    fun convert(html: String): String {
        val body = Jsoup.parseBodyFragment(html).body()
        val blocks = body.children().joinToString("\n\n") { renderBlock(it) }
        return blocks.trim() + "\n"
    }

    private fun renderBlock(el: Element): String {
        return when (el.tagName()) {
            "p" -> renderInline(el)

            "h1", "h2", "h3", "h4", "h5", "h6" -> {
                val level = el.tagName().substring(1).toInt()
                "${"#".repeat(level)} ${renderInline(el)}"
            }

            "pre" -> {
                val code = el.selectFirst("code")?.wholeText() ?: el.wholeText()
                "```\n$code\n```"
            }

            "blockquote" -> el.children().joinToString("\n\n") { renderBlock(it) }
                .lines().joinToString("\n") { if (it.isEmpty()) ">" else "> $it" }

            "hr" -> "---"

            "ul" -> if (el.attr("data-is-checklist") == "true") renderChecklist(el) else renderBulletList(el)

            "ol" -> renderOrderedList(el)

            "table" -> renderTable(el)

            "details" -> el.outerHtml() // no Markdown equivalent — pass through as raw HTML

            else -> renderInline(el)
        }
    }

    private fun renderBulletList(ul: Element): String =
        ul.children().filter { it.tagName() == "li" }.joinToString("\n") { li -> renderListItem(li, "-") }

    private fun renderOrderedList(ol: Element): String {
        val start = ol.attr("start").toIntOrNull() ?: 1
        return ol.children().filter { it.tagName() == "li" }.mapIndexed { index, li ->
            renderListItem(li, "${start + index}.")
        }.joinToString("\n")
    }

    private fun renderChecklist(ul: Element): String =
        ul.children().filter { it.tagName() == "li" }.joinToString("\n") { li ->
            val checked = li.selectFirst("input[type=checkbox]")?.hasAttr("checked") == true
            val marker = if (checked) "[x]" else "[ ]"
            val contentHost = li.selectFirst("div") ?: li
            "- $marker ${renderListItemContent(contentHost)}"
        }

    /** A list item's first block is its own text; any further blocks (nested lists,
     * extra paragraphs) are rendered below it, indented — real Joplin/CommonMark
     * renderers understand nested indented lists even though MarkdownToHtml.kt's
     * simple line-based parser doesn't reconstruct the nesting on pull. */
    private fun renderListItem(li: Element, marker: String): String {
        val first = "$marker ${renderListItemContent(li)}"
        val rest = li.children().drop(1).joinToString("\n") { child ->
            renderBlock(child).lines().joinToString("\n") { "  $it" }
        }
        return if (rest.isEmpty()) first else "$first\n$rest"
    }

    private fun renderListItemContent(host: Element): String {
        val firstBlock = host.children().firstOrNull { it.tagName() == "p" } ?: host
        return renderInline(firstBlock)
    }

    private fun renderTable(table: Element): String {
        val rows = table.select("tr")
        if (rows.isEmpty()) return ""
        val header = rows.first()!!.children().map { renderInline(it) }
        val separator = header.map { "---" }
        val body = rows.drop(1).map { row -> row.children().map { renderInline(it) } }

        fun rowLine(cells: List<String>) = "| ${cells.joinToString(" | ")} |"
        val lines = mutableListOf(rowLine(header), rowLine(separator))
        body.forEach { lines.add(rowLine(it)) }
        return lines.joinToString("\n")
    }

    /** Inline formatting within a block: images, links, bold, italic, code, etc. Spans
     * with no Markdown meaning (e.g. the heading arrow/content wrapper spans ProseMirror
     * emits) are unwrapped, not dropped, so their text content isn't lost. */
    private fun renderInline(el: Element): String {
        val sb = StringBuilder()
        for (node in el.childNodes()) renderInlineNode(node, sb)
        return sb.toString()
    }

    private fun renderInlineNode(node: Node, sb: StringBuilder) {
        when (node) {
            is TextNode -> sb.append(escapeMarkdown(node.text()))
            is Element -> sb.append(renderInlineElement(node))
        }
    }

    private fun renderInlineElement(el: Element): String = when (el.tagName()) {
        "strong", "b" -> "**${renderInline(el)}**"
        "em", "i" -> "*${renderInline(el)}*"
        "code" -> "`${el.text()}`"
        "s", "del", "strike" -> "~~${renderInline(el)}~~"
        "sub" -> "<sub>${renderInline(el)}</sub>"
        "sup" -> "<sup>${renderInline(el)}</sup>"
        "mark" -> "==${renderInline(el)}=="
        "a" -> "[${renderInline(el)}](${el.attr("href")})"
        "img" -> "![${el.attr("alt")}](${resourceLink(el)})"
        "br" -> "\n"
        else -> renderInline(el) // e.g. the heading wrapper spans — unwrap, keep text
    }

    /** Local images are stored as https://appassets.androidplatform.net/resources/{id}.ext
     * (see EditorScreen.copyImageIntoResources / JoplinSyncEngine.rewriteResourceLinks) —
     * convert back to Joplin's `:/resourceId` syntax so other Joplin clients can resolve
     * the image. Falls back to the raw src for anything that isn't a local resource. */
    private fun resourceLink(img: Element): String {
        img.attr("data-resource-id").takeIf { it.isNotBlank() }?.let { return ":/$it" }
        val src = img.attr("src")
        resourceUrlRegex.find(src)?.let { return ":/${it.groupValues[1]}" }
        return src
    }

    private fun escapeMarkdown(text: String): String = text
        .replace("\\", "\\\\")
        .replace("*", "\\*")
        .replace("_", "\\_")
        .replace("`", "\\`")
        .replace("[", "\\[")
        .replace("]", "\\]")
}
