import Foundation
import AppKit

enum PrivilegedHelper {
    static let helperPath = "/Library/PrivilegedHelperTools/com.rahulmasand.dns"
    /// Must match MenuBar/dns-toggle-helper HELPER_VERSION. Old helpers fail this check.
    static let requiredHelperVersion = "2"

    private static let allowedActions: Set<String> = [
        "version", "ping",
        "cloudflare", "google", "quad9", "opendns", "adguard", "controld", "mullvad",
        "auto", "clear", "flush",
        "proxy-on", "proxy62-on", "proxy22-on", "proxy-off"
    ]

    private static let cacheLock = NSLock()
    private static var cachedPasswordless: Bool?
    private static var cachedAt: Date = .distantPast

    private static var bundledInstallPaths: [String] {
        var paths: [String] = []
        if let res = Bundle.main.resourcePath {
            paths.append("\(res)/install-helper.sh")
        }
        paths.append("/Applications/DNSToggle.app/Contents/Resources/install-helper.sh")
        return paths
    }

    @discardableResult
    static func run(_ cmd: String, args: [String], timeoutSeconds: Double = 4) -> (output: String, ok: Bool) {
        ProcessRunner.run(cmd, args: args, timeoutSeconds: timeoutSeconds)
    }

    /// macOS password dialog — only from an explicit user click, never from watchdog.
    @discardableResult
    static func runAdmin(_ shell: String) -> Bool {
        let esc = shell
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        var err: NSDictionary?
        NSAppleScript(source: "do shell script \"\(esc)\" with administrator privileges")?
            .executeAndReturnError(&err)
        return err == nil
    }

    static var isPasswordless: Bool {
        cacheLock.lock()
        if let cached = cachedPasswordless, Date().timeIntervalSince(cachedAt) < 60 {
            cacheLock.unlock()
            return cached
        }
        cacheLock.unlock()

        if Thread.isMainThread {
            return cachedPasswordless ?? false
        }

        let ok = helperIsCurrentVersion()

        cacheLock.lock()
        cachedPasswordless = ok
        cachedAt = Date()
        cacheLock.unlock()
        return ok
    }

    /// True only when sudo -n works AND helper reports the expected version.
    static func helperIsCurrentVersion() -> Bool {
        guard FileManager.default.isExecutableFile(atPath: helperPath) else { return false }
        let ping = ProcessRunner.run("/usr/bin/sudo", args: ["-n", helperPath, "ping"], timeoutSeconds: 2)
        guard ping.ok else { return false }
        let ver = ProcessRunner.run("/usr/bin/sudo", args: ["-n", helperPath, "version"], timeoutSeconds: 2)
        let reported = ver.output.trimmingCharacters(in: .whitespacesAndNewlines)
        // Old helpers have no `version` action → empty / usage → force reinstall.
        return ver.ok && reported == requiredHelperVersion
    }

    static func invalidatePasswordlessCache() {
        cacheLock.lock()
        cachedPasswordless = nil
        cachedAt = .distantPast
        cacheLock.unlock()
    }

    @discardableResult
    static func runHelper(_ action: String) -> Bool {
        guard allowedActions.contains(action) else {
            SessionLog.warn("blocked unknown helper action")
            return false
        }
        guard isPasswordless else { return false }
        let timeout: Double = (action.hasPrefix("proxy") || action == "clear") ? 20 : 8
        let ok = ProcessRunner.run("/usr/bin/sudo", args: ["-n", helperPath, action], timeoutSeconds: timeout).ok
        if !ok { invalidatePasswordlessCache() }
        return ok
    }

    @discardableResult
    static func installPasswordlessHelper() -> Bool {
        guard let install = bundledInstallPaths.first(where: {
            FileManager.default.isReadableFile(atPath: $0) && isTrustedInstallPath($0)
        }) else { return false }
        // Single-quote path so spaces / metacharacters cannot break out of the shell string.
        let quoted = "'" + install.replacingOccurrences(of: "'", with: "'\\''") + "'"
        let ok = runAdmin("/bin/bash \(quoted)")
        invalidatePasswordlessCache()
        return ok && helperIsCurrentVersion()
    }

    private static func isTrustedInstallPath(_ path: String) -> Bool {
        let appRoot = "/Applications/DNSToggle.app/"
        if path.hasPrefix(appRoot) { return true }
        let bundle = Bundle.main.bundlePath
        if path.hasPrefix(bundle + "/") { return true }
        return false
    }
}
