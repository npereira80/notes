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
    var deletedTime: Long? = null,
    // Not a native Joplin field (standard Joplin has no pinned-note concept) — stored
    // in the note's own application_data JSON, a real Joplin field meant for exactly
    // this kind of app-specific custom state, so it round-trips safely through Joplin
    // Cloud sync. See JoplinItemSerializer/JoplinItemParser.
    var isPinned: Boolean = false,
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

    /** Resource id of the first image in the body, or null if there is none — used
     * for the note list's thumbnail (mirrors Apple Notes' list row thumbnail). */
    val firstImageResourceId: String?
        get() {
            val imgTag = Regex("<img\\b[^>]*>").find(body)?.value ?: return null
            return Regex("""data-resource-id="([^"]*)"""").find(imgTag)?.groupValues?.get(1)?.takeIf { it.isNotBlank() }
        }
}
