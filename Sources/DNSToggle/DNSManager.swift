import Foundation
import AppKit

struct DNSPreset: Equatable, Identifiable {
    let id: String
    let name: String
    let servers: [String]

    static let automatic = DNSPreset(id: "auto", name: "Institute / Automatic", servers: [])
    static let cloudflare = DNSPreset(id: "cf", name: "Cloudflare", servers: ["1.1.1.1", "1.0.0.1"])
    static let google = DNSPreset(id: "google", name: "Google", servers: ["8.8.8.8", "8.8.4.4"])
    static let quad9 = DNSPreset(id: "quad9", name: "Quad9", servers: ["9.9.9.9", "149.112.112.112"])

    static let all: [DNSPreset] = [.cloudflare, .google, .quad9, .automatic]
}

struct NetworkStatus: Equatable {
    let preset: DNSPreset
    let dnsServers: [String]
    let proxyEnabled: Bool
    let vpnLikelyActive: Bool
    let activeProxy: ProxyChoice?

    var label: String {
        if let proxy = activeProxy, proxyEnabled {
            return "\(proxy.shortLabel) · \(preset.name)"
        }
        if vpnLikelyActive && !proxyEnabled {
            return "\(preset.name) — VPN residue"
        }
        if preset.id == "auto" {
            return "Institute / Automatic"
        }
        return "\(preset.name) (\(preset.servers.first ?? ""))"
    }

    var isBypassDNS: Bool {
        preset.id != "auto"
    }
}

enum DNSManager {
    private static var cachedService: String?
    private static let cacheLock = NSLock()

    static func networkService() -> String {
        cacheLock.lock()
        if let cachedService {
            cacheLock.unlock()
            return cachedService
        }
        cacheLock.unlock()

        let out = PrivilegedHelper.run(
            "/usr/sbin/networksetup",
            args: ["-listallnetworkservices"],
            timeoutSeconds: 2
        ).output
        var found = "Wi-Fi"
        for raw in out.split(separator: "\n") {
            let line = String(raw)
            if line.hasPrefix("*") { continue }
            let name = line.trimmingCharacters(in: .whitespaces)
            if name.compare("Wi-Fi", options: .caseInsensitive) == .orderedSame
                || name.compare("WiFi", options: .caseInsensitive) == .orderedSame
                || name.compare("Airport", options: .caseInsensitive) == .orderedSame {
                found = name
                break
            }
        }
        cacheLock.lock()
        cachedService = found
        cacheLock.unlock()
        return found
    }

    /// Cheap status probe — must never run on the main thread.
    static func currentStatus(includeVPNScan: Bool = false) -> NetworkStatus {
        let servers = readDNSServers()
        let preset = matchPreset(servers)
        let (proxyOn, active) = readProxyState()
        let vpnRunning = includeVPNScan ? isVPNProcessRunning() : false
        return NetworkStatus(
            preset: preset,
            dnsServers: servers,
            proxyEnabled: proxyOn,
            vpnLikelyActive: (proxyOn && active == nil) || vpnRunning,
            activeProxy: active
        )
    }

    /// Single networksetup call instead of 4+.
    private static func readProxyState() -> (enabled: Bool, active: ProxyChoice?) {
        let svc = networkService()
        let web = PrivilegedHelper.run(
            "/usr/sbin/networksetup",
            args: ["-getwebproxy", svc],
            timeoutSeconds: 2
        ).output
        let enabled = web.split(separator: "\n").contains(where: { $0.lowercased().hasPrefix("enabled: yes") })
        guard enabled else { return (false, nil) }
        for choice in ProxyChoice.allCases where web.contains(choice.host) {
            return (true, choice)
        }
        return (true, nil)
    }

    static func applyPreset(_ preset: DNSPreset) -> Bool {
        let action: String
        switch preset.id {
        case "cf": action = "cloudflare"
        case "google": action = "google"
        case "quad9": action = "quad9"
        default: action = "auto"
        }
        if PrivilegedHelper.runHelper(action) {
            return true
        }
        // Fallback: admin prompt without helper.
        let svc = escapedShell(networkService())
        let command: String
        if preset.servers.isEmpty {
            command = "/usr/sbin/networksetup -setdnsservers \(svc) Empty"
        } else {
            let list = preset.servers.joined(separator: " ")
            command = "/usr/sbin/networksetup -setdnsservers \(svc) \(list)"
        }
        guard PrivilegedHelper.runAdmin(command) else { return false }
        flushCache()
        return true
    }

    @discardableResult
    static func setInstituteProxy(_ choice: ProxyChoice) -> Bool {
        if PrivilegedHelper.runHelper(choice.helperAction) {
            return true
        }
        let svc = escapedShell(networkService())
        let host = choice.host
        let cmds = [
            "/usr/sbin/networksetup -setwebproxy \(svc) \(host) 3128 off",
            "/usr/sbin/networksetup -setsecurewebproxy \(svc) \(host) 3128 off",
            "/usr/sbin/networksetup -setwebproxystate \(svc) on",
            "/usr/sbin/networksetup -setsecurewebproxystate \(svc) on",
            "/usr/sbin/networksetup -setsocksfirewallproxystate \(svc) off",
            "/usr/sbin/networksetup -setautoproxystate \(svc) off"
        ]
        return PrivilegedHelper.runAdmin(cmds.joined(separator: "; "))
    }

