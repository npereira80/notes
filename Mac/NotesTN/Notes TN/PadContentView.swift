import SwiftUI

// iPad-only. Fresh rebuild (per request) — a default NavigationSplitView with 3
// plain sections (Notebooks / Notes / Editor), no custom column-width persistence or
// styling yet. `.automatic` visibility (rather than a hardcoded `.all`) lets the
// system decide when to collapse columns as the window narrows, so we can first
// confirm that resize/collapse behavior works before layering anything custom back
// on top of it.
struct PadContentView: View {
    @State private var columnVisibility: NavigationSplitViewVisibility = .automatic
    // Read here, above NavigationSplitView, and passed down explicitly — inside a
    // column (e.g. PadNoteListView), @Environment(\.horizontalSizeClass) reflects that
    // column's own (narrow) width, not the overall window, so it was reporting
    // .compact even with all 3 columns visible on a full-size iPad.
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            PadSidebarView()
        } content: {
            PadNoteListView(windowSizeClass: horizontalSizeClass)
        } detail: {
            PadEditorView()
        }
    }
}

#Preview {
    PadContentView()
        .environmentObject(AppState())
}
