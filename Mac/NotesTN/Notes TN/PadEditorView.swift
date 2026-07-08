import SwiftUI

// iPad-only. Fresh rebuild (per request) — no custom formatting toolbar/embedded
// toolbar row yet, just the bare WKWebView editor. New Note lives only in
// PadNoteListView.swift's toolbar now (was duplicated here too before — removed per
// request). Not shared with iPhone (EditorView.swift's NoteEditorView) or Mac (its own
// EditorView.swift). Reuses EditorCoordinator/RichTextEditorView from
// EditorView.swift, though — that's the WKWebView/ProseMirror JS bridge, which is
// infrastructure identical across every platform, not UI chrome that should differ
// per idiom. Goal for now is just validating the 3-column NavigationSplitView's
// resize/collapse behavior — the formatting toolbar is a follow-up once that's
// confirmed working.
struct PadEditorView: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        Group {
            if let note = appState.selectedNote {
                PadNoteEditorView(note: note, readOnly: appState.isTrashSelected)
                    .id(note.id)
            } else {
                emptyState
            }
        }
        // System default search bar, same appState.searchText/search(_:) binding
        // PadNoteListView's own .searchable uses — kept regardless of which branch
        // above is showing, so it's always available in this column's toolbar.
        .searchable(
            text: Binding(get: { appState.searchText }, set: { appState.search($0) }),
            placement: .toolbar,
            prompt: "Search"
        )
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "square.and.pencil")
                .font(.system(size: 48))
                .foregroundStyle(.quaternary)
            Text("Select or create a note")
                .foregroundStyle(.secondary)
            Button("New Note") { appState.createNote() }
                .tint(Color.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(.systemBackground))
    }
}

private struct PadNoteEditorView: View {
    @EnvironmentObject var appState: AppState
    @StateObject private var editorCoordinator = EditorCoordinator()

    private let noteID: String
    private let initialTitle: String
    private let initialBody: String
    private let readOnly: Bool

    init(note: Note, readOnly: Bool = false) {
        self.noteID = note.id
        self.initialTitle = note.title
        self.initialBody = note.body
        self.readOnly = readOnly
    }

    var body: some View {
        RichTextEditorView(coordinator: editorCoordinator, readOnly: readOnly)
            .onAppear {
                editorCoordinator.onContentChanged = { title, html in
                    guard let note = appState.notes.first(where: { $0.id == noteID }) else { return }
                    var updated = note
                    updated.title = title
                    updated.body = html
                    appState.saveNote(updated)
                }
            }
            .onChange(of: editorCoordinator.isReady) { _, ready in
                guard ready else { return }
                editorCoordinator.setContent(title: initialTitle, body: initialBody)
                if !readOnly {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                        editorCoordinator.focus()
                    }
                }
            }
    }
}

#Preview {
    PadEditorView()
        .environmentObject(AppState())
}
