import SwiftUI
import WebKit
import AppKit
import UniformTypeIdentifiers

// MARK: - Selection State (mirrors JS SelectionState)

struct EditorSelectionState {
    var bold = false
    var italic = false
    var code = false
    var strikethrough = false
    var highlight = false
    var inCode = false
    var inBlockquote = false
    var inBulletList = false
    var inOrderedList = false
    var inTaskList = false
    var inCheckedTask = false
    var headingLevel = 0   // 0 = paragraph
    var hasLink = false
    var linkHref: String? = nil
}

// MARK: - Editor Coordinator (owns WKWebView, bridges Swift ↔ JS)

@MainActor
final class EditorCoordinator: NSObject, ObservableObject, WKScriptMessageHandler, WKNavigationDelegate {

    // MARK: Published
    @Published var selectionState = EditorSelectionState()
    @Published var isReady = false

    // The webview — set by RichTextEditorView.makeNSView
    weak var webView: WKWebView?

    // Called when the JS side sends us a message.
    // WKScriptMessage is @MainActor in macOS 14 SDK; no nonisolated needed.
    func userContentController(
        _ userContentController: WKUserContentController,
        didReceive message: WKScriptMessage
    ) {
        guard let body = message.body as? [String: Any],
              let type = body["type"] as? String else { return }
        handle(type: type, body: body)
    }

    private func handle(type: String, body: [String: Any]) {
        switch type {
        case "ready":
            isReady = true

        case "contentChanged":
            if let html = body["html"] as? String {
                onContentChanged?(body["title"] as? String ?? "", html)
            }

        case "selectionChanged":
            if let s = body["selectionState"] as? [String: Any] {
                selectionState = EditorSelectionState(
                    bold: s["bold"] as? Bool ?? false,
                    italic: s["italic"] as? Bool ?? false,
                    code: s["code"] as? Bool ?? false,
                    strikethrough: s["strikethrough"] as? Bool ?? false,
                    highlight: s["highlight"] as? Bool ?? false,
                    inCode: s["inCode"] as? Bool ?? false,
                    inBlockquote: s["inBlockquote"] as? Bool ?? false,
                    inBulletList: s["inBulletList"] as? Bool ?? false,
                    inOrderedList: s["inOrderedList"] as? Bool ?? false,
                    inTaskList: s["inTaskList"] as? Bool ?? false,
                    inCheckedTask: s["inCheckedTask"] as? Bool ?? false,
                    headingLevel: s["headingLevel"] as? Int ?? 0,
                    hasLink: s["hasLink"] as? Bool ?? false,
                    linkHref: s["linkHref"] as? String
                )
            }

        case "imageRequested":
            // User pasted an image — JS sends its raw "data:...;base64,..." URI in
            // `html` (see the paste handler in Mac/EditorBundle/src/index.ts).
            if let dataUri = body["html"] as? String {
                onImageRequested?(dataUri)
            }

        case "openUrl":
            if let urlString = body["url"] as? String,
               let url = URL(string: urlString) {
                NSWorkspace.shared.open(url)
            }

        case "log":
            if let msg = body["message"] as? String {
                print("[Editor JS] \(msg)")
            }

        default:
            break
        }
    }

    // MARK: Callbacks set by NoteEditorView
    var onContentChanged: ((String, String) -> Void)?
    var onImageRequested: ((String) -> Void)?

    // MARK: Commands → JS

    func setContent(title: String, body: String) {
        guard let wv = webView else { return }
        // JSONEncoder handles bare String top-level values safely.
        // NSJSONSerialization throws an ObjC NSException (not a Swift Error) for
        // bare strings, which bypasses try? and corrupts SwiftUI's run loop state,
        // freezing the entire UI after the first note is selected.
        guard let titleData = try? JSONEncoder().encode(title),
              let titleJSON = String(data: titleData, encoding: .utf8),
              let bodyData = try? JSONEncoder().encode(body),
              let bodyJSON = String(data: bodyData, encoding: .utf8) else { return }
        wv.evaluateJavaScript("window.NativeEditor?.setContent(\(titleJSON), \(bodyJSON))")
    }

