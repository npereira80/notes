import SwiftUI
import WebKit
import UIKit
import Combine
import QuickLook
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

    // The last content this editor is known to hold — written by setContent (what we
    // pushed in) and by the contentChanged message (what the user typed). Lets the
    // owning view tell a sync-pulled external change (DB body differs from this →
    // refresh the editor) from the echo of its own autosave (identical → ignore),
    // without re-keying/reloading the WKWebView. Mirrors Mac's EditorCoordinator.
    var lastKnownTitle: String = ""
    var lastKnownBody: String = ""

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
                UIApplication.shared.open(url)
            }

        case "openMaps":
            // A detected address (see the data detectors in EditorBundle) — let the
            // user pick which maps app to open it in.
            if let address = body["url"] as? String {
                presentMapsChooser(address: address)
            }

        case "openAttachment", "editAttachment":
            // Mobile is preview-only: both a tap and a double tap just preview the
            // file. Editing an attachment in place is a desktop feature (iOS hands
            // other apps a copy, so an edit there could never sync back).
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

    // Builds the two maps apps' universal-link search URLs. Universal links open the
    // app if installed, otherwise the website — no per-app scheme / installed check.
    static func mapsURL(forApp app: String, address: String) -> URL? {
        let query = address.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? address
        switch app {
        case "google": return URL(string: "https://www.google.com/maps/search/?api=1&query=\(query)")
        case "waze":   return URL(string: "https://waze.com/ul?q=\(query)")
        default:       return nil
        }
    }

    /// UIAlertController chooser (Google Maps / Waze) for a detected address. Presented
    /// from the active window's root view controller so it works from the coordinator
    /// without wiring every SwiftUI editor view; .alert style (not .actionSheet) is
    /// used so it needs no popover source on iPad.
    private func presentMapsChooser(address: String) {
        guard let root = Self.activeRootViewController() else { return }
        // Don't stack a second chooser if one is already up (e.g. two quick taps) —
        // present would otherwise silently no-op and swallow the second tap.
        guard root.presentedViewController == nil else { return }
        let alert = UIAlertController(title: "Open address in", message: address, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "Google Maps", style: .default) { _ in
            if let url = Self.mapsURL(forApp: "google", address: address) { UIApplication.shared.open(url) }
        })
        alert.addAction(UIAlertAction(title: "Waze", style: .default) { _ in
            if let url = Self.mapsURL(forApp: "waze", address: address) { UIApplication.shared.open(url) }
        })
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        root.present(alert, animated: true)
    }

    private static func activeRootViewController() -> UIViewController? {
        let scene = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive } ?? UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        let keyWindow = scene?.windows.first { $0.isKeyWindow } ?? scene?.windows.first
        var top = keyWindow?.rootViewController
        while let presented = top?.presentedViewController { top = presented }
        return top
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

    // MARK: WKNavigationDelegate — content process recovery

    // iOS kills WKWebView content processes readily (memory pressure, long
    // background stretches). Without this, the editor silently turns blank/broken
    // and stays that way until the app is force-quit and reopened. Reloading
    // re-runs the page, which re-fires the JS "ready" message — isReady flipping
    // back to true makes the owning view push the current content back in via its
    // onChange(of: isReady).
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
        // Serves "notestn://resource/<filename>" image URLs directly from
        // DatabaseManager's resourcesDirectory — see ImageResourceSchemeHandler above.
        config.setURLSchemeHandler(ImageResourceSchemeHandler(), forURLScheme: "notestn")

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

// MARK: - Image resource scheme handler

