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

    /// Runs a process with a hard timeout so the UI never waits forever.
    static func run(_ cmd: String, args: [String], timeoutSeconds: Double = 4) -> (output: String, ok: Bool) {
        let p = Process()
        let pipe = Pipe()
        p.executableURL = URL(fileURLWithPath: cmd)
        p.arguments = args
        p.standardOutput = pipe
        p.standardError = pipe

        let group = DispatchGroup()
        group.enter()
        var finished = false

        do {
            try p.run()
        } catch {
            return ("", false)
        }

        DispatchQueue.global(qos: .utility).async {
            p.waitUntilExit()
            finished = true
            group.leave()
        }

        let waited = group.wait(timeout: .now() + timeoutSeconds)
        if waited == .timedOut {
            p.terminate()
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 0.5) {
                if p.isRunning { kill(p.processIdentifier, SIGKILL) }
            }
            return ("", false)
        }

        let out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        return (out, finished && p.terminationStatus == 0)
    }

    /// macOS password dialog — only call from explicit user actions.
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
        if let cached = cachedPasswordless, Date().timeIntervalSince(cachedAt) < 30 {
            cacheLock.unlock()
            return cached
        }
        cacheLock.unlock()

        let ok = FileManager.default.isExecutableFile(atPath: helperPath)
            && run("/usr/bin/sudo", args: ["-n", helperPath, "ping"], timeoutSeconds: 2).ok

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

    /// Silent helper only — never shows a password dialog.
    /// Does NOT auto-install (that was causing reconnect password spam).
    @discardableResult
    static func runHelper(_ action: String) -> Bool {
        guard isPasswordless else { return false }
        let ok = run("/usr/bin/sudo", args: ["-n", helperPath, action], timeoutSeconds: 8).ok
        if !ok {
            // Helper may have been removed — don't keep trusting cache forever.
            invalidatePasswordlessCache()
        }
        return ok
    }

    /// One-time install; shows one password prompt. Call only from UI.
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
