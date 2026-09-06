import Foundation
import Network
import AppKit

/// Keeps institute proxy CGI logged in whenever the user wants it on.
/// Fixes: relaunch idle+checkmark, sleep/wake, Wi‑Fi blips, Keychain unlock delay.
final class ProxyWatchdog {
    static let shared = ProxyWatchdog()

    private let queue = DispatchQueue(label: "com.rahulmasand.dnstoggle.watchdog")
    private var pathMonitor: NWPathMonitor?
    private var reconcileTimer: DispatchSourceTimer?
    private var keychainRetryTimer: DispatchSourceTimer?
    private var lastPathSatisfied = true
    private var lastReconnectAt: Date = .distantPast
    private var wakeWorkItem: DispatchWorkItem?
    private var started = false

    private let minReconnectGap: TimeInterval = 8
    private let reconcileInterval: TimeInterval = 15

    private init() {}

    func start() {
        queue.async {
            guard !self.started else { return }
            self.started = true
            self.startPathMonitor()
            self.startReconcileTimer()
            self.bootstrapFromSystemOrDesired()
            self.startKeychainRetryWindow()
        }

        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: nil
        ) { [weak self] _ in
            self?.handleWake()
        }
    }

    // MARK: - Public triggers

    func requestReconnect(reason: String, force: Bool = false) {
        queue.async {
            self.reconnectIfNeeded(reason: reason, force: force)
        }
    }

    func handleWake() {
        queue.async {
            self.wakeWorkItem?.cancel()
            let work = DispatchWorkItem { [weak self] in
                self?.reconnectIfNeeded(reason: "wake", force: true)
            }
            self.wakeWorkItem = work
            // Wi‑Fi + Keychain need a beat after sleep.
            self.queue.asyncAfter(deadline: .now() + 5, execute: work)
        }
    }

    // MARK: - Bootstrap

    private func bootstrapFromSystemOrDesired() {
        // If macOS still has proxy22/62 on from a previous session, treat as desired-on.
        if let active = DNSManager.detectActiveProxy() {
            ProxySelection.markDesiredOn(active)
            reconnectIfNeeded(reason: "launch-system-proxy", force: true)
            return
        }
        if ProxySelection.desiredOn {
            reconnectIfNeeded(reason: "launch-desired", force: true)
        }
    }

    private func startKeychainRetryWindow() {
        keychainRetryTimer?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: queue)
        // Retry for ~90s after launch in case Keychain is still locked.
        timer.schedule(deadline: .now() + 5, repeating: 5)
        var ticks = 0
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            ticks += 1
            if ticks > 18 {
                self.keychainRetryTimer?.cancel()
                self.keychainRetryTimer = nil
                return
            }
            guard ProxySelection.desiredOn || DNSManager.detectActiveProxy() != nil else { return }
            let choice = DNSManager.detectActiveProxy() ?? ProxySelection.current
            guard KeychainStore.hasCredentials(for: choice) else { return }
            if !IITDProxySession.shared.isActive {
                self.reconnectIfNeeded(reason: "keychain-ready", force: true)
                self.keychainRetryTimer?.cancel()
                self.keychainRetryTimer = nil
            }
        }
        timer.resume()
        keychainRetryTimer = timer
    }

    // MARK: - Path + timer

    private func startPathMonitor() {
        let monitor = NWPathMonitor()
        pathMonitor = monitor
        monitor.pathUpdateHandler = { [weak self] path in
            guard let self else { return }
            self.queue.async {
                let ok = path.status == .satisfied
                let was = self.lastPathSatisfied
                self.lastPathSatisfied = ok
                if ok && !was {
                    // Network came back — debounce then reconnect.
                    self.queue.asyncAfter(deadline: .now() + 3) {
                        self.reconnectIfNeeded(reason: "path-restored", force: true)
                    }
                }
            }
        }
        monitor.start(queue: queue)
    }

    private func startReconcileTimer() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + reconcileInterval, repeating: reconcileInterval)
        timer.setEventHandler { [weak self] in
            self?.reconcile()
        }
        timer.resume()
        reconcileTimer = timer
    }

    /// Periodic: system proxy on or desired-on, but CGI not running → start again.
    private func reconcile() {
        let system = DNSManager.detectActiveProxy()
        if let system {
            // Stay in sync with what macOS has.
            if !ProxySelection.desiredOn {
                ProxySelection.markDesiredOn(system)
            } else if ProxySelection.current != system {
                ProxySelection.set(system)
            }
        }

        guard ProxySelection.desiredOn || system != nil else { return }

        let session = IITDProxySession.shared
        if !session.isActive {
            reconnectIfNeeded(reason: "watchdog-idle", force: false)
            return
        }
        if !session.lastHealthOK {
            // Soft nudge — session thinks it's on but traffic is bad.
            reconnectIfNeeded(reason: "watchdog-unhealthy", force: false)
        }
    }

    private func reconnectIfNeeded(reason: String, force: Bool) {
        guard ProxySelection.desiredOn || DNSManager.detectActiveProxy() != nil else { return }

        let now = Date()
        if !force, now.timeIntervalSince(lastReconnectAt) < minReconnectGap { return }
        lastReconnectAt = now

        let choice = DNSManager.detectActiveProxy() ?? ProxySelection.current
        ProxySelection.set(choice)

        guard KeychainStore.hasCredentials(for: choice) else {
            IITDProxySession.shared.publishExternal(
                status: "Need Kerberos for \(choice.shortLabel) — save it",
                healthOK: false
            )
            return
        }

        let session = IITDProxySession.shared
        if session.isActive, force || !session.lastHealthOK {
            session.forceReconnect(reason: reason)
        } else if !session.isActive {
            // Ensure system proxy points at the right host, then CGI login.
            _ = DNSManager.setInstituteProxy(choice)
            session.start(proxy: choice, reason: reason)
        }
    }
}
