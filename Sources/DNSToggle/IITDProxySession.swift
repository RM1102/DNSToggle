import Foundation
import Combine

/// CGI login + keepalive. I/O never runs on the state queue or the main thread.
/// Invariant: system HTTP proxy is on only while logged in and traffic-verified.
/// Sleep clears proxy (fail-open); wake forces campus-gated re-auth.
final class IITDProxySession: ObservableObject {
    static let shared = IITDProxySession()

    enum Phase: String {
        case idle
        case loggingIn
        case loggedIn
        case clearing
        case failedAuth
        case offCampus
        case asleep
        case waking
    }

    private let stateQueue = DispatchQueue(label: "com.rahulmasand.dnstoggle.proxy.state")
    private var phase: Phase = .idle
    private var generation = 0
    private var inFlight = false
    private var coalesceStart: ProxyChoice?
    private var coalesceStop = false
    private var proxy = ProxyChoice.proxy62
    private var sessionID = ""
    private var usingExistingSession = false
    private var refreshTimer: DispatchSourceTimer?
    private var healthTimer: DispatchSourceTimer?
    private var retryWork: DispatchWorkItem?
    private var softFailures = 0
    private var unreachableStreak = 0
    private var externalFailStreak = 0
    private var circuitOpen = false
    private var externalCircuitOpen = false
    /// Consecutive campus misses during wake/launch before clearing leftover Squid / opening circuit.
    private var wakeCampusMisses = 0
    private var savedDNSPresetID: String?

    /// After this many consecutive CGI unreachable failures (post-settle), stop auto-retry until reset.
    private static let circuitBreakerLimit = 3
    /// Wake/launch soft misses that do not open the circuit.
    private static let wakeSoftMissLimit = 2
    /// Stop flap-reconnect after this many external-through-proxy failures.
    private static let externalFailLimit = 3

    @Published private(set) var lastStatus = "Proxy Off"
    @Published private(set) var lastRefreshAt: Date?
    @Published private(set) var lastHealthOK = false
    @Published private(set) var activeProxy: ProxyChoice?
    @Published private(set) var isActive = false
    @Published private(set) var isBusy = false
    @Published private(set) var currentPhase: Phase = .idle
    @Published private(set) var isOffCampus = false

    var isLoggedIn: Bool { currentPhase == .loggedIn && lastHealthOK }

    private static let wakeReasons: Set<String> = [
        "wake", "wake-retry", "wake-8", "wake-20", "wake-45",
        "launch-leftover", "launch-desired", "path-restored"
    ]

    private static let forceReconnectReasons: Set<String> = [
        "user-click", "user-reconnect", "creds-saved",
        "wake", "wake-retry", "wake-8", "wake-20", "wake-45"
    ]

    // MARK: - Public API (never blocks the caller)

    func resetCircuitBreaker() {
        stateQueue.async {
            self.circuitOpen = false
            self.externalCircuitOpen = false
            self.unreachableStreak = 0
            self.externalFailStreak = 0
            self.softFailures = 0
            self.wakeCampusMisses = 0
        }
    }

    /// Lid closing / system sleep: cancel keepalive, mark not logged in, clear Squid. Keeps desiredOn.
    func markStaleForSleep() {
        stateQueue.async {
            self.retryWork?.cancel()
            self.retryWork = nil
            self.cancelTimers()
            self.coalesceStart = nil
            self.coalesceStop = true
            self.generation += 1
            self.sessionID = ""
            self.usingExistingSession = false
            self.inFlight = false
            self.softFailures = 0
            self.unreachableStreak = 0
            self.wakeCampusMisses = 0
            self.circuitOpen = false
            self.setPhase(.asleep, status: "Asleep — proxy cleared", health: false, proxy: nil)
            SessionLog.info("sleep — clearing proxy")
        }
        ProcessRunner.ioQueue.async {
            self.restoreSavedDNSIfNeeded()
            _ = DNSManager.turnProxyOff(allowAdminPrompt: false)
            DNSManager.invalidateProxyCache()
            PrivilegedHelper.invalidatePasswordlessCache()
        }
    }

