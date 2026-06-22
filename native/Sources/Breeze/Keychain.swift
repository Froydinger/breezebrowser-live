// Prompt-free local storage for the user's OpenAI API key.

import Foundation
import Security
import LocalAuthentication

enum LocalSecrets {
    private static let legacyService = "com.jakefreudinger.breeze.native"

    private static var directory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        var folder = "Breeze"
        if let index = CommandLine.arguments.firstIndex(of: "--profile"), index + 1 < CommandLine.arguments.count {
            folder = CommandLine.arguments[index + 1]
        } else if let profile = ProcessInfo.processInfo.environment["BREEZE_PROFILE"] {
            folder = profile
        }
        return base.appendingPathComponent(folder, isDirectory: true)
    }

    private static func url(for account: String) -> URL {
        directory.appendingPathComponent(".\(account).key")
    }

    static func set(_ account: String, _ value: String) {
        let key = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let file = url(for: account)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        guard !key.isEmpty else {
            try? FileManager.default.removeItem(at: file)
            return
        }
        do {
            try Data(key.utf8).write(to: file, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        } catch {
            print("Breeze could not save local API key: \(error.localizedDescription)")
        }
    }

    static func get(_ account: String) -> String {
        let file = url(for: account)
        guard let data = try? Data(contentsOf: file),
              let key = String(data: data, encoding: .utf8) else { return "" }
        return key.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func delete(_ account: String) { set(account, "") }

    /// Import a pre-3.7.3 Keychain item only when macOS can return it silently.
    /// A non-interactive authentication context guarantees this migration never
    /// shows a password, Touch ID, or passkey-style authorization prompt.
    static func migrateLegacyWithoutPrompt(_ account: String) -> String {
        let existing = get(account)
        if !existing.isEmpty { return existing }
        let context = LAContext()
        context.interactionNotAllowed = true
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: legacyService,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecUseAuthenticationContext as String: context,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data,
              let key = String(data: data, encoding: .utf8), !key.isEmpty else { return "" }
        set(account, key)
        return key
    }
}
