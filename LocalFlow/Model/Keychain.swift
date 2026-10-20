import Foundation
import Security

/// API keys are stored in the login keychain under the app's service name, never in UserDefaults or on disk.
///
/// Every call runs with keychain UI switched off. A keychain item remembers which app wrote it; one written by a
/// differently signed copy of Local Flow (a dev build, an older certificate) would otherwise make macOS show the
/// "Local Flow wants to access key…" password sheet on every read, often several times per screen. Instead such an
/// item is dropped and reported as absent, so Settings shows the key as missing and the user enters it once more.
///
/// (The data-protection keychain would avoid the problem outright, but its `keychain-access-groups` entitlement needs a
/// provisioning profile, which Developer ID apps don't have: a build carrying it is refused by AMFI at launch.)
enum Keychain {
    private static let service = "com.jzone3.LocalFlow"

    static func get(_ account: String) -> String? {
        var query = baseQuery(account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = withoutKeychainUI { SecItemCopyMatching(query as CFDictionary, &item) }
        switch status {
        case errSecSuccess:
            guard let data = item as? Data, let value = String(data: data, encoding: .utf8), !value.isEmpty else { return nil }
            return value
        case errSecInteractionNotAllowed, errSecAuthFailed:
            // Written by another signature of this app; unreadable without the password sheet. Drop it.
            delete(account)
            return nil
        default:
            return nil
        }
    }

    @discardableResult
    static func set(_ value: String, for account: String) -> Bool {
        delete(account)
        guard !value.isEmpty else { return true }
        var attributes = baseQuery(account)
        attributes[kSecValueData as String] = Data(value.utf8)
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlocked
        return withoutKeychainUI { SecItemAdd(attributes as CFDictionary, nil) } == errSecSuccess
    }

    static func delete(_ account: String) {
        _ = withoutKeychainUI { SecItemDelete(baseQuery(account) as CFDictionary) }
    }

    private static func baseQuery(_ account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
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
