import Foundation
import Security

/// API keys are stored in the login keychain under the app's service name, never in UserDefaults or on disk.
///
/// A keychain item remembers which app wrote it. An item written by a differently signed copy of Local Flow (a dev
/// build, an older certificate) can't be read, overwritten or deleted by this one without the "Local Flow wants to
/// access key…" password sheet — reading gives errSecAuthFailed, deleting errSecInvalidOwnerEdit, and adding over it
/// errSecDuplicateItem, so Save would silently fail. Two measures:
/// - every call runs with keychain UI switched off, so a foreign item fails quietly instead of prompting;
/// - items live under their own service name; the original name is read-only legacy (readable items are migrated once).
///
/// (The data-protection keychain would avoid the problem outright, but its `keychain-access-groups` entitlement needs a
/// provisioning profile, which Developer ID apps don't have: a build carrying it is refused by AMFI at launch.)
enum Keychain {
    private static let service = "com.jzone3.LocalFlow.keys"
    private static let legacyService = "com.jzone3.LocalFlow"

    static func get(_ account: String) -> String? {
        if let value = read(account, service: service) { return value }
        guard let legacy = read(account, service: legacyService) else { return nil }
        if write(legacy, for: account, service: service) { remove(account, service: legacyService) }
        return legacy
    }

    @discardableResult
    static func set(_ value: String, for account: String) -> Bool {
        delete(account)
        guard !value.isEmpty else { return true }
        return write(value, for: account, service: service)
    }

    static func delete(_ account: String) {
        remove(account, service: service)
        remove(account, service: legacyService)
    }

    // MARK: - Plumbing

    private static func baseQuery(_ account: String, service: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    private static func read(_ account: String, service: String) -> String? {
        var query = baseQuery(account, service: service)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = withoutKeychainUI { SecItemCopyMatching(query as CFDictionary, &item) }
        guard status == errSecSuccess, let data = item as? Data,
              let value = String(data: data, encoding: .utf8), !value.isEmpty else { return nil }
        return value
    }

    private static func write(_ value: String, for account: String, service: String) -> Bool {
        var attributes = baseQuery(account, service: service)
        attributes[kSecValueData as String] = Data(value.utf8)
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlocked
        return withoutKeychainUI { SecItemAdd(attributes as CFDictionary, nil) } == errSecSuccess
    }

    /// Best effort: an item owned by another signature can't be deleted (errSecInvalidOwnerEdit) and is left alone.
    private static func remove(_ account: String, service: String) {
        _ = withoutKeychainUI { SecItemDelete(baseQuery(account, service: service) as CFDictionary) }
    }

    /// Runs a keychain call with the password sheet disabled; a locked or foreign-signed item fails instead of asking.
    private static func withoutKeychainUI(_ body: () -> OSStatus) -> OSStatus {
        var wasAllowed: DarwinBoolean = true
        SecKeychainGetUserInteractionAllowed(&wasAllowed)
        SecKeychainSetUserInteractionAllowed(false)
        defer { SecKeychainSetUserInteractionAllowed(wasAllowed.boolValue) }
        return body()
    }
}
