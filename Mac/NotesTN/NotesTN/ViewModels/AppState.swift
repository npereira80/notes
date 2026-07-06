import SwiftUI
import Combine

@MainActor
final class AppState: ObservableObject {

    // MARK: - Published state

    @Published var folders: [Folder] = []
    @Published var notes: [Note] = []
    @Published var trashedNotes: [Note] = []
    @Published var trashedFolders: [Folder] = []
    @Published var isTrashSelected: Bool = false
    @Published var selectedFolderID: String? = nil     // nil = "All Notes"
    @Published var selectedNoteID: String? = nil
    @Published var searchText: String = ""
    @Published var isFocusingSearch: Bool = false
    @Published var isShowingJoplinLogin: Bool = false
    @Published private(set) var isSyncing: Bool = false
    @Published var syncError: String? = nil

    // MARK: - Derived

    var selectedNote: Note? {
        notes.first { $0.id == selectedNoteID } ?? trashedNotes.first { $0.id == selectedNoteID }
    }

    var selectedFolder: Folder? {
        folders.first { $0.id == selectedFolderID }
    }

    private let db = DatabaseManager.shared
    private let selectedNoteKey = "lastSelectedNoteID"
    private let syncEngine = JoplinSyncEngine()
    private var cancellables = Set<AnyCancellable>()

    // MARK: - Init

    init() {
        loadAll()
        restoreSelection()
        purgeExpiredTrash()
        loadAll()

        // Fires once immediately with whatever account state already exists (so an
        // already-logged-in user gets synced on launch), and again any time a login
        // happens later — JoplinAccountStore is a singleton, so this sees every login
        // regardless of where it happened.
        JoplinAccountStore.shared.$account
            .sink { [weak self] account in
                if account != nil { self?.syncNow() }
            }
            .store(in: &cancellables)
    }

    // MARK: - Joplin Cloud sync (pull + push, see JoplinSyncEngine)

    // Set when syncNow() is called while a sync is already running (e.g. the
    // debounced push after an edit lands mid pull-to-refresh) — without this, that
    // call used to just no-op and the edit's dirty note/resource would sit unpushed
    // until something else happened to trigger another sync. Rerun once the current
    // sync finishes instead of dropping it.
    private var syncRerunRequested = false

    func syncNow(force: Bool = false) {
        guard !isSyncing else {
            syncRerunRequested = true
            return
        }
        guard let account = JoplinAccountStore.shared.account else {
            syncError = "Not logged in to Joplin Cloud."
            return
        }
        isSyncing = true
        syncError = nil
        Task {
            let outcome = await syncEngine.sync(sessionId: account.sessionId, force: force)
            switch outcome {
            case .success:
                loadAll()
            case .failure(let message):
                syncError = message
            }
            isSyncing = false
            if syncRerunRequested {
                syncRerunRequested = false
                syncNow()
            }
        }
    }

    // MARK: - Push debounce

    private var pushDebounceTask: Task<Void, Never>?

    /// Schedules a push shortly after a local edit, mirroring the editor's own
    /// local-save debounce so we're not opening a network request on every keystroke.
    /// A no-op when logged out — otherwise every edit before ever logging in would
    /// surface a spurious "Not logged in" sync error.
    private func schedulePushDebounce() {
        guard JoplinAccountStore.shared.account != nil else { return }
        pushDebounceTask?.cancel()
        pushDebounceTask = Task {
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            guard !Task.isCancelled else { return }
            syncNow()
        }
    }

    // Restores the previously selected note, falling back to the first note.
    // Only called once at launch — subsequent loadNotes() calls leave selection intact.
    private func restoreSelection() {
        guard !notes.isEmpty else { return }
        let saved = UserDefaults.standard.string(forKey: selectedNoteKey)
        if let saved, notes.contains(where: { $0.id == saved }) {
            selectedNoteID = saved
        } else {
            selectedNoteID = notes.first?.id
        }
    }

    // MARK: - Load

    func loadAll() {
        folders = db.fetchFolders()
        trashedFolders = db.fetchTrashedFolders()
        loadNotes()
    }

