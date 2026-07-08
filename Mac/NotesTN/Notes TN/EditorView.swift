import SwiftUI
import WebKit
import UIKit
import Combine
import UniformTypeIdentifiers

// iOS/iPadOS port of Mac/NotesTN/NotesTN/Views/EditorView.swift — same shell structure
// and the same ProseMirror editor.html/editor.bundle.js loaded into a WKWebView, just
// wrapped in UIViewRepresentable instead of NSViewRepresentable, with UIKit equivalents
// swapped in wherever the Mac file used AppKit. Kept as its own file (not shared with
// the Mac target) since the two platforms' WKWebView wrapper and window/responder APIs
// are different enough that a single shared implementation would be more conditional
// compilation than shared code. Keep behavior in sync with the Mac file by hand when
// editor features change.

// MARK: - Selection State (mirrors JS SelectionState — identical to Mac's)

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

    // The webview — set by RichTextEditorView.makeUIView
    weak var webView: WKWebView?

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
                UIApplication.shared.open(url)
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

        // iOS has no window-level first responder concept like AppKit's
        // makeFirstResponder — each view manages its own responder status directly.
        wv.becomeFirstResponder()
        wv.evaluateJavaScript(js)
    }

    func focus() {
        guard let wv = webView else { return }
        wv.becomeFirstResponder()
        wv.evaluateJavaScript("window.NativeEditor?.focus()")
    }

    // MARK: WKNavigationDelegate — open links in default browser

    nonisolated func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
    ) {
        MainActor.assumeIsolated {
            if navigationAction.navigationType == .linkActivated,
               let url = navigationAction.request.url {
                decisionHandler(.cancel)
                UIApplication.shared.open(url)
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

// MARK: - WKWebView UIViewRepresentable

struct RichTextEditorView: UIViewRepresentable {
    @ObservedObject var coordinator: EditorCoordinator
    var readOnly: Bool = false

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.userContentController.add(coordinator, name: "editorMessage")

        let wv = WKWebView(frame: .zero, configuration: config)
        // Transparent background — body bg handles color (AppKit's "drawsBackground"
        // key-value trick doesn't apply on iOS; this is the UIKit equivalent).
        wv.isOpaque = false
        wv.backgroundColor = .clear
        wv.scrollView.backgroundColor = .clear
        wv.navigationDelegate = coordinator
        coordinator.webView = wv
        #if DEBUG
        // Lets Safari's Develop menu attach to this WKWebView for real console
        // errors/breakpoints — debug builds only.
        if #available(iOS 16.4, *) { wv.isInspectable = true }
        #endif

        // Load editor.html from the app bundle.
        // allowingReadAccessTo must cover the directory editor.html AND editor.bundle.js
        // both live in — unlike Mac, where the user's home directory really is a common
        // ancestor of the app bundle (under ~/Library/Developer/... for debug builds)
        // and Application Support, iOS keeps the app bundle and the app's data
        // (Application Support, where user image attachments live) in two completely
        // separate sandbox containers with no shared ancestor. Granting NSHomeDirectory()
        // (the data container) here was wrong — it doesn't cover the bundle container at
        // all, so editor.bundle.js's <script src="editor.bundle.js"> load was silently
        // blocked by WebKit's sandbox (see Xcode console: "Ignoring request to load this
        // main resource because it is outside the sandbox"), meaning the whole
        // ProseMirror/contentEditable JS never actually ran — only the static HTML/CSS
        // shell rendered, which is why nothing was focusable or typable.
        // NOTE: this fixes loading editor.html/editor.bundle.js, but user-attached image
        // resources (file:// URLs pointing into Application Support) are NOT under this
        // root either, and will likely hit the same sandbox error — a follow-up needs a
        // WKURLSchemeHandler to serve those from Swift instead of relying on file:// +
        // allowingReadAccessTo, which can only grant one directory tree per web view.
        if let htmlURL = Bundle.main.url(forResource: "editor", withExtension: "html", subdirectory: nil) {
            let accessRoot = htmlURL.deletingLastPathComponent()
            // ?readonly=1 disables ProseMirror's contentEditable entirely for a trashed
            // note opened from Trash — see EditorBundle/src/index.ts.
            var components = URLComponents(url: htmlURL, resolvingAgainstBaseURL: false)
            var queryItems: [URLQueryItem] = []
            if readOnly { queryItems.append(URLQueryItem(name: "readonly", value: "1")) }
            // Tells the shared editor CSS to use iPhone's narrower body padding (see
            // build.mjs's body.pm-ios-phone rule) instead of the default sized for
            // Mac's wider window. iPad keeps the default — only iPhone needs this.
            if UIDevice.current.userInterfaceIdiom == .phone {
                queryItems.append(URLQueryItem(name: "platform", value: "ios-phone"))
            }
            if !queryItems.isEmpty { components?.queryItems = queryItems }
            wv.loadFileURL(components?.url ?? htmlURL, allowingReadAccessTo: accessRoot)
        } else {
            let fallback = "<html><body><p style='color:red'>editor.html not found in bundle</p></body></html>"
            wv.loadHTMLString(fallback, baseURL: nil)
        }

        return wv
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {
        // State updates driven by coordinator callbacks — nothing needed here
    }

    static func dismantleUIView(_ uiView: WKWebView, coordinator: ()) {
        // Remove the message handler to break the retain cycle:
        // WKUserContentController holds a strong ref to EditorCoordinator,
        // so we must remove it when the view is destroyed.
        uiView.configuration.userContentController.removeScriptMessageHandler(forName: "editorMessage")
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
                .tint(Color.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(.systemBackground))
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

    // iPhone only (leave iPad/Mac/Android untouched) — the formatting toolbar floats
    // as a rounded, horizontally-scrolling bar just above the keyboard (mirrors
    // Android's EditorScreen.kt Surface-over-WebView approach) instead of sitting in
    // a fixed row under the nav bar. iPad keeps the original embedded top toolbar.
    private var isPhoneIdiom: Bool { UIDevice.current.userInterfaceIdiom == .phone }
    @State private var keyboardHeight: CGFloat = 0

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
                .background(Color(.systemBackground))
            } else if !isPhoneIdiom {
                // iPad keeps the original embedded top toolbar row — iPhone's version
                // floats above the keyboard instead (see the .overlay below).
                ScrollView(.horizontal, showsIndicators: false) {
                    EditorToolbarView(
                        coordinator: editorCoordinator,
                        onInsertImage: { isShowingImagePicker = true }
                    )
                    .padding(.horizontal, 16)
                    .padding(.vertical, 11)
                }
                .background(Color(.systemBackground))
            }

            Divider()

            // Title lives inside the shared ProseMirror doc (see Mac/EditorBundle's
            // `pm-title` node), so it scrolls together with the body.
            // Left/right inset on iPhone comes from the shared editor.html/CSS itself
            // (body.pm-ios-phone in build.mjs, activated via the ?platform=ios-phone
            // query param above) rather than SwiftUI-level padding here — Mac keeps
            // its own default CSS padding untouched.
            RichTextEditorView(coordinator: editorCoordinator, readOnly: readOnly)
                .frame(maxWidth: 760)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(Color(.systemBackground))
        // iPhone-only floating formatting toolbar (see isPhoneIdiom above) — hidden
        // whenever the keyboard isn't up, same as Android's imeVisible gate, since the
        // toolbar is only useful while actively typing.
        .overlay(alignment: .bottom) {
            if isPhoneIdiom && !readOnly && keyboardHeight > 0 {
                floatingToolbar
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillChangeFrameNotification)) { note in
            guard isPhoneIdiom,
                  let frame = note.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect else { return }
            keyboardHeight = max(0, UIScreen.main.bounds.height - frame.origin.y)
        }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)) { _ in
            keyboardHeight = 0
        }
        .toolbar {
            if !readOnly {
                ToolbarItem(placement: .primaryAction) {
                    Button { appState.createNote() } label: {
                        Image(systemName: "square.and.pencil")
                    }
                    .foregroundStyle(Color.secondary)
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
        .onChange(of: editorCoordinator.isReady) { _, ready in
            guard ready else { return }
            editorCoordinator.setContent(title: initialTitle, body: initialBody)
            // Unlike Mac (where clicking anywhere hands keyboard focus to whatever
            // NSView was clicked, via AppKit's default mouse-down handling), iOS has
            // no equivalent automatic tap-to-focus for a UIViewRepresentable-wrapped
            // WKWebView — especially a near-empty new note, whose title placeholder
            // has little to no visible/tappable content yet. Focus explicitly here so
            // notes (new or existing) are immediately editable without requiring the
            // user to find the right pixel to tap first.
            if !readOnly {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                    editorCoordinator.focus()
                }
            }
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

    // iPhone-only floating formatting toolbar — rounded card, horizontally scrolling,
    // positioned just above the keyboard (keyboardHeight, tracked above). Mirrors
    // Android's EditorScreen.kt Surface (14dp corner radius, hairline border, small
    // shadow) floating over the WebView instead of reserving its own layout row.
    private var floatingToolbar: some View {
        let shape = RoundedRectangle(cornerRadius: 14)
        return ScrollView(.horizontal, showsIndicators: false) {
            EditorToolbarView(
                coordinator: editorCoordinator,
                onInsertImage: { isShowingImagePicker = true }
            )
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
        .background(Color(.systemBackground), in: shape)
        .overlay(shape.stroke(Color.primary.opacity(0.15), lineWidth: 0.5))
        .shadow(color: .black.opacity(0.15), radius: 8, y: 2)
        .padding(.horizontal, 10)
        .padding(.bottom, keyboardHeight + 5)
    }

    // MARK: Setup

    private func setupCallbacks() {
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

        // fileImporter on iOS hands back a security-scoped URL — must bracket the
        // actual read with start/stopAccessingSecurityScopedResource, unlike macOS
        // where sandbox access is already implied by the picker itself.
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

        editorCoordinator.insertImage(
            src: destURL.absoluteString,
            alt: url.deletingPathExtension().lastPathComponent,
            resourceId: resourceId
        )
    }

    /// Counterpart to handleImagePick for the paste-from-clipboard path — the editor
    /// bundle hands us a raw "data:image/png;base64,..." URI (see the paste handler in
    /// Mac/EditorBundle/src/index.ts) instead of a picked file URL.
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
        DatabaseManager.shared.saveResource(resource, dirty: true, synced: false)
        return resource
    }
}

// MARK: - Toolbar

struct EditorToolbarView: View {
    @ObservedObject var coordinator: EditorCoordinator
    var onInsertImage: () -> Void
    @State private var isShowingLinkInput = false
    @State private var linkText = ""

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
                    .frame(width: 26, height: 22)
                    .contentShape(Rectangle())
            }
            .frame(width: 36)

            Divider().frame(height: 16)

            // Task list + Insert Image — moved up front (2nd/3rd items), per request
            FormatToggleButton(icon: "checklist", isActive: coordinator.selectionState.inTaskList) {
                coordinator.execCommand("taskList")
            }
            FormatButton(icon: "photo") {
                onInsertImage()
            }

            Divider().frame(height: 16)

            // Inline marks
            FormatToggleButton(icon: "bold", isActive: coordinator.selectionState.bold) {
                coordinator.execCommand("bold")
            }
            FormatToggleButton(icon: "italic", isActive: coordinator.selectionState.italic) {
                coordinator.execCommand("italic")
            }
            FormatToggleButton(icon: "strikethrough", isActive: coordinator.selectionState.strikethrough) {
                coordinator.execCommand("strikethrough")
            }
            FormatToggleButton(icon: "highlighter", isActive: coordinator.selectionState.highlight) {
                coordinator.execCommand("highlight")
            }
            FormatToggleButton(icon: "chevron.left.forwardslash.chevron.right", isActive: coordinator.selectionState.code) {
                coordinator.execCommand("code")
            }

            Divider().frame(height: 16)

            // Block formatting
            FormatToggleButton(icon: "quote.opening", isActive: coordinator.selectionState.inBlockquote) {
                coordinator.execCommand("blockquote")
            }

            Divider().frame(height: 16)

            // Indent / outdent
            FormatButton(icon: "decrease.indent") {
                coordinator.execCommand("outdent")
            }
            FormatButton(icon: "increase.indent") {
                coordinator.execCommand("indent")
            }

            Divider().frame(height: 16)

            // Insert (image moved above; table/HR remain)
            FormatButton(icon: "tablecells") {
                coordinator.execCommand("table", value: ["rows": 3, "cols": 3])
            }
            FormatButton(icon: "minus") {
                coordinator.execCommand("horizontalRule")
            }

            Divider().frame(height: 16)

            // Link
            FormatToggleButton(icon: "link", isActive: coordinator.selectionState.hasLink) {
                if coordinator.selectionState.hasLink {
                    coordinator.execCommand("link")  // removes link
                } else {
                    linkText = ""
                    isShowingLinkInput = true
                }
            }

            Divider().frame(height: 16)

            // Undo/redo — no longer pushed to the trailing edge with a Spacer() now
            // that this toolbar scrolls horizontally (see NoteEditorView): a Spacer()
            // inside a horizontal ScrollView tries to expand to fill the proposed
            // (effectively infinite) scroll width instead of just the visible width.
            FormatButton(icon: "arrow.uturn.backward") {
                coordinator.execCommand("undo")
            }
            FormatButton(icon: "arrow.uturn.forward") {
                coordinator.execCommand("redo")
            }
        }
        .contentShape(Rectangle())  // entire toolbar row is event-opaque; gaps between buttons don't fall through
        // SwiftUI alert replacement for Mac's NSAlert + NSTextField accessory view —
        // there's no UIKit/iOS equivalent of an alert with an embedded text field
        // outside of SwiftUI's own .alert(_:isPresented:actions:) TextField support.
        .alert("Insert Link", isPresented: $isShowingLinkInput) {
            TextField("https://example.com", text: $linkText)
                .keyboardType(.URL)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            Button("OK") {
                let href = linkText.trimmingCharacters(in: .whitespaces)
                if !href.isEmpty {
                    coordinator.execCommand("link", value: ["href": href])
                }
            }
            Button("Cancel", role: .cancel) {}
        }
    }
}

// MARK: - Format buttons

struct FormatButton: View {
    let icon: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 12))
                .frame(width: 26, height: 22)
                .contentShape(Rectangle())  // full frame is tappable, not just icon pixels
        }
        .foregroundStyle(.secondary)
    }
}

struct FormatToggleButton: View {
    let icon: String
    let isActive: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 12))
                .frame(width: 26, height: 22)
                .background(isActive ? Color.accentColor.opacity(0.15) : Color.clear)
                .cornerRadius(4)
                .contentShape(Rectangle())  // full frame is tappable
        }
        .foregroundStyle(isActive ? Color.accentColor : Color.secondary)
    }
}

#Preview {
    EditorView()
        .environmentObject(AppState())
}
