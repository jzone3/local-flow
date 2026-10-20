import Foundation
import Security

/// API keys are stored in the Keychain under the app's service name, never in UserDefaults or on disk.
///
/// Items go to the data-protection keychain (`kSecUseDataProtectionKeychain`): it is tied to the app identifier, not to
/// the code signature, so a re-signed build (dev → release, new certificate) reads its keys without macOS asking for the
/// login keychain password. That store needs the `keychain-access-groups` entitlement with a team prefix, which only a
/// Developer ID build has; ad-hoc dev builds get `errSecMissingEntitlement` and fall back to the legacy login keychain.
///
/// Legacy items are read with keychain UI switched off: an item written by a differently signed copy of the app would
/// otherwise pop the "Local Flow wants to access key…" password sheet. Such an item is treated as absent instead, and
/// the next save lands in the data-protection store.
enum Keychain {
    private static let service = "com.jzone3.LocalFlow"

    static func get(_ account: String) -> String? {
        if let value = read(account, dataProtection: true) { return value }
        guard let legacy = read(account, dataProtection: false) else { return nil }
        // Migrate silently; if this build can't use the data-protection store the legacy item simply stays.
        if write(legacy, for: account, dataProtection: true) == errSecSuccess { remove(account, dataProtection: false) }
        return legacy
    }

    @discardableResult
    static func set(_ value: String, for account: String) -> Bool {
        remove(account, dataProtection: true)
        guard !value.isEmpty else { remove(account, dataProtection: false); return true }
        switch write(value, for: account, dataProtection: true) {
        case errSecSuccess:
            remove(account, dataProtection: false)
            return true
        case errSecMissingEntitlement:
            remove(account, dataProtection: false)
            return write(value, for: account, dataProtection: false) == errSecSuccess
        default:
            return false
        }
    }

    static func delete(_ account: String) {
        remove(account, dataProtection: true)
        remove(account, dataProtection: false)
    }

    // MARK: - Plumbing

    private static func baseQuery(_ account: String, dataProtection: Bool) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        if dataProtection { query[kSecUseDataProtectionKeychain as String] = true }
        return query
    }

    private static func read(_ account: String, dataProtection: Bool) -> String? {
        var query = baseQuery(account, dataProtection: dataProtection)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = withoutKeychainUI { SecItemCopyMatching(query as CFDictionary, &item) }
        guard status == errSecSuccess, let data = item as? Data,
              let value = String(data: data, encoding: .utf8), !value.isEmpty else { return nil }
        return value
    }

    private static func write(_ value: String, for account: String, dataProtection: Bool) -> OSStatus {
        var attributes = baseQuery(account, dataProtection: dataProtection)
        attributes[kSecValueData as String] = Data(value.utf8)
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlocked
        return withoutKeychainUI { SecItemAdd(attributes as CFDictionary, nil) }
    }

    private static func remove(_ account: String, dataProtection: Bool) {
        _ = withoutKeychainUI { SecItemDelete(baseQuery(account, dataProtection: dataProtection) as CFDictionary) }
    }

    /// Runs a legacy-keychain call with the password sheet disabled; a locked or foreign-signed item fails instead of asking.
    private static func withoutKeychainUI(_ body: () -> OSStatus) -> OSStatus {
        var wasAllowed: DarwinBoolean = true
        SecKeychainGetUserInteractionAllowed(&wasAllowed)
        SecKeychainSetUserInteractionAllowed(false)
        defer { SecKeychainSetUserInteractionAllowed(wasAllowed.boolValue) }
        return body()
    }
}
