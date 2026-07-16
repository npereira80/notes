package com.ikuteam.notestn.data.joplin

import java.time.Instant
import java.time.format.DateTimeParseException

/**
 * Parses Joplin's plain-text item serialization: title, blank line, body, blank line,
 * then a footer of `key: value` metadata lines (see BaseItem.serialize() in Joplin's
 * source). We don't know the exact footer key set ahead of time, so we scan from the
 * bottom collecting contiguous `key: value` lines instead of matching a fixed list.
 */
object JoplinItemParser {

    data class ParsedItem(val title: String, val body: String, val props: Map<String, String>)

    private val propertyLine = Regex("^([a-z_]+): ?(.*)$")

    fun parse(raw: String): ParsedItem {
        val lines = raw.replace("\r\n", "\n").split("\n")

        // Walk backward from the end collecting the metadata footer: as long as a line
        // matches "key: value", it's part of the footer; the first line that doesn't
        // (blank separator or actual content) ends the scan.
        var footerStart = lines.size
        for (index in lines.indices.reversed()) {
            if (!propertyLine.matches(lines[index])) break
            footerStart = index
        }

        val props = linkedMapOf<String, String>()
        for (index in footerStart until lines.size) {
            val match = propertyLine.find(lines[index]) ?: continue
            props[match.groupValues[1]] = match.groupValues[2]
        }

        // Everything above the footer (minus the blank separator line right before it)
        // is title + blank line + body.
        val aboveFooter = lines.subList(0, footerStart).let {
            if (it.isNotEmpty() && it.last().isBlank()) it.subList(0, it.size - 1) else it
        }
        val title = aboveFooter.firstOrNull().orEmpty()
        val body = if (aboveFooter.size > 1) {
            // Skip the blank line that separates title from body.
            aboveFooter.drop(1).let { if (it.isNotEmpty() && it.first().isBlank()) it.drop(1) else it }
                .joinToString("\n").trim()
        } else {
            ""
        }

        return ParsedItem(title = title, body = body, props = props)
    }

    /** Joplin serializes timestamps as ISO-8601 (e.g. "2021-08-07T17:03:33.592Z"),
     * we store epoch millis locally. Falls back to now if unparseable/missing. */
    fun parseTime(value: String?): Long {
        if (value.isNullOrBlank()) return System.currentTimeMillis()
        return try {
            Instant.parse(value).toEpochMilli()
        } catch (_: DateTimeParseException) {
            System.currentTimeMillis()
        }
    }
}