    func loadNotes() {
        if !searchText.isEmpty {
            notes = db.searchNotes(query: searchText)
        } else {
            notes = db.fetchNotes(folderId: selectedFolderID)
        }
        trashedNotes = db.fetchTrashedNotes()
    }

    // MARK: - Folder actions

    func selectFolder(_ folder: Folder?) {
        isTrashSelected = false
        selectedFolderID = folder?.id
        selectedNoteID = nil
        loadNotes()
    }

    func selectTrash() {
        // selectedFolderID is left untouched here — SidebarView routes the Trash row
        // through the same List(selection:) binding as every other row (via a sentinel
        // tag), so it's already been set correctly by the time this runs.
        isTrashSelected = true
        selectedNoteID = nil
    }

    func createFolder(title: String = "New Notebook") {
        let folder = Folder(title: title)
        // New folder, never seen by Joplin Cloud yet — dirty so it gets pushed, not
        // synced since the server doesn't know about it.
        db.saveFolder(folder, dirty: true, synced: false)
        loadAll()
        selectedFolderID = folder.id
        schedulePushDebounce()
    }

    func renameFolder(_ folder: Folder, to title: String) {
        guard !title.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        var updated = folder
        updated.title = title
        updated.updatedTime = Date()
        // Preserve whatever synced state the folder already had — only is_dirty
        // changes here; INSERT OR REPLACE would otherwise reset is_synced to 0.
        db.saveFolder(updated, dirty: true, synced: db.folderSyncedFlag(id: folder.id))
        loadAll()
        schedulePushDebounce()
    }

    /// Soft delete: moves the notebook and every note inside it to Trash (matches real
    /// Joplin's own delete-to-trash behavior). Reversible via restoreFolder() until
    /// someone permanently deletes it, or 90 days pass (see purgeExpiredTrash()).
    func deleteFolder(_ folder: Folder) {
        let now = Date()
        var updated = folder
        updated.deletedTime = now
        updated.updatedTime = now
        db.saveFolder(updated, dirty: true, synced: db.folderSyncedFlag(id: folder.id))
        for note in db.fetchNotes(folderId: folder.id) {
            var updatedNote = note
            updatedNote.deletedTime = now
            updatedNote.updatedTime = now
            db.saveNote(updatedNote, dirty: true, synced: db.noteSyncedFlag(id: note.id))
        }
        if selectedFolderID == folder.id {
            selectedFolderID = nil
            selectedNoteID = nil
        }
        loadAll()
        schedulePushDebounce()
    }

    /// Un-trashes the notebook and every trashed note inside it.
    func restoreFolder(_ folder: Folder) {
        let now = Date()
        var updated = folder
        updated.deletedTime = nil
        updated.updatedTime = now
        db.saveFolder(updated, dirty: true, synced: db.folderSyncedFlag(id: folder.id))
        for note in db.fetchTrashedNotes().filter({ $0.folderId == folder.id }) {
            var updatedNote = note
            updatedNote.deletedTime = nil
            updatedNote.updatedTime = now
            db.saveNote(updatedNote, dirty: true, synced: db.noteSyncedFlag(id: note.id))
        }
        loadAll()
        schedulePushDebounce()
    }

    /// Unrecoverable: hard-deletes the notebook, every note inside it, and their
    /// resources, queuing remote deletes for anything Joplin Cloud already knew about.
    func permanentlyDeleteFolder(_ folder: Folder) {
        permanentlyDeleteFolderNow(folder)
        if selectedFolderID == folder.id {
            selectedFolderID = nil
            selectedNoteID = nil
        }
        loadAll()
        schedulePushDebounce()
    }

    // MARK: - Note actions

    func selectNote(_ note: Note?) {
        selectedNoteID = note?.id
        UserDefaults.standard.set(note?.id, forKey: selectedNoteKey)
    }

