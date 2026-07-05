package com.ikuteam.notestn.data

import android.content.ContentValues
import android.content.Context
import android.database.Cursor
import android.database.sqlite.SQLiteDatabase
import android.database.sqlite.SQLiteOpenHelper
import java.io.File

/**
 * SQLite wrapper mirroring Mac/NotesTN/NotesTN/Database/DatabaseManager.swift.
 * Schema is Joplin-compatible so sync can be layered on later. Local-only for now,
 * called exclusively from NotesViewModel on a background dispatcher.
 */
class DatabaseManager private constructor(context: Context) :
    SQLiteOpenHelper(context.applicationContext, DB_NAME, null, DB_VERSION) {

    private val appContext = context.applicationContext

    init {
        setWriteAheadLoggingEnabled(true)
    }

    companion object {
        private const val DB_NAME = "notes.db"
        private const val DB_VERSION = 1

        @Volatile
        private var instance: DatabaseManager? = null

        fun init(context: Context) {
            if (instance == null) {
                synchronized(this) {
                    if (instance == null) instance = DatabaseManager(context)
                }
            }
        }

        val shared: DatabaseManager
            get() = instance ?: throw IllegalStateException(
                "DatabaseManager.init(context) must be called before use — see NotesTNApplication.onCreate()."
            )
    }

    // MARK: - Setup

    override fun onCreate(db: SQLiteDatabase) {
        db.execSQL(
            """
            CREATE TABLE IF NOT EXISTS folders (
                id TEXT PRIMARY KEY,
                title TEXT NOT NULL DEFAULT '',
                created_time INTEGER NOT NULL,
                updated_time INTEGER NOT NULL
            )
            """.trimIndent()
        )
        db.execSQL("CREATE INDEX IF NOT EXISTS folders_title ON folders (title)")
        db.execSQL("CREATE INDEX IF NOT EXISTS folders_updated_time ON folders (updated_time)")

        db.execSQL(
            """
            CREATE TABLE IF NOT EXISTS notes (
                id TEXT PRIMARY KEY,
                parent_id TEXT NOT NULL DEFAULT '',
                title TEXT NOT NULL DEFAULT '',
                body TEXT NOT NULL DEFAULT '',
                created_time INTEGER NOT NULL,
                updated_time INTEGER NOT NULL,
                is_conflict INTEGER NOT NULL DEFAULT 0,
                is_todo INTEGER NOT NULL DEFAULT 0,
                todo_due INTEGER NOT NULL DEFAULT 0,
                todo_completed INTEGER NOT NULL DEFAULT 0,
                source TEXT NOT NULL DEFAULT '',
                source_application TEXT NOT NULL DEFAULT 'com.ikuteam.notestn'
            )
            """.trimIndent()
        )
        db.execSQL("CREATE INDEX IF NOT EXISTS notes_parent_id ON notes (parent_id)")
        db.execSQL("CREATE INDEX IF NOT EXISTS notes_updated_time ON notes (updated_time)")
        db.execSQL("CREATE INDEX IF NOT EXISTS notes_is_todo ON notes (is_todo)")

        db.execSQL(
            """
            CREATE TABLE IF NOT EXISTS resources (
                id TEXT PRIMARY KEY,
                title TEXT NOT NULL DEFAULT '',
                mime TEXT NOT NULL DEFAULT '',
                filename TEXT NOT NULL DEFAULT '',
                file_size INTEGER NOT NULL DEFAULT 0,
                created_time INTEGER NOT NULL,
                updated_time INTEGER NOT NULL
            )
            """.trimIndent()
        )
        db.execSQL("CREATE INDEX IF NOT EXISTS resources_updated_time ON resources (updated_time)")

        db.execSQL(
            """
            CREATE TABLE IF NOT EXISTS note_resources (
                note_id TEXT NOT NULL,
                resource_id TEXT NOT NULL,
                PRIMARY KEY (note_id, resource_id)
            )
            """.trimIndent()
        )
    }

    override fun onUpgrade(db: SQLiteDatabase, oldVersion: Int, newVersion: Int) {
        // No migrations yet — schema hasn't changed since v1.
    }

    override fun onConfigure(db: SQLiteDatabase) {
        db.setForeignKeyConstraintsEnabled(true)
    }

    // MARK: - Resources directory

    /** Private app storage — analogous to ~/Library/Application Support/NotesTN/resources on Mac. */
    val resourcesDirectory: File
        get() = File(appContext.filesDir, "resources").apply { mkdirs() }

    // MARK: - Folders

    fun fetchFolders(): List<Folder> {
        val folders = mutableListOf<Folder>()
        readableDatabase.rawQuery(
            "SELECT id, title, created_time, updated_time FROM folders ORDER BY title ASC",
            null
        ).use { c ->
            while (c.moveToNext()) {
                folders.add(
                    Folder(
                        id = c.getString(0),
                        title = c.getString(1),
                        createdTime = c.getLong(2),
                        updatedTime = c.getLong(3),
                    )
                )
            }
        }
        return folders
    }

    fun saveFolder(folder: Folder) {
        val values = ContentValues().apply {
            put("id", folder.id)
            put("title", folder.title)
            put("created_time", folder.createdTime)
            put("updated_time", folder.updatedTime)
        }
        writableDatabase.insertWithOnConflict("folders", null, values, SQLiteDatabase.CONFLICT_REPLACE)
    }

    fun deleteFolder(id: String) {
        // Also delete all notes in the folder
        writableDatabase.delete("notes", "parent_id = ?", arrayOf(id))
        writableDatabase.delete("folders", "id = ?", arrayOf(id))
    }

    // MARK: - Notes

    fun fetchNotes(folderId: String? = null): List<Note> {
        val notes = mutableListOf<Note>()
        val sql = if (folderId != null) {
            """
            SELECT id, parent_id, title, body, created_time, updated_time, is_todo, todo_completed
            FROM notes
            WHERE parent_id = ? AND is_conflict = 0
            ORDER BY updated_time DESC
            """.trimIndent()
        } else {
            """
            SELECT id, parent_id, title, body, created_time, updated_time, is_todo, todo_completed
            FROM notes
            WHERE is_conflict = 0
            ORDER BY updated_time DESC
            """.trimIndent()
        }
        val args = if (folderId != null) arrayOf(folderId) else null
        readableDatabase.rawQuery(sql, args).use { c ->
            while (c.moveToNext()) notes.add(c.toNote())
        }
        return notes
    }

    fun saveNote(note: Note) {
        val values = ContentValues().apply {
            put("id", note.id)
            put("parent_id", note.folderId)
            put("title", note.title)
            put("body", note.body)
            put("created_time", note.createdTime)
            put("updated_time", note.updatedTime)
            put("is_todo", if (note.isTodo) 1 else 0)
            put("todo_completed", if (note.todoCompleted) 1 else 0)
            put("source_application", "com.ikuteam.notestn")
        }
        writableDatabase.insertWithOnConflict("notes", null, values, SQLiteDatabase.CONFLICT_REPLACE)
    }

    fun deleteNote(id: String) {
        writableDatabase.delete("notes", "id = ?", arrayOf(id))
    }

    fun searchNotes(query: String): List<Note> {
        val notes = mutableListOf<Note>()
        val pattern = "%$query%"
        readableDatabase.rawQuery(
            """
            SELECT id, parent_id, title, body, created_time, updated_time, is_todo, todo_completed
            FROM notes
            WHERE is_conflict = 0
              AND (title LIKE ? OR body LIKE ?)
            ORDER BY updated_time DESC
            LIMIT 200
            """.trimIndent(),
            arrayOf(pattern, pattern)
        ).use { c ->
            while (c.moveToNext()) notes.add(c.toNote())
        }
        return notes
    }

    private fun Cursor.toNote() = Note(
        id = getString(0),
        folderId = getString(1),
        title = getString(2),
        body = getString(3),
        createdTime = getLong(4),
        updatedTime = getLong(5),
        isTodo = getInt(6) != 0,
        todoCompleted = getInt(7) != 0,
    )

    // MARK: - Resources

    fun saveResource(resource: Resource) {
        val now = System.currentTimeMillis()
        val values = ContentValues().apply {
            put("id", resource.id)
            put("title", resource.title)
            put("mime", resource.mimeType)
            put("filename", resource.filename)
            put("file_size", resource.fileSize)
            put("created_time", now)
            put("updated_time", now)
        }
        writableDatabase.insertWithOnConflict("resources", null, values, SQLiteDatabase.CONFLICT_REPLACE)

        // Link resource to note
        val link = ContentValues().apply {
            put("note_id", resource.noteId)
            put("resource_id", resource.id)
        }
        writableDatabase.insertWithOnConflict("note_resources", null, link, SQLiteDatabase.CONFLICT_IGNORE)
    }

    fun deleteResource(id: String) {
        // Remove file from disk
        var filename = ""
        readableDatabase.rawQuery("SELECT filename FROM resources WHERE id = ?", arrayOf(id)).use { c ->
            if (c.moveToFirst()) filename = c.getString(0)
        }
        if (filename.isNotEmpty()) {
            File(resourcesDirectory, filename).delete()
        }
        writableDatabase.delete("note_resources", "resource_id = ?", arrayOf(id))
        writableDatabase.delete("resources", "id = ?", arrayOf(id))
    }
}
