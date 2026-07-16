package com.ikuteam.notestn.data

import androidx.compose.runtime.Immutable
import java.util.UUID

/**
 * Mirrors Mac/NotesTN/NotesTN/Models/Note.swift. `body` is stored as HTML
 * (the ProseMirror editor's serialized output), same as the Mac app.
 */
// All properties are val (not var) — every update site already goes through copy().
// This matters for performance, not just style: Compose infers stability from the
// class shape, and var fields made Note "unstable", so NoteRow could never skip
// recomposition — every list emission re-composed every visible row. @Immutable
// states it explicitly (the lazy delegates below would otherwise make the
// inference fall back to unstable again — they're pure caches of val state, so
// the promise holds).
@Immutable
data class Note(
    val id: String = generateId(),
    val folderId: String = "",
    val title: String = "",
    val body: String = "",
    val createdTime: Long = System.currentTimeMillis(),
    val updatedTime: Long = System.currentTimeMillis(),
    val isTodo: Boolean = false,
    val todoCompleted: Boolean = false,
    val deletedTime: Long? = null,
    // Not a native Joplin field (standard Joplin has no pinned-note concept) — stored
    // in the note's own application_data JSON, a real Joplin field meant for exactly
    // this kind of app-specific custom state, so it round-trips safely through Joplin
    // Cloud sync. See JoplinItemSerializer/JoplinItemParser.
    val isPinned: Boolean = false,
) {
    companion object {
        // Joplin-compatible: 32-char lowercase hex, no hyphens
        fun generateId(): String = UUID.randomUUID().toString().replace("-", "").lowercase()

        private val tagRegex = Regex("<[^>]+>")
        private val whitespaceRegex = Regex("\\s+")
        private val imgTagRegex = Regex("<img\\b[^>]*>")
        private val resourceIdAttrRegex = Regex("""data-resource-id="([^"]*)"""")
        private val srcResourceIdRegex = Regex("""src="[^"]*/([0-9a-fA-F]{32})\.[A-Za-z0-9]+"""")
    }

    /** Plain-text preview extracted from the HTML body. Mirrors Note.swift `preview`.
     * Lazy (computed at most once per instance) — this runs regexes over the entire
     * HTML body, and the note list used to re-run it per visible row on every
     * recomposition, which is a large share of the list's scroll/typing jank. Safe to
     * memoize now that `body` is a val. */
    val preview: String by lazy {
        if (body.isEmpty()) return@lazy ""
        val noTags = body.replace(tagRegex, " ")
        val collapsed = noTags
            .split(whitespaceRegex)
            .filter { it.isNotEmpty() }
            .joinToString(" ")
            .replace("&amp;", "&")
            .replace("&lt;", "<")
            .replace("&gt;", ">")
            .replace("&nbsp;", " ")
            .replace("&#39;", "'")
            .replace("&quot;", "\"")
            .trim()
        collapsed.take(160)
    }

    /** Resource id of the first image in the body, or null if there is none — used
     * for the note list's thumbnail (mirrors Apple Notes' list row thumbnail).
     * Lazy for the same reason as [preview]. */
    val firstImageResourceId: String? by lazy {
        val imgTag = imgTagRegex.find(body)?.value ?: return@lazy null

        // Locally-inserted/pasted images carry this explicitly (see EditorScreen's
        // image-insert path → EditorBridge → the ProseMirror image node's
        // data-resource-id attribute).
        resourceIdAttrRegex.find(imgTag)?.groupValues?.get(1)
            ?.takeIf { it.isNotBlank() }
            ?.let { return@lazy it }

        // Images pulled from Joplin Cloud never get that attribute — MarkdownToHtml
        // and JoplinSyncEngine's rewriteResourceLinks both just rewrite `src` to a
        // local WebView URL, no data-resource-id. Every resource is saved locally
        // as "<resourceId>.<ext>" (see DatabaseManager.saveResource), so recover the
        // id from the src path's last component instead of requiring the attribute.
        srcResourceIdRegex.find(imgTag)?.groupValues?.get(1)
    }
}
