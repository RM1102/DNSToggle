import Foundation

/// Isolated process I/O. Never call from the main thread.
enum ProcessRunner {
    /// Dedicated serial queue so waits never sit on the GCD thread pool.
    static let ioQueue = DispatchQueue(label: "com.rahulmasand.dnstoggle.io", qos: .utility)

    struct Result {
        let stdout: String
        let stderr: String
        let ok: Bool
        var output: String { stdout.isEmpty ? stderr : stdout }
    }

    @discardableResult
    static func run(_ cmd: String, args: [String], timeoutSeconds: Double = 4) -> (output: String, ok: Bool) {
        let r = runDetailed(cmd, args: args, timeoutSeconds: timeoutSeconds)
        return (r.output, r.ok)
    }

    /// Prefer this when parsing `%{http_code}` — stderr must not pollute stdout.
    static func runDetailed(_ cmd: String, args: [String], timeoutSeconds: Double = 4) -> Result {
        if Thread.isMainThread {
            assertionFailure("ProcessRunner.run must not run on the main thread")
            return Result(stdout: "", stderr: "", ok: false)
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: cmd)
        process.arguments = args
        // Own process group so timeout can kill sudo + networksetup children.
        process.qualityOfService = .utility

        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        process.standardInput = FileHandle.nullDevice

        let lock = NSLock()
        var outChunks = Data()
        var errChunks = Data()

        stdout.fileHandleForReading.readabilityHandler = { h in
            let data = h.availableData
            guard !data.isEmpty else { return }
            lock.lock()
            outChunks.append(data)
            lock.unlock()
        }
        stderr.fileHandleForReading.readabilityHandler = { h in
            let data = h.availableData
            guard !data.isEmpty else { return }
            lock.lock()
            errChunks.append(data)
            lock.unlock()
        }

        let done = DispatchSemaphore(value: 0)
        var status: Int32 = -1
        process.terminationHandler = { proc in
            stdout.fileHandleForReading.readabilityHandler = nil
            stderr.fileHandleForReading.readabilityHandler = nil
            let tailOut = stdout.fileHandleForReading.availableData
            let tailErr = stderr.fileHandleForReading.availableData
            lock.lock()
            outChunks.append(tailOut)
            errChunks.append(tailErr)
            lock.unlock()
            status = proc.terminationStatus
            done.signal()
        }

        do {
            try process.run()
            // Put the child in its own group for SIGKILL of descendants.
            if process.processIdentifier > 0 {
                setpgid(process.processIdentifier, process.processIdentifier)
            }
        } catch {
            return Result(stdout: "", stderr: "", ok: false)
        }

        if done.wait(timeout: .now() + timeoutSeconds) == .timedOut {
            let pid = process.processIdentifier
            if pid > 0 {
                kill(-pid, SIGKILL)
            }
            if process.isRunning {
                kill(pid, SIGKILL)
            }
            _ = done.wait(timeout: .now() + 1.0)
            return Result(stdout: "", stderr: "timeout", ok: false)
        }

        lock.lock()
        let outData = outChunks
        let errData = errChunks
        lock.unlock()
        let outText = String(data: outData, encoding: .utf8) ?? ""
        let errText = String(data: errData, encoding: .utf8) ?? ""
        return Result(stdout: outText, stderr: errText, ok: status == 0)
    }
}