    func execCommand(_ command: String, value: Any? = nil) {
        guard let wv = webView else { return }

        let js: String
        if let value,
           let data = try? JSONSerialization.data(withJSONObject: value),
           let json = String(data: data, encoding: .utf8) {
            js = "window.NativeEditor?.execCommand('\(command)', \(json))"
        } else {
            js = "window.NativeEditor?.execCommand('\(command)')"
        }

        // Return first-responder to the WKWebView BEFORE sending the JS command.
        // Without this, macOS steals focus for the toolbar button that was clicked,
        // and ProseMirror has no active selection when the command arrives.
        wv.window?.makeFirstResponder(wv)
        wv.evaluateJavaScript(js)
    }

    func focus() {
        guard let wv = webView else { return }
        // Move AppKit first-responder to the WKWebView, then focus ProseMirror.
        wv.window?.makeFirstResponder(wv)
        wv.evaluateJavaScript("window.NativeEditor?.focus()")
    }

    // MARK: WKNavigationDelegate — open links in default browser

    nonisolated func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
    ) {
        // WebKit always calls navigation delegate methods on the main thread, so it's
        // safe to assume isolation here — navigationAction's properties are main-actor
        // isolated in the current SDK even though this delegate method itself isn't.
        MainActor.assumeIsolated {
            if navigationAction.navigationType == .linkActivated,
               let url = navigationAction.request.url {
                decisionHandler(.cancel)
                NSWorkspace.shared.open(url)
                return
            }
            decisionHandler(.allow)
        }
    }

    // MARK: Image insertion

    func insertImage(src: String, alt: String? = nil, resourceId: String? = nil) {
        var value: [String: Any] = ["src": src]
        if let alt { value["alt"] = alt }
        if let resourceId { value["resourceId"] = resourceId }
        execCommand("image", value: value)
    }
}

// MARK: - WKWebView with strict hit-testing

/// WKWebView's internal subviews (NSScrollView, input-delegate views, etc.) don't
/// clip their hit-test areas to the WKWebView's own bounds. On macOS, this causes
/// the editor to absorb mouse events that are physically outside its frame — including
/// events on the SwiftUI toolbar above it and on the note-list column to the left.
/// Overriding hitTest here ensures only points actually inside this view are handled.
final class EditorWebView: WKWebView {
    override func hitTest(_ point: NSPoint) -> NSView? {
        // `point` arrives in the superview's coordinate space, not our own — must
        // convert before comparing against `bounds`, or this check is meaningless
        // whenever our frame origin isn't (0, 0) in the superview (the normal case).
        let localPoint = superview?.convert(point, to: self) ?? point
        guard bounds.contains(localPoint) else { return nil }
        return super.hitTest(point)
    }
}


// MARK: - WKWebView NSViewRepresentable

struct RichTextEditorView: NSViewRepresentable {
    @ObservedObject var coordinator: EditorCoordinator
    var readOnly: Bool = false

    func makeNSView(context: Context) -> EditorWebView {
        let config = WKWebViewConfiguration()
        config.userContentController.add(coordinator, name: "editorMessage")

        let wv = EditorWebView(frame: .zero, configuration: config)
        wv.setValue(false, forKey: "drawsBackground") // transparent — body bg handles color
        wv.navigationDelegate = coordinator
        coordinator.webView = wv
        #if DEBUG
        // Lets Safari's Develop menu attach to this WKWebView (Develop > [device name] >
        // NotesTN) for real console errors/breakpoints — debug builds only.
        if #available(macOS 13.3, *) { wv.isInspectable = true }
        #endif

        // Load editor.html from the app bundle.
        // allowingReadAccessTo must cover BOTH the bundle directory (editor.html,
        // editor.bundle.js) AND ~/Library/Application Support/NotesTN/resources/
        // (user image attachments). The home directory is the common ancestor for
        // debug builds (bundle is under ~/Library/Developer/Xcode/DerivedData).
        if let htmlURL = Bundle.main.url(forResource: "editor", withExtension: "html", subdirectory: nil) {
            let accessRoot = FileManager.default.homeDirectoryForCurrentUser
            // ?readonly=1 disables ProseMirror's contentEditable entirely for a trashed
            // note opened from Trash — see EditorBundle/src/index.ts. Appended via
            // URLComponents since htmlURL is a file:// URL (query strings are still
            // valid there and WKWebView preserves them for location.search).
            var components = URLComponents(url: htmlURL, resolvingAgainstBaseURL: false)
            if readOnly { components?.queryItems = [URLQueryItem(name: "readonly", value: "1")] }
            wv.loadFileURL(components?.url ?? htmlURL, allowingReadAccessTo: accessRoot)
        } else {
            let fallback = "<html><body><p style='color:red'>editor.html not found in bundle</p></body></html>"
            wv.loadHTMLString(fallback, baseURL: nil)
        }

        return wv
    }

