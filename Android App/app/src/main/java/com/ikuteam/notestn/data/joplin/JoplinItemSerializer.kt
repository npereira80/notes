package com.ikuteam.notestn.data.joplin

import com.ikuteam.notestn.data.Folder
import com.ikuteam.notestn.data.Note
import com.ikuteam.notestn.data.Resource
import java.time.Instant
import java.time.ZoneOffset
import java.time.format.DateTimeFormatter

/**
 * Builds Joplin's plain-text item serialization (the reverse of JoplinItemParser) for
 * push sync: title, blank line, body, blank line, then `key: value` footer lines ending
 * in `type_`. Missing fields are safe — Joplin's own unserialize() only requires
 * `type_` and defaults everything else — so we only write the fields this app actually
 * tracks rather than every column Joplin's official clients use (confirmed against
 * packages/lib/BaseItem.ts serialize()/unserialize() before implementing this).
 */
object JoplinItemSerializer {

    private val isoFormatter = DateTimeFormatter
        .ofPattern("yyyy-MM-dd'T'HH:mm:ss.SSS'Z'")
        .withZone(ZoneOffset.UTC)

    fun serialize(note: Note): String {
        val markdown = HtmlToMarkdown.convert(note.body)
        val props = linkedMapOf(
            "id" to note.id,
            "parent_id" to note.folderId,
            "created_time" to formatTime(note.createdTime),
            "updated_time" to formatTime(note.updatedTime),
            "is_todo" to if (note.isTodo) "1" else "0",
            "todo_completed" to if (note.todoCompleted) "1" else "0",
            // Always Markdown (1), never HTML (2, Joplin's rich-text format) — we
            // always emit real Markdown here regardless of what markup_language the
            // note previously had. Leaving this out would let a note that started as
            // markup_language=2 keep that stale flag on the server while its body is
            // now Markdown text, which breaks rendering in Joplin's own clients.
            "markup_language" to "1",
            // Plain epoch-millis integer, NOT an ISO date string like created_time/
            // updated_time — deleted_time is an ordinary int field in Joplin, same as
            // is_todo/file_size, not one of the handful of fields Joplin formats as a
            // date. Written explicitly (never omitted) so "0" unambiguously means "not
            // trashed" to any reader.
            "deleted_time" to (note.deletedTime ?: 0L).toString(),
            // Standard Joplin has no native pinned-note field, so we stash it in
            // application_data — a real Joplin field meant for exactly this kind of
            // app-specific custom data, blank when unused (matches Joplin's own
            // convention). Whatever else might be in this field is not preserved —
            // acceptable here since this app is the only writer of it in practice.
            "application_data" to if (note.isPinned) "{\"pinned\":true}" else "",
            "type_" to "1",
        )
        return buildItem(note.title, markdown, props)
    }

    fun serialize(folder: Folder): String {
        val props = linkedMapOf(
            "id" to folder.id,
            "created_time" to formatTime(folder.createdTime),
            "updated_time" to formatTime(folder.updatedTime),
            "deleted_time" to (folder.deletedTime ?: 0L).toString(),
            "type_" to "2",
        )
        return buildItem(folder.title, "", props)
    }

    /** Resource (attachment/image) metadata item — the binary bytes go to a separate
     * `.resource/{id}` path (see JoplinCloudApi.putResourceBlob), this is just the
     * `{id}.md`-style metadata Joplin Server expects alongside it. Resource has no
     * createdTime/updatedTime of its own (unlike Note/Folder), so both are stamped as
     * "now" at push time — these are descriptive metadata only, never used by our own
     * pull logic for conflict resolution. */
    fun serialize(resource: Resource): String {
        val extension = resource.filename.substringAfterLast('.', missingDelimiterValue = "")
        val now = formatTime(System.currentTimeMillis())
        val props = linkedMapOf(
            "id" to resource.id,
            "mime" to resource.mimeType,
            "file_extension" to extension,
            "size" to resource.fileSize.toString(),
            "created_time" to now,
            "updated_time" to now,
            "type_" to "4",
        )
        return buildItem(resource.title, "", props)
    }

    /** No trailing newline after the last footer line — JoplinItemParser scans
     * backward for `key: value` lines and stops at the first line that doesn't match,
     * so a trailing blank line (from a trailing "\n") would end the scan before it
     * finds anything, silently dropping every property including the required type_. */
    private fun buildItem(title: String, body: String, props: Map<String, String>): String {
        val footer = props.entries.joinToString("\n") { (key, value) -> "$key: ${escapeValue(value)}" }
        return "$title\n\n$body\n\n$footer"
    }

    private fun formatTime(epochMillis: Long): String = isoFormatter.format(Instant.ofEpochMilli(epochMillis))

    // Footer lines are single-line key:value pairs — escape any embedded newlines,
    // matching BaseItem.serialize_format()'s \n -> \\n / \r -> \\r escaping.
    private fun escapeValue(value: String): String = value
        .replace("\\", "\\\\")
        .replace("\n", "\\n")
        .replace("\r", "\\r")
}
