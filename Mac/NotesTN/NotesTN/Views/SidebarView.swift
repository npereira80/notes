import SwiftUI
#if os(iOS)
import UIKit
#endif

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

private extension View {
    // .onExitCommand (Escape key) only exists on macOS/tvOS — no-op on iOS for now.
    // A touch-friendly replacement (e.g. a Cancel button on the inline rename/new-folder
    // field) is a follow-up; this just keeps the iOS target compiling in the meantime.
    @ViewBuilder
    func onExitCommandCompat(perform action: @escaping () -> Void) -> some View {
        #if os(macOS)
        self.onExitCommand(perform: action)
        #else
        self
        #endif
    }
}

struct SidebarView: View {
    @EnvironmentObject var appState: AppState
    @Environment(\.colorScheme) private var colorScheme
    @State private var newFolderName: String = ""
    @State private var isAddingFolder = false
    @State private var renamingFolderID: String? = nil
    @State private var renameText: String = ""
    // Log Out lives in NotesTNApp.swift's menu bar on Mac (no visible chrome needed
    // there) — iOS has no menu bar, so it needs a touch-reachable button here instead.
    // See showLogoutConfirmationDialog below for the NSAlert-free confirmation.
    @ObservedObject private var joplinAccountStore = JoplinAccountStore.shared
    @State private var showLogoutConfirm = false

    // iPad only — Login/Force Resync are already in NotesTNApp.swift's .commands (which
    // populates iPadOS's Mac-style menu bar), but that's easy to miss/not discover, and
    // this app has no other iPad-reachable UI for logging in at all (Force Resync at
    // least has pull-to-refresh as an equivalent). See bottom safeAreaInset below.
    #if os(iOS)
    private var isPadIdiom: Bool { UIDevice.current.userInterfaceIdiom == .pad }
    #else
    private var isPadIdiom: Bool { false }
    #endif
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

    // Queries the database directly instead of filtering appState.notes — that array
    // is scoped to whichever folder is currently selected (db.fetchNotes(folderId:)),
    // so counting against it showed 0 for every notebook except the selected one.
    private func noteCount(for folder: Folder) -> Int {
        DatabaseManager.shared.fetchNotes(folderId: folder.id).count
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

    #if !os(macOS)
    // iOS/iPadOS equivalent of sidebarSelection above, using List's OPTIONAL-binding
    // selection: overload (Binding<String?>) instead of the non-optional one Mac uses
    // (that overload is macOS/tvOS-only — see the "unavailable in iOS" build error this
    // replaces). NavigationSplitView needs this real selection: binding to know when to
    // push forward to the note list on iPhone's single-column compact layout; without it
    // (the previous plain-List + per-row tap approach) taps updated AppState correctly
    // but the UI never advanced past the sidebar.
    private var sidebarSelectionIOS: Binding<String?> {
        Binding<String?>(
            get: {
                if appState.isTrashSelected { return trashSentinel }
                return appState.selectedFolderID ?? allNotesSentinel
            },
            set: { newValue in
                switch newValue {
                case trashSentinel: appState.selectTrash()
                case allNotesSentinel, nil: appState.selectFolder(nil)
                default:
                    let folder = appState.folders.first { $0.id == newValue }
                    appState.selectFolder(folder)
                }
            }
        )
    }
    #endif

    // .tag(...) is read by List's native selection: binding on both platforms (see body).
    @ViewBuilder
    private var sidebarRows: some View {
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
                    .onExitCommandCompat { renamingFolderID = nil }
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
                .onExitCommandCompat {
                    newFolderName = ""
                    isAddingFolder = false
                }
            }
        }
    }

    var body: some View {
        Group {
            #if os(macOS)
            List(selection: sidebarSelection) {
                sidebarRows
            }
            #else
            // Optional-binding overload (see sidebarSelectionIOS above) — this is what
            // NavigationSplitView needs to detect selection changes and push forward on
            // iPhone's compact single-column layout.
            List(selection: sidebarSelectionIOS) {
                sidebarRows
            }
            #endif
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
                .padding(.vertical, 8)
                .padding(.leading, 20)
                .padding(.trailing, 8)
                Spacer()
                #if !os(macOS)
                if joplinAccountStore.account != nil {
                    // iPad only — Force Resync, alongside pull-to-refresh (which does a
                    // normal, non-force sync — see NoteListView's forceResync()).
                    if isPadIdiom {
                        Button {
                            appState.syncNow(force: true)
                        } label: {
                            Label("Force Resync", systemImage: "arrow.triangle.2.circlepath")
                                .labelStyle(.iconOnly)
                                .foregroundStyle(Color.secondary)
                        }
                        .buttonStyle(.plain)
                        .padding(8)
                        .help("Force Resync")
                    }
                    Button {
                        showLogoutConfirm = true
                    } label: {
                        Label("Log Out", systemImage: "rectangle.portrait.and.arrow.right")
                            .labelStyle(.iconOnly)
                            .foregroundStyle(Color.secondary)
                    }
                    .buttonStyle(.plain)
                    .padding(8)
                } else if isPadIdiom {
                    // iPad only — the only touch-reachable way to log in; previously this
                    // only existed inside NotesTNApp.swift's .commands (iPadOS's Mac-style
                    // menu bar), which isn't a reliable/discoverable UI on its own. Opens
                    // the same shared Joplin Cloud email/password modal (LoginView).
                    Button {
                        appState.isShowingJoplinLogin = true
                    } label: {
                        Label("Log In to Joplin Cloud…", systemImage: "person.crop.circle.badge.plus")
                            .labelStyle(.iconOnly)
                            .foregroundStyle(Color.secondary)
                    }
                    .buttonStyle(.plain)
                    .padding(8)
                    .help("Log In to Joplin Cloud…")
                }
                #endif
            }
        }
        // Matches Mac's confirmLogout() (NotesTNApp.swift) wording — SwiftUI's
        // .confirmationDialog instead of NSAlert, which doesn't exist on iOS. Only
        // reachable via the iOS-only button above; harmless to leave declared
        // unconditionally.
        .confirmationDialog(
            "Log out of Joplin Cloud on this device? Your local notes stay put.",
            isPresented: $showLogoutConfirm,
            titleVisibility: .visible
        ) {
            Button("Log Out", role: .destructive) { joplinAccountStore.clear() }
            Button("Cancel", role: .cancel) {}
        }
        .navigationTitle("Notes TN")
    }
}

#Preview {
    SidebarView()
        .environmentObject(AppState())
}
