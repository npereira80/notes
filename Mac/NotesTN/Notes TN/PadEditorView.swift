import SwiftUI
import UniformTypeIdentifiers

// iPad-only. Fresh rebuild (per request). Not shared with iPhone (EditorView.swift's
// NoteEditorView) or Mac (its own EditorView.swift). Reuses EditorCoordinator/
// RichTextEditorView from EditorView.swift, though — that's the WKWebView/ProseMirror
// JS bridge, which is infrastructure identical across every platform, not UI chrome
// that should differ per idiom.
//
// The formatting toolbar itself (EditorToolbarView, FormatButton/FormatToggleButton)
// is also reused as-is from EditorView.swift rather than duplicated: it's already a
// plain SwiftUI view (no AppKit/NSAlert dependency — its link-input uses a SwiftUI
// .alert with an embedded TextField) shared with iPhone, so it's the same kind of
// shared infra as EditorCoordinator, not per-idiom UI chrome. Placed in this column's
// own native toolbar (.primaryAction), per request — same row as the search field.
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
        // Enter key — opens/previews the first result. Typing alone (the binding
        // above) only re-filters the list now.
        .onSubmit(of: .search) {
            appState.submitSearch()
        }
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
    @State private var isShowingImagePicker = false

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
            .toolbar {
                if !readOnly {
                    // See EditorFormatToolbar below — caps at the toolbar's natural
                    // width (no empty trailing space on a wide window) but still
                    // shrinks on a narrower window, scrolling its buttons instead of
                    // overflowing.
                    ToolbarItemGroup(placement: .primaryAction) {
                        EditorFormatToolbar(
                            coordinator: editorCoordinator,
                            onInsertImage: { isShowingImagePicker = true }
                        )
                    }
                }
            }
            .fileImporter(
                isPresented: $isShowingImagePicker,
                allowedContentTypes: [.image],
                allowsMultipleSelection: false
            ) { result in
                handleImagePick(result: result)
            }
    }

    // Ported as-is from EditorView.swift's NoteEditorView.handleImagePick — same
    // resource-copy + dirty/synced bookkeeping.
    private func handleImagePick(result: Result<[URL], Error>) {
        guard case .success(let urls) = result, let url = urls.first else { return }

        let didStartAccessing = url.startAccessingSecurityScopedResource()
        defer { if didStartAccessing { url.stopAccessingSecurityScopedResource() } }

        let resourceId = Note.generateId()
        guard let resourcesDir = DatabaseManager.shared.resourcesDirectory else { return }

        let ext = url.pathExtension.isEmpty ? "png" : url.pathExtension
        let destURL = resourcesDir.appendingPathComponent("\(resourceId).\(ext)")

        do {
            try FileManager.default.copyItem(at: url, to: destURL)
        } catch {
            print("[Editor] Failed to copy image: \(error)")
            return
        }

        let mimeType = UTType(filenameExtension: ext)?.preferredMIMEType ?? "image/png"
        DatabaseManager.shared.saveResource(Resource(
            id: resourceId,
            title: url.lastPathComponent,
            mimeType: mimeType,
            filename: "\(resourceId).\(ext)",
            fileSize: (try? destURL.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0,
            noteId: noteID
        ), dirty: true, synced: false)

        editorCoordinator.insertImage(
            src: destURL.absoluteString,
            alt: url.deletingPathExtension().lastPathComponent,
            resourceId: resourceId
        )
    }
}

// Wraps EditorToolbarView in a horizontal ScrollView whose width is capped at the
// toolbar's own natural (unclipped) content width — measured once via an invisible,
// .fixedSize clone below — so a wide window doesn't leave the bar padded with empty
// trailing space. .frame(maxWidth:), unlike .fixedSize alone, still lets the bar
// shrink below that cap on a narrower window, scrolling its buttons instead of
// overflowing.
private struct EditorFormatToolbar: View {
    @ObservedObject var coordinator: EditorCoordinator
    var onInsertImage: () -> Void
    @State private var naturalWidth: CGFloat?

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            toolbar
        }
        .frame(maxWidth: naturalWidth)
        .background(
            Color.clear
                .frame(width: 0, height: 0)
                .overlay(alignment: .leading) {
                    toolbar
                        .fixedSize(horizontal: true, vertical: false)
                        .opacity(0)
                        .allowsHitTesting(false)
                        .background(
                            GeometryReader { proxy in
                                Color.clear
                                    .onAppear { naturalWidth = proxy.size.width }
                                    .onChange(of: proxy.size.width) { _, newValue in naturalWidth = newValue }
                            }
                        )
                }
        )
    }

    private var toolbar: some View {
        EditorToolbarView(coordinator: coordinator, onInsertImage: onInsertImage, showsUndoRedo: false)
    }
}

#Preview {
    PadEditorView()
        .environmentObject(AppState())
}