    /// Path lost Wi‑Fi / network: clear Squid and pause refresh so apps do not hang.
    func handlePathDown() {
        stateQueue.async {
            self.retryWork?.cancel()
            self.retryWork = nil
            self.cancelTimers()
            self.coalesceStart = nil
            self.generation += 1
            self.sessionID = ""
            self.usingExistingSession = false
            self.inFlight = false
            let keepDesired = ProxySelection.desiredOn
            self.setPhase(
                .idle,
                status: keepDesired ? "Network down — proxy cleared" : "Proxy Off",
                health: false,
                proxy: nil
            )
            SessionLog.info("path down — clearing proxy")
        }
        ProcessRunner.ioQueue.async {
            self.restoreSavedDNSIfNeeded()
            _ = DNSManager.turnProxyOff(allowAdminPrompt: false)
            DNSManager.invalidateProxyCache()
        }
    }

    /// Force reconnect after wake even if we previously looked logged in.
    func recoverAfterWake(reason: String) {
        stateQueue.async {
            self.coalesceStop = false
            self.circuitOpen = false
            self.externalCircuitOpen = false
            if reason.hasPrefix("wake") {
                self.softFailures = 0
            }
            let choice = ProxySelection.current
            if self.inFlight {
                self.coalesceStart = choice
                return
            }
            if reason.hasPrefix("wake") {
                self.setPhase(.waking, status: "Waking — waiting for campus network…", health: false, proxy: nil)
            }
            self.beginLogin(choice, reason: reason)
        }
    }

    /// Called by watchdog when CGI probe fails during wake/launch (before login).
    func noteCampusMiss(reason: String, leftoverProxyPresent: Bool) {
        stateQueue.async {
            self.wakeCampusMisses += 1
            let soft = Self.wakeReasons.contains(reason)
            if soft, self.wakeCampusMisses <= Self.wakeSoftMissLimit {
                self.setPhase(
                    .waking,
                    status: "Waking — waiting for campus network…",
                    health: false,
                    proxy: nil
                )
                return
            }
            self.setPhase(
                .offCampus,
                status: "Off campus — proxy left off. Will retry when IIT proxy is reachable.",
                health: false,
                proxy: nil
            )
            if leftoverProxyPresent, self.wakeCampusMisses >= Self.wakeSoftMissLimit {
                ProcessRunner.ioQueue.async {
                    self.restoreSavedDNSIfNeeded()
                    _ = DNSManager.turnProxyOff(allowAdminPrompt: false)
                }
            }
        }
    }

    func requestConnect(_ choice: ProxyChoice, reason: String = "manual") {
        stateQueue.async {
            self.coalesceStop = false
            if self.inFlight {
                self.coalesceStart = choice
                return
            }
            self.beginLogin(choice, reason: reason)
        }
    }

    func requestReconnect(reason: String = "manual") {
        stateQueue.async {
            let choice = ProxySelection.current
            self.coalesceStop = false
            if self.inFlight {
                self.coalesceStart = choice
                return
            }
            self.beginLogin(choice, reason: reason)
        }
    }

    /// User / Clear / Quit path. System proxy off FIRST; CGI logout second (best-effort).
    /// `allowAdminPrompt` true for explicit user Off so it works without the helper.
    func requestStop(clearSystemProxy: Bool, logoutCGI: Bool, allowAdminPrompt: Bool = false) {
        stateQueue.async {
            self.retryWork?.cancel()
            self.retryWork = nil
            self.cancelTimers()
            self.coalesceStart = nil
            self.coalesceStop = true
            self.generation += 1
            self.circuitOpen = false
            self.externalCircuitOpen = false
            self.unreachableStreak = 0
            self.externalFailStreak = 0
            self.softFailures = 0
            self.wakeCampusMisses = 0
            let gen = self.generation
            let sid = self.sessionID
            let choice = self.proxy
            self.sessionID = ""
            self.usingExistingSession = false
            self.inFlight = true
            self.setPhase(.clearing, status: "Turning proxy off…", health: false, proxy: nil)
            SessionLog.info("stop requested")

            ProcessRunner.ioQueue.async {
                self.restoreSavedDNSIfNeeded()
                if clearSystemProxy {
                    _ = DNSManager.turnProxyOff(allowAdminPrompt: allowAdminPrompt)
                    DNSManager.flushDNSOnly()
                    if DNSManager.detectActiveProxy() != nil {
                        _ = DNSManager.turnProxyOff(allowAdminPrompt: allowAdminPrompt)
                    }
                }
                if logoutCGI, !sid.isEmpty {
                    _ = Self.cgi(on: choice, fields: ["sessionid": sid, "action": "logout"])
                }
                self.stateQueue.async {
                    guard gen == self.generation else { return }
                    self.inFlight = false
                    self.coalesceStop = false
                    self.setPhase(.idle, status: "Proxy Off", health: false, proxy: nil)
                }
            }
        }
    }

