import SwiftUI

@main
struct NotesTNApp: App {
    @StateObject private var appState = AppState()

    @ObservedObject private var joplinAccountStore = JoplinAccountStore.shared

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(appState)
                #if os(macOS)
                .frame(minWidth: 800, minHeight: 500)
                #endif
                .sheet(isPresented: $appState.isShowingJoplinLogin) {
                    LoginView()
                }
        }
        #if os(macOS)
        .windowStyle(.titleBar)
        .windowToolbarStyle(.unified(showsTitle: false))
        #endif
        .commands {
            CommandGroup(after: .appInfo) {
                if let account = joplinAccountStore.account {
                    // Disabled — informational only, since there's no separate
                    // Settings/Preferences window to show this (see Android's Settings
                    // screen, which shows the same thing as a non-interactive row).
                    Button("Signed in as \(account.email)") {}
                        .disabled(true)
                    #if os(macOS)
                    // iOS equivalent (a SwiftUI alert/sheet reachable from in-view UI,
                    // since there's no Mac-style menu bar) is a follow-up — see the
                    // NSAlert dialogs task.
                    Button("Log Out of Joplin Cloud…") {
                        confirmLogout()
                    }
                    #endif
                    // ⌘R — a normal (non-force) sync: push local changes, pull whatever's
                    // new on the server. Matches Android/iOS's pull-to-refresh. "Force
                    // Resync" below is the heavier full re-download/re-render and is
                    // menu-only on purpose, so it isn't triggered by muscle memory.
                    Button("Refresh") {
                        appState.syncNow()
                    }
                    .keyboardShortcut("r", modifiers: .command)

                    Button("Force Resync") {
                        appState.syncNow(force: true)
                    }
                } else {
                    Button("Log In to Joplin Cloud…") {
                        appState.isShowingJoplinLogin = true
                    }
                }
            }

            CommandGroup(replacing: .newItem) {
                Button("New Note") {
                    appState.createNote()
                }
                .keyboardShortcut("n", modifiers: .command)

                Button("New Notebook") {
                    appState.createFolder()
                }
                .keyboardShortcut("n", modifiers: [.command, .shift])
            }

            CommandGroup(after: .pasteboard) {
                Divider()
                Button("Find…") {
                    appState.isFocusingSearch = true
                }
                .keyboardShortcut("f", modifiers: .command)
            }
        }
    }

    #if os(macOS)
    /// Matches Android's confirmation before logging out ("local notes stay put").
    private func confirmLogout() {
        let alert = NSAlert()
        alert.messageText = "Log Out"
        alert.informativeText = "Log out of Joplin Cloud on this device? Your local notes stay put."
        alert.addButton(withTitle: "Log Out")
        alert.addButton(withTitle: "Cancel")
        if alert.runModal() == .alertFirstButtonReturn {
            joplinAccountStore.clear()
        }
    }
    #endif
}
