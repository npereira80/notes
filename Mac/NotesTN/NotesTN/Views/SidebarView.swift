import SwiftUI

// Sentinel tags for the All Notes / Trash rows' List(selection:) binding — not real
// folder ids, so they can never collide with one (Joplin-compatible folder ids are
// 32-char hex). Every row in the sidebar is tagged with one of these plain, non-optional
// Strings — never `nil` — because macOS's List(selection: Binding<T?>) treats a
// nil-tagged row as "clear selection" rather than a real selectable row: once something
// else was selected, clicking (or arrow-keying to) the nil-tagged row again silently did
// nothing, and that confusion also broke selecting the row next to it. Routing every row
// through appState.selectedFolderID/isTrashSelected via plain string sentinels (see
// `sidebarSelection` below) sidesteps that entirely.
private let allNotesSentinel = "__all__"
private let trashSentinel = "__trash__"

struct SidebarView: View {
    @EnvironmentObject var appState: AppState
    @Environment(\.colorScheme) private var colorScheme
    @State private var newFolderName: String = ""
    @State private var isAddingFolder = false
    @State private var renamingFolderID: String? = nil
    @State private var renameText: String = ""
    // Whether the sidebar List itself has keyboard focus, vs. the note list or
    // the editor — drives the selected row's Vivid (focused) vs. gray+dark-yellow
    // text (not focused) appearance. Forwarded to AppState so NoteListView can
    // react to it too (see AppState.isSidebarFocused).
    @FocusState private var isFocused: Bool

    // Rounded rect inset from the row's left/right edges — mirrors the selected
    // note row's look in NoteListView.swift (RoundedRectangle(cornerRadius: 8)
    // sized to the row's own horizontal padding) instead of List's default
    // edge-to-edge listRowBackground fill.
    private func rowBackground(selected: Bool) -> some View {
        let color: Color = selected
            ? (appState.isSidebarFocused ? AppColors.vividYellow : AppColors.sidebarSelectedInactiveBackground(colorScheme))
            : Color.clear
        return RoundedRectangle(cornerRadius: 6)
            .fill(color)
            .padding(.horizontal, 8)
    }

    private func rowForeground(selected: Bool) -> Color {
        guard selected else { return Color.secondary }
        return appState.isSidebarFocused ? Color.primary : AppColors.darkYellow
    }

    private func noteCount(for folder: Folder) -> Int {
        appState.notes.filter { $0.folderId == folder.id }.count
    }

    // Builds "All Notes"/"Trash" rows as an explicit Image + Text instead of
    // Label(_:systemImage:) — macOS sidebar Lists don't reliably apply
    // .foregroundStyle to a Label's SF Symbol icon (the row content's own
    // tinting wins), leaving the icon gray even when the text is yellow. A
    // plain Image respects .foregroundStyle correctly.
    private func sidebarRow(title: String, systemImage: String, selected: Bool) -> some View {
        HStack(spacing: 4) {
            Image(systemName: systemImage)
            Text(title)
        }
        .foregroundStyle(rowForeground(selected: selected))
    }

    // Bridges the sentinel-based row tags to AppState's real selectedFolderID/
    // isTrashSelected — see the comment on the sentinels above for why this can't just
    // be `$appState.selectedFolderID` directly.
    private var sidebarSelection: Binding<String> {
        Binding<String>(
            get: {
                if appState.isTrashSelected { return trashSentinel }
                return appState.selectedFolderID ?? allNotesSentinel
            },
            set: { newValue in
                if newValue == trashSentinel {
                    appState.selectTrash()
                } else if newValue == allNotesSentinel {
                    appState.selectFolder(nil)
                } else {
                    let folder = appState.folders.first { $0.id == newValue }
                    appState.selectFolder(folder)
                }
            }
        )
    }

    var body: some View {
        List(selection: sidebarSelection) {

            // MARK: All Notes / Trash
            Section {
                sidebarRow(title: "All Notes", systemImage: "note.text", selected: appState.selectedFolderID == nil && !appState.isTrashSelected)
                    .tag(allNotesSentinel)
                    .listRowBackground(rowBackground(selected: appState.selectedFolderID == nil && !appState.isTrashSelected))

                sidebarRow(title: "Trash", systemImage: "trash", selected: appState.isTrashSelected)
                    .tag(trashSentinel)
                    .listRowBackground(rowBackground(selected: appState.isTrashSelected))
            }

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
                        HStack {
                            sidebarRow(title: folder.title, systemImage: "folder", selected: appState.selectedFolderID == folder.id && !appState.isTrashSelected)
                            Spacer()
                            // Always a muted gray, regardless of selection — matches
                            // Apple Notes, where the count stays quiet even on a
                            // highlighted row.
                            Text("\(noteCount(for: folder))")
                                .font(.system(size: 11))
                                .foregroundStyle(Color.secondary)
                        }
                            .tag(folder.id)
                            .listRowBackground(rowBackground(selected: appState.selectedFolderID == folder.id && !appState.isTrashSelected))
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
        .focused($isFocused)
        .onChange(of: isFocused) { _, newValue in
            appState.isSidebarFocused = newValue
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
                        .foregroundStyle(Color.secondary)
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