    /// Quit always clears system proxy. Best-effort CGI logout. Persists desiredOn.
    func prepareForTermination() {
        Heartbeat.stop()
        var sid = ""
        var choice = ProxyChoice.proxy62
        let lock = DispatchSemaphore(value: 0)
        stateQueue.async {
            self.generation += 1
            self.retryWork?.cancel()
            self.cancelTimers()
            self.coalesceStop = true
            self.inFlight = false
            sid = self.sessionID
            choice = self.proxy
            self.sessionID = ""
            lock.signal()
        }
        _ = lock.wait(timeout: .now() + 0.2)

        let sem = DispatchSemaphore(value: 0)
        Thread.detachNewThread {
            self.restoreSavedDNSIfNeeded()
            _ = DNSManager.turnProxyOff(allowAdminPrompt: false)
            if FileManager.default.isExecutableFile(atPath: PrivilegedHelper.helperPath) {
                _ = ProcessRunner.run(
                    "/usr/bin/sudo",
                    args: ["-n", PrivilegedHelper.helperPath, "proxy-off"],
                    timeoutSeconds: 2
                )
            }
            if !sid.isEmpty {
                _ = Self.cgi(on: choice, fields: ["sessionid": sid, "action": "logout"])
            }
            sem.signal()
        }
        _ = sem.wait(timeout: .now() + 2.5)
    }

    func publishExternal(status: String, healthOK: Bool) {
        publish(status: status, healthOK: healthOK, refreshAt: nil)
    }

    /// Enforce invariant: IITD system proxy only while desired + logged in + healthy.
    func reconcileSystemProxy() {
        stateQueue.async {
            guard !self.inFlight else { return }
            let phase = self.phase
            let healthy = phase == .loggedIn && self.lastHealthOK
            let desired = ProxySelection.desiredOn
            ProcessRunner.ioQueue.async {
                let active = DNSManager.detectActiveProxy()
                self.stateQueue.async {
                    guard !self.inFlight else { return }
                    if let active, !(desired && healthy) {
                        SessionLog.warn("reconcile — leftover \(active.host), clearing")
                        self.inFlight = true
                        self.setPhase(.clearing, status: "Clearing leftover proxy…", health: false, proxy: nil)
                        let gen = self.generation
                        ProcessRunner.ioQueue.async {
                            self.restoreSavedDNSIfNeeded()
                            _ = DNSManager.turnProxyOff(allowAdminPrompt: false)
                            self.stateQueue.async {
                                guard gen == self.generation else { return }
                                self.inFlight = false
                                let status = desired
                                    ? "Proxy cleared — reconnecting…"
                                    : "Proxy Off"
                                self.setPhase(.idle, status: status, health: false, proxy: nil)
                                if desired, !self.circuitOpen, !self.externalCircuitOpen {
                                    self.beginLogin(ProxySelection.current, reason: "reconcile")
                                }
                            }
                        }
                        return
                    }
                    if healthy, desired, active == nil {
                        SessionLog.warn("reconcile — green UI but system proxy missing")
                        self.cancelTimers()
                        self.sessionID = ""
                        self.setPhase(.idle, status: "System proxy missing — reconnecting…", health: false, proxy: nil)
                        if !self.circuitOpen, !self.externalCircuitOpen {
                            self.beginLogin(ProxySelection.current, reason: "reconcile-missing")
                        }
                    }
                }
            }
        }
    }

    // MARK: - Campus reachability

    /// True when CGI HTML returns a sessionid within curl timeout (~5s connect).
    static func isCampusReachable(for choice: ProxyChoice = ProxySelection.current) -> Bool {
        fetchSessionID(on: choice) != nil
    }

    // MARK: - Login

