package com.ikuteam.notestn.data

import java.util.UUID

/**
 * Mirrors Mac/NotesTN/NotesTN/Models/Note.swift. `body` is stored as HTML
 * (the ProseMirror editor's serialized output), same as the Mac app.
 */
data class Note(
    val id: String = generateId(),
    var folderId: String = "",
    var title: String = "",
    var body: String = "",
    var createdTime: Long = System.currentTimeMillis(),
    var updatedTime: Long = System.currentTimeMillis(),
    var isTodo: Boolean = false,
    var todoCompleted: Boolean = false,
) {
    companion object {
        // Joplin-compatible: 32-char lowercase hex, no hyphens
        fun generateId(): String = UUID.randomUUID().toString().replace("-", "").lowercase()
    }

    /** Plain-text preview extracted from the HTML body. Mirrors Note.swift `preview`. */
    val preview: String
        get() {
            if (body.isEmpty()) return ""
            val noTags = body.replace(Regex("<[^>]+>"), " ")
            val collapsed = noTags
                .split(Regex("\\s+"))
                .filter { it.isNotEmpty() }
                .joinToString(" ")
                .replace("&amp;", "&")
                .replace("&lt;", "<")
                .replace("&gt;", ">")
                .replace("&nbsp;", " ")
                .replace("&#39;", "'")
                .replace("&quot;", "\"")
                .trim()
            return collapsed.take(160)
        }
}
