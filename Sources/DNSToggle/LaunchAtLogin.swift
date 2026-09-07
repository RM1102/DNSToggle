import Foundation
import ServiceManagement

enum LaunchAtLogin {
    /// Never call this on the main thread at app launch — SMAppService can hang.
    static func readEnabled() -> Bool {
        SMAppService.mainApp.status == .enabled
    }

    static func setEnabled(_ enabled: Bool, completion: ((Bool) -> Void)? = nil) {
        DispatchQueue.global(qos: .utility).async {
            do {
                if enabled {
                    try SMAppService.mainApp.register()
                } else {
                    try SMAppService.mainApp.unregister()
                }
                DispatchQueue.main.async { completion?(true) }
            } catch {
                DispatchQueue.main.async { completion?(false) }
            }
        }
    }
}
