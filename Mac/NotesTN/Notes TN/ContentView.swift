import SwiftUI
import UIKit

// iOS/iPadOS-only. Duplicated from the Mac target's ContentView.swift (same pattern
// already used for EditorView.swift) so iPhone/iPad navigation can diverge from Mac's
// without #if os(...) branching in a shared file. Sidebar-collapsed-by-default/
// persistence (Mac only, per request) doesn't apply here — the sidebar column always
// starts expanded; NavigationSplitView itself handles collapsing it into a stack on
// compact-width (iPhone) automatically.
//
// iPad routes to PadContentView — a freshly rebuilt, separate NavigationSplitView
// (own Sidebar/NoteList/Editor types, no shared code with the iPhone path below) per
// request, after repeated iPad-specific toolbar/navigation bugs in the old shared
// implementation. iPhone keeps using the exact same NavigationSplitView(Sidebar/
// NoteList/Editor) wiring it always has — untouched.
struct ContentView: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        if UIDevice.current.userInterfaceIdiom == .pad {
            PadContentView()
                .environmentObject(appState)
        } else {
            PhoneContentView()
                .environmentObject(appState)
        }
    }
}

private struct PhoneContentView: View {
    @EnvironmentObject var appState: AppState

    @State private var columnVisibility: NavigationSplitViewVisibility = .all

    // Persists the note list column's width across launches. NavigationSplitView has
    // no live width binding to read the user's dragged size back from — only a static
    // `ideal:` starting value — so a GeometryReader on the column observes its actual
    // rendered width and writes it to UserDefaults on every change.
    private static let noteListWidthKey = "noteListColumnWidth"
    @State private var noteListColumnWidth: CGFloat = {
        let saved = UserDefaults.standard.double(forKey: noteListWidthKey)
        return saved > 0 ? CGFloat(saved) : 360
    }()

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
                .navigationSplitViewColumnWidth(min: 220, ideal: noteListColumnWidth, max: 360)
        } detail: {
            EditorView()
        }
        .navigationSplitViewStyle(.balanced)
    }
}

#Preview {
    ContentView()
        .environmentObject(AppState())
}