    private func beginLogin(_ choice: ProxyChoice, reason: String) {
        retryWork?.cancel()
        retryWork = nil
        cancelTimers()

        let force = Self.forceReconnectReasons.contains(reason)
        if circuitOpen && !force {
            setPhase(
                .offCampus,
                status: "Off campus — proxy left off. Will retry when IIT proxy is reachable.",
                health: false,
                proxy: nil
            )
            return
        }
        if externalCircuitOpen && !force {
            setPhase(
                .idle,
                status: "Internet via proxy failed — stopped. Click Reconnect.",
                health: false,
                proxy: nil
            )
            return
        }

        generation += 1
        let gen = generation
        proxy = choice
        inFlight = true
        usingExistingSession = false
        sessionID = ""
        let status: String
        if reason.hasPrefix("wake") {
            status = "Reconnecting after sleep…"
        } else {
            status = "Logging in to \(choice.host)…"
        }
        setPhase(.loggingIn, status: status, health: false, proxy: choice)
        SessionLog.info("login begin reason=\(reason) host=\(choice.host)")

        ProcessRunner.ioQueue.async {
            DNSManager.quitConflictingVPNs()
            let outcome = self.performLogin(choice)
            self.stateQueue.async {
                guard gen == self.generation else { return }
                self.inFlight = false
                if self.coalesceStop {
                    self.coalesceStop = false
                    self.coalesceStart = nil
                    return
                }
                if let next = self.coalesceStart {
                    self.coalesceStart = nil
                    self.beginLogin(next, reason: "coalesced")
                    return
                }
                self.applyLoginOutcome(outcome, choice: choice, reason: reason)
            }
        }
    }

    private enum LoginOutcome {
        case success(sessionID: String, adopted: Bool, trafficOK: Bool)
        case unreachable
        case alreadyElsewhere
        case badPassword
        case missingCreds
        case proxySetFailed
    }

    private func performLogin(_ choice: ProxyChoice) -> LoginOutcome {
        guard let creds = KeychainStore.load(for: choice) else { return .missingCreds }

        if DNSManager.detectActiveProxy() != nil {
            _ = DNSManager.turnProxyOff(allowAdminPrompt: false)
        }

        guard let sid = Self.fetchSessionID(on: choice) else { return .unreachable }

        let loginText = Self.cgi(on: choice, fields: [
            "sessionid": sid, "action": "Validate", "userid": creds.user, "pass": creds.pass
        ])

        if loginText.lowercased().contains("logged in successfully") {
            rememberDNSAndForceAutomatic()
            let setOK = DNSManager.setInstituteProxy(choice, allowAdminPrompt: false)
            guard setOK else {
                _ = DNSManager.turnProxyOff(allowAdminPrompt: false)
                restoreSavedDNSIfNeeded()
                return .proxySetFailed
            }
            Self.waitForProxyApplied(choice)
            let traffic = Self.verifyTraffic(on: choice)
            if !traffic {
                _ = DNSManager.turnProxyOff(allowAdminPrompt: false)
                restoreSavedDNSIfNeeded()
            }
            return .success(sessionID: sid, adopted: false, trafficOK: traffic)
        }

        if loginText.contains("already logged in") {
            rememberDNSAndForceAutomatic()
            let setOK = DNSManager.setInstituteProxy(choice, allowAdminPrompt: false)
            if setOK {
                Self.waitForProxyApplied(choice)
                if Self.verifyTraffic(on: choice) {
                    return .success(sessionID: sid, adopted: true, trafficOK: true)
                }
            }
            Self.logoutOnProxy(choice, user: creds.user, pass: creds.pass)
            guard let sid2 = Self.fetchSessionID(on: choice) else {
                _ = DNSManager.turnProxyOff(allowAdminPrompt: false)
                restoreSavedDNSIfNeeded()
                return .unreachable
            }
            let again = Self.cgi(on: choice, fields: [
                "sessionid": sid2, "action": "Validate", "userid": creds.user, "pass": creds.pass
            ])
            if again.lowercased().contains("logged in successfully") {
                let setOK2 = DNSManager.setInstituteProxy(choice, allowAdminPrompt: false)
                Self.waitForProxyApplied(choice)
                let traffic = setOK2 && Self.verifyTraffic(on: choice)
                if !traffic {
                    _ = DNSManager.turnProxyOff(allowAdminPrompt: false)
                    restoreSavedDNSIfNeeded()
                }
                return .success(sessionID: sid2, adopted: false, trafficOK: traffic)
            }
            _ = DNSManager.turnProxyOff(allowAdminPrompt: false)
            restoreSavedDNSIfNeeded()
            return .alreadyElsewhere
        }

        if loginText.isEmpty {
            _ = DNSManager.turnProxyOff(allowAdminPrompt: false)
            restoreSavedDNSIfNeeded()
            return .unreachable
        }

        let lower = loginText.lowercased()
        let credentialReject =
            lower.contains("userid and/or password")
            || lower.contains("password does'not match")
            || lower.contains("password does not match")
            || lower.contains("authentication failed")

        _ = DNSManager.turnProxyOff(allowAdminPrompt: false)
        restoreSavedDNSIfNeeded()
        return credentialReject ? .badPassword : .unreachable
    }

