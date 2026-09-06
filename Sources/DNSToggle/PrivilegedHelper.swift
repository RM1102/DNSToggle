import Foundation
import AppKit

enum PrivilegedHelper {
    static let helperPath = "/Library/PrivilegedHelperTools/com.rahulmasand.dns"

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
            // Give it a moment, then force-kill if needed.
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 0.5) {
                if p.isRunning { kill(p.processIdentifier, SIGKILL) }
            }
            return ("", false)
        }

        let out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        return (out, finished && p.terminationStatus == 0)
    }

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
        FileManager.default.isExecutableFile(atPath: helperPath)
            && run("/usr/bin/sudo", args: ["-n", helperPath, "ping"], timeoutSeconds: 2).ok
    }

    @discardableResult
    static func runHelper(_ action: String) -> Bool {
        if isPasswordless {
            return run("/usr/bin/sudo", args: ["-n", helperPath, action], timeoutSeconds: 8).ok
        }
        if installPasswordlessHelper() {
            return run("/usr/bin/sudo", args: ["-n", helperPath, action], timeoutSeconds: 8).ok
        }
        return false
    }

    @discardableResult
    static func installPasswordlessHelper() -> Bool {
        guard let install = bundledInstallPaths.first(where: {
            FileManager.default.isReadableFile(atPath: $0)
        }) else { return false }
        return runAdmin("/bin/bash \(install)")
    }
}
