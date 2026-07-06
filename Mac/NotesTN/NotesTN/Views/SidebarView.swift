import SwiftUI

// Sentinel tag for the Trash row's List(selection:) binding — not a real folder id,
// so it can never collide with one (Joplin-compatible folder ids are 32-char hex).
private let trashSentinel = "__trash__"

struct SidebarView: View {
    @EnvironmentObject var appState: AppState
    @State private var newFolderName: String = ""
    @State private var isAddingFolder = false
    @State private var renamingFolderID: String? = nil
    @State private var renameText: String = ""

    var body: some View {
        List(selection: $appState.selectedFolderID) {

            // MARK: All Notes
            Label("All Notes", systemImage: "note.text")
                .tag(Optional<String>.none)
                .foregroundStyle(appState.selectedFolderID == nil && !appState.isTrashSelected ? .primary : .secondary)

            // MARK: Trash
            // Routed through the same selectedFolderID tag/selection mechanism as every
            // other row (via a sentinel value) rather than a separate tap gesture, since
            // List(selection:) rows on macOS don't reliably forward taps to a plain
            // onTapGesture underneath their own selection handling.
            Label("Trash", systemImage: "trash")
                .tag(Optional(trashSentinel))
                .foregroundStyle(appState.isTrashSelected ? .primary : .secondary)

            // MARK: Notebooks
            Section("Notebooks") {
                ForEach(appState.folders) { folder in
                    if renamingFolderID == folder.id {
                        // Inline rename field
                        TextField("Notebook name", text: $renameText, onCommit: {
                            appState.renameFolder(folder, to: renameText)
                            renamingFolderID = nil
                        })
                        .textFieldStyle(.plain)
                        .onExitCommand { renamingFolderID = nil }
                    } else {
                        Label(folder.title, systemImage: "folder")
                            .tag(Optional(folder.id))
                            .contextMenu {
                                Button("Rename") {
                                    renameText = folder.title
                                    renamingFolderID = folder.id
                                }
                                Divider()
                                Button("Delete Notebook", role: .destructive) {
                                    appState.deleteFolder(folder)
                                }
                            }
                    }
                }
            }

            // MARK: Add Notebook inline
            if isAddingFolder {
                HStack {
                    Image(systemName: "folder.badge.plus")
                        .foregroundStyle(.secondary)
                    TextField("Notebook name", text: $newFolderName, onCommit: {
                        let name = newFolderName.trimmingCharacters(in: .whitespaces)
                        if !name.isEmpty {
                            appState.createFolder(title: name)
                        }
                        newFolderName = ""
                        isAddingFolder = false
                    })
                    .textFieldStyle(.plain)
                    .onExitCommand {
                        newFolderName = ""
                        isAddingFolder = false
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .onChange(of: appState.selectedFolderID) { _, newValue in
            if newValue == trashSentinel {
                appState.selectTrash()
            } else {
                let folder = appState.folders.first { $0.id == newValue }
                appState.selectFolder(folder)
            }
        }
        .safeAreaInset(edge: .top) {
            if appState.isSyncing {
                ProgressView()
                    .controlSize(.small)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
            }
        }
        .safeAreaInset(edge: .bottom) {
            HStack {
                Button {
                    isAddingFolder = true
                } label: {
                    Label("Add Notebook", systemImage: "folder.badge.plus")
                        .labelStyle(.iconOnly)
                }
                .buttonStyle(.plain)
                .padding(8)
                Spacer()
            }
        }
        .navigationTitle("Notes TN")
    }
}

#Preview {
    SidebarView()
        .environmentObject(AppState())
}
