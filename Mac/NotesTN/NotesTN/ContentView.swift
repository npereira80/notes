import SwiftUI
import AppKit

// Mac only. NavigationSplitView's `ideal:` width is only a hint for the very first
// layout pass — but macOS's own window-state restoration ("Resume") separately
// remembers and re-applies the whole window's last saved layout (including the
// NavigationSplitView's NSSplitView divider positions) on every launch, AFTER that
// initial layout, silently overriding our `ideal:` value.
//
// A previous attempt reached into the NSSplitView directly and forced a divider
// position — that fought the `.balanced` style's own layout math and ended up
// resizing the WRONG divider (the sidebar/content one), shrinking the sidebar
// instead. Reaching into live AppKit layout state like that is too fragile.
//
// The standard, supported fix is simpler: opt the window itself out of state
// restoration via `NSWindow.isRestorable = false`. With nothing saved to restore,
// NavigationSplitView always falls back to its `ideal:` starting widths — no divider
// manipulation needed. Side effect: the window's position/size also won't be
// remembered across launches anymore (this is an all-or-nothing switch, not
// divider-specific) — flagging this in case it matters later.
private struct WindowRestorationDisabler: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let marker = NSView(frame: .zero)
        DispatchQueue.main.async { [weak marker] in
            marker?.window?.isRestorable = false
        }
        return marker
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}

struct ContentView: View {
    @EnvironmentObject var appState: AppState

    // Persists whether the sidebar (Sidebar column: All Notes, Trash, etc.) is
    // expanded or collapsed across launches — per request. First launch (no saved
    // preference yet) starts collapsed; every launch after that restores whatever
    // the user last left it as (see the onChange below that saves it).
    private static let sidebarVisibilityKey = "sidebarExpanded"
    @State private var columnVisibility: NavigationSplitViewVisibility = {
        guard UserDefaults.standard.object(forKey: sidebarVisibilityKey) != nil else {
            return .doubleColumn // collapsed — no saved preference yet (first launch)
        }
        return UserDefaults.standard.bool(forKey: sidebarVisibilityKey) ? .all : .doubleColumn
    }()

    // Persists the note list column's width across launches. NavigationSplitView has
    // no live width binding to read the user's dragged size back from — only a static
    // `ideal:` starting value — so a GeometryReader on the column observes its actual
    // rendered width and writes it to UserDefaults on every change. That keeps the
    // saved value continuously up to date, which covers "save on app close" for free
    // without needing a separate app-termination hook.
    private static let noteListWidthKey = "noteListColumnWidth"
    // Every launch starts at max width (360), ignoring whatever was saved from the
    // previous session, per request. Resizing during the running session is still
    // written to UserDefaults below (onChange, unchanged) — it's just no longer read
    // back as the initial value here.
    @State private var noteListColumnWidth: CGFloat = 360

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            SidebarView()
                .navigationSplitViewColumnWidth(min: 180, ideal: 220, max: 280)
        } content: {
            NoteListView()
                .background(
                    GeometryReader { proxy in
                        Color.clear
                            .onChange(of: proxy.size.width) { _, newWidth in
                                UserDefaults.standard.set(Double(newWidth), forKey: Self.noteListWidthKey)
                            }
                    }
                )
                .background(WindowRestorationDisabler())
                .navigationSplitViewColumnWidth(min: 220, ideal: noteListColumnWidth, max: 360)
        } detail: {
            EditorView()
        }
        .navigationSplitViewStyle(.balanced)
        .onChange(of: columnVisibility) { _, newValue in
            UserDefaults.standard.set(newValue == .all, forKey: Self.sidebarVisibilityKey)
        }
    }
}

#Preview {
    ContentView()
        .environmentObject(AppState())
}
