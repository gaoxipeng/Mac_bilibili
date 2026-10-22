import Foundation
import LocalAuthentication
import OSLog
import Security

/// Account secrets remain in the local Keychain. Background restoration must
/// never display login-keychain authorization dialogs.
@MainActor
final class KeychainAccountStore {
    private static let service = "gaoxipeng.bilibili"
    private static let account = "signed-in-account-v2"
    private static let legacyAccount = "signed-in-account"
    private static let skipLegacyKey = "account_keychain_skip_legacy"
    private static let signedOutKey = "account_keychain_signed_out"
    private static let logger = Logger(subsystem: "gaoxipeng.bilibili", category: "AccountKeychain")

    private(set) var needsLoginRecovery = false
    private var lastSavedData: Data?

    init() {
        Self.removeLegacyPlaintextAccount()
    }

    func load() -> BiliAccount? {
        needsLoginRecovery = false
        guard !UserDefaults.standard.bool(forKey: Self.signedOutKey) else { return nil }
        let current = Self.readData(account: Self.account)
        if let data = current.data, let account = try? JSONDecoder().decode(BiliAccount.self, from: data) {
            lastSavedData = Self.encode(account)
            return account
        }
        guard current.status == errSecItemNotFound,
              !UserDefaults.standard.bool(forKey: Self.skipLegacyKey) else {
            needsLoginRecovery = current.status != errSecItemNotFound
            return nil
        }
        // Best-effort migration only. An older binary's ACL may prohibit access;
        // signing in again creates our new item without modifying that ACL.
        let legacy = Self.readData(account: Self.legacyAccount)
        guard let data = legacy.data,
              let account = try? JSONDecoder().decode(BiliAccount.self, from: data) else {
            needsLoginRecovery = legacy.status != errSecItemNotFound
            return nil
        }
        if save(account) {
            Self.delete(account: Self.legacyAccount)
        }
        return account
    }

    @discardableResult
    func save(_ account: BiliAccount) -> Bool {
        guard let data = Self.encode(account) else { return false }
        if lastSavedData == data { return true }
        let query = Self.baseQuery(account: Self.account)
        let status = Self.withoutInteraction {
            let updated = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
            guard updated == errSecItemNotFound else { return updated }
            var addQuery = query
            addQuery[kSecValueData as String] = data
            return SecItemAdd(addQuery as CFDictionary, nil)
        }
        guard status == errSecSuccess else {
            Self.logger.error("Account persistence failed with status \(status, privacy: .public)")
            return false
        }
        lastSavedData = data
        needsLoginRecovery = false
        UserDefaults.standard.set(true, forKey: Self.skipLegacyKey)
        UserDefaults.standard.set(false, forKey: Self.signedOutKey)
        return true
    }

    func clear() {
        // Prevent inaccessible legacy credentials from reviving after logout.
        UserDefaults.standard.set(true, forKey: Self.signedOutKey)
        UserDefaults.standard.set(true, forKey: Self.skipLegacyKey)
        lastSavedData = nil
        needsLoginRecovery = false
        Self.delete(account: Self.account)
        Self.delete(account: Self.legacyAccount)
    }

    private static func encode(_ account: BiliAccount) -> Data? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        return try? encoder.encode(account)
    }

    private static func readData(account: String) -> (data: Data?, status: OSStatus) {
        var query = baseQuery(account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = withoutInteraction {
            SecItemCopyMatching(query as CFDictionary, &result)
        }
        return (status == errSecSuccess ? result as? Data : nil, status)
    }

    private static func delete(account: String) {
        let query = baseQuery(account: account)
        _ = withoutInteraction { SecItemDelete(query as CFDictionary) }
    }

    private static func baseQuery(account: String) -> [String: Any] {
        let context = LAContext()
        context.interactionNotAllowed = true
        return [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecUseAuthenticationContext as String: context,
        ]
    }

    private static func withoutInteraction(_ operation: () -> OSStatus) -> OSStatus {
        // LAContext alone does not suppress legacy file-keychain ACL dialogs.
        // Scope the legacy switch to this synchronous, main-actor operation and
        // restore its previous value even when the operation fails.
        var wasAllowed = DarwinBoolean(false)
        guard SecKeychainGetUserInteractionAllowed(&wasAllowed) == errSecSuccess,
              SecKeychainSetUserInteractionAllowed(false) == errSecSuccess else {
            return errSecInteractionNotAllowed
        }
        defer { SecKeychainSetUserInteractionAllowed(wasAllowed.boolValue) }
        return operation()
    }

    private static func removeLegacyPlaintextAccount() {
        guard let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return }
        let legacyURL = support
            .appendingPathComponent("gaoxipeng.bilibili", isDirectory: true)
            .appendingPathComponent("account.json", isDirectory: false)
        try? FileManager.default.removeItem(at: legacyURL)
    }
}
