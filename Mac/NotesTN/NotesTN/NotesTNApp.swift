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
                if joplinAccountStore.account != nil {
                    Button("Log Out of Joplin Cloud…") {
                        joplinAccountStore.clear()
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
}
