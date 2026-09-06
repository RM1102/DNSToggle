import Foundation
import Combine

/// Keepalive interval — official scripts often use 60–120s; 60s is safer against idle drop.
private let refreshIntervalSeconds: TimeInterval = 60
private let maxConsecutiveFailures = 2

/// CGI login + keepalive for proxy22 / proxy62.
/// Critical rule: if the CGI session dies while macOS still has HTTP(S) proxy set,
/// every app hangs. Always clear the system proxy when we cannot restore the session.
final class IITDProxySession: ObservableObject {
    static let shared = IITDProxySession()

    private let stateQueue = DispatchQueue(label: "com.rahulmasand.dnstoggle.proxy.state")
    private var refreshTimer: DispatchSourceTimer?
    private var healthTimer: DispatchSourceTimer?
    private var running = false
    private var sessionID = ""
    private var proxy = ProxyChoice.proxy62
    private var usingExistingSession = false
    private var consecutiveFailures = 0

    @Published private(set) var lastStatus = "Proxy idle"
    @Published private(set) var lastRefreshAt: Date?
    @Published private(set) var lastHealthOK = false
    @Published private(set) var activeProxy: ProxyChoice?
    @Published private(set) var isActive = false

    // MARK: public API

    func start(proxy: ProxyChoice) {
        stateQueue.async {
            self.cancelTimers()
            self.proxy = proxy
            self.running = true
            self.usingExistingSession = false
            self.sessionID = ""
            self.consecutiveFailures = 0
            DispatchQueue.main.async {
                self.activeProxy = proxy
                self.isActive = true
            }
            self.loginOrAdopt()
        }
    }

    func stop(logoutCGI: Bool = true) {
        stateQueue.async {
            self.cancelTimers()
            self.running = false
            self.usingExistingSession = false
            self.consecutiveFailures = 0
            if logoutCGI {
                self.logoutCurrent()
            }
            self.sessionID = ""
            self.publish(status: "Proxy logged out", healthOK: false, refreshAt: nil)
            DispatchQueue.main.async {
                self.activeProxy = nil
                self.isActive = false
            }
        }
    }

    func forceReconnect() {
        stateQueue.async {
            self.cancelTimers()
            self.usingExistingSession = false
            self.logoutCurrent()
            self.sessionID = ""
            self.consecutiveFailures = 0
            self.publish(status: "Reconnecting…", healthOK: false, refreshAt: nil)
            if self.running {
                _ = PrivilegedHelper.runHelper(self.proxy.helperAction)
                self.loginOrAdopt()
            }
        }
    }

    /// Prefer clearing system proxy first (caller should do that), then best-effort CGI logout.
    func logoutEverywhere(completion: (() -> Void)? = nil) {
        DispatchQueue.global(qos: .userInitiated).async {
            let snap = self.stateQueue.sync { () -> (ProxyChoice, String) in
                self.cancelTimers()
                let pair = (self.proxy, self.sessionID)
                self.running = false
                self.usingExistingSession = false
                self.sessionID = ""
                self.consecutiveFailures = 0
                return pair
            }

            if !snap.1.isEmpty {
                _ = Self.cgi(on: snap.0, fields: ["sessionid": snap.1, "action": "logout"])
            }

            var loggedOutAny = false
            for choice in ProxyChoice.allCases {
                guard let creds = KeychainStore.load(for: choice) else { continue }
                Self.logoutOnProxy(choice, user: creds.user, pass: creds.pass)
                loggedOutAny = true
            }
            if loggedOutAny {
                self.publish(status: "Logged out on proxy62 + proxy22", healthOK: false, refreshAt: nil)
            } else {
                self.publish(status: "Proxy cleared", healthOK: false, refreshAt: nil)
            }

            DispatchQueue.main.async {
                self.activeProxy = nil
                self.isActive = false
                completion?()
            }
        }
    }

    // MARK: CGI helpers — always bypass macOS/env proxy so a dead session cannot block keepalive

    private static let curlBase = [
        "-k", "-s", "--noproxy", "*",
        "--connect-timeout", "6", "--max-time", "10"
    ]

    private static func curl(_ args: [String]) -> String {
        PrivilegedHelper.run("/usr/bin/curl", args: args, timeoutSeconds: 12).output
    }

