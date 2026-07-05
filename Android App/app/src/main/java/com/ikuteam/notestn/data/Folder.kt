package com.ikuteam.notestn.data

import java.util.UUID

/** Mirrors Mac/NotesTN/NotesTN/Models/Folder.swift (a "notebook"). */
data class Folder(
    val id: String = generateId(),
    var title: String = "",
    var createdTime: Long = System.currentTimeMillis(),
    var updatedTime: Long = System.currentTimeMillis(),
) {
    companion object {
        fun generateId(): String = UUID.randomUUID().toString().replace("-", "").lowercase()
    }
}