    private func applyLoginOutcome(_ outcome: LoginOutcome, choice: ProxyChoice, reason: String) {
        let isWakeLike = Self.wakeReasons.contains(reason) || reason.hasPrefix("wake")

        switch outcome {
        case .success(let sid, let adopted, let trafficOK):
            sessionID = sid
            usingExistingSession = adopted
            softFailures = 0
            unreachableStreak = 0
            wakeCampusMisses = 0
            circuitOpen = false
            proxy = choice
            if trafficOK {
                externalFailStreak = 0
                externalCircuitOpen = false
                setPhase(
                    .loggedIn,
                    status: adopted ? "\(choice.host) connected (existing login)" : "\(choice.host) logged in",
                    health: true,
                    proxy: choice,
                    refreshAt: Date()
                )
                scheduleRefresh()
                scheduleHealthProbe()
                SessionLog.info("login OK adopted=\(adopted)")
            } else {
                externalFailStreak += 1
                SessionLog.warn("login CGI OK but external verify failed streak=\(externalFailStreak)")
                setPhase(
                    .idle,
                    status: "Internet via proxy failed — clearing and reconnecting…",
                    health: false,
                    proxy: nil
                )
                if externalFailStreak >= Self.externalFailLimit {
                    externalCircuitOpen = true
                    setPhase(
                        .idle,
                        status: "Internet via proxy failed — stopped. Click Reconnect.",
                        health: false,
                        proxy: nil
                    )
                } else if ProxySelection.desiredOn {
                    scheduleRetry(after: 12, choice: choice)
                }
            }

        case .unreachable:
            ProcessRunner.ioQueue.async {
                self.restoreSavedDNSIfNeeded()
                _ = DNSManager.turnProxyOff(allowAdminPrompt: false)
            }
            softFailures += 1

            if isWakeLike {
                wakeCampusMisses += 1
                if wakeCampusMisses <= Self.wakeSoftMissLimit {
                    setPhase(
                        .waking,
                        status: "Waking — waiting for campus network…",
                        health: false,
                        proxy: nil
                    )
                    return
                }
            }

            unreachableStreak += 1
            if unreachableStreak >= Self.circuitBreakerLimit {
                circuitOpen = true
                setPhase(
                    .offCampus,
                    status: "Off campus — proxy left off. Will retry when IIT proxy is reachable.",
                    health: false,
                    proxy: nil
                )
                return
            }
            let delay = min(60.0, 8.0 * pow(2.0, Double(min(softFailures, 3))))
            setPhase(.idle, status: "Cannot reach \(choice.host) — retry in \(Int(delay))s", health: false, proxy: nil)
            if ProxySelection.desiredOn {
                scheduleRetry(after: delay, choice: choice)
            }

        case .alreadyElsewhere:
            softFailures += 1
            setPhase(.idle, status: "Logged in elsewhere — retrying…", health: false, proxy: nil)
            if ProxySelection.desiredOn {
                scheduleRetry(after: 20, choice: choice)
            }

        case .badPassword:
            ProxySelection.markDesiredOff()
            setPhase(.failedAuth, status: "Login failed — check Kerberos for \(choice.shortLabel)", health: false, proxy: nil)

        case .missingCreds:
            setPhase(.idle, status: "Need Kerberos for \(choice.shortLabel) — save it", health: false, proxy: nil)

        case .proxySetFailed:
            setPhase(.idle, status: "Could not set system proxy — enable password-free helper", health: false, proxy: nil)
            if ProxySelection.desiredOn {
                scheduleRetry(after: 15, choice: choice)
            }
        }
    }

    // MARK: - Refresh + health

    private func scheduleRefresh() {
        refreshTimer?.cancel()
        refreshTimer = nil
        let timer = DispatchSource.makeTimerSource(queue: stateQueue)
        let interval: TimeInterval = 90
        timer.schedule(deadline: .now() + interval, repeating: interval)
        timer.setEventHandler { [weak self] in self?.refreshOrHealth(includeCGI: true) }
        timer.resume()
        refreshTimer = timer
    }

