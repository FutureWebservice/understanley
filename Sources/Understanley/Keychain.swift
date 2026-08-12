import Foundation
import Security

/// Secret storage.
///
/// Every API token lives here and nowhere else — not `UserDefaults`, not the
/// graph, not the cache, not a log line. The app is not sandboxed and reads
/// arbitrary user folders, so a key written to a plist would sit in plain text
/// in a directory the user might well be analyzing.
///
/// Reads are deliberately write-only from the UI's perspective: `has()` answers
/// whether a key exists, and only the provider that needs it ever calls
/// `read()`. Nothing in the interface displays a stored secret back.
enum Keychain {
    private static let service = "com.futurewebservice.understanley"

    /// Stores or replaces a secret. An empty value removes it, so clearing a
    /// field in Settings is the same action as deleting the key.
    @discardableResult
    static func write(_ value: String, for account: String) -> Bool {
        guard !value.isEmpty else { return remove(account) }

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let attributes: [String: Any] = [
            kSecValueData as String: Data(value.utf8),
            // Available after first unlock but never synced to iCloud or
            // included in a backup — a machine-local credential.
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]

        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecSuccess { return true }
        guard status == errSecItemNotFound else { return false }

        var insert = query
        insert.merge(attributes) { current, _ in current }
        return SecItemAdd(insert as CFDictionary, nil) == errSecSuccess
    }

    static func read(_ account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data,
              let value = String(data: data, encoding: .utf8),
              !value.isEmpty
        else { return nil }
        return value
    }

    /// Whether a secret exists, without retrieving it. This is what the UI
    /// asks — showing a filled field is enough, and reading the value to render
    /// a row of dots would put it in memory for no reason.
    static func has(_ account: String) -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: false,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        return SecItemCopyMatching(query as CFDictionary, nil) == errSecSuccess
    }

    @discardableResult
    static func remove(_ account: String) -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let status = SecItemDelete(query as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }
}