    private static func urlEncode(_ s: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return s.addingPercentEncoding(withAllowedCharacters: allowed) ?? s
    }

    private static func cgi(on proxy: ProxyChoice, fields: [String: String]) -> String {
        let body = fields.map { "\($0.key)=\(urlEncode($0.value))" }.joined(separator: "&")
        return curl(curlBase + ["-d", body, proxy.cgiURL])
    }

    private static func fetchSessionID(on proxy: ProxyChoice) -> String? {
        let html = curl(curlBase + [proxy.cgiURL])
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
        // Explicit -x; still noproxy for other URLs. Short timeouts so we fail fast.
        let code = curl([
            "-k", "-s", "-o", "/dev/null", "-w", "%{http_code}",
            "--connect-timeout", "4", "--max-time", "8",
            "-x", "http://\(proxy.host):3128",
            "http://www.iitd.ac.in/"
        ]).trimmingCharacters(in: .whitespacesAndNewlines)
        return code == "200" || code == "301" || code == "302" || code == "303"
    }

    private static func logoutOnProxy(_ proxy: ProxyChoice, user: String, pass: String) {
        guard let sid = fetchSessionID(on: proxy) else { return }
        let login = cgi(on: proxy, fields: [
            "sessionid": sid, "action": "Validate", "userid": user, "pass": pass
        ])
        if login.lowercased().contains("logged in successfully") {
            _ = cgi(on: proxy, fields: ["sessionid": sid, "action": "logout"])
            return
        }
        _ = cgi(on: proxy, fields: ["sessionid": sid, "action": "logout"])
    }

    private func cgi(_ fields: [String: String]) -> String {
        Self.cgi(on: proxy, fields: fields)
    }

    private func logoutCurrent() {
        guard !sessionID.isEmpty else { return }
        _ = cgi(["sessionid": sessionID, "action": "logout"])
        sessionID = ""
    }

    private func publish(status: String, healthOK: Bool, refreshAt: Date?) {
        DispatchQueue.main.async {
            self.lastStatus = status
            self.lastHealthOK = healthOK
            if let refreshAt {
                self.lastRefreshAt = refreshAt
            } else if !healthOK {
                self.lastRefreshAt = nil
            }
        }
    }

    private func cancelTimers() {
        refreshTimer?.cancel()
        refreshTimer = nil
        healthTimer?.cancel()
        healthTimer = nil
    }

    /// Tear down CGI session and clear macOS proxy so the Mac is not left bricked.
    private func abandonSession(reason: String) {
        cancelTimers()
        running = false
        usingExistingSession = false
        logoutCurrent()
        sessionID = ""
        consecutiveFailures = 0
        publish(status: reason, healthOK: false, refreshAt: nil)
        DispatchQueue.main.async {
            self.activeProxy = nil
            self.isActive = false
        }
        // Clear system proxy off this queue so we don't deadlock.
        DispatchQueue.global(qos: .userInitiated).async {
            _ = DNSManager.turnProxyOff()
            DNSManager.flushDNSOnly()
        }
    }

    /// When "already logged in" blocks us, try logout-then-login once.
    private func reclaimSession() {
        publish(status: "Reclaiming session…", healthOK: false, refreshAt: nil)
        if let creds = KeychainStore.load(for: proxy) {
            Self.logoutOnProxy(proxy, user: creds.user, pass: creds.pass)
        }
        logoutCurrent()
        sessionID = ""
        usingExistingSession = false
        // Brief pause so CSC releases the old session.
        Thread.sleep(forTimeInterval: 1.0)
        loginOrAdopt(allowReclaim: false)
    }

    private func noteFailureThen(_ action: () -> Void) {
        consecutiveFailures += 1
        if consecutiveFailures >= maxConsecutiveFailures {
            abandonSession(reason: "Proxy unreachable — system proxy cleared so internet works")
            return
        }
        action()
    }