    private func scheduleHealthProbe() {
        healthTimer?.cancel()
        healthTimer = nil
        let timer = DispatchSource.makeTimerSource(queue: stateQueue)
        timer.schedule(deadline: .now() + 25, repeating: 25)
        timer.setEventHandler { [weak self] in self?.refreshOrHealth(includeCGI: false) }
        timer.resume()
        healthTimer = timer
    }

    private func refreshOrHealth(includeCGI: Bool) {
        guard phase == .loggedIn, !inFlight else { return }
        let gen = generation
        let choice = proxy
        let sid = sessionID
        let adopted = usingExistingSession
        inFlight = true

        ProcessRunner.ioQueue.async {
            enum RefreshOutcome { case healthy, cgiExpired, externalFailed }
            let outcome: RefreshOutcome
            if includeCGI, !adopted, !sid.isEmpty {
                let body = Self.cgi(on: choice, fields: ["sessionid": sid, "action": "Refresh"])
                if body.lowercased().contains("logged in successfully") {
                    outcome = Self.verifyTraffic(on: choice) ? .healthy : .externalFailed
                } else {
                    outcome = .cgiExpired
                }
            } else {
                outcome = Self.verifyTraffic(on: choice) ? .healthy : .externalFailed
            }
            self.stateQueue.async {
                guard gen == self.generation else { return }
                self.inFlight = false
                if self.coalesceStart != nil || self.coalesceStop { return }
                if outcome == .healthy {
                    self.softFailures = 0
                    self.externalFailStreak = 0
                    self.setPhase(
                        .loggedIn,
                        status: adopted ? "\(choice.host) connected (existing login)" : "\(choice.host) logged in",
                        health: true,
                        proxy: choice,
                        refreshAt: Date()
                    )
                    return
                }
                self.cancelTimers()
                self.sessionID = ""
                self.externalFailStreak += 1
                let clearingStatus = outcome == .cgiExpired
                    ? "Session expired — clearing proxy…"
                    : "Internet via proxy failed — clearing and reconnecting…"
                SessionLog.warn("health fail outcome=\(outcome) streak=\(self.externalFailStreak)")
                self.setPhase(.clearing, status: clearingStatus, health: false, proxy: nil)
                let stopGen = self.generation
                ProcessRunner.ioQueue.async {
                    self.restoreSavedDNSIfNeeded()
                    _ = DNSManager.turnProxyOff(allowAdminPrompt: false)
                    self.stateQueue.async {
                        guard stopGen == self.generation else { return }
                        if self.externalFailStreak >= Self.externalFailLimit, outcome == .externalFailed {
                            self.externalCircuitOpen = true
                            self.setPhase(
                                .idle,
                                status: "Internet via proxy failed — stopped. Click Reconnect.",
                                health: false,
                                proxy: nil
                            )
                            return
                        }
                        let idleStatus = outcome == .cgiExpired
                            ? "Session expired"
                            : "Internet via proxy failed"
                        let reconnectReason = outcome == .cgiExpired
                            ? "refresh-expired"
                            : "external-verify-failed"
                        self.setPhase(.idle, status: idleStatus, health: false, proxy: nil)
                        if ProxySelection.desiredOn, !self.circuitOpen, !self.externalCircuitOpen {
                            self.beginLogin(choice, reason: reconnectReason)
                        }
                    }
                }
            }
        }
    }