    func createNote() {
        // Joplin has no "notebook-less note" concept — every real client always
        // resolves to a concrete folder id before saving. A note pushed with
        // parent_id = "" (which is what "All Notes" selected means locally) doesn't
        // show up in Joplin's per-notebook views. Fall back to an existing folder, or
        // create one, rather than ever pushing an empty parent_id.
        let folderId = selectedFolderID ?? ensureAnyFolder()
        let note = Note(
            folderId: folderId,
            title: "New Note",
            body: ""
        )
        // New note, never seen by Joplin Cloud yet — dirty so it gets pushed, not
        // synced since the server doesn't know about it.
        db.saveNote(note, dirty: true, synced: false)
        loadAll()
        selectedNoteID = note.id
        UserDefaults.standard.set(note.id, forKey: selectedNoteKey)
        schedulePushDebounce()
    }

    /// Returns an existing folder's id, or creates a default one if there are none.
    private func ensureAnyFolder() -> String {
        if let existing = db.fetchFolders().first { return existing.id }
        let folder = Folder(title: "Notes")
        db.saveFolder(folder, dirty: true, synced: false)
        return folder.id
    }

    func saveNote(_ note: Note) {
        let previousBody = notes.first(where: { $0.id == note.id })?.body
        var updated = note
        updated.updatedTime = Date()
        // Preserve whatever synced state the note already had — only is_dirty changes
        // here; INSERT OR REPLACE would otherwise reset is_synced to 0.
        db.saveNote(updated, dirty: true, synced: db.noteSyncedFlag(id: note.id))
        // An image removed from the body (but the note itself kept) leaves an orphaned
        // resource behind — clean it up the same way a deleted note's resources are
        // cleaned up below.
        if let previousBody {
            unlinkRemovedResources(noteId: note.id, oldBody: previousBody, newBody: updated.body)
        }
        // Refresh list without losing selection
        notes = db.fetchNotes(folderId: selectedFolderID)
        schedulePushDebounce()
    }

    /// Soft delete: moves the note to Trash (matches real Joplin's own delete-to-trash
    /// behavior). Reversible via restoreNote() until someone permanently deletes it, or
    /// 90 days pass (see purgeExpiredTrash()). Resources are left alone — they're only
    /// cleaned up once the note is actually gone for good.
    func deleteNote(_ note: Note) {
        let now = Date()
        var updated = note
        updated.deletedTime = now
        updated.updatedTime = now
        db.saveNote(updated, dirty: true, synced: db.noteSyncedFlag(id: note.id))
        if selectedNoteID == note.id {
            selectedNoteID = nil
        }
        loadAll()
        schedulePushDebounce()
    }

    /// Un-trashes the note, leaving its notebook assignment untouched.
    func restoreNote(_ note: Note) {
        var updated = note
        updated.deletedTime = nil
        updated.updatedTime = Date()
        db.saveNote(updated, dirty: true, synced: db.noteSyncedFlag(id: note.id))
        loadAll()
        schedulePushDebounce()
    }

    /// Toggles the note's pinned state (see Note.isPinned's doc comment on how this
    /// syncs via application_data).
    func togglePin(_ note: Note) {
        var updated = note
        updated.isPinned.toggle()
        updated.updatedTime = Date()
        db.saveNote(updated, dirty: true, synced: db.noteSyncedFlag(id: note.id))
        loadAll()
        schedulePushDebounce()
    }

    /// Unrecoverable: hard-deletes the note and cleans up any resources it referenced
    /// that no other note still links to, queuing a remote delete for anything Joplin
    /// Cloud already knew about.
    func permanentlyDeleteNote(_ note: Note) {
        permanentlyDeleteNoteNow(note)
        if selectedNoteID == note.id {
            selectedNoteID = nil
        }
        loadAll()
        schedulePushDebounce()
    }

    /// Permanently deletes everything currently in Trash — notebooks first (each one
    /// cascades its own notes), then any note trashed individually whose notebook wasn't.
    func emptyTrash() {
        for folder in trashedFolders { permanentlyDeleteFolderNow(folder) }
        for note in db.fetchTrashedNotes() { permanentlyDeleteNoteNow(note) }
        selectedNoteID = nil
        loadAll()
        schedulePushDebounce()
    }

