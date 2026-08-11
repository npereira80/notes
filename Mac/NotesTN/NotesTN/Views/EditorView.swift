import SwiftUI
import WebKit
import AppKit
import QuickLook
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

    // The last content this editor is known to hold — written by setContent (what we
    // pushed in) and by the contentChanged message (what the user typed). Lets
    // NoteEditorView tell a sync-pulled external change (DB body differs from this →
    // refresh the editor) from the echo of its own autosave (identical → ignore),
    // without re-keying/reloading the WKWebView.
    var lastKnownTitle: String = ""
    var lastKnownBody: String = ""

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
                let title = body["title"] as? String ?? ""
                lastKnownTitle = title
                lastKnownBody = html
                onContentChanged?(title, html)
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

        case "openMaps":
            // A detected address (see the data detectors in EditorBundle) — let the
            // user pick which maps app to open it in.
            if let address = body["url"] as? String {
                presentMapsChooser(address: address)
            }

        case "openAttachment":
            // Attachment card tapped — preview the file in QuickLook, the system's
            // own previewer, rather than handing it to another app.
            if let resourceId = body["resourceId"] as? String,
               let url = DatabaseManager.shared.resourceLocalFileURL(id: resourceId),
               FileManager.default.fileExists(atPath: url.path) {
                AttachmentPreview.show(url: url)
            }

        case "findResult":
            onFindResult?(body["count"] as? Int ?? 0, body["index"] as? Int ?? 0)

        case "log":
            if let msg = body["message"] as? String {
                print("[Editor JS] \(msg)")
            }

        default:
            break
        }
    }

    // Shared by Mac + iOS builds of the two maps apps' universal-link search URLs.
    // Universal links open the app if installed, otherwise the website — no per-app
    // URL scheme / installed-check needed.
    static func mapsURL(forApp app: String, address: String) -> URL? {
        let query = address.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? address
        switch app {
        case "google": return URL(string: "https://www.google.com/maps/search/?api=1&query=\(query)")
        case "waze":   return URL(string: "https://waze.com/ul?q=\(query)")
        default:       return nil
        }
    }

    /// NSAlert chooser (Google Maps / Waze) for a detected address, then opens the pick.
    private func presentMapsChooser(address: String) {
        let alert = NSAlert()
        alert.messageText = "Open address in"
        alert.informativeText = address
        alert.addButton(withTitle: "Google Maps")
        alert.addButton(withTitle: "Waze")
        alert.addButton(withTitle: "Cancel")
        let app: String?
        switch alert.runModal() {
        case .alertFirstButtonReturn:  app = "google"
        case .alertSecondButtonReturn: app = "waze"
        default:                       app = nil
        }
        if let app, let url = Self.mapsURL(forApp: app, address: address) {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: Callbacks set by NoteEditorView
    var onContentChanged: ((String, String) -> Void)?
    var onImageRequested: ((String) -> Void)?
    // In-note find progress: (total matches, 1-based current index; 0 = none).
    var onFindResult: ((Int, Int) -> Void)?

    // MARK: In-note find

    /// caseSensitive is true once Replace is showing, so a replace only rewrites the
    /// exact-case text that was highlighted (see the find plugin in EditorBundle).
    func find(_ query: String, caseSensitive: Bool = false) {
        guard let wv = webView,
              let data = try? JSONEncoder().encode(query),
              let json = String(data: data, encoding: .utf8) else { return }
        wv.evaluateJavaScript("window.NativeEditor?.find(\(json), \(caseSensitive))")
    }

    func findNext() { webView?.evaluateJavaScript("window.NativeEditor?.findNext()") }
    func findPrevious() { webView?.evaluateJavaScript("window.NativeEditor?.findPrevious()") }
    func endFind() { webView?.evaluateJavaScript("window.NativeEditor?.endFind()") }

    func replaceCurrent(_ replacement: String) { evaluateReplace("replaceCurrent", replacement) }
    func replaceAll(_ replacement: String) { evaluateReplace("replaceAll", replacement) }

    private func evaluateReplace(_ method: String, _ replacement: String) {
        guard let wv = webView,
              let data = try? JSONEncoder().encode(replacement),
              let json = String(data: data, encoding: .utf8) else { return }
        wv.evaluateJavaScript("window.NativeEditor?.\(method)(\(json))")
    }

    // MARK: Commands → JS

    func setContent(title: String, body: String) {
        guard let wv = webView else { return }
        lastKnownTitle = title
        lastKnownBody = body
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

    // MARK: Native toolbar inset (content flowing under the translucent toolbar)

    /// Pushes the note's content down by `points` inside the WebView's own scrollable
    /// area (see build.mjs's --native-toolbar-inset), so text
    /// starts right below the toolbar visually but can still scroll further up
    /// underneath its translucent material instead of hard-clipping flush against it.
    /// The WKWebView itself extends full-height under the toolbar (see
    /// RichTextEditorView's .ignoresSafeArea below) — this is what keeps the *content*
    /// looking like it starts in the same place it used to.
    func setTopInset(_ points: CGFloat) {
        guard let wv = webView else { return }
        wv.evaluateJavaScript("document.documentElement.style.setProperty('--native-toolbar-inset', '\(points)px')")
    }

    // MARK: WKNavigationDelegate — content process recovery

    // WebKit can kill the editor page's content process (memory pressure, long
    // background stretches). Without this, the editor silently turns blank/broken
    // and stays that way until the app is relaunched. Reloading re-runs the page,
    // which re-fires the JS "ready" message — isReady flipping back to true makes
    // NoteEditorView push the current content back in via its onChange(of: isReady).
    nonisolated func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        MainActor.assumeIsolated {
            isReady = false
            webView.reload()
        }
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

    /// Inserts a file attachment card (see the `attachment` node in the editor schema).
    func insertAttachment(resourceId: String, title: String, size: Int, mime: String) {
        execCommand("attachment", value: [
            "resourceId": resourceId,
            "title": title,
            "size": size,
            "mime": mime,
        ])
    }

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
    // Which picker the single .fileImporter below is currently standing in for.
    // pickerKind is set before opening and left alone afterwards, so it's still valid
    // when the completion handler runs.
    private enum PickerKind { case image, attachment }
    @State private var pickerKind: PickerKind = .image
    @State private var isShowingPicker = false
    // A picked file waiting on the "this is a large file" confirmation below.
    @State private var oversizeAttachment: URL?
    @State private var showPermanentDeleteConfirm = false
    // In-note find (Cmd+Shift+F) — highlights matches in the editor, distinct from the
    // global note-list search.
    @State private var showFind = false
    @State private var findQuery = ""
    @State private var findCount = 0
    @State private var findCurrent = 0
    // Replace row (Apple Notes-style toggle). While it's showing, matching switches
    // to case-sensitive so a replace only rewrites the exact text it highlighted.
    @State private var showReplace = false
    @State private var replaceText = ""
    // Captured below (see the GeometryReader background) from the safe area the
    // native window toolbar reserves — pushed into the WebView's own content via
    // editorCoordinator.setTopInset so it can flow its full height underneath the
    // toolbar's translucent material instead of hard-clipping flush against it.
    @State private var toolbarInset: CGFloat = 0
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

            // In-note find bar (Cmd+Shift+F) — sits under the window toolbar like
            // Apple Notes' find bar, above the editor content.
            if showFind {
                EditorFindBar(
                    query: $findQuery,
                    replacement: $replaceText,
                    showReplace: $showReplace,
                    current: findCurrent,
                    count: findCount,
                    onNext: { editorCoordinator.findNext() },
                    onPrevious: { editorCoordinator.findPrevious() },
                    onReplace: { editorCoordinator.replaceCurrent(replaceText) },
                    onReplaceAll: { editorCoordinator.replaceAll(replaceText) },
                    onClose: closeFind
                )
                Divider()
            }

            // MARK: Toolbar
            // A trashed note is read-only until restored — Restore/Delete Permanently
            // replace the formatting toolbar entirely instead of sitting alongside it.
            // The formatting toolbar itself now lives in the native window toolbar
            // (see .toolbar below) instead of this content row, so it renders on the
            // same line as NoteListView's search field / New Note button.
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
            }

            // Title now lives inside the shared ProseMirror doc (see
            // Mac/EditorBundle's `pm-title` node), so it scrolls together with
            // the body instead of sitting in a separate native field above it.
            // .ignoresSafeArea lets this extend its full height underneath the native
            // toolbar's translucent material — toolbarInset (captured below) tells the
            // WebView's own content to leave the same visual gap it used to via CSS
            // padding instead, so text still starts in the same place but can keep
            // scrolling up underneath the toolbar instead of hard-clipping against it.
            RichTextEditorView(coordinator: editorCoordinator, readOnly: readOnly)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .ignoresSafeArea(edges: .top)
        }
        .background(
            // Reads the safe area the native toolbar reserves — measured on this
            // (non-ignoring) VStack, not on RichTextEditorView itself, since a view
            // that's ignoring a safe area no longer reports an inset for that edge.
            GeometryReader { proxy in
                Color.clear
                    .onAppear { toolbarInset = proxy.safeAreaInsets.top }
                    .onChange(of: proxy.safeAreaInsets.top) { _, newValue in toolbarInset = newValue }
            }
        )
        .onChange(of: toolbarInset) { _, newValue in editorCoordinator.setTopInset(newValue) }
        .onChange(of: editorCoordinator.isReady) { _, ready in
            // The CSS variable lives on the page itself, so a fresh page load (or
            // switching notes, which re-keys this whole view — see NotesNavHost)
            // starts back at the default 0px until we push the current value again.
            if ready { editorCoordinator.setTopInset(toolbarInset) }
        }
        .background(.windowBackground)
        .toolbar {
            // Merges into the same native window toolbar as NoteListView's search
            // field / New Note button (NavigationSplitView combines .toolbar content
            // from every visible column into one bar) — not shown for a read-only
            // (trashed) note, which uses Restore/Delete Permanently instead.
            if !readOnly {
                ToolbarItem(placement: .primaryAction) {
                    EditorToolbarView(
                        coordinator: editorCoordinator,
                        onInsertImage: { pickerKind = .image; isShowingPicker = true },
                        onAttachFile: { pickerKind = .attachment; isShowingPicker = true }
                    )
                }
            }
        }
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
        // Cmd+Shift+F toggles the in-note find bar (a hidden, zero-opacity button just
        // to host the keyboard shortcut).
        .background(
            Button("") { toggleFind() }
                .keyboardShortcut("f", modifiers: [.command, .shift])
                .opacity(0)
        )
        // Cmd+Option+F — the standard macOS Find & Replace shortcut: opens find with
        // the replace row already showing.
        .background(
            Button("") { openFindWithReplace() }
                .keyboardShortcut("f", modifiers: [.command, .option])
                .opacity(0)
        )
        .onChange(of: findQuery) { _, q in editorCoordinator.find(q, caseSensitive: showReplace) }
        // Toggling Replace changes how matches are found (exact case while replacing),
        // so re-run the search against the current query.
        .onChange(of: showReplace) { _, replacing in
            editorCoordinator.find(findQuery, caseSensitive: replacing)
        }
        .onChange(of: editorCoordinator.isReady) { _, ready in
            // Reads the note fresh from AppState (falling back to the values captured
            // at init) — isReady also re-fires after a content-process-terminate
            // reload (see EditorCoordinator.webViewWebContentProcessDidTerminate),
            // by which time the init-time snapshot may be stale.
            guard ready else { return }
            let note = currentNote
            editorCoordinator.setContent(title: note?.title ?? initialTitle, body: note?.body ?? initialBody)
        }
        // A sync pull that updates the currently open note used to leave the editor
        // showing the old content (it was only ever set once per note id) — the list
        // preview and the editor would disagree until the note was reopened or the
        // app relaunched, and the next autosave would overwrite the pulled remote
        // edit with the stale editor content. lastKnown* filtering keeps this from
        // reacting to the echo of the editor's own autosaves.
        .onChange(of: currentNote?.updatedTime) { _, _ in
            guard editorCoordinator.isReady, let note = currentNote else { return }
            if note.title != editorCoordinator.lastKnownTitle || note.body != editorCoordinator.lastKnownBody {
                editorCoordinator.setContent(title: note.title, body: note.body)
            }
        }
        // ONE file importer for both the image and attachment pickers, switching its
        // allowed types on pickerKind. Two .fileImporter modifiers stacked on the same
        // view is a SwiftUI trap — the second one often never presents.
        .fileImporter(
            isPresented: $isShowingPicker,
            allowedContentTypes: pickerKind == .image ? [.image] : [.item],
            allowsMultipleSelection: false
        ) { result in
            switch pickerKind {
            case .image: handleImagePick(result: result)
            case .attachment: handleAttachmentPick(result: result)
            }
        }
        .confirmationDialog(
            "Attach this large file?",
            isPresented: Binding(
                get: { oversizeAttachment != nil },
                set: { if !$0 { oversizeAttachment = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Attach") {
                if let url = oversizeAttachment { attachFile(at: url) }
                oversizeAttachment = nil
            }
            Button("Cancel", role: .cancel) { oversizeAttachment = nil }
        } message: {
            Text("This file is over 20 MB. It will be uploaded to Joplin Cloud and downloaded onto your other devices.")
        }
    }

    private var trashedNote: Note? {
        appState.trashedNotes.first { $0.id == noteID }
    }

    /// The freshest copy of this view's note in AppState (live or trashed) — the
    /// init-time title/body snapshot goes stale as soon as the user types or a sync
    /// pulls a newer version.
    private var currentNote: Note? {
        appState.notes.first { $0.id == noteID } ?? trashedNote
    }

    // MARK: Setup

    private func setupCallbacks() {
        // Title now arrives from the same combined callback as the body (see
        // Mac/EditorBundle's `pm-title` node) — one save path instead of the old
        // separate immediate-body-save / debounced-title-save paths.
        editorCoordinator.onContentChanged = { title, html in
            // Falls back to the DB copy when the note isn't in appState.notes — it can
            // legitimately be missing (e.g. an active search whose results no longer
            // include it after this very edit); returning here silently dropped the
            // user's keystrokes.
            guard var updated = self.appState.notes.first(where: { $0.id == self.noteID })
                ?? DatabaseManager.shared.fetchNote(id: self.noteID) else { return }
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
        editorCoordinator.onFindResult = { count, index in
            findCount = count
            findCurrent = index
        }
    }

    // MARK: Find

    private func toggleFind() {
        if showFind { closeFind() } else { showFind = true }
    }

    /// Cmd+Option+F: open find with the replace row already showing.
    private func openFindWithReplace() {
        showReplace = true
        showFind = true
    }

    private func closeFind() {
        showFind = false
        showReplace = false
        findQuery = ""
        replaceText = ""
        findCount = 0
        findCurrent = 0
        editorCoordinator.endFind()
    }

    // MARK: Attachment handling

    /// Files at or above this size prompt for confirmation first — every attachment is
    /// uploaded to Joplin Cloud and downloaded onto every other device.
    private static let largeAttachmentBytes = 20 * 1_000_000

    private func handleAttachmentPick(result: Result<[URL], Error>) {
        guard case .success(let urls) = result, let url = urls.first else { return }
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
        if size >= Self.largeAttachmentBytes {
            oversizeAttachment = url   // ask first (see the confirmationDialog above)
        } else {
            attachFile(at: url)
        }
    }

    /// Copies the file into the resources directory, records it as a Resource so sync
    /// picks it up, and inserts the attachment card.
    private func attachFile(at url: URL) {
        let resourceId = Note.generateId()
        guard let resourcesDir = DatabaseManager.shared.resourcesDirectory else { return }

        let ext = url.pathExtension.isEmpty ? "bin" : url.pathExtension
        let filename = "\(resourceId).\(ext)"
        let destURL = resourcesDir.appendingPathComponent(filename)
        do {
            try FileManager.default.copyItem(at: url, to: destURL)
        } catch {
            print("[Editor] Failed to copy attachment: \(error)")
            return
        }

        let size = (try? destURL.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
        let mimeType = UTType(filenameExtension: ext)?.preferredMIMEType ?? "application/octet-stream"
        let displayName = url.lastPathComponent
        // New resource, never seen by Joplin Cloud yet — dirty so it gets pushed, not
        // synced since the server doesn't know about it.
        DatabaseManager.shared.saveResource(Resource(
            id: resourceId,
            title: displayName,
            mimeType: mimeType,
            filename: filename,
            fileSize: size,
            noteId: noteID
        ), dirty: true, synced: false)

        editorCoordinator.insertAttachment(
            resourceId: resourceId,
            title: displayName,
            size: size,
            mime: mimeType
        )
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

// MARK: - Attachment preview (QuickLook)

/// Presents an attachment in QuickLook — the same preview you get from Space in
/// Finder. QLPreviewPanel is a shared, app-wide panel that pulls its items from a
/// data source, so this singleton holds the URL being previewed and acts as that
/// source. Using the system panel rather than opening the file in another app keeps
/// the preview lightweight and read-only.
final class AttachmentPreview: NSObject, QLPreviewPanelDataSource {
    private static let shared = AttachmentPreview()
    private var url: URL?

    static func show(url: URL) {
        shared.url = url
        guard let panel = QLPreviewPanel.shared() else { return }
        panel.dataSource = shared
        panel.reloadData()
        panel.makeKeyAndOrderFront(nil)
    }

    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int { url == nil ? 0 : 1 }

    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> QLPreviewItem! {
        url as NSURL?
    }
}

// MARK: - Find bar

/// In-note find bar (Cmd+Shift+F, or Cmd+Option+F to open with Replace showing).
/// Search field, match counter, prev/next, a Replace toggle, and — when it's on — a
/// second row with the replacement field and Replace / Replace All, mirroring the
/// Mac Notes find bar.
struct EditorFindBar: View {
    @Binding var query: String
    @Binding var replacement: String
    @Binding var showReplace: Bool
    let current: Int
    let count: Int
    var onNext: () -> Void
    var onPrevious: () -> Void
    var onReplace: () -> Void
    var onReplaceAll: () -> Void
    var onClose: () -> Void
    @FocusState private var focused: Bool

    var body: some View {
        VStack(spacing: 6) {
            HStack(spacing: 8) {
                Toggle("Replace", isOn: $showReplace)
                    .toggleStyle(.checkbox)
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Find in note", text: $query)
                    .textFieldStyle(.plain)
                    .autocorrectionDisabled()
                    .focused($focused)
                    .onSubmit(onNext)
                if !query.isEmpty {
                    Text(count > 0 ? "\(current)/\(count)" : "0/0")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                Button(action: onPrevious) { Image(systemName: "chevron.up") }
                    .buttonStyle(.borderless)
                    .disabled(count == 0)
                Button(action: onNext) { Image(systemName: "chevron.down") }
                    .buttonStyle(.borderless)
                    .disabled(count == 0)
                Button("Done", action: onClose)
                    .keyboardShortcut(.cancelAction)
            }
            if showReplace {
                HStack(spacing: 8) {
                    Image(systemName: "arrow.2.squarepath").foregroundStyle(.secondary)
                    TextField("Replace with", text: $replacement)
                        .textFieldStyle(.plain)
                        .autocorrectionDisabled()
                        .onSubmit(onReplace)
                    Button("Replace", action: onReplace)
                        .disabled(count == 0)
                    Button("Replace All", action: onReplaceAll)
                        .disabled(count == 0)
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(.bar)
        .onAppear { focused = true }
    }
}

// MARK: - Toolbar

struct EditorToolbarView: View {
    @ObservedObject var coordinator: EditorCoordinator
    var onInsertImage: () -> Void
    var onAttachFile: () -> Void
    @State private var showMarkdownSource = false

    var body: some View {
        HStack(spacing: 8) {
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
                // .imageScale(.large) instead of a fixed point size/frame — lets AppKit
                // size the icon to the native toolbar's own max comfortable height
                // instead of us guessing a value that could get clipped by the
                // toolbar's fixed row height.
                Image(systemName: "textformat")
                    .imageScale(.large)
                    .contentShape(Rectangle())
            }
            .menuStyle(.borderlessButton)
            .padding(.leading, 8)

            Divider()

            // Task list + Insert Image — moved up front (2nd/3rd items), per request
            FormatToggleButton(icon: "checklist", tooltip: "Task List", isActive: coordinator.selectionState.inTaskList) {
                coordinator.execCommand("taskList")
            }
            FormatButton(icon: "photo", tooltip: "Insert Image") {
                onInsertImage()
            }
            FormatButton(icon: "paperclip", tooltip: "Attach File") {
                onAttachFile()
            }

            Divider()

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
            // Code: a partial selection inside a line becomes inline code, a whole
            // paragraph (or several) becomes a code block — see setCodeBlock in
            // EditorBundle/src/commands.ts. Active for either kind.
            FormatToggleButton(icon: "chevron.left.forwardslash.chevron.right", tooltip: "Code", isActive: coordinator.selectionState.inCode || coordinator.selectionState.code) {
                coordinator.execCommand("codeBlock")
            }

            Divider()

            // Lists
            FormatToggleButton(icon: "list.bullet", tooltip: "Bullet List", isActive: coordinator.selectionState.inBulletList) {
                coordinator.execCommand("bulletList")
            }
            FormatToggleButton(icon: "list.number", tooltip: "Number List", isActive: coordinator.selectionState.inOrderedList) {
                coordinator.execCommand("orderedList")
            }

            Divider()

            // Block formatting
            FormatToggleButton(icon: "quote.opening", tooltip: "Blockquote", isActive: coordinator.selectionState.inBlockquote) {
                coordinator.execCommand("blockquote")
            }

            Divider()

            // Indent / outdent
            FormatButton(icon: "decrease.indent", tooltip: "Outdent (⇧Tab)") {
                coordinator.execCommand("outdent")
            }
            FormatButton(icon: "increase.indent", tooltip: "Indent (Tab)") {
                coordinator.execCommand("indent")
            }

            Divider()

            // Insert (image moved above; table/HR remain)
            FormatButton(icon: "tablecells", tooltip: "Insert Table") {
                coordinator.execCommand("table", value: ["rows": 3, "cols": 3])
            }
            FormatButton(icon: "minus", tooltip: "Horizontal Rule") {
                coordinator.execCommand("horizontalRule")
            }

            Divider()

            // Link
            FormatToggleButton(icon: "link", tooltip: "Insert Link", isActive: coordinator.selectionState.hasLink) {
                if coordinator.selectionState.hasLink {
                    coordinator.execCommand("link")  // removes link
                } else {
                    // TODO: show link input panel — for now use a simple prompt
                    showLinkInput()
                }
            }

            Divider()

            // Debugging aid — view the Joplin Markdown the current editor HTML converts
            // to (the format actually stored/synced), so an HTML rendering bug can be
            // traced to its Markdown source.
            FormatButton(icon: "doc.plaintext", tooltip: "View Markdown Source") {
                showMarkdownSource = true
            }
            .padding(.trailing, 8)
        }
        .contentShape(Rectangle())  // entire toolbar row is event-opaque; gaps between buttons don't fall through
        .sheet(isPresented: $showMarkdownSource) {
            MarkdownSourceView(markdown: HtmlToMarkdown.convert(coordinator.lastKnownBody))
        }
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
            // .imageScale(.large) instead of a fixed point size/frame — matches the
            // text-style menu icon above: lets AppKit size this to the native
            // toolbar's own max comfortable height rather than a guessed value that
            // could get clipped by the toolbar's fixed row height.
            Image(systemName: icon)
                .imageScale(.large)
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
                .imageScale(.large)
                .padding(4)
                .background(isActive ? Color.accentColor.opacity(0.15) : Color.clear)
                .cornerRadius(4)
                .contentShape(Rectangle())  // full frame is clickable
        }
        .buttonStyle(.borderless)
        .help(tooltip)
        .foregroundStyle(isActive ? Color.accentColor : Color.secondary)
    }
}

// MARK: - Markdown source viewer

/// Read-only view of a note's Markdown source (what HtmlToMarkdown produces from the
/// current editor HTML). A debugging aid for tracing HTML rendering issues back to
/// their stored/synced Markdown.
private struct MarkdownSourceView: View {
    let markdown: String
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Markdown Source").font(.headline)
                Spacer()
                Button("Copy") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(markdown, forType: .string)
                }
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding()
            Divider()
            ScrollView {
                Text(markdown.isEmpty ? "(empty)" : markdown)
                    .font(.system(.body, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding()
            }
        }
        .frame(width: 540, height: 480)
    }
}

#Preview {
    EditorView()
        .environmentObject(AppState())
}
