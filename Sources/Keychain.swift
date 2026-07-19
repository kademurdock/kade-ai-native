import Foundation
import Security

/// Tiny, dependency-free Keychain wrapper (kSecClassGenericPassword).
///
/// Everything sensitive the app persists — the access token and the cached
/// user record — lives here, not in UserDefaults. Items are stored with
/// `kSecAttrAccessibleAfterFirstUnlock` so a launched-from-notification or
/// background refresh can still read them, but nothing is readable while the
/// device is locked-cold.
enum Keychain {
    /// One namespace for all of this app's items.
    private static let service = "com.kademurdock.kadeai.native"

    enum Key: String {
        case accessToken
        case user
    }

    @discardableResult
    static func set(_ value: String, for key: Key) -> Bool {
        set(Data(value.utf8), for: key)
    }

    @discardableResult
    static func set(_ data: Data, for key: Key) -> Bool {
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key.rawValue,
        ]
        // Upsert: delete any existing item, then add fresh.
        SecItemDelete(base as CFDictionary)
        var attrs = base
        attrs[kSecValueData as String] = data
        attrs[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        return SecItemAdd(attrs as CFDictionary, nil) == errSecSuccess
    }

    static func data(for key: Key) -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key.rawValue,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return data
    }

    static func string(for key: Key) -> String? {
        guard let data = data(for: key) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    @discardableResult
    static func remove(_ key: Key) -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key.rawValue,
        ]
        let status = SecItemDelete(query as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }
}
