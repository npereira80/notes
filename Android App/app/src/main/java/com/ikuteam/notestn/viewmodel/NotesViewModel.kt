package com.ikuteam.notestn.viewmodel

import android.app.Application
import androidx.lifecycle.AndroidViewModel
import androidx.lifecycle.viewModelScope
import com.ikuteam.notestn.data.DatabaseManager
import com.ikuteam.notestn.data.Folder
import com.ikuteam.notestn.data.Note
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.SharingStarted
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.combine
import kotlinx.coroutines.flow.stateIn
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

/**
 * Mirrors Mac/NotesTN/NotesTN/ViewModels/AppState.swift.
 *
 * DB calls are the same synchronous SQLite operations as the Mac app, but are
 * pushed to Dispatchers.IO here since Android disallows disk I/O on the main thread.
 */
class NotesViewModel(application: Application) : AndroidViewModel(application) {

    private val db = DatabaseManager.shared
    private val prefs = application.getSharedPreferences("notestn_prefs", Application.MODE_PRIVATE)
    private val selectedNoteKey = "lastSelectedNoteID"

    // MARK: - Published state

    private val _folders = MutableStateFlow<List<Folder>>(emptyList())
    val folders: StateFlow<List<Folder>> = _folders.asStateFlow()

    private val _notes = MutableStateFlow<List<Note>>(emptyList())
    val notes: StateFlow<List<Note>> = _notes.asStateFlow()

    private val _selectedFolderId = MutableStateFlow<String?>(null) // null = "All Notes"
    val selectedFolderId: StateFlow<String?> = _selectedFolderId.asStateFlow()

    private val _selectedNoteId = MutableStateFlow<String?>(null)
    val selectedNoteId: StateFlow<String?> = _selectedNoteId.asStateFlow()

    private val _searchText = MutableStateFlow("")
    val searchText: StateFlow<String> = _searchText.asStateFlow()

    private val _isFocusingSearch = MutableStateFlow(false)
    val isFocusingSearch: StateFlow<Boolean> = _isFocusingSearch.asStateFlow()

    // MARK: - Derived

    val selectedNote: StateFlow<Note?> = combine(_notes, _selectedNoteId) { notes, id ->
        notes.firstOrNull { it.id == id }
    }.stateIn(viewModelScope, SharingStarted.Eagerly, null)

    val selectedFolder: StateFlow<Folder?> = combine(_folders, _selectedFolderId) { folders, id ->
        folders.firstOrNull { it.id == id }
    }.stateIn(viewModelScope, SharingStarted.Eagerly, null)

    // MARK: - Init

    init {
        viewModelScope.launch {
            loadAll()
            restoreSelection()
        }
    }

    // Restores the previously selected note, falling back to the first note.
    // Only called once at launch — subsequent loadNotes() calls leave selection intact.
    private fun restoreSelection() {
        val current = _notes.value
        if (current.isEmpty()) return
        val saved = prefs.getString(selectedNoteKey, null)
        _selectedNoteId.value = if (saved != null && current.any { it.id == saved }) saved else current.first().id
    }

    // MARK: - Load

    private suspend fun loadAll() {
        _folders.value = withContext(Dispatchers.IO) { db.fetchFolders() }
        loadNotes()
    }

    private suspend fun loadNotes() {
        _notes.value = withContext(Dispatchers.IO) {
            val query = _searchText.value
            if (query.isNotEmpty()) db.searchNotes(query) else db.fetchNotes(_selectedFolderId.value)
        }
    }

    // MARK: - Folder actions

    fun selectFolder(folder: Folder?) {
        _selectedFolderId.value = folder?.id
        _selectedNoteId.value = null
        viewModelScope.launch { loadNotes() }
    }

    fun createFolder(title: String = "New Notebook") {
        viewModelScope.launch {
            val folder = Folder(title = title)
            withContext(Dispatchers.IO) { db.saveFolder(folder) }
            loadAll()
            _selectedFolderId.value = folder.id
        }
    }

    fun renameFolder(folder: Folder, title: String) {
        if (title.isBlank()) return
        viewModelScope.launch {
            val updated = folder.copy(title = title, updatedTime = System.currentTimeMillis())
            withContext(Dispatchers.IO) { db.saveFolder(updated) }
            loadAll()
        }
    }

    fun deleteFolder(folder: Folder) {
        viewModelScope.launch {
            withContext(Dispatchers.IO) { db.deleteFolder(folder.id) }
            if (_selectedFolderId.value == folder.id) {
                _selectedFolderId.value = null
                _selectedNoteId.value = null
            }
            loadAll()
        }
    }

    // MARK: - Note actions

    fun selectNote(note: Note?) {
        _selectedNoteId.value = note?.id
        prefs.edit().putString(selectedNoteKey, note?.id).apply()
    }

    fun createNote() {
        viewModelScope.launch {
            val note = Note(folderId = _selectedFolderId.value ?: "", title = "New Note", body = "")
            withContext(Dispatchers.IO) { db.saveNote(note) }
            loadNotes()
            _selectedNoteId.value = note.id
            prefs.edit().putString(selectedNoteKey, note.id).apply()
        }
    }

    fun saveNote(note: Note) {
        viewModelScope.launch {
            val updated = note.copy(updatedTime = System.currentTimeMillis())
            withContext(Dispatchers.IO) { db.saveNote(updated) }
            // Refresh list without losing selection
            _notes.value = withContext(Dispatchers.IO) { db.fetchNotes(_selectedFolderId.value) }
        }
    }

    fun deleteNote(note: Note) {
        viewModelScope.launch {
            withContext(Dispatchers.IO) { db.deleteNote(note.id) }
            if (_selectedNoteId.value == note.id) _selectedNoteId.value = null
            loadNotes()
        }
    }

    // MARK: - Search

    fun search(query: String) {
        _searchText.value = query
        viewModelScope.launch { loadNotes() }
    }

    fun clearSearch() {
        _searchText.value = ""
        viewModelScope.launch { loadNotes() }
    }

    // MARK: - Search focus request (Ctrl+F parity — see NotesTNApp.swift Find… command)

    fun requestFocusSearch() {
        _isFocusingSearch.value = true
    }

    fun consumeFocusSearch() {
        _isFocusingSearch.value = false
    }
}
