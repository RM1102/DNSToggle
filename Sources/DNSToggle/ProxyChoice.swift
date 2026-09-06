import Foundation

enum ProxyChoice: String, CaseIterable, Identifiable {
    case proxy22
    case proxy62

    var id: String { rawValue }

    var host: String {
        switch self {
        case .proxy62: return "proxy62.iitd.ac.in"
        case .proxy22: return "proxy22.iitd.ac.in"
        }
    }

    var shortLabel: String {
        switch self {
        case .proxy22: return "Proxy 22"
        case .proxy62: return "Proxy 62"
        }
    }

    var label: String {
        switch self {
        case .proxy62: return "proxy62 (dual / MTech)"
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

/// User intent + last selected proxy. Watchdog keeps CGI in sync with this.
enum ProxySelection {
    private static let selectedProxyDefaultsKey = "iitdSelectedProxy"
    private static let desiredOnDefaultsKey = "iitdDesiredProxyOn"

    static var current: ProxyChoice {
        if let raw = UserDefaults.standard.string(forKey: selectedProxyDefaultsKey),
           let choice = ProxyChoice(rawValue: raw) {
            return choice
        }
        return .proxy62
    }

    static func set(_ choice: ProxyChoice) {
        UserDefaults.standard.set(choice.rawValue, forKey: selectedProxyDefaultsKey)
    }

    /// True when the user wants institute proxy kept logged in (survives relaunch).
    static var desiredOn: Bool {
        get { UserDefaults.standard.bool(forKey: desiredOnDefaultsKey) }
        set { UserDefaults.standard.set(newValue, forKey: desiredOnDefaultsKey) }
    }

    static func markDesiredOn(_ choice: ProxyChoice) {
        set(choice)
        desiredOn = true
    }

    static func markDesiredOff() {
        desiredOn = false
    }
}
