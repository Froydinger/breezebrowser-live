// Tiny macOS Keychain wrapper for secrets we don't want sitting in settings JSON
// (the OpenAI BYOK key). Generic-password items in the login keychain; works for the
// self-signed, non-sandboxed app without special entitlements.

import Foundation
import Security

enum Keychain {
    private static let service = "com.jakefreudinger.breeze.native"

    /// Store (or, if empty, delete) a secret for `account`.
    static func set(_ account: String, _ value: String) {
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(base as CFDictionary)
        let v = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !v.isEmpty else { return }
        var add = base
        add[kSecValueData as String] = Data(v.utf8)
        SecItemAdd(add as CFDictionary, nil)
    }

    /// Fetch a secret, or "" if none.
    static func get(_ account: String) -> String {
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
              let s = String(data: data, encoding: .utf8) else { return "" }
        return s
    }

    static func delete(_ account: String) { set(account, "") }
}
