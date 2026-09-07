import Foundation

/// Append-only local log. Never write passwords, userids, or CGI session ids.
enum SessionLog {
    private static let queue = DispatchQueue(label: "com.rahulmasand.dnstoggle.log")
    private static let maxBytes = 256 * 1024

    private static var logURL: URL {
        let dir = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first!
            .appendingPathComponent("Logs", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("DNSToggle.log")
    }

    static func info(_ message: String) {
        write("INFO", message)
    }

    static func warn(_ message: String) {
        write("WARN", message)
    }

    private static func write(_ level: String, _ message: String) {
        queue.async {
            let line = "\(isoNow()) [\(level)] \(sanitize(message))\n"
            let url = logURL
            let data = Data(line.utf8)
            if FileManager.default.fileExists(atPath: url.path) {
                if let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
                   let size = attrs[.size] as? NSNumber,
                   size.intValue > maxBytes {
                    try? FileManager.default.removeItem(at: url)
                }
                if let handle = try? FileHandle(forWritingTo: url) {
                    defer { try? handle.close() }
                    _ = try? handle.seekToEnd()
                    try? handle.write(contentsOf: data)
                }
            } else {
                try? data.write(to: url, options: .atomic)
            }
        }
    }

    private static func sanitize(_ s: String) -> String {
        var out = s
        // Strip common form fields if they ever leak into a status string.
        out = out.replacingOccurrences(
            of: #"pass=[^&\s]+"#,
            with: "pass=***",
            options: .regularExpression
        )
        out = out.replacingOccurrences(
            of: #"sessionid=[^&\s]+"#,
            with: "sessionid=***",
            options: .regularExpression
        )
        return out
    }

    private static func isoNow() -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f.string(from: Date())
    }
}
