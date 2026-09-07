import Foundation
import AppKit

enum PrivilegedHelper {
    static let helperPath = "/Library/PrivilegedHelperTools/com.rahulmasand.dns"

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
        if let cached = cachedPasswordless, Date().timeIntervalSince(cachedAt) < 120 {
            cacheLock.unlock()
            return cached
        }
        cacheLock.unlock()

        if Thread.isMainThread {
            return cachedPasswordless ?? FileManager.default.isExecutableFile(atPath: helperPath)
        }

        let ok = FileManager.default.isExecutableFile(atPath: helperPath)
            && ProcessRunner.run("/usr/bin/sudo", args: ["-n", helperPath, "ping"], timeoutSeconds: 2).ok

        cacheLock.lock()
        cachedPasswordless = ok
        cachedAt = Date()
        cacheLock.unlock()
        return ok
    }

    static func invalidatePasswordlessCache() {
        cacheLock.lock()
        cachedPasswordless = nil
        cachedAt = .distantPast
        cacheLock.unlock()
    }

    @discardableResult
    static func runHelper(_ action: String) -> Bool {
        guard isPasswordless else { return false }
        // proxy-on/off walks multiple networksetup services — allow up to 20s.
        let timeout: Double = (action.hasPrefix("proxy") || action == "clear") ? 20 : 8
        let ok = ProcessRunner.run("/usr/bin/sudo", args: ["-n", helperPath, action], timeoutSeconds: timeout).ok
        if !ok { invalidatePasswordlessCache() }
        return ok
    }

    @discardableResult
    static func installPasswordlessHelper() -> Bool {
        guard let install = bundledInstallPaths.first(where: {
            FileManager.default.isReadableFile(atPath: $0)
        }) else { return false }
        let ok = runAdmin("/bin/bash \(install)")
        invalidatePasswordlessCache()
        return ok && isPasswordless
    }
}
