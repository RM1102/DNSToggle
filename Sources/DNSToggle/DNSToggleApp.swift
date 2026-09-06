import SwiftUI
import AppKit

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
                        Text(model.status.label)
                            .font(.headline)
                            .fixedSize(horizontal: false, vertical: true)
                        if model.proxySessionActive {
                            Text(model.proxyStatusLine)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
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

                ForEach(ProxyChoice.allCases) { choice in
                    Button {
                        model.connectProxy(choice)
                    } label: {
                        HStack {
                            Text(choice.shortLabel)
                            Spacer()
                            if model.activeProxy == choice {
                                Image(systemName: "checkmark")
                            }
                        }
                    }
                    .buttonStyle(.bordered)
                }

                Button("Save Kerberos…") {
                    model.promptKerberos()
                }
                .buttonStyle(.bordered)

                Button("Log out proxy") {
                    model.logoutProxy()
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

                HStack {
                    Button("Refresh Status") { model.refresh(forceNetwork: true) }
                        .buttonStyle(.bordered)
                    Button("Quit DNSToggle") { NSApplication.shared.terminate(nil) }
                        .buttonStyle(.bordered)
                }
            }
            .padding(12)
            .frame(width: 280)
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
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        // Never touch SMAppService / networksetup on the main thread at launch.
        LaunchAtLogin.enableOnFirstLaunchIfNeeded()

        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(onWake),
            name: NSWorkspace.didWakeNotification,
            object: nil
        )

        DispatchQueue.global(qos: .utility).async {
            guard KeychainStore.hasCredentials else { return }
            if let active = DNSManager.detectActiveProxy() {
                ProxySelection.set(active)
                IITDProxySession.shared.start(proxy: active)
            }
        }
    }

    @objc private func onWake() {
        DispatchQueue.global(qos: .utility).async {
            guard let active = DNSManager.detectActiveProxy(), KeychainStore.hasCredentials else { return }
            let session = IITDProxySession.shared
            if session.isActive {
                session.forceReconnect()
            } else {
                session.start(proxy: active)
            }
        }
    }
}

@MainActor
final class AppModel: ObservableObject {
    @Published private(set) var status: NetworkStatus = NetworkStatus(
        preset: .automatic, dnsServers: [], proxyEnabled: false, vpnLikelyActive: false, activeProxy: nil
    )
    @Published private(set) var launchAtLogin = false
    @Published private(set) var busy = false
    @Published private(set) var sessionStatus = "Proxy idle"
    @Published private(set) var sessionHealthOK = false
    @Published private(set) var sessionRefreshAt: Date?
    @Published private(set) var sessionActive = false
    @Published private(set) var sessionProxy: ProxyChoice?

    private var refreshInFlight = false
    private var pollCount = 0

    var activeProxy: ProxyChoice? {
        status.activeProxy ?? sessionProxy
    }

    var proxySessionActive: Bool {
        sessionActive || status.proxyEnabled
    }

    var proxyHealthy: Bool {
        sessionHealthOK && status.proxyEnabled
    }

    var isInProgress: Bool {
        if busy { return true }
        let s = sessionStatus.lowercased()
        return s.contains("reconnect")
            || s.contains("re-log")
            || s.contains("logging")
            || s.contains("expired")
            || s.contains("checking")
            || s.contains("no traffic yet")
    }

    var isConnected: Bool {
        if status.proxyEnabled || sessionActive {
            return proxyHealthy
        }
        if status.vpnLikelyActive { return false }
        return true
    }

    var proxyStatusLine: String {
        var line = sessionStatus
        if let t = sessionRefreshAt {
            let mins = max(0, Int(Date().timeIntervalSince(t) / 60))
            line += " · refreshed \(mins)m ago"
        }
        return line
    }

    init() {
        // Session fields only on a fast timer; network probes stay off the main thread.
        Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        refresh(forceNetwork: true)
        DispatchQueue.global(qos: .utility).async {
            let enabled = LaunchAtLogin.readEnabled()
            DispatchQueue.main.async { [weak self] in
                self?.launchAtLogin = enabled
            }
        }
    }

    private func tick() {
        pullSessionFields()
        pollCount += 1
        // Full network probe every ~10s, not every 2s.
        if pollCount % 5 == 0 {
            refresh(forceNetwork: false)
        }
    }

    /// Copies cheap @Published session state — never blocks.
    private func pullSessionFields() {
        let session = IITDProxySession.shared
        sessionStatus = session.lastStatus
        sessionHealthOK = session.lastHealthOK
        sessionRefreshAt = session.lastRefreshAt
        sessionActive = session.isActive
        sessionProxy = session.activeProxy
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

    /// Network status is always gathered off the main thread.
    func refresh(forceNetwork: Bool = false) {
        pullSessionFields()
        guard !refreshInFlight else { return }
        refreshInFlight = true
        let scanVPN = forceNetwork
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
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

    func connectProxy(_ choice: ProxyChoice) {
        guard !busy else { return }
        if !KeychainStore.hasCredentials {
            promptKerberos()
            guard KeychainStore.hasCredentials else { return }
        }
        busy = true
        ProxySelection.set(choice)
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            IITDProxySession.shared.stop(logoutCGI: false)
            usleep(200_000)
            let ok = DNSManager.setInstituteProxy(choice)
            if ok {
                IITDProxySession.shared.start(proxy: choice)
            }
            DispatchQueue.main.async {
                self?.busy = false
                self?.refresh(forceNetwork: true)
            }
        }
    }

    func logoutProxy() {
        guard !busy else { return }
        busy = true
        // Clear system proxy FIRST so internet recovers immediately.
        // CGI logout is best-effort afterward (can hang if proxy is already dead).
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            _ = DNSManager.turnProxyOff()
            DNSManager.flushDNSOnly()
            DispatchQueue.main.async {
                self?.refresh(forceNetwork: true)
            }
            IITDProxySession.shared.logoutEverywhere {
                DNSManager.reloadOpenBrowsers()
                DispatchQueue.main.async {
                    self?.busy = false
                    self?.refresh(forceNetwork: true)
                }
            }
        }
    }

    func clearVPN() {
        guard !busy else { return }
        busy = true
        IITDProxySession.shared.stop(logoutCGI: true)
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            _ = DNSManager.clearVPNEffects(reloadBrowsers: true)
            DispatchQueue.main.async {
                self?.busy = false
                self?.refresh(forceNetwork: true)
            }
        }
    }

    func promptKerberos() {
        let alert = NSAlert()
        alert.messageText = "IITD Kerberos"
        alert.informativeText = "Saved only in your Mac Keychain. Used for Proxy 22 and Proxy 62."
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")

        let width: CGFloat = 280
        let stack = NSStackView(frame: NSRect(x: 0, y: 0, width: width, height: 54))
        stack.orientation = .vertical
        stack.spacing = 6

        let userField = NSTextField(frame: NSRect(x: 0, y: 0, width: width, height: 24))
        userField.placeholderString = "Kerberos userid"
        userField.stringValue = KeychainStore.savedUsername

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
        _ = KeychainStore.save(user: user, password: pass)
        refresh(forceNetwork: true)
    }
}
