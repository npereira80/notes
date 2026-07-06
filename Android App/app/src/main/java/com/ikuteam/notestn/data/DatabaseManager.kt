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
        private const val DB_VERSION = 5

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
                updated_time INTEGER NOT NULL,
                is_dirty INTEGER NOT NULL DEFAULT 0,
                is_synced INTEGER NOT NULL DEFAULT 0,
                deleted_time INTEGER NOT NULL DEFAULT 0
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
                source_application TEXT NOT NULL DEFAULT 'com.ikuteam.notestn',
                is_dirty INTEGER NOT NULL DEFAULT 0,
                is_synced INTEGER NOT NULL DEFAULT 0,
                deleted_time INTEGER NOT NULL DEFAULT 0,
                is_pinned INTEGER NOT NULL DEFAULT 0
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
                updated_time INTEGER NOT NULL,
                is_dirty INTEGER NOT NULL DEFAULT 0,
                is_synced INTEGER NOT NULL DEFAULT 0
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

        createPendingDeletesTable(db)
    }

    override fun onUpgrade(db: SQLiteDatabase, oldVersion: Int, newVersion: Int) {
        if (oldVersion < 2) {
            db.execSQL("ALTER TABLE folders ADD COLUMN is_dirty INTEGER NOT NULL DEFAULT 0")
            db.execSQL("ALTER TABLE folders ADD COLUMN is_synced INTEGER NOT NULL DEFAULT 0")
            db.execSQL("ALTER TABLE notes ADD COLUMN is_dirty INTEGER NOT NULL DEFAULT 0")
            db.execSQL("ALTER TABLE notes ADD COLUMN is_synced INTEGER NOT NULL DEFAULT 0")
            createPendingDeletesTable(db)
        }
        if (oldVersion < 3) {
            db.execSQL("ALTER TABLE resources ADD COLUMN is_dirty INTEGER NOT NULL DEFAULT 0")
            db.execSQL("ALTER TABLE resources ADD COLUMN is_synced INTEGER NOT NULL DEFAULT 0")
            // Existing rows predate this column and could be either pulled-from-server
            // or locally-inserted-but-never-pushed — we can't tell which after the fact.
            // Default to "already synced" (safer: guarantees a later removal queues a
            // remote delete) rather than "dirty" (which would just re-push identical
            // bytes the server likely already has for most rows).
            db.execSQL("UPDATE resources SET is_synced = 1")
        }
        if (oldVersion < 4) {
            // 0 = not trashed (matches Joplin's own deleted_time convention) — mapped
            // to/from Note.deletedTime / Folder.deletedTime's Long? at the app layer.
            db.execSQL("ALTER TABLE folders ADD COLUMN deleted_time INTEGER NOT NULL DEFAULT 0")
            db.execSQL("ALTER TABLE notes ADD COLUMN deleted_time INTEGER NOT NULL DEFAULT 0")
        }
        if (oldVersion < 5) {
            // Not a native Joplin column — mirrors the pinned flag we stash in each
            // note's application_data on the server (see JoplinItemSerializer/Parser).
            db.execSQL("ALTER TABLE notes ADD COLUMN is_pinned INTEGER NOT NULL DEFAULT 0")
        }
    }

    private fun createPendingDeletesTable(db: SQLiteDatabase) {
        // Remote deletions queued for the next push — populated when a note/folder that
        // was already known to Joplin Cloud (is_synced = 1) gets deleted locally, since
        // deleting the row also destroys the id we'd need to tell the server about it.
        db.execSQL(
            """
            CREATE TABLE IF NOT EXISTS pending_deletes (
                id TEXT PRIMARY KEY,
                item_type TEXT NOT NULL
            )
            """.trimIndent()
        )
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
            "SELECT id, title, created_time, updated_time, deleted_time FROM folders WHERE deleted_time = 0 ORDER BY title ASC",
            null
        ).use { c ->
            while (c.moveToNext()) folders.add(c.toFolder())
        }
        return folders
    }

    /** Every trashed notebook, most-recently-deleted first. */
    fun fetchTrashedFolders(): List<Folder> {
        val folders = mutableListOf<Folder>()
        readableDatabase.rawQuery(
            "SELECT id, title, created_time, updated_time, deleted_time FROM folders WHERE deleted_time != 0 ORDER BY deleted_time DESC",
            null
        ).use { c ->
            while (c.moveToNext()) folders.add(c.toFolder())
        }
        return folders
    }

    private fun Cursor.toFolder() = Folder(
        id = getString(0),
        title = getString(1),
        createdTime = getLong(2),
        updatedTime = getLong(3),
        deletedTime = getLong(4).takeIf { it != 0L },
    )

    /** Null if the folder doesn't exist locally yet. Used by sync to decide whether a
     * pulled remote item is newer than what's already stored. */
    fun folderUpdatedTime(id: String): Long? {
        readableDatabase.rawQuery("SELECT updated_time FROM folders WHERE id = ?", arrayOf(id)).use { c ->
            return if (c.moveToFirst()) c.getLong(0) else null
        }
    }

    /** Whether Joplin Cloud already knows about this folder (came from a pull, or was
     * pushed successfully at least once). False for a folder that only exists locally
     * — used to decide whether deleting it needs a remote delete queued too. */
    fun folderSyncedFlag(id: String): Boolean {
        readableDatabase.rawQuery("SELECT is_synced FROM folders WHERE id = ?", arrayOf(id)).use { c ->
            return c.moveToFirst() && c.getInt(0) != 0
        }
    }

    /** [dirty] = has local changes not yet pushed to Joplin Cloud. [synced] = Joplin
     * Cloud already knows about this id. Both are written explicitly on every save
     * (rather than defaulted) because INSERT OR REPLACE re-creates the whole row —
     * any column left out of [values] would silently reset to its table default. */
    fun saveFolder(folder: Folder, dirty: Boolean, synced: Boolean) {
        val values = ContentValues().apply {
            put("id", folder.id)
            put("title", folder.title)
            put("created_time", folder.createdTime)
            put("updated_time", folder.updatedTime)
            put("is_dirty", if (dirty) 1 else 0)
            put("is_synced", if (synced) 1 else 0)
            put("deleted_time", folder.deletedTime ?: 0L)
        }
        writableDatabase.insertWithOnConflict("folders", null, values, SQLiteDatabase.CONFLICT_REPLACE)
    }

    fun markFolderSynced(id: String) {
        val values = ContentValues().apply {
            put("is_dirty", 0)
            put("is_synced", 1)
        }
        writableDatabase.update("folders", values, "id = ?", arrayOf(id))
    }

    fun fetchDirtyFolders(): List<Folder> {
        val folders = mutableListOf<Folder>()
        readableDatabase.rawQuery(
            "SELECT id, title, created_time, updated_time, deleted_time FROM folders WHERE is_dirty = 1",
            null
        ).use { c ->
            while (c.moveToNext()) folders.add(c.toFolder())
        }
        return folders
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
            SELECT id, parent_id, title, body, created_time, updated_time, is_todo, todo_completed, deleted_time, is_pinned
            FROM notes
            WHERE parent_id = ? AND is_conflict = 0 AND deleted_time = 0
            ORDER BY updated_time DESC
            """.trimIndent()
        } else {
            """
            SELECT id, parent_id, title, body, created_time, updated_time, is_todo, todo_completed, deleted_time, is_pinned
            FROM notes
            WHERE is_conflict = 0 AND deleted_time = 0
            ORDER BY updated_time DESC
            """.trimIndent()
        }
        val args = if (folderId != null) arrayOf(folderId) else null
        readableDatabase.rawQuery(sql, args).use { c ->
            while (c.moveToNext()) notes.add(c.toNote())
        }
        return notes
    }

    /** Every trashed note across all notebooks, most-recently-deleted first. */
    fun fetchTrashedNotes(): List<Note> {
        val notes = mutableListOf<Note>()
        readableDatabase.rawQuery(
            """
            SELECT id, parent_id, title, body, created_time, updated_time, is_todo, todo_completed, deleted_time, is_pinned
            FROM notes
            WHERE deleted_time != 0
            ORDER BY deleted_time DESC
            """.trimIndent(),
            null
        ).use { c ->
            while (c.moveToNext()) notes.add(c.toNote())
        }
        return notes
    }

    /** Null if the note doesn't exist locally yet. Used by sync to decide whether a
     * pulled remote item is newer than what's already stored. */
    fun noteUpdatedTime(id: String): Long? {
        readableDatabase.rawQuery("SELECT updated_time FROM notes WHERE id = ?", arrayOf(id)).use { c ->
            return if (c.moveToFirst()) c.getLong(0) else null
        }
    }

    /** Whether Joplin Cloud already knows about this note (came from a pull, or was
     * pushed successfully at least once). False for a note that only exists locally
     * — used to decide whether deleting it needs a remote delete queued too. */
    fun noteSyncedFlag(id: String): Boolean {
        readableDatabase.rawQuery("SELECT is_synced FROM notes WHERE id = ?", arrayOf(id)).use { c ->
            return c.moveToFirst() && c.getInt(0) != 0
        }
    }

    /** [dirty] = has local changes not yet pushed to Joplin Cloud. [synced] = Joplin
     * Cloud already knows about this id. Both are written explicitly on every save
     * (rather than defaulted) because INSERT OR REPLACE re-creates the whole row —
     * any column left out of [values] would silently reset to its table default. */
    fun saveNote(note: Note, dirty: Boolean, synced: Boolean) {
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
            put("is_dirty", if (dirty) 1 else 0)
            put("is_synced", if (synced) 1 else 0)
            put("deleted_time", note.deletedTime ?: 0L)
            put("is_pinned", if (note.isPinned) 1 else 0)
        }
        writableDatabase.insertWithOnConflict("notes", null, values, SQLiteDatabase.CONFLICT_REPLACE)
    }

    fun markNoteSynced(id: String) {
        val values = ContentValues().apply {
            put("is_dirty", 0)
            put("is_synced", 1)
        }
        writableDatabase.update("notes", values, "id = ?", arrayOf(id))
    }

    fun fetchDirtyNotes(): List<Note> {
        val notes = mutableListOf<Note>()
        readableDatabase.rawQuery(
            """
            SELECT id, parent_id, title, body, created_time, updated_time, is_todo, todo_completed, deleted_time, is_pinned
            FROM notes
            WHERE is_dirty = 1
            """.trimIndent(),
            null
        ).use { c ->
            while (c.moveToNext()) notes.add(c.toNote())
        }
        return notes
    }

    fun deleteNote(id: String) {
        writableDatabase.delete("notes", "id = ?", arrayOf(id))
    }

    // MARK: - Pending remote deletes

    fun queueDelete(id: String, itemType: String) {
        val values = ContentValues().apply {
            put("id", id)
            put("item_type", itemType)
        }
        writableDatabase.insertWithOnConflict("pending_deletes", null, values, SQLiteDatabase.CONFLICT_REPLACE)
    }

    /** Pairs of (id, itemType) — itemType is "note" or "folder". */
    fun fetchPendingDeletes(): List<Pair<String, String>> {
        val result = mutableListOf<Pair<String, String>>()
        readableDatabase.rawQuery("SELECT id, item_type FROM pending_deletes", null).use { c ->
            while (c.moveToNext()) result.add(c.getString(0) to c.getString(1))
        }
        return result
    }

    fun clearPendingDelete(id: String) {
        writableDatabase.delete("pending_deletes", "id = ?", arrayOf(id))
    }

    fun searchNotes(query: String): List<Note> {
        val notes = mutableListOf<Note>()
        val pattern = "%$query%"
        readableDatabase.rawQuery(
            """
            SELECT id, parent_id, title, body, created_time, updated_time, is_todo, todo_completed, deleted_time, is_pinned
            FROM notes
            WHERE is_conflict = 0 AND deleted_time = 0
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
        deletedTime = getLong(8).takeIf { it != 0L },
        isPinned = getInt(9) != 0,
    )

    // MARK: - Resources

    /** Local WebView URL for an already-synced resource, or null if it hasn't been
     * downloaded yet. Used to rewrite Joplin's `:/resourceId` links into something the
     * editor's WebView can actually load — see EditorWebView's asset loader mapping. */
    fun resourceLocalUrl(id: String): String? {
        readableDatabase.rawQuery("SELECT filename FROM resources WHERE id = ?", arrayOf(id)).use { c ->
            if (!c.moveToFirst()) return null
            return "https://appassets.androidplatform.net/resources/${c.getString(0)}"
        }
    }

    /** Local file for an already-synced resource, or null if it hasn't been
     * downloaded yet — for contexts needing an actual file (e.g. loading a note-list
     * thumbnail with Coil), unlike [resourceLocalUrl] which returns a WebView-only
     * virtual URL. */
    fun resourceLocalFile(id: String): File? {
        readableDatabase.rawQuery("SELECT filename FROM resources WHERE id = ?", arrayOf(id)).use { c ->
            if (!c.moveToFirst()) return null
            return File(resourcesDirectory, c.getString(0))
        }
    }

    fun resourceExists(id: String): Boolean {
        readableDatabase.rawQuery("SELECT 1 FROM resources WHERE id = ?", arrayOf(id)).use { c ->
            return c.moveToFirst()
        }
    }

    /** [dirty] = has local bytes not yet pushed to Joplin Cloud. [synced] = Joplin Cloud
     * already knows about this id. Same explicit-write rule as saveNote/saveFolder. */
    fun saveResource(resource: Resource, dirty: Boolean, synced: Boolean) {
        val now = System.currentTimeMillis()
        val values = ContentValues().apply {
            put("id", resource.id)
            put("title", resource.title)
            put("mime", resource.mimeType)
            put("filename", resource.filename)
            put("file_size", resource.fileSize)
            put("created_time", now)
            put("updated_time", now)
            put("is_dirty", if (dirty) 1 else 0)
            put("is_synced", if (synced) 1 else 0)
        }
        writableDatabase.insertWithOnConflict("resources", null, values, SQLiteDatabase.CONFLICT_REPLACE)

        // Link resource to note
        val link = ContentValues().apply {
            put("note_id", resource.noteId)
            put("resource_id", resource.id)
        }
        writableDatabase.insertWithOnConflict("note_resources", null, link, SQLiteDatabase.CONFLICT_IGNORE)
    }

    fun resourceSyncedFlag(id: String): Boolean {
        readableDatabase.rawQuery("SELECT is_synced FROM resources WHERE id = ?", arrayOf(id)).use { c ->
            return c.moveToFirst() && c.getInt(0) != 0
        }
    }

    fun markResourceSynced(id: String) {
        val values = ContentValues().apply {
            put("is_dirty", 0)
            put("is_synced", 1)
        }
        writableDatabase.update("resources", values, "id = ?", arrayOf(id))
    }

    fun fetchDirtyResources(): List<Resource> {
        val resources = mutableListOf<Resource>()
        readableDatabase.rawQuery(
            "SELECT id, title, mime, filename, file_size FROM resources WHERE is_dirty = 1",
            null
        ).use { c ->
            while (c.moveToNext()) {
                resources.add(
                    Resource(
                        id = c.getString(0),
                        title = c.getString(1),
                        mimeType = c.getString(2),
                        filename = c.getString(3),
                        fileSize = c.getLong(4),
                        noteId = "",
                    )
                )
            }
        }
        return resources
    }

    /** Removes just the note<->resource link, without touching the resource row itself
     * — used when an image is removed from a note's body but the note stays alive. */
    fun unlinkNoteResource(noteId: String, resourceId: String) {
        writableDatabase.delete("note_resources", "note_id = ? AND resource_id = ?", arrayOf(noteId, resourceId))
    }

    fun isResourceReferenced(id: String): Boolean {
        readableDatabase.rawQuery("SELECT 1 FROM note_resources WHERE resource_id = ? LIMIT 1", arrayOf(id)).use { c ->
            return c.moveToFirst()
        }
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