    // Matches Joplin's own default trash retention period.
    private static let trashRetentionSeconds: TimeInterval = 90 * 24 * 60 * 60

    /// Sweeps Trash for anything past the 90-day retention window and permanently
    /// deletes it — mirrors Joplin's own default auto-purge. Runs once at launch (see
    /// init), before the first sync, so a stale trashed item doesn't sit around forever
    /// just because the app wasn't opened for a while.
    private func purgeExpiredTrash() {
        let cutoff = Date().addingTimeInterval(-Self.trashRetentionSeconds)
        for folder in db.fetchTrashedFolders() {
            guard let deletedTime = folder.deletedTime else { continue }
            if deletedTime < cutoff { permanentlyDeleteFolderNow(folder) }
        }
        for note in db.fetchTrashedNotes() {
            guard let deletedTime = note.deletedTime else { continue }
            if deletedTime < cutoff { permanentlyDeleteNoteNow(note) }
        }
    }

    /// Core shared by permanentlyDeleteFolder/emptyTrash/purgeExpiredTrash — the public
    /// permanentlyDeleteFolder() wraps this with UI-state cleanup.
    private func permanentlyDeleteFolderNow(_ folder: Folder) {
        if db.folderSyncedFlag(id: folder.id) { db.queueDelete(id: folder.id, itemType: "folder") }
        // Every note in this folder, trashed or not — a permanent folder delete cascades
        // regardless of a note's own trash state.
        let notesInFolder = (db.fetchNotes(folderId: folder.id) + db.fetchTrashedNotes().filter { $0.folderId == folder.id })
        var seen = Set<String>()
        for note in notesInFolder where seen.insert(note.id).inserted {
            if db.noteSyncedFlag(id: note.id) { db.queueDelete(id: note.id, itemType: "note") }
            unlinkRemovedResources(noteId: note.id, oldBody: note.body, newBody: "")
        }
        db.deleteFolder(id: folder.id)
    }

    /// Core shared by permanentlyDeleteNote/emptyTrash/purgeExpiredTrash.
    private func permanentlyDeleteNoteNow(_ note: Note) {
        if db.noteSyncedFlag(id: note.id) { db.queueDelete(id: note.id, itemType: "note") }
        db.deleteNote(id: note.id)
        unlinkRemovedResources(noteId: note.id, oldBody: note.body, newBody: "")
    }

    private static let resourceIdRegex = try! NSRegularExpression(pattern: "data-resource-id=\"([0-9a-fA-F]{32})\"")

    private func extractResourceIds(_ html: String) -> Set<String> {
        let range = NSRange(html.startIndex..<html.endIndex, in: html)
        var ids = Set<String>()
        Self.resourceIdRegex.enumerateMatches(in: html, range: range) { match, _, _ in
            guard let match, let idRange = Range(match.range(at: 1), in: html) else { return }
            ids.insert(String(html[idRange]))
        }
        return ids
    }

    /// Unlinks any resource referenced in [oldBody] but not [newBody] from [noteId], and
    /// if that leaves the resource unreferenced by any note, deletes it locally and
    /// queues a remote delete if Joplin Cloud already knew about it. Called with
    /// newBody = "" to cascade every resource a deleted note referenced.
    private func unlinkRemovedResources(noteId: String, oldBody: String, newBody: String) {
        let removed = extractResourceIds(oldBody).subtracting(extractResourceIds(newBody))
        for resourceId in removed {
            db.unlinkNoteResource(noteId: noteId, resourceId: resourceId)
            if !db.isResourceReferenced(id: resourceId) {
                if db.resourceSyncedFlag(id: resourceId) { db.queueDelete(id: resourceId, itemType: "resource") }
                db.deleteResource(id: resourceId)
            }
        }
    }

    // MARK: - Search

    func search(_ query: String) {
        searchText = query
        loadNotes()
    }

    func clearSearch() {
        searchText = ""
        loadNotes()
    }
}
