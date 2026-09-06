import Foundation
import Security

/// Kerberos credentials in Apple Keychain.
/// Service id matches DNS.app so previously saved passwords still work.
enum KeychainStore {
    static let service = "com.rahulmasand.dns.iitd-proxy"
    private static let usernameDefaultsKey = "iitdProxyUsername"

    private static var cachedPassword: String?
    private static var cachedAccount: String?

    static func clearCache() {
        cachedPassword = nil
        cachedAccount = nil
    }

    static var savedUsername: String {
        UserDefaults.standard.string(forKey: usernameDefaultsKey) ?? ""
    }

    /// One Kerberos userid + password for whichever proxy is selected.
    @discardableResult
    static func save(user: String, password: String) -> Bool {
        let trimmed = user.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !password.isEmpty else { return false }
        UserDefaults.standard.set(trimmed, forKey: usernameDefaultsKey)
        // Also mirror per-proxy username keys used by older DNS.app builds.
        for proxy in ProxyChoice.allCases {
            UserDefaults.standard.set(trimmed, forKey: "iitdProxyUsername.\(proxy.rawValue)")
        }
        let ok = savePassword(password, account: trimmed)
        // Keep per-proxy Keychain accounts in sync for DNS.app compatibility.
        for proxy in ProxyChoice.allCases {
            _ = savePassword(password, account: "\(proxy.rawValue):\(trimmed)")
        }
        return ok
    }

    static func load() -> (user: String, pass: String)? {
        let user = savedUsername
        if !user.isEmpty, let pass = loadPassword(account: user) {
            return (user, pass)
        }
        // Fall back to per-proxy accounts from older builds.
        for proxy in ProxyChoice.allCases {
            let key = "iitdProxyUsername.\(proxy.rawValue)"
            let u = UserDefaults.standard.string(forKey: key) ?? ""
            guard !u.isEmpty else { continue }
            if let pass = loadPassword(account: "\(proxy.rawValue):\(u)") {
                UserDefaults.standard.set(u, forKey: usernameDefaultsKey)
                return (u, pass)
            }
            if let pass = loadPassword(account: u) {
                UserDefaults.standard.set(u, forKey: usernameDefaultsKey)
                return (u, pass)
            }
        }
        return nil
    }

    static var hasCredentials: Bool { load() != nil }

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
        let ok = SecItemAdd(add as CFDictionary, nil) == errSecSuccess
        if ok {
            cachedPassword = password
            cachedAccount = account
        }
        return ok
    }

    private static func loadPassword(account: String) -> String? {
        if cachedAccount == account, let cachedPassword { return cachedPassword }
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
        let pass = String(data: data, encoding: .utf8)
        if let pass {
            cachedPassword = pass
            cachedAccount = account
        }
        return pass
    }
}
