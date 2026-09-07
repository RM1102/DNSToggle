import Foundation
import Network
import AppKit

/// Scheduler only. Never runs curl or waits on CGI.
/// Sleep clears proxy; wake forces staggered campus-gated re-auth.
final class ProxyWatchdog {
    static let shared = ProxyWatchdog()

    private let queue = DispatchQueue(label: "com.rahulmasand.dnstoggle.watchdog")
    private var pathMonitor: NWPathMonitor?
    private var timer: DispatchSourceTimer?
    private var started = false
    private var pathOK = true
    private var wakeWorks: [DispatchWorkItem] = []
    private var pathRestoreWork: DispatchWorkItem?

    /// Staggered wake attempts (seconds after didWake). Wi‑Fi often needs >5s.
    private static let wakeDelays: [TimeInterval] = [8, 20, 45]

    private init() {}

    func start() {
        queue.async {
            guard !self.started else { return }
            self.started = true
            self.startPathMonitor()
            self.startTimer()
            self.recoverAtLaunch()
        }

        let nc = NSWorkspace.shared.notificationCenter
        nc.addObserver(
            forName: NSWorkspace.willSleepNotification,
            object: nil,
            queue: nil
        ) { [weak self] _ in
            self?.handleWillSleep()
        }
        nc.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: nil
        ) { [weak self] _ in
            self?.handleWake()
        }
    }

    func requestReconnect(reason: String) {
        queue.async {
            guard ProxySelection.desiredOn else { return }
            let choice = ProxySelection.current
            guard KeychainStore.hasCredentials(for: choice) else {
                IITDProxySession.shared.publishExternal(
                    status: "Need Kerberos for \(choice.shortLabel) — save it",
                    healthOK: false
                )
                return
            }
            self.connectIfCampusReachable(choice, reason: reason)
        }
    }

    // MARK: - Sleep / wake

    private func handleWillSleep() {
        queue.async {
            self.cancelWakeWorks()
            self.pathRestoreWork?.cancel()
            // Keep desiredOn. Clear Squid so overnight sleep cannot brick the Mac.
            IITDProxySession.shared.markStaleForSleep()
        }
    }

    func handleWake() {
        queue.async {
            self.cancelWakeWorks()
            DNSManager.invalidateProxyCache()
            PrivilegedHelper.invalidatePasswordlessCache()
            IITDProxySession.shared.resetCircuitBreaker()

            guard ProxySelection.desiredOn else { return }

            IITDProxySession.shared.publishExternal(
                status: "Waking — waiting for campus network…",
                healthOK: false
            )

            for delay in Self.wakeDelays {
                let label = "wake-\(Int(delay))"
                let work = DispatchWorkItem { [weak self] in
                    self?.wakeAttempt(reason: label)
                }
                self.wakeWorks.append(work)
                self.queue.asyncAfter(deadline: .now() + delay, execute: work)
            }
        }
    }

    private func wakeAttempt(reason: String) {
        guard ProxySelection.desiredOn else { return }
        // Wait until path looks up; staggered schedule will try again.
        guard pathOK else {
            IITDProxySession.shared.publishExternal(
                status: "Waking — waiting for campus network…",
                healthOK: false
            )
            return
        }

        let session = IITDProxySession.shared
        if session.isLoggedIn {
            cancelWakeWorks()
            return
        }
        if session.isBusy && session.currentPhase == .loggingIn {
            return
        }
        if session.currentPhase == .failedAuth { return }

        let choice = ProxySelection.current
        guard KeychainStore.hasCredentials(for: choice) else { return }

        // Settle briefly after path.satisfied before CGI probe.
        let settle = DispatchWorkItem { [weak self] in
            guard let self, self.pathOK, ProxySelection.desiredOn else { return }
            if IITDProxySession.shared.isLoggedIn {
                self.cancelWakeWorks()
                return
            }
            self.connectIfCampusReachable(choice, reason: reason, softMiss: true)
        }
        queue.asyncAfter(deadline: .now() + 2, execute: settle)
    }

    private func cancelWakeWorks() {
        wakeWorks.forEach { $0.cancel() }
        wakeWorks.removeAll()
    }

    // MARK: - Launch

    private func recoverAtLaunch() {
        ProcessRunner.ioQueue.async {
            let leftover = DNSManager.detectActiveProxy()
            self.queue.async {
                if let leftover {
                    if ProxySelection.desiredOn, KeychainStore.hasCredentials(for: leftover) {
                        ProxySelection.set(leftover)
                        self.connectIfCampusReachable(leftover, reason: "launch-leftover", softMiss: true)
                        return
                    }
                    ProcessRunner.ioQueue.async {
                        _ = DNSManager.turnProxyOff(allowAdminPrompt: false)
                    }
                    IITDProxySession.shared.publishExternal(
                        status: "Cleared leftover proxy from last session",
                        healthOK: false
                    )
                }
                if ProxySelection.desiredOn, KeychainStore.hasCredentials(for: ProxySelection.current) {
                    self.connectIfCampusReachable(ProxySelection.current, reason: "launch-desired", softMiss: true)
                }
            }
        }
    }

    // MARK: - Path + timer

    private func startPathMonitor() {
        let monitor = NWPathMonitor()
        pathMonitor = monitor
        monitor.pathUpdateHandler = { [weak self] path in
            guard let self else { return }
            self.queue.async {
                let ok = path.status == .satisfied
                let was = self.pathOK
                self.pathOK = ok
                if !ok && was {
                    self.pathRestoreWork?.cancel()
                    IITDProxySession.shared.handlePathDown()
                }
                if ok && !was {
                    IITDProxySession.shared.resetCircuitBreaker()
                    DNSManager.invalidateProxyCache()
                    self.pathRestoreWork?.cancel()
                    let work = DispatchWorkItem { [weak self] in
                        self?.tick(reason: "path-restored")
                    }
                    self.pathRestoreWork = work
                    // 2s settle after unsatisfied→satisfied, then tick.
                    self.queue.asyncAfter(deadline: .now() + 2, execute: work)
                }
            }
        }
        monitor.start(queue: queue)
    }

    private func startTimer() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 15, repeating: 15)
        timer.setEventHandler { [weak self] in self?.tick(reason: "watchdog") }
        timer.resume()
        self.timer = timer
    }

    private func tick(reason: String) {
        // Always reconcile leftover IITD proxy vs session state (even when desiredOff).
        IITDProxySession.shared.reconcileSystemProxy()

        guard pathOK else { return }
        guard ProxySelection.desiredOn else { return }

        let session = IITDProxySession.shared
        if session.isBusy { return }
        if session.currentPhase == .failedAuth { return }

        let isWake = reason.hasPrefix("wake")
        // Normal watchdog: skip connect if already healthy (health probe owns mid-session checks).
        if !isWake, session.isLoggedIn { return }

        let choice = ProxySelection.current
        guard KeychainStore.hasCredentials(for: choice) else { return }

        if isWake {
            connectIfCampusReachable(choice, reason: reason, softMiss: true)
        } else {
            connectIfCampusReachable(choice, reason: reason, softMiss: reason == "path-restored")
        }
    }

    private func connectIfCampusReachable(
        _ choice: ProxyChoice,
        reason: String,
        softMiss: Bool = false
    ) {
        ProcessRunner.ioQueue.async {
            let reachable = IITDProxySession.isCampusReachable(for: choice)
            let leftover = DNSManager.detectActiveProxy() != nil
            self.queue.async {
                guard ProxySelection.desiredOn else { return }
                if !reachable {
                    if softMiss {
                        IITDProxySession.shared.noteCampusMiss(
                            reason: reason,
                            leftoverProxyPresent: leftover
                        )
                    } else {
                        ProcessRunner.ioQueue.async {
                            if DNSManager.detectActiveProxy() != nil {
                                _ = DNSManager.turnProxyOff(allowAdminPrompt: false)
                            }
                        }
                        IITDProxySession.shared.publishExternal(
                            status: "Off campus — proxy left off. Will retry when IIT proxy is reachable.",
                            healthOK: false
                        )
                    }
                    return
                }
                IITDProxySession.shared.resetCircuitBreaker()
                if reason.hasPrefix("wake") {
                    IITDProxySession.shared.recoverAfterWake(reason: reason)
                    // Success path will cancel remaining wake works via isLoggedIn checks.
                } else {
                    IITDProxySession.shared.requestConnect(choice, reason: reason)
                }
            }
        }
    }
}
