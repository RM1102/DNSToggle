import SwiftUI
import AppKit
import Darwin

@main
struct DNSToggleApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var model = AppModel()

    var body: some Scene {
        MenuBarExtra("DNS", systemImage: "globe") {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .top, spacing: 8) {
                    Circle()
                        .fill(statusColor)
                        .frame(width: 8, height: 8)
                        .padding(.top, 4)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(model.headline)
                            .font(.headline)
                            .fixedSize(horizontal: false, vertical: true)
                        Text(model.proxyStatusLine)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                Text("DNS Presets")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                ForEach(DNSPreset.all) { preset in
                    Button {
                        model.apply(preset)
                    } label: {
                        HStack {
                            Text(preset.name)
                            Spacer()
                            if model.status.preset.id == preset.id {
                                Image(systemName: "checkmark")
                            }
                        }
                    }
                    .buttonStyle(.bordered)
                }

                Text("Institute Proxy")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.top, 2)

                Button {
                    model.turnProxyOff()
                } label: {
                    HStack {
                        Text("Proxy Off")
                        Spacer()
                        if !ProxySelection.desiredOn && !model.sessionActive && !model.status.proxyEnabled {
                            Image(systemName: "checkmark")
                        }
                    }
                }
                .buttonStyle(.bordered)

                ForEach(ProxyChoice.allCases) { choice in
                    Button {
                        model.toggleProxy(choice)
                    } label: {
                        HStack {
                            Text(choice.shortLabel)
                            Spacer()
                            if model.sessionHealthyFor(choice) {
                                Image(systemName: "checkmark")
                            } else if ProxySelection.desiredOn && ProxySelection.current == choice {
                                Image(systemName: "circle")
                                    .foregroundStyle(.orange)
                            } else if model.systemProxyIs(choice) {
                                Image(systemName: "exclamationmark.circle")
                                    .foregroundStyle(.orange)
                            }
                        }
                    }
                    .buttonStyle(.bordered)
                }

                if ProxySelection.desiredOn {
                    Button("Reconnect proxy now") {
                        model.reconnectNow()
                    }
                    .buttonStyle(.bordered)
                }

                if !model.passwordFreeOn {
                    Button("Enable password-free switching…") {
                        model.enablePasswordFree()
                    }
                    .buttonStyle(.bordered)
                    Text("Required before Connect — so the app can always turn Squid off without a password.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Button("Unbrick internet now") {
                    model.unbrickNow()
                }
                .buttonStyle(.bordered)

                Button("Save Kerberos for Proxy 22…") {
                    model.promptKerberos(for: .proxy22)
                }
                .buttonStyle(.bordered)

                Button("Save Kerberos for Proxy 62…") {
                    model.promptKerberos(for: .proxy62)
                }
                .buttonStyle(.bordered)

                Button("Clear VPN & Reset Network") {
                    model.clearVPN()
                }
                .buttonStyle(.bordered)

                Text("Resets DNS, proxies, cache. Reloads browser tabs.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)

                Toggle("Launch at Login", isOn: Binding(
                    get: { model.launchAtLogin },
                    set: { model.setLaunchAtLogin($0) }
                ))
                .toggleStyle(.checkbox)
                .font(.caption)

                if ProxySelection.desiredOn && !model.launchAtLogin {
                    Text("Enable Launch at Login so proxy recovers after restart.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                HStack {
                    Button("Refresh Status") { model.refresh(forceNetwork: true) }
                        .buttonStyle(.bordered)
                    Button("Quit DNSToggle") { NSApplication.shared.terminate(nil) }
                        .buttonStyle(.bordered)
                }
            }
            .padding(12)
            .frame(width: 300)
            .onAppear { model.refresh(forceNetwork: true) }
        }
        .menuBarExtraStyle(.window)
    }

    private var statusColor: Color {
        if model.isInProgress { return .orange }
        if model.isConnected { return .green }
        return .red
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var singleInstanceLock: FileHandle?

    func applicationDidFinishLaunching(_ notification: Notification) {
        if !claimSingleInstance() {
            NSApp.terminate(nil)
            return
        }
        NSApp.setActivationPolicy(.accessory)
        Heartbeat.start()
        ProxyWatchdog.shared.start()
        SessionLog.info("app launched")
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        Heartbeat.stop()
        IITDProxySession.shared.prepareForTermination()
        return .terminateNow
    }

    /// Only one globe — two copies fight over system proxy.
    private func claimSingleInstance() -> Bool {
        let path = NSTemporaryDirectory() + "com.rahulmasand.dnstoggle.lock"
        FileManager.default.createFile(atPath: path, contents: nil)
        guard let handle = FileHandle(forWritingAtPath: path) else { return true }
        let fd = handle.fileDescriptor
        if flock(fd, LOCK_EX | LOCK_NB) != 0 {
            try? handle.close()
            return false
        }
        singleInstanceLock = handle
        return true
    }
}

@MainActor
final class AppModel: ObservableObject {
    @Published private(set) var status: NetworkStatus = NetworkStatus(
        preset: .automatic, dnsServers: [], proxyEnabled: false, vpnLikelyActive: false, activeProxy: nil
    )
    @Published private(set) var launchAtLogin = false
    @Published private(set) var busy = false
    @Published private(set) var sessionStatus = "Proxy Off"
    @Published private(set) var sessionHealthOK = false
    @Published private(set) var sessionRefreshAt: Date?
    @Published private(set) var sessionActive = false
    @Published private(set) var sessionBusy = false
    @Published private(set) var sessionProxy: ProxyChoice?
    @Published private(set) var passwordFreeOn = false
    @Published private(set) var offCampus = false

    private var refreshInFlight = false
    private var pollCount = 0

    func sessionHealthyFor(_ choice: ProxyChoice) -> Bool {
        sessionActive && sessionProxy == choice && sessionHealthOK
    }

    func systemProxyIs(_ choice: ProxyChoice) -> Bool {
        status.activeProxy == choice
    }

    var proxyHealthy: Bool {
        sessionHealthOK && sessionActive
    }

    var isInProgress: Bool {
        if busy || sessionBusy { return true }
        let s = sessionStatus.lowercased()
        return s.contains("logging")
            || s.contains("connecting")
            || s.contains("reconnecting")
            || s.contains("waking")
            || s.contains("clearing")
            || s.contains("turning proxy")
            || s.contains("internet via proxy")
    }

    var isConnected: Bool {
        if sessionActive || status.proxyEnabled || ProxySelection.desiredOn {
            return proxyHealthy
        }
        if status.vpnLikelyActive { return false }
        return true
    }

    var headline: String {
        let s = sessionStatus.lowercased()
        if s.contains("asleep") {
            return "Asleep — proxy cleared"
        }
        if s.contains("internet via proxy failed — stopped") {
            return "Internet via proxy failed — click Reconnect"
        }
        if s.contains("internet via proxy") {
            return "Internet via proxy failed — recovering…"
        }
        if s.contains("session expired") && ProxySelection.desiredOn {
            return "Session expired — reconnecting…"
        }
        if sessionBusy || busy {
            if s.contains("internet via proxy") {
                return "Internet via proxy failed — recovering…"
            }
            if s.contains("session expired") {
                return "Session expired — reconnecting…"
            }
            if s.contains("clear") || s.contains("turning") {
                return "Turning proxy off…"
            }
            if s.contains("waking") || s.contains("reconnecting after sleep") {
                return "Reconnecting after sleep…"
            }
            return "Connecting…"
        }
        if s.contains("waking") {
            return "Waking — waiting for campus…"
        }
        if proxyHealthy, let p = sessionProxy {
            return "Connected (\(p.rawValue))"
        }
        if offCampus && ProxySelection.desiredOn {
            return "Off campus"
        }
        if status.proxyEnabled && !sessionActive {
            return "Proxy stuck on — clear it"
        }
        if ProxySelection.desiredOn {
            return "Proxy remembered on"
        }
        return "Off · \(status.preset.name)"
    }

    var proxyStatusLine: String {
        if status.proxyEnabled && !sessionActive && !sessionBusy {
            let host = status.activeProxy?.host ?? "proxy"
            return "\(host) on without a session — use Proxy Off"
        }
        var line = sessionStatus
        if let t = sessionRefreshAt, sessionHealthOK {
            let mins = max(0, Int(Date().timeIntervalSince(t) / 60))
            line += " · refreshed \(mins)m ago"
        }
        return line
    }

    init() {
        Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        refresh(forceNetwork: true)
        DispatchQueue.global(qos: .utility).async {
            let enabled = LaunchAtLogin.readEnabled()
            let free = PrivilegedHelper.isPasswordless
            DispatchQueue.main.async { [weak self] in
                self?.launchAtLogin = enabled
                self?.passwordFreeOn = free
            }
        }
    }

    private func tick() {
        pullSessionFields()
        pollCount += 1
        if pollCount % 5 == 0 {
            refresh(forceNetwork: false)
        }
        if pollCount % 15 == 0 {
            DispatchQueue.global(qos: .utility).async { [weak self] in
                let free = PrivilegedHelper.isPasswordless
                DispatchQueue.main.async { self?.passwordFreeOn = free }
            }
        }
    }

    private func pullSessionFields() {
        let session = IITDProxySession.shared
        sessionStatus = session.lastStatus
        sessionHealthOK = session.lastHealthOK
        sessionRefreshAt = session.lastRefreshAt
        sessionActive = session.isActive
        sessionBusy = session.isBusy
        sessionProxy = session.activeProxy
        offCampus = session.isOffCampus
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        guard enabled != launchAtLogin else { return }
        launchAtLogin = enabled
        LaunchAtLogin.setEnabled(enabled) { [weak self] ok in
            guard let self, !ok else { return }
            DispatchQueue.global(qos: .utility).async {
                let actual = LaunchAtLogin.readEnabled()
                DispatchQueue.main.async { self.launchAtLogin = actual }
            }
        }
    }

    func refresh(forceNetwork: Bool = false) {
        pullSessionFields()
        guard !refreshInFlight else { return }
        refreshInFlight = true
        let scanVPN = forceNetwork
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let next = DNSManager.currentStatus(includeVPNScan: scanVPN)
            DispatchQueue.main.async {
                guard let self else { return }
                self.status = next
                self.refreshInFlight = false
            }
        }
    }

    func apply(_ preset: DNSPreset) {
        guard !busy else { return }
        busy = true
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            _ = DNSManager.applyPreset(preset)
            DispatchQueue.main.async {
                self?.busy = false
                self?.refresh(forceNetwork: true)
            }
        }
    }

    /// Clicking the active proxy again turns it off.
    func toggleProxy(_ choice: ProxyChoice) {
        if ProxySelection.desiredOn && ProxySelection.current == choice {
            turnProxyOff()
            return
        }
        connectProxy(choice)
    }

    func connectProxy(_ choice: ProxyChoice) {
        guard ensureHelperForConnect() else { return }
        if !KeychainStore.hasCredentials(for: choice) {
            promptKerberos(for: choice)
            guard KeychainStore.hasCredentials(for: choice) else { return }
        }
        ProxySelection.markDesiredOn(choice)
        IITDProxySession.shared.resetCircuitBreaker()
        IITDProxySession.shared.requestConnect(choice, reason: "user-click")
        refresh(forceNetwork: true)
    }

    func turnProxyOff() {
        ProxySelection.markDesiredOff()
        IITDProxySession.shared.requestStop(clearSystemProxy: true, logoutCGI: true, allowAdminPrompt: true)
        refresh(forceNetwork: true)
    }

    func reconnectNow() {
        guard ensureHelperForConnect() else { return }
        let choice = sessionProxy ?? ProxySelection.current
        if !KeychainStore.hasCredentials(for: choice) {
            promptKerberos(for: choice)
            guard KeychainStore.hasCredentials(for: choice) else { return }
        }
        ProxySelection.markDesiredOn(choice)
        IITDProxySession.shared.resetCircuitBreaker()
        IITDProxySession.shared.requestConnect(choice, reason: "user-reconnect")
        refresh(forceNetwork: true)
    }

    func unbrickNow() {
        busy = true
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            ProxySelection.markDesiredOff()
            IITDProxySession.shared.requestStop(clearSystemProxy: true, logoutCGI: false, allowAdminPrompt: true)
            _ = DNSManager.turnProxyOff(allowAdminPrompt: true)
            SessionLog.warn("manual unbrick")
            DispatchQueue.main.async {
                self?.busy = false
                self?.refresh(forceNetwork: true)
            }
        }
    }

    /// Connect requires password-free helper so sleep/health can always clear Squid.
    private func ensureHelperForConnect() -> Bool {
        if PrivilegedHelper.isPasswordless {
            passwordFreeOn = true
            return true
        }
        passwordFreeOn = false
        let alert = NSAlert()
        alert.messageText = "Enable password-free switching first"
        alert.informativeText = "Without the helper, DNSToggle cannot clear a dead proxy in the background. That is how the Mac gets stuck. Click Enable, enter your password once, then Connect."
        alert.addButton(withTitle: "Enable…")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return false }
        let ok = PrivilegedHelper.installPasswordlessHelper()
        passwordFreeOn = ok
        if !ok {
            let fail = NSAlert()
            fail.messageText = "Helper install failed"
            fail.informativeText = "Connect is blocked until password-free switching works."
            fail.addButton(withTitle: "OK")
            fail.runModal()
        }
        return ok
    }

    func enablePasswordFree() {
        guard !busy else { return }
        busy = true
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let ok = PrivilegedHelper.installPasswordlessHelper()
            DispatchQueue.main.async {
                self?.busy = false
                self?.passwordFreeOn = ok
                if ok, ProxySelection.desiredOn {
                    ProxyWatchdog.shared.requestReconnect(reason: "helper-installed")
                }
                self?.refresh(forceNetwork: true)
            }
        }
    }

    func clearVPN() {
        ProxySelection.markDesiredOff()
        IITDProxySession.shared.requestStop(clearSystemProxy: true, logoutCGI: true, allowAdminPrompt: true)
        busy = true
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            _ = DNSManager.clearVPNEffects(reloadBrowsers: true)
            DispatchQueue.main.async {
                self?.busy = false
                self?.refresh(forceNetwork: true)
            }
        }
    }

    func promptKerberos(for proxy: ProxyChoice) {
        let alert = NSAlert()
        alert.messageText = "IITD Kerberos — \(proxy.shortLabel)"
        alert.informativeText = "Saved only in your Mac Keychain for \(proxy.host). Proxy 22 and 62 can have different passwords. Saving does not turn the proxy on."
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")

        let width: CGFloat = 280
        let stack = NSStackView(frame: NSRect(x: 0, y: 0, width: width, height: 54))
        stack.orientation = .vertical
        stack.spacing = 6

        let userField = NSTextField(frame: NSRect(x: 0, y: 0, width: width, height: 24))
        userField.placeholderString = "Kerberos userid for \(proxy.rawValue)"
        userField.stringValue = KeychainStore.savedUsername(for: proxy)

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
        _ = KeychainStore.save(for: proxy, user: user, password: pass)
        // Never force-connect on save — only reconnect if user already wanted proxy on.
        if ProxySelection.desiredOn {
            ProxySelection.set(proxy)
            IITDProxySession.shared.resetCircuitBreaker()
            IITDProxySession.shared.requestConnect(proxy, reason: "creds-saved")
        }
        refresh(forceNetwork: true)
    }
}