/// Serves image bytes for "notestn://resource/<filename>" URLs directly from
/// DatabaseManager's resourcesDirectory, instead of relying on file:// +
/// allowingReadAccessTo — which can only grant one directory tree per WKWebView, and
/// that tree is already spent on the app bundle (see the comment on
/// RichTextEditorView.makeUIView above). This mirrors Android's approach of serving
/// resources through a virtual origin (WebViewAssetLoader) rather than raw file://
/// paths. Registered on the WKWebViewConfiguration in makeUIView below.
/// DatabaseManager.resourceLocalUrl(id:) is the single place that emits this scheme
/// (iOS-only branch) — see DatabaseManager.swift.
final class ImageResourceSchemeHandler: NSObject, WKURLSchemeHandler {
    // Tasks WebKit has cancelled (stop was called) — calling didReceive/didFinish on
    // a stopped task throws an ObjC exception. Guarded because the file read below
    // now happens off-thread, so a task can be stopped mid-read. Accessed on the
    // main thread only (WebKit delivers start/stop there, and the read hops back).
    private var stoppedTasks = Set<ObjectIdentifier>()

    func webView(_ webView: WKWebView, start urlSchemeTask: WKURLSchemeTask) {
        guard let url = urlSchemeTask.request.url,
              let dir = DatabaseManager.shared.resourcesDirectory else {
            urlSchemeTask.didFailWithError(URLError(.badURL))
            return
        }
        let filename = url.lastPathComponent
        let fileURL = dir.appendingPathComponent(filename)

        // The read runs off the main thread — WebKit calls this handler on main, and
        // a multi-MB photo read with Data(contentsOf:) stalled the whole UI every
        // time a note containing images was opened. The urlSchemeTask calls hop back
        // to main (they must run on the thread the task was delivered on).
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let data = try? Data(contentsOf: fileURL)
            let mimeType = UTType(filenameExtension: fileURL.pathExtension)?.preferredMIMEType ?? "application/octet-stream"
            DispatchQueue.main.async {
                guard let self else { return }
                // Removing (not just checking) keeps the set from accumulating —
                // every stopped task's marker is consumed exactly once, by the
                // completion of its own in-flight read.
                if self.stoppedTasks.remove(ObjectIdentifier(urlSchemeTask)) != nil { return }
                guard let data else {
                    urlSchemeTask.didFailWithError(URLError(.fileDoesNotExist))
                    return
                }
                let response = URLResponse(url: url, mimeType: mimeType, expectedContentLength: data.count, textEncodingName: nil)
                urlSchemeTask.didReceive(response)
                urlSchemeTask.didReceive(data)
                urlSchemeTask.didFinish()
            }
        }
    }

    func webView(_ webView: WKWebView, stop urlSchemeTask: WKURLSchemeTask) {
        stoppedTasks.insert(ObjectIdentifier(urlSchemeTask))
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
    // In-note find (a toolbar button on iPhone, Cmd+Shift+F with a keyboard) —
    // highlights matches in the editor, distinct from the global note-list search.
    @State private var showFind = false
    @State private var findQuery = ""
    @State private var findCount = 0
    @State private var findCurrent = 0
    // Replace row. While it's showing, matching switches to case-sensitive so a
    // replace only rewrites the exact text it highlighted.
    @State private var showReplace = false
    @State private var replaceText = ""
    private let noteID: String
    private let initialTitle: String
    private let initialBody: String
    private let readOnly: Bool

    // iPad only — custom search field (NoteListView.swift's own .searchable didn't
    // reliably dock into the toolbar in this app's 3-column NavigationSplitView; it
    // silently fell back to rendering inline under the note list's title instead).
    // Declared here, next to the New Note button below, so both land in this
    // column's (detail's) own toolbar segment — the trailing/top-right area above
    // the editor pane — per the red-boxed mockup.
    @FocusState private var isTabletSearchFocused: Bool

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

            // In-note find bar — under the nav bar, above the editor content.
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
                    .padding(.vertical, 13.75)
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
            // New Note first (leading), search field second (trailing) — declaration
            // order is left-to-right for .primaryAction items. iPhone and iPad both
            // get New Note; default system button styling (no .foregroundStyle
            // override) per request.
            if !readOnly {
                ToolbarItem(placement: .primaryAction) {
                    Button { appState.createNote() } label: {
                        Image(systemName: "square.and.pencil")
                    }
                }
                .sharedBackgroundVisibility(.hidden)
            }
            // In-note find button (iPhone) — iPad triggers find via Cmd+Shift+F instead.
            if isPhoneIdiom && !readOnly {
                ToolbarItem(placement: .primaryAction) {
                    Button { toggleFind() } label: {
                        Image(systemName: "magnifyingglass")
                    }
                }
                .sharedBackgroundVisibility(.hidden)
            }
            // iPad only — see isTabletSearchFocused's doc comment above. A separate
            // ToolbarItem from the New Note button above (not merged into one), per
            // earlier request — .sharedBackgroundVisibility(.hidden) on both stops
            // iPadOS from auto-fusing adjacent .primaryAction items into one shared
            // pill.
            if !isPhoneIdiom {
                ToolbarItem(placement: .primaryAction) {
                    tabletSearchField
                }
                .sharedBackgroundVisibility(.hidden)
            }
        }
        .onChange(of: appState.isFocusingSearch) { _, focused in
            // iPhone's own search field lives in NoteListView.swift, which has its
            // own identical onChange handler for isPhoneSearchFocused — leave
            // appState.isFocusingSearch untouched here so that handler still fires.
            guard focused, !isPhoneIdiom else { return }
            isTabletSearchFocused = true
            appState.isFocusingSearch = false
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
        // Cmd+Shift+F toggles find (external keyboard on iPad/iPhone); iPhone also has
        // the toolbar find button above.
        .background(
            Button("") { toggleFind() }
                .keyboardShortcut("f", modifiers: [.command, .shift])
                .opacity(0)
        )
        // Cmd+Option+F (external keyboard) — opens find with replace already showing.
        .background(
            Button("") { showReplace = true; showFind = true }
                .keyboardShortcut("f", modifiers: [.command, .option])
                .opacity(0)
        )
        .onChange(of: findQuery) { _, q in editorCoordinator.find(q, caseSensitive: showReplace) }
        // Toggling Replace changes how matches are found (exact case while replacing).
        .onChange(of: showReplace) { _, replacing in
            editorCoordinator.find(findQuery, caseSensitive: replacing)
        }
        .onChange(of: editorCoordinator.isReady) { _, ready in
            guard ready else { return }
            // Reads the note fresh from AppState (falling back to the init-time
            // snapshot) — isReady also re-fires after a content-process-terminate
            // reload (see EditorCoordinator.webViewWebContentProcessDidTerminate),
            // by which time the snapshot may be stale.
            let note = currentNote
            editorCoordinator.setContent(title: note?.title ?? initialTitle, body: note?.body ?? initialBody)
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
        // A sync pull that updates the currently open note used to leave the editor
        // showing the old content until the note was reopened or the app relaunched
        // — and the next autosave would overwrite the pulled remote edit with the
        // stale editor content. lastKnown* filtering keeps this from reacting to the
        // echo of the editor's own autosaves. Same fix as Mac's NoteEditorView.
        .onChange(of: currentNote?.updatedTime) { _, _ in
            guard editorCoordinator.isReady, let note = currentNote else { return }
            if note.title != editorCoordinator.lastKnownTitle || note.body != editorCoordinator.lastKnownBody {
                editorCoordinator.setContent(title: note.title, body: note.body)
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

    /// The freshest copy of this view's note in AppState (live or trashed) — the
    /// init-time title/body snapshot goes stale as soon as the user types or a sync
    /// pulls a newer version.
    private var currentNote: Note? {
        appState.notes.first { $0.id == noteID } ?? trashedNote
    }

    // iPad-only compact search field, placed directly in this view's own toolbar
    // (see .toolbar above) next to the New Note button — .searchable(placement:
    // .toolbar) attached to NoteListView.swift didn't reliably dock into the native
    // toolbar in this app's 3-column NavigationSplitView (it silently rendered
    // inline under the note list's title instead), so this is a hand-built
    // stand-in, matching phoneSearchBar's look in NoteListView.swift.
    @ViewBuilder
    private var tabletSearchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField("Search", text: Binding(get: { appState.searchText }, set: { appState.search($0) }))
                .focused($isTabletSearchFocused)
                .submitLabel(.search)
                .frame(minWidth: 100, idealWidth: 180, maxWidth: 220)
            if !appState.searchText.isEmpty {
                Button {
                    appState.search("")
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Color.gray.opacity(0.15), in: Capsule())
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
            .padding(.horizontal, 15)
            .padding(.vertical, 10)
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
                  let src = DatabaseManager.shared.resourceLocalUrl(id: resource.id) else { return }
            editorCoordinator.insertImage(
                src: src,
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

    private func closeFind() {
        showFind = false
        showReplace = false
        findQuery = ""
        replaceText = ""
        findCount = 0
        findCurrent = 0
        editorCoordinator.endFind()
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

        guard let src = DatabaseManager.shared.resourceLocalUrl(id: resourceId) else { return }
        editorCoordinator.insertImage(
            src: src,
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

// MARK: - Attachment preview (QuickLook)

/// Previews an attachment in QuickLook — the system previewer, same as Files or Mail.
/// QLPreviewController needs a data source, so this singleton holds the URL being
/// previewed and acts as it. iPhone and iPad are preview-only; attachments are created
/// and edited on the Mac.
final class AttachmentPreview: NSObject, QLPreviewControllerDataSource {
    private static let shared = AttachmentPreview()
    private var url: URL?

    @MainActor
    static func show(url: URL) {
        shared.url = url
        guard let presenter = activeViewController() else { return }
        // Don't stack a second previewer if one is already up.
        guard presenter.presentedViewController == nil else { return }
        let controller = QLPreviewController()
        controller.dataSource = shared
        presenter.present(controller, animated: true)
    }

    func numberOfPreviewItems(in controller: QLPreviewController) -> Int { url == nil ? 0 : 1 }

    func previewController(_ controller: QLPreviewController, previewItemAt index: Int) -> QLPreviewItem {
        (url ?? URL(fileURLWithPath: "")) as NSURL
    }

    @MainActor
    private static func activeViewController() -> UIViewController? {
        let scene = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive }
            ?? UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        let keyWindow = scene?.windows.first { $0.isKeyWindow } ?? scene?.windows.first
        var top = keyWindow?.rootViewController
        while let presented = top?.presentedViewController { top = presented }
        return top
    }
}

// MARK: - Find bar

/// In-note find bar (Cmd+Shift+F on iPad; a toolbar button on iPhone). Search field,
/// match counter, prev/next, Done. Shared by iPhone (NoteEditorView) and iPad
/// (PadEditorView).
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
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Find in note", text: $query)
                    .textFieldStyle(.plain)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .submitLabel(.search)
                    .focused($focused)
                    .onSubmit(onNext)
                if !query.isEmpty {
                    Text(count > 0 ? "\(current)/\(count)" : "0/0")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                // Toggling this shows the replace row; it also switches matching to
                // exact case, so a replace only rewrites what was highlighted.
                // A Toggle with the system .button style draws its own on/off state,
                // rather than us swapping icons by hand.
                Toggle(isOn: $showReplace) {
                    Image(systemName: "arrow.2.squarepath")
                }
                .toggleStyle(.button)
                .accessibilityLabel("Replace")
                Button(action: onPrevious) { Image(systemName: "chevron.up") }
                    .disabled(count == 0)
                Button(action: onNext) { Image(systemName: "chevron.down") }
                    .disabled(count == 0)
                Button("Done", action: onClose)
            }
            if showReplace {
                HStack(spacing: 8) {
                    Image(systemName: "arrow.2.squarepath").foregroundStyle(.secondary)
                    TextField("Replace with", text: $replacement)
                        .textFieldStyle(.plain)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        .onSubmit(onReplace)
                    Button("Replace", action: onReplace)
                        .disabled(count == 0)
                    Button("All", action: onReplaceAll)
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
    // Defaults to true so existing call sites (iPhone floating toolbar, iPad's prior
    // embedded row) keep undo/redo unchanged — PadEditorView.swift passes false to
    // omit them from its bar specifically.
    var showsUndoRedo: Bool = true
    @State private var isShowingLinkInput = false
    @State private var linkText = ""
    @State private var showMarkdownSource = false

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
            .frame(width: 45)

            Divider().frame(height: 20)

            // Task list + Insert Image — moved up front (2nd/3rd items), per request
            FormatToggleButton(icon: "checklist", isActive: coordinator.selectionState.inTaskList) {
                coordinator.execCommand("taskList")
            }
            FormatButton(icon: "photo") {
                onInsertImage()
            }

            Divider().frame(height: 20)

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
            // Code: a partial selection inside a line becomes inline code, a whole
            // paragraph (or several) becomes a code block — see setCodeBlock in
            // EditorBundle/src/commands.ts. Active for either kind.
            FormatToggleButton(icon: "chevron.left.forwardslash.chevron.right", isActive: coordinator.selectionState.inCode || coordinator.selectionState.code) {
                coordinator.execCommand("codeBlock")
            }

            Divider().frame(height: 20)

            // Lists
            FormatToggleButton(icon: "list.bullet", isActive: coordinator.selectionState.inBulletList) {
                coordinator.execCommand("bulletList")
            }
            FormatToggleButton(icon: "list.number", isActive: coordinator.selectionState.inOrderedList) {
                coordinator.execCommand("orderedList")
            }

            Divider().frame(height: 20)

            // Block formatting
            FormatToggleButton(icon: "quote.opening", isActive: coordinator.selectionState.inBlockquote) {
                coordinator.execCommand("blockquote")
            }

            Divider().frame(height: 20)

            // Indent / outdent
            FormatButton(icon: "decrease.indent") {
                coordinator.execCommand("outdent")
            }
            FormatButton(icon: "increase.indent") {
                coordinator.execCommand("indent")
            }

            Divider().frame(height: 20)

            // Insert (image moved above; table/HR remain)
            FormatButton(icon: "tablecells") {
                coordinator.execCommand("table", value: ["rows": 3, "cols": 3])
            }
            FormatButton(icon: "minus") {
                coordinator.execCommand("horizontalRule")
            }

            Divider().frame(height: 20)

            // Link
            FormatToggleButton(icon: "link", isActive: coordinator.selectionState.hasLink) {
                if coordinator.selectionState.hasLink {
                    coordinator.execCommand("link")  // removes link
                } else {
                    linkText = ""
                    isShowingLinkInput = true
                }
            }

            Divider().frame(height: 20)

            // Debugging aid — view the Joplin Markdown the current editor HTML converts
            // to (the format actually stored/synced), so an HTML rendering bug can be
            // traced to its Markdown source.
            FormatButton(icon: "doc.plaintext") { showMarkdownSource = true }

            Divider().frame(height: 20)

            if showsUndoRedo {
                // Undo/redo — no longer pushed to the trailing edge with a Spacer()
                // now that this toolbar scrolls horizontally (see NoteEditorView): a
                // Spacer() inside a horizontal ScrollView tries to expand to fill the
                // proposed (effectively infinite) scroll width instead of just the
                // visible width.
                FormatButton(icon: "arrow.uturn.backward") {
                    coordinator.execCommand("undo")
                }
                FormatButton(icon: "arrow.uturn.forward") {
                    coordinator.execCommand("redo")
                }
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
        .sheet(isPresented: $showMarkdownSource) {
            MarkdownSourceView(markdown: HtmlToMarkdown.convert(coordinator.lastKnownBody))
        }
    }
}

// MARK: - Markdown source viewer

/// Read-only view of a note's Markdown source (what HtmlToMarkdown produces from the
/// current editor HTML). A debugging aid for tracing HTML rendering issues back to
/// their stored/synced Markdown. Shared by iPad (PadEditorView) and iPhone.
private struct MarkdownSourceView: View {
    let markdown: String
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                Text(markdown.isEmpty ? "(empty)" : markdown)
                    .font(.system(.body, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding()
            }
            .navigationTitle("Markdown Source")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Copy") { UIPasteboard.general.string = markdown }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
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
                .font(.system(size: 15))
                .frame(width: 32.5, height: 27.5)
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
                .font(.system(size: 15))
                .frame(width: 32.5, height: 27.5)
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
