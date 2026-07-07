import SwiftUI

struct ContentView: View {
    @EnvironmentObject var appState: AppState
    @State private var columnVisibility = NavigationSplitViewVisibility.all

    // Persists the note list column's width across launches. NavigationSplitView has
    // no live width binding to read the user's dragged size back from — only a static
    // `ideal:` starting value — so a GeometryReader on the column observes its actual
    // rendered width and writes it to UserDefaults on every change. That keeps the
    // saved value continuously up to date, which covers "save on app close" for free
    // without needing a separate app-termination hook.
    private static let noteListWidthKey = "noteListColumnWidth"
    // Default (no saved width yet, e.g. first launch) is the column's max — 360, matching
    // the `max:` below.
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