    private func scheduleRetry(after seconds: TimeInterval, choice: ProxyChoice) {
        retryWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            guard ProxySelection.desiredOn, !self.inFlight, self.phase != .failedAuth else { return }
            guard !self.circuitOpen, !self.externalCircuitOpen else { return }
            self.beginLogin(choice, reason: "retry")
        }
        retryWork = work
        stateQueue.asyncAfter(deadline: .now() + seconds, execute: work)
    }

    // MARK: - DNS while on proxy

    private func rememberDNSAndForceAutomatic() {
        let servers = DNSManager.readDNSServers()
        if !servers.isEmpty {
            savedDNSPresetID = DNSManager.matchPresetID(servers)
        }
        _ = PrivilegedHelper.runHelper("auto")
    }

    private func restoreSavedDNSIfNeeded() {
        // Best-effort; never block Off on DNS restore failure.
        guard let id = savedDNSPresetID, id != "auto" else { return }
        savedDNSPresetID = nil
        let action: String
        switch id {
        case "cf": action = "cloudflare"
        case "google": action = "google"
        case "quad9": action = "quad9"
        default: return
        }
        _ = PrivilegedHelper.runHelper(action)
    }

    // MARK: - CGI

    private static let curlBase = [
        "-k", "-sS", "--noproxy", "*",
        "--ipv4", "--http1.1",
        "--connect-timeout", "5", "--max-time", "8"
    ]

    private static func curl(_ args: [String], timeout: Double = 10) -> String {
        // Strip shell proxy env so campus CGI / probes are not double-proxied.
        let envArgs = [
            "-u", "http_proxy", "-u", "https_proxy", "-u", "HTTP_PROXY",
            "-u", "HTTPS_PROXY", "-u", "ALL_PROXY", "-u", "all_proxy",
            "-u", "NO_PROXY", "-u", "no_proxy",
            "/usr/bin/curl"
        ] + args
        return ProcessRunner.runDetailed("/usr/bin/env", args: envArgs, timeoutSeconds: timeout).stdout
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

    private static func waitForProxyApplied(_ choice: ProxyChoice) {
        for _ in 0..<10 {
            if DNSManager.detectActiveProxy() == choice { return }
            Thread.sleep(forTimeInterval: 0.1)
        }
    }

    /// Open internet through Squid. Do not use --noproxy here (CGI uses --noproxy *).
    /// Campus URLs are a bad probe: IITD is in the system bypass list.
    private static func verifyTraffic(on proxy: ProxyChoice) -> Bool {
        let proxyURL = "http://\(proxy.host):3128"
        let base = [
            "-k", "-sS", "-o", "/dev/null",
            "--ipv4", "--http1.1",
            "--connect-timeout", "4", "--max-time", "6",
            "-x", proxyURL
        ]

        // Primary: HTTPS CONNECT — what Gmail actually needs.
        for attempt in 0..<2 {
            let codes = curl(
                base + ["-w", "%{http_code} %{http_connect}", "https://www.gstatic.com/generate_204"],
                timeout: 8
            ).trimmingCharacters(in: .whitespacesAndNewlines)
            let parts = codes.split(whereSeparator: { $0.isWhitespace }).map(String.init)
            let http = parts.first ?? ""
            let connect = parts.count > 1 ? parts[1] : ""
            SessionLog.info("verify https attempt=\(attempt) http=\(http) connect=\(connect)")
            // Origin 204 means the tunnel worked. Prefer CONNECT 200; some curl builds leave it blank.
            if http == "204" {
                if connect.isEmpty || connect == "200" { return true }
            }
            if attempt == 0 { Thread.sleep(forTimeInterval: 0.4) }
        }

        for url in [
            "http://www.gstatic.com/generate_204",
            "http://connectivitycheck.gstatic.com/generate_204"
        ] {
            let code = curl(base + ["-w", "%{http_code}", url], timeout: 8)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            SessionLog.info("verify http \(url) code=\(code)")
            if code == "204" { return true }
        }

        // Last resort: example.com, but reject IITD login HTML (hthuwal).
        let bodyProbe = [
            "-k", "-sS",
            "--ipv4", "--http1.1",
            "--connect-timeout", "4", "--max-time", "6",
            "-x", proxyURL,
            "-w", "\n%{http_code}",
            "http://example.com/"
        ]
        let raw = curl(bodyProbe, timeout: 8)
        let lines = raw.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        let code = lines.last?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let body = lines.dropLast().joined(separator: "\n").lowercased()
        if body.contains("iit delhi proxy") || body.contains("proxy.cgi") {
            SessionLog.warn("verify example.com got IITD login page")
            return false
        }
        let ok = code == "200" || code == "301" || code == "302" || code == "303"
        SessionLog.info("verify example.com code=\(code) ok=\(ok)")
        return ok
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

    // MARK: - State publish

    private func setPhase(
        _ new: Phase,
        status: String,
        health: Bool,
        proxy: ProxyChoice?,
        refreshAt: Date? = nil
    ) {
        phase = new
        publish(status: status, healthOK: health, refreshAt: refreshAt)
        DispatchQueue.main.async {
            self.currentPhase = new
            self.activeProxy = proxy
            self.isActive = new == .loggedIn
            self.isBusy = new == .loggingIn || new == .clearing || new == .waking
            self.isOffCampus = new == .offCampus
        }
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
}