    func updateNSView(_ nsView: EditorWebView, context: Context) {
        // State updates driven by coordinator callbacks — nothing needed here
    }

    static func dismantleNSView(_ nsView: EditorWebView, coordinator: ()) {
        // Remove the message handler to break the retain cycle:
        // WKUserContentController holds a strong ref to EditorCoordinator,
        // so we must remove it when the view is destroyed.
        nsView.configuration.userContentController.removeScriptMessageHandler(forName: "editorMessage")
    }
}

// MARK: - Editor Shell

struct EditorView: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        Group {
            if let note = appState.selectedNote {
                NoteEditorView(note: note, readOnly: appState.isTrashSelected)
                    .id(note.id)
            } else {
                emptyState
            }
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
                .keyboardShortcut("n", modifiers: .command)
                .tint(Color.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.windowBackground)
    }
}

// MARK: - Note Editor

struct NoteEditorView: View {
    @EnvironmentObject var appState: AppState

    @StateObject private var editorCoordinator = EditorCoordinator()
    @State private var isShowingImagePicker = false
    @State private var showPermanentDeleteConfirm = false
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
        VStack(spacing: 0) {

            // MARK: Toolbar
            // A trashed note is read-only until restored — Restore/Delete Permanently
            // replace the formatting toolbar entirely instead of sitting alongside it.
            if readOnly {
                HStack {
                    Spacer()
                    Button("Restore") {
                        guard let note = trashedNote else { return }
                        appState.restoreNote(note)
                    }
                    Button("Delete Permanently", role: .destructive) { showPermanentDeleteConfirm = true }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 11)
                .background(.windowBackground)
            } else {
                EditorToolbarView(
                    coordinator: editorCoordinator,
                    onInsertImage: { isShowingImagePicker = true }
                )
                .padding(.horizontal, 16)
                .padding(.vertical, 13.75)
                .background(.windowBackground)
            }

            Divider()

            // Title now lives inside the shared ProseMirror doc (see
            // Mac/EditorBundle's `pm-title` node), so it scrolls together with
            // the body instead of sitting in a separate native field above it.
            RichTextEditorView(coordinator: editorCoordinator, readOnly: readOnly)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(.windowBackground)
        .confirmationDialog(
            "Permanently delete this note?",
            isPresented: $showPermanentDeleteConfirm,
            titleVisibility: .visible
        ) {
            Button("Delete Permanently", role: .destructive) {
                guard let note = trashedNote else { return }
                appState.permanentlyDeleteNote(note)
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This can't be undone.")
        }
        .onAppear {
            setupCallbacks()
        }
        .onChange(of: editorCoordinator.isReady) { _, ready in
            if ready { editorCoordinator.setContent(title: initialTitle, body: initialBody) }
        }
        // Image picker
        .fileImporter(
            isPresented: $isShowingImagePicker,
            allowedContentTypes: [.image],
            allowsMultipleSelection: false
        ) { result in
            handleImagePick(result: result)
        }
    }

    private var trashedNote: Note? {
        appState.trashedNotes.first { $0.id == noteID }
    }

    // MARK: Setup

    private func setupCallbacks() {
        // Title now arrives from the same combined callback as the body (see
        // Mac/EditorBundle's `pm-title` node) — one save path instead of the old
        // separate immediate-body-save / debounced-title-save paths.
        editorCoordinator.onContentChanged = { title, html in
            guard let note = self.appState.notes.first(where: { $0.id == self.noteID }) else { return }
            var updated = note
            updated.title = title
            updated.body = html
            self.appState.saveNote(updated)
        }
        editorCoordinator.onImageRequested = { dataUri in
            guard let resource = copyDataUriIntoResources(dataUri: dataUri, noteId: noteID),
                  let dir = DatabaseManager.shared.resourcesDirectory else { return }
            // file:// URL that WKWebView can load (local access granted via loadFileURL)
            editorCoordinator.insertImage(
                src: dir.appendingPathComponent(resource.filename).absoluteString,
                alt: resource.title,
                resourceId: resource.id
            )
        }
    }

    // MARK: Image handling

    private func handleImagePick(result: Result<[URL], Error>) {
        guard case .success(let urls) = result, let url = urls.first else { return }

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

        // Save to DB and insert into editor
        let mimeType = UTType(filenameExtension: ext)?.preferredMIMEType ?? "image/png"
        // New resource, never seen by Joplin Cloud yet — dirty so it gets pushed, not
        // synced since the server doesn't know about it.
        DatabaseManager.shared.saveResource(Resource(
            id: resourceId,
            title: url.lastPathComponent,
            mimeType: mimeType,
            filename: "\(resourceId).\(ext)",
            fileSize: (try? destURL.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0,
            noteId: noteID
        ), dirty: true, synced: false)

        // file:// URL that WKWebView can load (local access granted via loadFileURL)
        editorCoordinator.insertImage(
            src: destURL.absoluteString,
            alt: url.deletingPathExtension().lastPathComponent,
            resourceId: resourceId
        )
    }

    /// Counterpart to handleImagePick for the paste-from-clipboard path — the editor
    /// bundle hands us a raw "data:image/png;base64,..." URI (see the paste handler in
    /// Mac/EditorBundle/src/index.ts) instead of a picked file URL, since there's no
    /// system picker involved.
    private func copyDataUriIntoResources(dataUri: String, noteId: String) -> Resource? {
        guard let commaIndex = dataUri.firstIndex(of: ","),
              let dir = DatabaseManager.shared.resourcesDirectory else { return nil }

        let header = dataUri[dataUri.index(dataUri.startIndex, offsetBy: "data:".count)..<commaIndex]
        let mimeType = String(header.split(separator: ";").first ?? "image/png")
        let base64 = String(dataUri[dataUri.index(after: commaIndex)...])
        guard let bytes = Data(base64Encoded: base64) else { return nil }

        let ext = UTType(mimeType: mimeType)?.preferredFilenameExtension ?? "png"
        let resourceId = Note.generateId()
        let filename = "\(resourceId).\(ext)"
        do {
            try bytes.write(to: dir.appendingPathComponent(filename))
        } catch {
            print("[Editor] Failed to write pasted image: \(error)")
            return nil
        }

        let resource = Resource(
            id: resourceId,
            title: filename,
            mimeType: mimeType,
            filename: filename,
            fileSize: bytes.count,
            noteId: noteId
        )
        // New resource, never seen by Joplin Cloud yet — dirty so it gets pushed, not
        // synced since the server doesn't know about it.
        DatabaseManager.shared.saveResource(resource, dirty: true, synced: false)
        return resource
    }
}

// MARK: - Toolbar

struct EditorToolbarView: View {
    @ObservedObject var coordinator: EditorCoordinator
    var onInsertImage: () -> Void

    var body: some View {
        HStack(spacing: 2) {
            // Text style picker
            Menu {
                // "Title" reuses heading level 1 (restyled in CSS to match the note
                // title's look) so it can be applied to any paragraph in the body.
                Button("Title") { coordinator.execCommand("heading1") }
                Button("Heading") { coordinator.execCommand("heading3") }
                Button("Subheading") { coordinator.execCommand("heading4") }
                Button("Paragraph") { coordinator.execCommand("paragraph") }
                Divider()
                Button("Bullet List") { coordinator.execCommand("bulletList") }
                Button("Number List") { coordinator.execCommand("orderedList") }
                Divider()
                Button("Monospaced") { coordinator.execCommand("code") }
                Button("Code Block") { coordinator.execCommand("codeBlock") }
            } label: {
                Image(systemName: "textformat")
                    .frame(width: 32.5, height: 27.5)
                    .contentShape(Rectangle())
            }
            .menuStyle(.borderlessButton)
            .frame(width: 45)

            Divider().frame(height: 20)

            // Task list + Insert Image — moved up front (2nd/3rd items), per request
            FormatToggleButton(icon: "checklist", tooltip: "Task List", isActive: coordinator.selectionState.inTaskList) {
                coordinator.execCommand("taskList")
            }
            FormatButton(icon: "photo", tooltip: "Insert Image") {
                onInsertImage()
            }

            Divider().frame(height: 20)

            // Inline marks
            FormatToggleButton(icon: "bold", tooltip: "Bold (⌘B)", isActive: coordinator.selectionState.bold) {
                coordinator.execCommand("bold")
            }
            FormatToggleButton(icon: "italic", tooltip: "Italic (⌘I)", isActive: coordinator.selectionState.italic) {
                coordinator.execCommand("italic")
            }
            FormatToggleButton(icon: "strikethrough", tooltip: "Strikethrough", isActive: coordinator.selectionState.strikethrough) {
                coordinator.execCommand("strikethrough")
            }
            FormatToggleButton(icon: "highlighter", tooltip: "Highlight", isActive: coordinator.selectionState.highlight) {
                coordinator.execCommand("highlight")
            }
            FormatToggleButton(icon: "chevron.left.forwardslash.chevron.right", tooltip: "Inline Code (⌘`)", isActive: coordinator.selectionState.code) {
                coordinator.execCommand("code")
            }

            Divider().frame(height: 20)

            // Block formatting
            FormatToggleButton(icon: "quote.opening", tooltip: "Blockquote", isActive: coordinator.selectionState.inBlockquote) {
                coordinator.execCommand("blockquote")
            }

            Divider().frame(height: 20)

            // Indent / outdent
            FormatButton(icon: "decrease.indent", tooltip: "Outdent (⇧Tab)") {
                coordinator.execCommand("outdent")
            }
            FormatButton(icon: "increase.indent", tooltip: "Indent (Tab)") {
                coordinator.execCommand("indent")
            }

            Divider().frame(height: 20)

            // Insert (image moved above; table/HR remain)
            FormatButton(icon: "tablecells", tooltip: "Insert Table") {
                coordinator.execCommand("table", value: ["rows": 3, "cols": 3])
            }
            FormatButton(icon: "minus", tooltip: "Horizontal Rule") {
                coordinator.execCommand("horizontalRule")
            }

            Divider().frame(height: 20)

            // Link
            FormatToggleButton(icon: "link", tooltip: "Insert Link", isActive: coordinator.selectionState.hasLink) {
                if coordinator.selectionState.hasLink {
                    coordinator.execCommand("link")  // removes link
                } else {
                    // TODO: show link input panel — for now use a simple prompt
                    showLinkInput()
                }
            }
        }
        .contentShape(Rectangle())  // entire toolbar row is event-opaque; gaps between buttons don't fall through
    }

    private func showLinkInput() {
        // Simple NSAlert-based link input for now
        let alert = NSAlert()
        alert.messageText = "Insert Link"
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Cancel")

        let input = NSTextField(frame: NSRect(x: 0, y: 0, width: 300, height: 24))
        input.placeholderString = "https://example.com"
        alert.accessoryView = input

        alert.window.initialFirstResponder = input
        let response = alert.runModal()
        if response == .alertFirstButtonReturn {
            let href = input.stringValue.trimmingCharacters(in: .whitespaces)
            if !href.isEmpty {
                coordinator.execCommand("link", value: ["href": href])
            }
        }
    }
}

// MARK: - Format buttons

struct FormatButton: View {
    let icon: String
    let tooltip: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 15))
                .frame(width: 32.5, height: 27.5)
                .contentShape(Rectangle())  // full frame is clickable, not just icon pixels
        }
        .buttonStyle(.borderless)
        .help(tooltip)
        .foregroundStyle(.secondary)
    }
}

struct FormatToggleButton: View {
    let icon: String
    let tooltip: String
    let isActive: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 15))
                .frame(width: 32.5, height: 27.5)
                .background(isActive ? Color.accentColor.opacity(0.15) : Color.clear)
                .cornerRadius(4)
                .contentShape(Rectangle())  // full frame is clickable
        }
        .buttonStyle(.borderless)
        .help(tooltip)
        .foregroundStyle(isActive ? Color.accentColor : Color.secondary)
    }
}

#Preview {
    EditorView()
        .environmentObject(AppState())
}
