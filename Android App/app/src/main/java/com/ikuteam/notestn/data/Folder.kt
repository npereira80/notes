package com.ikuteam.notestn.data

import androidx.compose.runtime.Immutable
import java.util.UUID

/** Mirrors Mac/NotesTN/NotesTN/Models/Folder.swift (a "notebook").
 * All properties are val + @Immutable for the same Compose-stability reason as
 * [Note] — var fields made the class unstable, forcing sidebar rows to re-compose
 * on every list emission. Every update site already goes through copy(). */
@Immutable
data class Folder(
    val id: String = generateId(),
    val title: String = "",
    val createdTime: Long = System.currentTimeMillis(),
    val updatedTime: Long = System.currentTimeMillis(),
    val deletedTime: Long? = null,
) {
    companion object {
        fun generateId(): String = UUID.randomUUID().toString().replace("-", "").lowercase()
    }
}
