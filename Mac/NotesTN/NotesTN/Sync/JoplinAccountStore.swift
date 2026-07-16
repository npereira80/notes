import Foundation
import Combine
import Security

struct JoplinAccount: Codable, Equatable {
    let email: String
    let sessionId: String
    let userId: String
    // Stored (Keychain-encrypted, same as the rest of this struct) so a dead session
    // (Joplin Cloud sessions are fixed-12-hour, non-renewable — see SessionModel.ts on
    // the server) can be silently replaced with a fresh one via JoplinCloudApi.login()
    // instead of forcing the user to type their password in again. See AppState.syncNow.
    let password: String
}

/// Persists the Joplin Cloud session (email + session id + user id) in the macOS
/// Keychain. Mirrors Android App's JoplinAccountStore (encrypted SharedPreferences
/// there, Keychain here — same idea: don't keep the session id in plain UserDefaults).
@MainActor
final class JoplinAccountStore: ObservableObject {
    static let shared = JoplinAccountStore()

    @Published private(set) var account: JoplinAccount?

    private let service = "com.ikuteam.NotesTN.joplinAccount"
    private let account_ = "joplinCloud" // Keychain "account" attribute; fixed since there's one Joplin Cloud login per device.

    private init() {
        account = Self.load(service: service, account: account_)
    }

    func save(_ account: JoplinAccount) {
        guard let data = try? JSONEncoder().encode(account) else { return }
        Self.deleteFromKeychain(service: service, account: account_)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account_,
            kSecValueData as String: data,
        ]
        SecItemAdd(query as CFDictionary, nil)
        self.account = account
    }

    func clear() {
        Self.deleteFromKeychain(service: service, account: account_)
        account = nil
    }

    private static func load(service: String, account: String) -> JoplinAccount? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else { return nil }
        return try? JSONDecoder().decode(JoplinAccount.self, from: data)
    }

    private static func deleteFromKeychain(service: String, account: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
    }
}
