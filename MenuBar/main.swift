import AppKit
import Security

private let helperPath = "/Library/PrivilegedHelperTools/com.rahulmasand.dns"
private let bundledInstall = "/Applications/DNS.app/Contents/Resources/install-helper.sh"
private let keychainService = "com.rahulmasand.dns.iitd-proxy"
private let usernameDefaultsKey = "iitdProxyUsername" // legacy single-user (proxy62)
private let selectedProxyDefaultsKey = "iitdSelectedProxy"

/// Official IITD proxy.sh refreshes every 120s to stay under the ~3h idle timeout.
private let refreshIntervalSeconds: TimeInterval = 120

enum ProxyChoice: String, CaseIterable {
    case proxy62
    case proxy22

    var host: String {
        switch self {
        case .proxy62: return "proxy62.iitd.ac.in"
        case .proxy22: return "proxy22.iitd.ac.in"
        }
    }

    var label: String {
        switch self {
        case .proxy62: return "proxy62 (dual degree)"
        case .proxy22: return "proxy22 (BTech)"
        }
    }

    var helperAction: String {
        switch self {
        case .proxy62: return "proxy62-on"
        case .proxy22: return "proxy22-on"
        }
    }

    var cgiURL: String { "https://\(host)/cgi-bin/proxy.cgi" }
}

private func selectedProxy() -> ProxyChoice {
    if let raw = UserDefaults.standard.string(forKey: selectedProxyDefaultsKey),
       let choice = ProxyChoice(rawValue: raw) {
        return choice
    }
    return .proxy62
}

private func setSelectedProxy(_ choice: ProxyChoice) {
    UserDefaults.standard.set(choice.rawValue, forKey: selectedProxyDefaultsKey)
}

private func run(_ cmd: String, args: [String]) -> (output: String, ok: Bool) {
    let p = Process()
    let pipe = Pipe()
    p.executableURL = URL(fileURLWithPath: cmd)
    p.arguments = args
    p.standardOutput = pipe
    p.standardError = pipe
    do { try p.run(); p.waitUntilExit() } catch { return ("", false) }
    let out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    return (out, p.terminationStatus == 0)
}

@discardableResult
private func runAdmin(_ shell: String) -> Bool {
    let esc = shell.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
    var err: NSDictionary?
    NSAppleScript(source: "do shell script \"\(esc)\" with administrator privileges")?.executeAndReturnError(&err)
    return err == nil
}

private func isPasswordless() -> Bool {
    FileManager.default.isExecutableFile(atPath: helperPath)
        && run("/usr/bin/sudo", args: ["-n", helperPath, "ping"]).ok
}

@discardableResult
private func runHelper(_ action: String) -> Bool {
    if isPasswordless() {
        return run("/usr/bin/sudo", args: ["-n", helperPath, action]).ok
    }
    if installPasswordlessHelper() {
        return run("/usr/bin/sudo", args: ["-n", helperPath, action]).ok
    }
    return false
}

@discardableResult
private func installPasswordlessHelper() -> Bool {
    guard FileManager.default.isReadableFile(atPath: bundledInstall) else { return false }
    return runAdmin("/bin/bash \(bundledInstall)")
}

private func networkService() -> String {
    let out = run("/usr/sbin/networksetup", args: ["-listallnetworkservices"]).output
    for raw in out.split(separator: "\n") {
        let line = String(raw)
        if line.hasPrefix("*") { continue }
        let name = line.trimmingCharacters(in: .whitespaces)
        if name.compare("Wi-Fi", options: .caseInsensitive) == .orderedSame
            || name.compare("WiFi", options: .caseInsensitive) == .orderedSame
            || name.compare("Airport", options: .caseInsensitive) == .orderedSame {
            return name
        }
    }
    return "Wi-Fi"
}

