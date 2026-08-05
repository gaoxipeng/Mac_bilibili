import Foundation
import Security

/// Stores the signed-in account in the macOS Keychain instead of a plaintext file.
struct KeychainAccountStore: Sendable {
    private static let service = "gaoxipeng.bilibili"
    private static let account = "signed-in-account"

    init() {
        // Older builds wrote the account, including session tokens, to disk.
        // This app intentionally does not migrate that format; users sign in again.
        Self.removeLegacyPlaintextAccount()
    }

    func load() -> BiliAccount? {
        guard let data = Self.readData() else { return nil }
        return try? JSONDecoder().decode(BiliAccount.self, from: data)
    }

    func save(_ account: BiliAccount) {
        guard let data = try? JSONEncoder().encode(account) else { return }

        let query = Self.baseQuery()
        let updateStatus = SecItemUpdate(
            query as CFDictionary,
            [kSecValueData as String: data] as CFDictionary
        )
        guard updateStatus == errSecItemNotFound else { return }

        var addQuery = query
        addQuery[kSecValueData as String] = data
        _ = SecItemAdd(addQuery as CFDictionary, nil)
    }

    func clear() {
        _ = SecItemDelete(Self.baseQuery() as CFDictionary)
    }

    private static func readData() -> Data? {
        var query = baseQuery()
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess else { return nil }
        return result as? Data
    }

    private static func baseQuery() -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    private static func removeLegacyPlaintextAccount() {
        guard let support = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first else {
            return
        }

        let legacyURL = support
            .appendingPathComponent("gaoxipeng.bilibili", isDirectory: true)
            .appendingPathComponent("account.json", isDirectory: false)
        try? FileManager.default.removeItem(at: legacyURL)
    }
}