    private func loginOrAdopt(allowReclaim: Bool = true) {
        guard running else { return }

        guard let creds = KeychainStore.load(for: proxy) else {
            abandonSession(reason: "Missing Kerberos for \(proxy.shortLabel) — save it first")
            return
        }

        guard let sid = Self.fetchSessionID(on: proxy) else {
            noteFailureThen {
                self.publish(status: "Cannot reach \(self.proxy.host) — retrying…", healthOK: false, refreshAt: nil)
                self.scheduleRetry(after: 10)
            }
            return
        }

        sessionID = sid
        let loginText = cgi([
            "sessionid": sid, "action": "Validate", "userid": creds.user, "pass": creds.pass
        ])

        if loginText.lowercased().contains("logged in successfully") {
            usingExistingSession = false
            consecutiveFailures = 0
            let ok = Self.verifyTraffic(on: proxy)
            let msg = ok ? "\(proxy.host) logged in" : "\(proxy.host) logged in (checking…)"
            publish(status: msg, healthOK: ok, refreshAt: Date())
            scheduleRefreshTimer()
            // Confirm traffic shortly after login.
            scheduleHealthProbe(after: 15)
            return
        }

        if loginText.contains("already logged in") {
            if Self.verifyTraffic(on: proxy) {
                usingExistingSession = true
                consecutiveFailures = 0
                publish(status: "\(proxy.host) connected (existing login)", healthOK: true, refreshAt: Date())
                scheduleHealthTimerOnly()
                return
            }
            if allowReclaim {
                reclaimSession()
                return
            }
            abandonSession(reason: "Logged in elsewhere — proxy cleared. Log out there, then retry.")
            return
        }

        if loginText.isEmpty {
            noteFailureThen {
                self.publish(status: "Login timed out — retrying…", healthOK: false, refreshAt: nil)
                self.scheduleRetry(after: 10)
            }
            return
        }

        // Bad password shouldn't leave proxy on forever either.
        abandonSession(reason: "Login failed — check Kerberos password (proxy cleared)")
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
        timer.schedule(deadline: .now() + 45, repeating: 45)
        timer.setEventHandler { [weak self] in self?.performHealthCheck() }
        timer.resume()
        healthTimer = timer
    }

    private func scheduleHealthProbe(after seconds: TimeInterval) {
        stateQueue.asyncAfter(deadline: .now() + seconds) { [weak self] in
            guard let self, self.running else { return }
            if Self.verifyTraffic(on: self.proxy) {
                self.consecutiveFailures = 0
                self.publish(
                    status: "\(self.proxy.host) logged in",
                    healthOK: true,
                    refreshAt: self.lastRefreshAt ?? Date()
                )
            } else {
                self.noteFailureThen {
                    self.publish(status: "Traffic check failed — re-logging in…", healthOK: false, refreshAt: nil)
                    self.logoutCurrent()
                    self.loginOrAdopt()
                }
            }
        }
    }

    private func performRefresh() {
        guard running, !usingExistingSession else { return }

        if sessionID.isEmpty {
            loginOrAdopt()
            return
        }

        let refresh = cgi(["sessionid": sessionID, "action": "Refresh"])
        if refresh.lowercased().contains("logged in successfully") {
            consecutiveFailures = 0
            let ok = Self.verifyTraffic(on: proxy)
            if ok {
                publish(status: "\(proxy.host) logged in", healthOK: true, refreshAt: Date())
            } else {
                // CGI says logged in but proxy path is dead — reclaim.
                noteFailureThen {
                    self.publish(status: "Proxy path dead — re-logging in…", healthOK: false, refreshAt: nil)
                    self.logoutCurrent()
                    self.loginOrAdopt()
                }
            }
            return
        }

        // Empty / expired / weird response → re-login. If that fails, abandon clears proxy.
        logoutCurrent()
        publish(status: "Session expired — re-logging in…", healthOK: false, refreshAt: nil)
        loginOrAdopt()
    }

    private func performHealthCheck() {
        guard running else { return }
        if Self.verifyTraffic(on: proxy) {
            consecutiveFailures = 0
            publish(status: "\(proxy.host) connected (existing login)", healthOK: true, refreshAt: Date())
            return
        }
        // Existing foreign session died — reclaim or clear so the Mac is usable.
        noteFailureThen {
            self.publish(status: "Proxy stopped — reclaiming…", healthOK: false, refreshAt: nil)
            self.reclaimSession()
        }
    }
}
