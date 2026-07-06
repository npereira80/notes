import SwiftUI

/// Phase 1 of Joplin Cloud sync: login only. Presented as a sheet from the app's
/// menu bar command (see NotesTNApp.swift). Item sync is a later phase.
struct LoginView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var store = JoplinAccountStore.shared

    @State private var email = ""
    @State private var password = ""
    @State private var isLoggingIn = false
    @State private var errorMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Log In to Joplin Cloud")
                .font(.title2)
                .bold()

            TextField("Email", text: $email)
                .textFieldStyle(.roundedBorder)
                .textContentType(.username)

            SecureField("Password", text: $password)
                .textFieldStyle(.roundedBorder)
                .textContentType(.password)
                .onSubmit(logIn)

            if let errorMessage {
                Text(errorMessage)
                    .foregroundStyle(.red)
                    .font(.callout)
            }

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button {
                    logIn()
                } label: {
                    if isLoggingIn {
                        ProgressView()
                            .controlSize(.small)
                            .frame(width: 16, height: 16)
                    } else {
                        Text("Log In")
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(isLoggingIn || email.isEmpty || password.isEmpty)
            }
        }
        .padding(24)
        .frame(width: 360)
    }

    private func logIn() {
        errorMessage = nil
        isLoggingIn = true
        let email = self.email.trimmingCharacters(in: .whitespacesAndNewlines)
        let password = self.password

        Task {
            let result = await JoplinCloudApi.login(email: email, password: password)
            isLoggingIn = false
            switch result {
            case .success(let session):
                store.save(JoplinAccount(email: email, sessionId: session.sessionId, userId: session.userId))
                dismiss()
            case .failure(let error):
                errorMessage = error.localizedDescription
            }
        }
    }
}

#Preview {
    LoginView()
}
