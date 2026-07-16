package com.ikuteam.notestn.data

/** Mirrors Mac/NotesTN/NotesTN/Models/Resource.swift (an image attachment). */
data class Resource(
    val id: String,
    val title: String,
    val mimeType: String,
    val filename: String,
    val fileSize: Long,
    val noteId: String, // which note owns this resource (for note_resources table)
)
