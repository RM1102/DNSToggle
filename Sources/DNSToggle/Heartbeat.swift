import Foundation

/// Lease file so a hung app (process still listed) can still be unbricked.
enum Heartbeat {
    static let relativePath = "DNSToggle/heartbeat"

    static var fileURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = base.appendingPathComponent("DNSToggle", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("heartbeat")
    }

    /// Must never run on the curl/io queue — keepalive hangs must not stop the lease.
    private static let pulseQueue = DispatchQueue(label: "com.rahulmasand.dnstoggle.heartbeat")
    private static var timer: DispatchSourceTimer?

    static func start() {
        pulseQueue.async {
            guard timer == nil else { return }
            touch()
            let t = DispatchSource.makeTimerSource(queue: pulseQueue)
            t.schedule(deadline: .now(), repeating: 10)
            t.setEventHandler { touch() }
            t.resume()
            timer = t
        }
    }

    static func stop() {
        pulseQueue.async {
            timer?.cancel()
            timer = nil
            try? FileManager.default.removeItem(at: fileURL)
        }
    }

    static func touch() {
        let stamp = "\(Int(Date().timeIntervalSince1970))\n"
        try? Data(stamp.utf8).write(to: fileURL, options: .atomic)
    }
}
