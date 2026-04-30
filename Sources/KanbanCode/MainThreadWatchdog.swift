import Foundation
import QuartzCore
import os

/// Detects main thread hangs by pinging from a background thread.
/// Logs any hang > threshold to ~/.kanban-code/logs/main-thread-hangs.log
/// Dormant by default. start() only enables sampling when
/// KANBAN_WATCHDOG=1 is set.
final class MainThreadWatchdog: @unchecked Sendable {
    static let shared = MainThreadWatchdog()

    private let checkInterval: TimeInterval = 0.5
    private let hangThreshold: TimeInterval = 0.5
    private let minLogInterval: TimeInterval = 10
    private let _isRunning = os.OSAllocatedUnfairLock(initialState: false)
    private let lastLogTime = os.OSAllocatedUnfairLock(initialState: Date.distantPast)
    private let logPath: String
    private let formatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        return f
    }()

    private init() {
        let logsDir = (NSHomeDirectory() as NSString).appendingPathComponent(".kanban-code/logs")
        try? FileManager.default.createDirectory(atPath: logsDir, withIntermediateDirectories: true)
        logPath = (logsDir as NSString).appendingPathComponent("main-thread-hangs.log")
        // Clear previous log on init
        try? "".write(toFile: logPath, atomically: true, encoding: .utf8)
    }

    func start() {
        // This watchdog is diagnostic-only. Running it during normal use can
        // amplify a UI hang by writing a log line every sampling interval.
        guard ProcessInfo.processInfo.environment["KANBAN_WATCHDOG"] == "1" else { return }

        let alreadyRunning = _isRunning.withLock { val -> Bool in
            if val { return true }
            val = true
            return false
        }
        guard !alreadyRunning else { return }

        DispatchQueue.global(qos: .userInteractive).async { [weak self] in
            guard let self else { return }

            while self._isRunning.withLock({ $0 }) {
                let semaphore = DispatchSemaphore(value: 0)
                let pingTime = CACurrentMediaTime()

                DispatchQueue.main.async {
                    semaphore.signal()
                }

                let result = semaphore.wait(timeout: .now() + 0.5)
                let elapsed = CACurrentMediaTime() - pingTime

                if result == .timedOut {
                    self.logThrottled(String(format: "HANG: main thread blocked for >500ms at %.3f", pingTime))
                } else if elapsed > self.hangThreshold {
                    self.logThrottled(String(format: "HITCH: main thread blocked for %.1fms at %.3f", elapsed * 1000, pingTime))
                }

                Thread.sleep(forTimeInterval: self.checkInterval)
            }
        }
    }

    func stop() {
        _isRunning.withLock { $0 = false }
    }

    private func log(_ message: String) {
        let timestamp = formatter.string(from: Date())
        let line = "[\(timestamp)] \(message)\n"
        if let data = line.data(using: .utf8) {
            do {
                let url = URL(fileURLWithPath: logPath)
                if !FileManager.default.fileExists(atPath: logPath) {
                    FileManager.default.createFile(atPath: logPath, contents: nil)
                }
                let handle = try FileHandle(forWritingTo: url)
                defer { try? handle.close() }
                try handle.seekToEnd()
                try handle.write(contentsOf: data)
            } catch {
                // Diagnostic logging must never make an existing hang worse.
            }
        }
    }

    private func logThrottled(_ message: String) {
        let shouldLog = lastLogTime.withLock { last -> Bool in
            let now = Date()
            guard now.timeIntervalSince(last) >= minLogInterval else { return false }
            last = now
            return true
        }
        if shouldLog { log(message) }
    }
}