private func getDNS() -> [String] {
    let out = run("/usr/sbin/networksetup", args: ["-getdnsservers", networkService()]).output
    if out.contains("aren't any DNS Servers") { return [] }
    return out.split(separator: "\n").map { String($0).trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
}

private func isSystemProxyOn(for proxy: ProxyChoice) -> Bool {
    let svc = networkService()
    let web = run("/usr/sbin/networksetup", args: ["-getwebproxy", svc]).output
    guard web.split(separator: "\n").contains(where: { $0.lowercased().hasPrefix("enabled: yes") }) else {
        return false
    }
    return web.contains(proxy.host)
}

private func actionForServers(_ servers: [String]) -> String {
    switch servers {
    case ["1.1.1.1", "1.0.0.1"]: return "cloudflare"
    case ["8.8.8.8", "8.8.4.4"]: return "google"
    case ["9.9.9.9", "149.112.112.112"]: return "quad9"
    case ["208.67.222.222", "208.67.220.220"]: return "opendns"
    case ["94.140.14.14", "94.140.15.15"]: return "adguard"
    case ["76.76.2.0", "76.76.10.0"]: return "controld"
    case ["194.242.2.2", "194.242.2.3"]: return "mullvad"
    default: return "auto"
    }
}

@discardableResult
private func setDNS(_ servers: [String]) -> Bool {
    runHelper(actionForServers(servers))
}

private func quitVPNApps() {
    _ = run("/usr/bin/osascript", args: ["-e", "tell application \"ProtonVPN\" to quit"])
    _ = run("/usr/bin/osascript", args: ["-e", "tell application \"Tailscale\" to quit"])
    _ = run("/usr/bin/killall", args: ["-x", "ProtonVPN"])
}

@discardableResult
private func clearVPN() -> Bool {
    quitVPNApps()
    return runHelper("clear")
}

// MARK: - Keychain

private enum Keychain {
    private static var cachedPassword: String?
    private static var cachedAccount: String?

    static func clearCache() {
        cachedPassword = nil
        cachedAccount = nil
    }

    static func savePassword(_ password: String, account: String) -> Bool {
        let data = Data(password.utf8)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
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

    static func loadPassword(account: String) -> String? {
        if cachedAccount == account, let cachedPassword { return cachedPassword }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
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

    static func deletePassword(account: String) {
        clearCache()
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(query as CFDictionary)
    }
}

private func usernameDefaultsKey(for proxy: ProxyChoice) -> String {
    "iitdProxyUsername.\(proxy.rawValue)"
}

private func keychainAccount(for proxy: ProxyChoice, user: String) -> String {
    "\(proxy.rawValue):\(user)"
}

private func savedUsername(for proxy: ProxyChoice) -> String {
    if let u = UserDefaults.standard.string(forKey: usernameDefaultsKey(for: proxy)), !u.isEmpty {
        return u
    }
    // Older builds stored one username for everything — treat as proxy62.
    if proxy == .proxy62 {
        return UserDefaults.standard.string(forKey: usernameDefaultsKey) ?? ""
    }
    return ""
}

private func saveCredentials(for proxy: ProxyChoice, user: String, password: String) -> Bool {
    UserDefaults.standard.set(user, forKey: usernameDefaultsKey(for: proxy))
    if proxy == .proxy62 {
        UserDefaults.standard.set(user, forKey: usernameDefaultsKey)
    }
    return Keychain.savePassword(password, account: keychainAccount(for: proxy, user: user))
}

private func loadCredentials(for proxy: ProxyChoice) -> (user: String, pass: String)? {
    let user = savedUsername(for: proxy)
    guard !user.isEmpty else { return nil }
    if let pass = Keychain.loadPassword(account: keychainAccount(for: proxy, user: user)) {
        return (user, pass)
    }
    // Legacy Keychain account = bare username (pre per-proxy).
    if proxy == .proxy62, let pass = Keychain.loadPassword(account: user) {
        return (user, pass)
    }
    return nil
}

private func hasProxyCredentials(for proxy: ProxyChoice) -> Bool {
    loadCredentials(for: proxy) != nil
}

/// True if at least one proxy has saved Kerberos creds.
private func hasAnyProxyCredentials() -> Bool {
    ProxyChoice.allCases.contains { hasProxyCredentials(for: $0) }
}

// MARK: - IITD proxy (matches csc.iitd.ac.in/uploads/proxy.sh)

final class IITDProxySession {
    static let shared = IITDProxySession()

    private let stateQueue = DispatchQueue(label: "com.rahulmasand.dns.proxy.state")
    private var refreshTimer: DispatchSourceTimer?
    private var healthTimer: DispatchSourceTimer?
    private var running = false
    private var sessionID = ""
    private var proxy = ProxyChoice.proxy62
    private var usingExistingSession = false
    private(set) var lastStatus = "Proxy idle"
    private(set) var lastRefreshAt: Date?
    private(set) var lastHealthOK = false

    var isRunning: Bool {
        stateQueue.sync { running }
    }

    // MARK: public API

    func start(proxy: ProxyChoice) {
        stateQueue.async {
            self.cancelTimers()
            self.proxy = proxy
            self.running = true
            self.usingExistingSession = false
            self.sessionID = ""
            self.loginOrAdopt()
        }
    }

    func stop() {
        stateQueue.async {
            self.cancelTimers()
            self.running = false
            self.usingExistingSession = false
            self.logoutCurrent()
            self.lastHealthOK = false
            self.lastStatus = "Proxy logged out"
        }
    }

    func forceReconnect() {
        stateQueue.async {
            self.cancelTimers()
            self.usingExistingSession = false
            self.logoutCurrent()
            self.lastHealthOK = false
            self.lastStatus = "Reconnecting…"
            if self.running {
                _ = runHelper(self.proxy.helperAction)
                self.loginOrAdopt()
            }
        }
    }

    /// Fast — runs on its own thread, never blocked by refresh sleep.
    func logoutEverywhere(completion: (() -> Void)? = nil) {
        DispatchQueue.global(qos: .userInitiated).async {
            self.stateQueue.sync {
                self.cancelTimers()
                self.running = false
                self.usingExistingSession = false
                self.logoutCurrent()
            }

            var loggedOutAny = false
            for choice in ProxyChoice.allCases {
                guard let c = loadCredentials(for: choice) else { continue }
                Self.logoutOnProxy(choice, user: c.user, pass: c.pass)
                loggedOutAny = true
            }

            self.sessionID = ""
            if loggedOutAny {
                self.setStatus("Logged out on proxy62 + proxy22", healthOK: false)
            } else {
                self.setStatus("Save Kerberos credentials first", healthOK: false)
            }
            DispatchQueue.main.async { completion?() }
        }
    }

    // MARK: CGI helpers (stateless, safe from any thread)

    private static func curl(_ args: [String]) -> String {
        run("/usr/bin/curl", args: args).output
    }

    private static func urlEncode(_ s: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return s.addingPercentEncoding(withAllowedCharacters: allowed) ?? s
    }

    private static func cgi(on proxy: ProxyChoice, fields: [String: String]) -> String {
        var args = ["-k", "-s", "--connect-timeout", "8", "--max-time", "12", "-d"]
        let body = fields.map { "\($0.key)=\(urlEncode($0.value))" }.joined(separator: "&")
        args.append(body)
        args.append(proxy.cgiURL)
        return curl(args)
    }

    private static func fetchSessionID(on proxy: ProxyChoice) -> String? {
        let html = curl(["-k", "-s", "--connect-timeout", "8", "--max-time", "12", proxy.cgiURL])
        guard let range = html.range(of: #"sessionid["=\w\s]*"([0-9][A-Za-z0-9]*)""#, options: .regularExpression) else {
            return nil
        }
        let matched = String(html[range])
        if let q = matched.range(of: #"\"([0-9][A-Za-z0-9]+)\""#, options: .regularExpression) {
            return String(matched[q]).trimmingCharacters(in: CharacterSet(charactersIn: "\""))
        }
        return nil
    }

    private static func verifyTraffic(on proxy: ProxyChoice) -> Bool {
        let code = curl([
            "-k", "-s", "-o", "/dev/null", "-w", "%{http_code}",
            "--connect-timeout", "6", "--max-time", "10",
            "-x", "http://\(proxy.host):3128",
            "https://www.iitd.ac.in/"
        ]).trimmingCharacters(in: .whitespacesAndNewlines)
        return code == "200" || code == "301" || code == "302"
    }

    private static func logoutOnProxy(_ proxy: ProxyChoice, user: String, pass: String) {
        guard let sid = fetchSessionID(on: proxy) else { return }
        // If we can log in, immediately log out (clears our session).
        let login = cgi(on: proxy, fields: [
            "sessionid": sid, "action": "Validate", "userid": user, "pass": pass
        ])
        if login.lowercased().contains("logged in successfully") {
            _ = cgi(on: proxy, fields: ["sessionid": sid, "action": "logout"])
            return
        }
        // Best effort even when "already logged in" (remote session — may not clear).
        _ = cgi(on: proxy, fields: ["sessionid": sid, "action": "logout"])
    }

    // MARK: instance CGI (uses current proxy + sessionID)

    private func cgi(_ fields: [String: String]) -> String {
        Self.cgi(on: proxy, fields: fields)
    }

    private func logoutCurrent() {
        guard !sessionID.isEmpty else { return }
        _ = cgi(["sessionid": sessionID, "action": "logout"])
        sessionID = ""
    }

    private func setStatus(_ text: String, healthOK: Bool) {
        stateQueue.sync {
            self.lastStatus = text
            self.lastHealthOK = healthOK
        }
    }

    private func cancelTimers() {
        refreshTimer?.cancel()
        refreshTimer = nil
        healthTimer?.cancel()
        healthTimer = nil
    }

    private func loginOrAdopt() {
        guard running else { return }

        guard let creds = loadCredentials(for: proxy) else {
            lastStatus = "Missing Kerberos for \(proxy.rawValue)"
            lastHealthOK = false
            return
        }
        let user = creds.user
        let pass = creds.pass

        guard let sid = Self.fetchSessionID(on: proxy) else {
            lastStatus = "Cannot reach \(proxy.host)"
            lastHealthOK = false
            scheduleRetry(after: 8)
            return
        }

        sessionID = sid
        let loginText = cgi([
            "sessionid": sid, "action": "Validate", "userid": user, "pass": pass
        ])

        if loginText.lowercased().contains("logged in successfully") {
            usingExistingSession = false
            lastRefreshAt = Date()
            lastHealthOK = Self.verifyTraffic(on: proxy)
            lastStatus = lastHealthOK ? "\(proxy.host) logged in" : "\(proxy.host) logged in (no traffic yet)"
            scheduleRefreshTimer()
            return
        }

        // Official proxy.sh: "already logged in" means an session exists — often still works.
        if loginText.contains("already logged in") {
            if Self.verifyTraffic(on: proxy) {
                usingExistingSession = true
                lastHealthOK = true
                lastStatus = "\(proxy.host) connected (existing login)"
                scheduleHealthTimerOnly()
                return
            }
            lastHealthOK = false
            lastStatus = "Logged in on another device — log out there, or wait ~3h"
            return
        }

        lastHealthOK = false
        lastStatus = "Login failed — check Kerberos password"
        scheduleRetry(after: 8)
    }

    private func scheduleRetry(after seconds: TimeInterval) {
        stateQueue.asyncAfter(deadline: .now() + seconds) { [weak self] in
            guard let self, self.running else { return }
            self.loginOrAdopt()
        }
    }

    private func scheduleRefreshTimer() {
        cancelTimers()
        let timer = DispatchSource.makeTimerSource(queue: stateQueue)
        timer.schedule(deadline: .now() + refreshIntervalSeconds, repeating: refreshIntervalSeconds)
        timer.setEventHandler { [weak self] in self?.performRefresh() }
        timer.resume()
        refreshTimer = timer
    }

    private func scheduleHealthTimerOnly() {
        cancelTimers()
        let timer = DispatchSource.makeTimerSource(queue: stateQueue)
        timer.schedule(deadline: .now() + 60, repeating: 60)
        timer.setEventHandler { [weak self] in self?.performHealthCheck() }
        timer.resume()
        healthTimer = timer
    }

    private func performRefresh() {
        guard running, !usingExistingSession, !sessionID.isEmpty else { return }

        let refresh = cgi(["sessionid": sessionID, "action": "Refresh"])
        if refresh.lowercased().contains("logged in successfully") {
            lastRefreshAt = Date()
            lastHealthOK = Self.verifyTraffic(on: proxy)
            lastStatus = lastHealthOK ? "\(proxy.host) logged in" : "\(proxy.host) refresh ok (checking…)"
            return
        }

        // Session died — re-login (same as proxy.sh mainloop).
        logoutCurrent()
        lastHealthOK = false
        lastStatus = "Session expired — re-logging in…"
        loginOrAdopt()
    }

    private func performHealthCheck() {
        guard running else { return }
        let ok = Self.verifyTraffic(on: proxy)
        lastHealthOK = ok
        if ok {
            lastStatus = "\(proxy.host) connected (existing login)"
        } else {
            lastStatus = "Proxy stopped working — try Log out everywhere, then turn on again"
        }
    }
}

private enum SwitchDot {
    case idle, progress, success, failure

    var color: NSColor {
        switch self {
        case .idle, .success: return .systemGreen
        case .progress: return .systemYellow
        case .failure: return .systemRed
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var item: NSStatusItem!
    private var menu: NSMenu!
    private var statusLine: NSMenuItem!
    private var authLine: NSMenuItem!
    private var proxyLine: NSMenuItem!
    private var switchDot: SwitchDot = .idle
    private var switching = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.isVisible = true
        if let btn = item.button {
            btn.title = ""
            btn.imagePosition = .imageOnly
            let config = NSImage.SymbolConfiguration(pointSize: 13, weight: .regular)
            if let icon = NSImage(systemSymbolName: "globe", accessibilityDescription: "DNS")?
                .withSymbolConfiguration(config) {
                icon.isTemplate = true
                btn.image = icon
            }
        }

        menu = NSMenu()
        statusLine = NSMenuItem(title: "Status…", action: nil, keyEquivalent: "")
        authLine = NSMenuItem(title: "Auth…", action: nil, keyEquivalent: "")
        proxyLine = NSMenuItem(title: "Proxy…", action: nil, keyEquivalent: "")
        menu.addItem(statusLine)
        menu.addItem(authLine)
        menu.addItem(proxyLine)
        menu.addItem(.separator())

        addPreset("Cloudflare", servers: ["1.1.1.1", "1.0.0.1"])
        addPreset("Google", servers: ["8.8.8.8", "8.8.4.4"])
        addPreset("Quad9", servers: ["9.9.9.9", "149.112.112.112"])
        addPreset("OpenDNS", servers: ["208.67.222.222", "208.67.220.220"])
        addPreset("AdGuard", servers: ["94.140.14.14", "94.140.15.15"])
        addPreset("Control D", servers: ["76.76.2.0", "76.76.10.0"])
        addPreset("Mullvad", servers: ["194.242.2.2", "194.242.2.3"])
        addPreset("Institute / Auto", servers: [])

        menu.addItem(.separator())
        addAction("Institute Proxy On (proxy62 — dual degree)", action: #selector(onProxy62On))
        addAction("Institute Proxy On (proxy22 — BTech)", action: #selector(onProxy22On))
        addAction("Institute Proxy Off", action: #selector(onProxyOff))
        addAction("Log out proxy everywhere", action: #selector(onLogoutEverywhere))
        addAction("Save Kerberos for proxy62…", action: #selector(onSaveCreds62))
        addAction("Save Kerberos for proxy22…", action: #selector(onSaveCreds22))
        addAction("Reconnect proxy now", action: #selector(onReconnectNow))
        menu.addItem(.separator())
        addAction("Clear VPN & Reset", action: #selector(onClear))
        let unlock = NSMenuItem(title: "Enable password-free switching…", action: #selector(onUnlock), keyEquivalent: "")
        unlock.target = self
        unlock.tag = 42
        menu.addItem(unlock)
        menu.addItem(.separator())
        addAction("Quit", action: #selector(onQuit), key: "q")

        item.menu = menu

        Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            self?.refreshProxyLine()
            self?.refreshAuthLine()
        }

        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(onWake), name: NSWorkspace.didWakeNotification, object: nil
        )

        if hasAnyProxyCredentials() {
            for choice in ProxyChoice.allCases {
                _ = loadCredentials(for: choice)
            }
        }
        let proxy = selectedProxy()
        if isSystemProxyOn(for: proxy) && hasProxyCredentials(for: proxy) {
            IITDProxySession.shared.start(proxy: proxy)
        }
        switchDot = .success
        refresh()
    }

    @objc private func onWake() {
        let proxy = selectedProxy()
        guard isSystemProxyOn(for: proxy), hasProxyCredentials(for: proxy) else { return }
        IITDProxySession.shared.forceReconnect()
    }

    private func addPreset(_ title: String, servers: [String]) {
        let mi = NSMenuItem(title: title, action: #selector(onPreset(_:)), keyEquivalent: "")
        mi.target = self
        mi.representedObject = servers
        menu.addItem(mi)
    }

    private func addAction(_ title: String, action: Selector, key: String = "") {
        let mi = NSMenuItem(title: title, action: action, keyEquivalent: key)
        mi.target = self
        menu.addItem(mi)
    }

    private func statusLabel(for dns: [String]) -> String {
        if switching { return statusLine.title.replacingOccurrences(of: "● ", with: "") }
        if dns.isEmpty { return "Institute / Auto" }
        return dns.joined(separator: ", ")
    }

    private func applyStatusTitle(_ label: String) {
        statusLine.attributedTitle = dottedTitle(label, color: switchDot.color)
    }

    private func dottedTitle(_ label: String, color: NSColor) -> NSAttributedString {
        let text = "● \(label)"
        let attributed = NSMutableAttributedString(string: text)
        attributed.addAttribute(.foregroundColor, value: NSColor.labelColor, range: NSRange(location: 0, length: text.utf16.count))
        attributed.addAttribute(.foregroundColor, value: color, range: NSRange(location: 0, length: 1))
        return attributed
    }

    private func refreshAuthLine() {
        let free = isPasswordless()
        authLine.attributedTitle = dottedTitle(
            free ? "Password-free switching on" : "Password-free switching off",
            color: free ? .systemGreen : .systemRed
        )
        menu.items.first(where: { $0.tag == 42 })?.isHidden = free
    }

    private func refreshProxyLine() {
        let proxy = selectedProxy()
        let sysOn = isSystemProxyOn(for: proxy)
        let sess = IITDProxySession.shared
        let lower = sess.lastStatus.lowercased()
        let ok = sess.lastHealthOK && sysOn
        let bad = lower.contains("failed") || lower.contains("missing") || lower.contains("cannot reach")
            || lower.contains("another device") || lower.contains("stopped working")
        let busy = lower.contains("reconnect") || lower.contains("re-log") || lower.contains("logging out")

        var label = "\(proxy.host): \(sysOn ? "on" : "off") · \(sess.lastStatus)"
        if let t = sess.lastRefreshAt, !lower.contains("existing login") {
            label += " · refreshed \(max(0, Int(Date().timeIntervalSince(t) / 60)))m ago"
        }

        let color: NSColor = ok ? .systemGreen : (busy ? .systemYellow : (bad || !sysOn ? .systemRed : .systemYellow))
        proxyLine.attributedTitle = dottedTitle(label, color: color)
    }

    private func refresh(dnsOverride: [String]? = nil) {
        applyStatusTitle(statusLabel(for: dnsOverride ?? getDNS()))
        refreshAuthLine()
        refreshProxyLine()
    }

    private func runSwitch(progressLabel: String, work: @escaping () -> Bool) {
        guard !switching else { return }
        switching = true
        switchDot = .progress
        applyStatusTitle(progressLabel)
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let ok = work()
            DispatchQueue.main.async {
                guard let self else { return }
                self.switching = false
                self.switchDot = ok ? .success : .failure
                self.refresh(dnsOverride: getDNS())
            }
        }
    }

    @objc private func onPreset(_ sender: NSMenuItem) {
        runSwitch(progressLabel: "Switching DNS…") { setDNS(sender.representedObject as? [String] ?? []) }
    }

    private func turnProxyOn(_ choice: ProxyChoice) {
        if !hasProxyCredentials(for: choice) { promptCredentials(for: choice) }
        guard hasProxyCredentials(for: choice) else { return }
        setSelectedProxy(choice)
        runSwitch(progressLabel: "Turning on \(choice.host)…") {
            IITDProxySession.shared.stop()
            usleep(300_000)
            let ok = runHelper(choice.helperAction)
            if ok { IITDProxySession.shared.start(proxy: choice) }
            return ok
        }
    }

    @objc private func onProxy62On() { turnProxyOn(.proxy62) }
    @objc private func onProxy22On() { turnProxyOn(.proxy22) }

    @objc private func onLogoutEverywhere() {
        guard hasAnyProxyCredentials() else {
            promptCredentials(for: selectedProxy())
            return
        }
        switching = true
        switchDot = .progress
        applyStatusTitle("Logging out…")
        IITDProxySession.shared.logoutEverywhere { [weak self] in
            guard let self else { return }
            self.switching = false
            self.switchDot = .success
            self.refresh()
        }
    }

    @objc private func onProxyOff() {
        runSwitch(progressLabel: "Turning off proxy…") {
            IITDProxySession.shared.stop()
            return runHelper("proxy-off")
        }
    }

    @objc private func onReconnectNow() {
        let proxy = selectedProxy()
        guard hasProxyCredentials(for: proxy) else { promptCredentials(for: proxy); return }
        switching = true
        switchDot = .progress
        applyStatusTitle("Reconnecting…")
        DispatchQueue.global(qos: .userInitiated).async {
            _ = runHelper(proxy.helperAction)
            IITDProxySession.shared.forceReconnect()
            if !IITDProxySession.shared.isRunning {
                IITDProxySession.shared.start(proxy: proxy)
            }
            DispatchQueue.main.async { [weak self] in
                self?.switching = false
                self?.switchDot = .success
                self?.refresh()
            }
        }
    }

    @objc private func onSaveCreds62() {
        promptCredentials(for: .proxy62)
        refresh()
    }

    @objc private func onSaveCreds22() {
        promptCredentials(for: .proxy22)
        refresh()
    }

    private func promptCredentials(for proxy: ProxyChoice) {
        let alert = NSAlert()
        alert.messageText = "IITD Kerberos — \(proxy.label)"
        alert.informativeText = "Saved only in your Mac Keychain for this proxy. Don’t paste passwords into chat."
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")

        let width: CGFloat = 280
        let stack = NSStackView(frame: NSRect(x: 0, y: 0, width: width, height: 54))
        stack.orientation = .vertical
        stack.spacing = 6

        let userField = NSTextField(frame: NSRect(x: 0, y: 0, width: width, height: 24))
        userField.placeholderString = "Kerberos userid for \(proxy.rawValue)"
        userField.stringValue = savedUsername(for: proxy)

        let passField = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: width, height: 24))
        passField.placeholderString = "Kerberos password"

        stack.addArrangedSubview(userField)
        stack.addArrangedSubview(passField)
        alert.accessoryView = stack

        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let user = userField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let pass = passField.stringValue
        guard !user.isEmpty, !pass.isEmpty else { return }
        _ = saveCredentials(for: proxy, user: user, password: pass)
    }

    @objc private func onClear() {
        IITDProxySession.shared.stop()
        runSwitch(progressLabel: "Clearing VPN…") { clearVPN() }
    }

    @objc private func onUnlock() {
        runSwitch(progressLabel: "Unlocking…") { installPasswordlessHelper() }
    }

    @objc private func onQuit() {
        IITDProxySession.shared.stop()
        NSApp.terminate(nil)
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
