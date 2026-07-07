import SwiftUI

@main
struct NotesTNApp: App {
    @StateObject private var appState = AppState()

    @ObservedObject private var joplinAccountStore = JoplinAccountStore.shared

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(appState)
                .frame(minWidth: 800, minHeight: 500)
                .sheet(isPresented: $appState.isShowingJoplinLogin) {
                    LoginView()
                }
        }
        .windowStyle(.titleBar)
        .windowToolbarStyle(.unified(showsTitle: false))
        .commands {
            CommandGroup(after: .appInfo) {
                if let account = joplinAccountStore.account {
                    // Disabled — informational only, since there's no separate
                    // Settings/Preferences window to show this (see Android's Settings
                    // screen, which shows the same thing as a non-interactive row).
                    Button("Signed in as \(account.email)") {}
                        .disabled(true)
                    Button("Log Out of Joplin Cloud…") {
                        confirmLogout()
                    }
                    Button("Force Resync") {
                        appState.syncNow(force: true)
                    }
                    .keyboardShortcut("r", modifiers: .command)
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
}