    @discardableResult
    static func turnProxyOff() -> Bool {
        if PrivilegedHelper.runHelper("proxy-off") {
            return true
        }
        let svc = escapedShell(networkService())
        // Fully disable every proxy flavour — leftover PAC/hosts brick the network.
        let cmds = [
            "/usr/sbin/networksetup -setwebproxystate \(svc) off",
            "/usr/sbin/networksetup -setsecurewebproxystate \(svc) off",
            "/usr/sbin/networksetup -setsocksfirewallproxystate \(svc) off",
            "/usr/sbin/networksetup -setautoproxystate \(svc) off",
            "/usr/sbin/networksetup -setproxybypassdomains \(svc) Empty",
            "/usr/bin/dscacheutil -flushcache",
            "/usr/bin/killall -HUP mDNSResponder"
        ]
        return PrivilegedHelper.runAdmin(cmds.joined(separator: "; "))
    }

    /// Flush resolver cache without changing DNS servers.
    static func flushDNSOnly() {
        if PrivilegedHelper.isPasswordless {
            _ = PrivilegedHelper.run(
                "/usr/bin/sudo",
                args: ["-n", PrivilegedHelper.helperPath, "flush"],
                timeoutSeconds: 6
            )
            return
        }
        _ = PrivilegedHelper.runAdmin(
            "/usr/bin/dscacheutil -flushcache; /usr/bin/killall -HUP mDNSResponder"
        )
    }

    @discardableResult
    static func clearVPNEffects(reloadBrowsers: Bool = true) -> Bool {
        _ = PrivilegedHelper.run("/usr/bin/osascript", args: ["-e", "tell application \"ProtonVPN\" to quit"])
        _ = PrivilegedHelper.run("/usr/bin/osascript", args: ["-e", "tell application \"Tailscale\" to quit"])
        _ = PrivilegedHelper.run("/usr/bin/killall", args: ["-x", "ProtonVPN"])

        let ok: Bool
        if PrivilegedHelper.runHelper("clear") {
            ok = true
        } else {
            let svc = escapedShell(networkService())
            let cmds = [
                "/usr/sbin/networksetup -setdnsservers \(svc) Empty",
                "/usr/sbin/networksetup -setwebproxystate \(svc) off",
                "/usr/sbin/networksetup -setsecurewebproxystate \(svc) off",
                "/usr/sbin/networksetup -setsocksfirewallproxystate \(svc) off",
                "/usr/sbin/networksetup -setautoproxystate \(svc) off",
                "/usr/bin/dscacheutil -flushcache; /usr/bin/killall -HUP mDNSResponder"
            ]
            ok = PrivilegedHelper.runAdmin(cmds.joined(separator: "; "))
        }

        if ok && reloadBrowsers {
            reloadOpenBrowsers()
        }
        return ok
    }

    static func flushCache() {
        _ = PrivilegedHelper.runAdmin("/usr/bin/dscacheutil -flushcache; /usr/bin/killall -HUP mDNSResponder")
    }

    static func isSystemProxyOn(for proxy: ProxyChoice) -> Bool {
        let (_, active) = readProxyState()
        return active == proxy
    }

    static func detectActiveProxy() -> ProxyChoice? {
        readProxyState().active
    }

    static func reloadOpenBrowsers() {
        // Fire-and-forget — never block the caller waiting on browsers.
        DispatchQueue.global(qos: .utility).async {
            let script = """
            set browserList to {"Brave Browser", "Google Chrome", "Arc"}
            repeat with browserName in browserList
                try
                    tell application browserName
                        repeat with w in windows
                            repeat with t in tabs of w
                                reload t
                            end repeat
                        end repeat
                    end tell
                end try
            end repeat
            """
            var error: NSDictionary?
            NSAppleScript(source: script)?.executeAndReturnError(&error)
        }
    }

    private static func matchPreset(_ servers: [String]) -> DNSPreset {
        guard !servers.isEmpty else { return .automatic }
        for preset in DNSPreset.all where !preset.servers.isEmpty {
            if Set(servers) == Set(preset.servers) {
                return preset
            }
        }
        return DNSPreset(id: "custom", name: "Custom", servers: servers)
    }

    private static func isVPNProcessRunning() -> Bool {
        let output = PrivilegedHelper.run("/bin/ps", args: ["-ax", "-o", "comm="], timeoutSeconds: 2).output
        let names = output.lowercased()
        return names.contains("protonvpn") || names.contains("tailscale") || names.contains("wireguard")
    }

    static func readDNSServers() -> [String] {
        let output = PrivilegedHelper.run(
            "/usr/sbin/networksetup",
            args: ["-getdnsservers", networkService()],
            timeoutSeconds: 2
        ).output
        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty || trimmed.contains("aren't any DNS Servers") {
            return []
        }
        return trimmed
            .split(separator: "\n")
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    private static func escapedShell(_ value: String) -> String {
        value.replacingOccurrences(of: " ", with: "\\ ")
    }
}
