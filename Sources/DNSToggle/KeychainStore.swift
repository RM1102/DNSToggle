import Foundation
import Security

/// Per-proxy Kerberos credentials in Apple Keychain.
/// Service id matches DNS.app so previously saved passwords still work.
enum KeychainStore {
    static let service = "com.rahulmasand.dns.iitd-proxy"
    private static let legacyUsernameKey = "iitdProxyUsername"

    static func clearCache() {
        // Reserved for future ephemeral buffers; passwords are no longer cached in-process.
    }

    private static func usernameKey(for proxy: ProxyChoice) -> String {
        "iitdProxyUsername.\(proxy.rawValue)"
    }

    private static func account(for proxy: ProxyChoice, user: String) -> String {
        "\(proxy.rawValue):\(user)"
    }

    static func savedUsername(for proxy: ProxyChoice) -> String {
        if let u = UserDefaults.standard.string(forKey: usernameKey(for: proxy)), !u.isEmpty {
            return u
        }
        // Older single-user builds only stored one username (treated as proxy62).
        if proxy == .proxy62 {
            return UserDefaults.standard.string(forKey: legacyUsernameKey) ?? ""
        }
        return ""
    }

    @discardableResult
    static func save(for proxy: ProxyChoice, user: String, password: String) -> Bool {
        let trimmed = user.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !password.isEmpty else { return false }
        UserDefaults.standard.set(trimmed, forKey: usernameKey(for: proxy))
        if proxy == .proxy62 {
            UserDefaults.standard.set(trimmed, forKey: legacyUsernameKey)
        }
        let ok = savePassword(password, account: account(for: proxy, user: trimmed))
        // Also keep bare-username account for proxy62 legacy DNS.app reads.
        if proxy == .proxy62 {
            _ = savePassword(password, account: trimmed)
        }
        return ok
    }

    static func load(for proxy: ProxyChoice) -> (user: String, pass: String)? {
        let user = savedUsername(for: proxy)
        guard !user.isEmpty else { return nil }
        if let pass = loadPassword(account: account(for: proxy, user: user)) {
            return (user, pass)
        }
        // Legacy: bare username Keychain account (pre per-proxy).
        if proxy == .proxy62, let pass = loadPassword(account: user) {
            return (user, pass)
        }
        return nil
    }

    static func hasCredentials(for proxy: ProxyChoice) -> Bool {
        load(for: proxy) != nil
    }

    /// True if at least one proxy has saved Kerberos creds.
    static var hasAnyCredentials: Bool {
        ProxyChoice.allCases.contains { hasCredentials(for: $0) }
    }

    // MARK: - Keychain primitives

    @discardableResult
    private static func savePassword(_ password: String, account: String) -> Bool {
        let data = Data(password.utf8)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(query as CFDictionary)
        var add = query
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        // Do not keep password in process memory longer than needed.
        clearCache()
        return SecItemAdd(add as CFDictionary, nil) == errSecSuccess
    }

    private static func loadPassword(account: String) -> String? {
        // No long-lived password cache — reduces dump risk if process is inspected.
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess, let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }
}
