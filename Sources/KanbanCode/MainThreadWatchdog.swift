import Foundation
import QuartzCore
import os

/// Detects main thread hangs by pinging from a background thread.
/// Logs any hang > threshold to ~/.kanban-code/logs/main-thread-hangs.log
/// Enabled by default; set KANBAN_WATCHDOG=0 to disable.
final class MainThreadWatchdog: @unchecked Sendable {
    static let shared = MainThreadWatchdog()

    private let checkInterval: TimeInterval = 0.5
    private let hangThreshold: TimeInterval = 0.5
    private let minLogInterval: TimeInterval = 10
    private let minSampleInterval: TimeInterval = 300
    private let maxSampleFiles = 40
    private let maxSampleBytes: UInt64 = 250 * 1024 * 1024
    private let _isRunning = os.OSAllocatedUnfairLock(initialState: false)
    private let isSampling = os.OSAllocatedUnfairLock(initialState: false)
    private let lastLogTime = os.OSAllocatedUnfairLock(initialState: Date.distantPast)
    private let lastSampleTime = os.OSAllocatedUnfairLock(initialState: Date.distantPast)
    private let logPath: String
    private let samplesDir: String
    private let formatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    private init() {
        let logsDir = (NSHomeDirectory() as NSString).appendingPathComponent(".kanban-code/logs")
        try? FileManager.default.createDirectory(atPath: logsDir, withIntermediateDirectories: true)
        logPath = (logsDir as NSString).appendingPathComponent("main-thread-hangs.log")
        samplesDir = (logsDir as NSString).appendingPathComponent("main-thread-samples")
        try? FileManager.default.createDirectory(atPath: samplesDir, withIntermediateDirectories: true)
        pruneSamples()
    }

    func start() {
        guard ProcessInfo.processInfo.environment["KANBAN_WATCHDOG"] != "0" else { return }

        let alreadyRunning = _isRunning.withLock { val -> Bool in
            if val { return true }
            val = true
            return false
        }
        guard !alreadyRunning else { return }
        log("WATCHDOG START pid=\(ProcessInfo.processInfo.processIdentifier)")

        DispatchQueue.global(qos: .utility).async { [weak self] in
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
                    self.captureSampleThrottled(reason: "hang")
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

    private func captureSampleThrottled(reason: String) {
        let startedSampling = isSampling.withLock { sampling -> Bool in
            guard !sampling else { return false }
            sampling = true
            return true
        }
        guard startedSampling else { return }

        let shouldSample = lastSampleTime.withLock { last -> Bool in
            let now = Date()
            guard now.timeIntervalSince(last) >= minSampleInterval else { return false }
            last = now
            return true
        }
        guard shouldSample else {
            isSampling.withLock { $0 = false }
            return
        }

        let pid = String(ProcessInfo.processInfo.processIdentifier)
        let stamp = formatter.string(from: Date())
            .replacingOccurrences(of: ":", with: "-")
            .replacingOccurrences(of: ".", with: "-")
        let samplePath = (samplesDir as NSString).appendingPathComponent(
            "main-thread-\(reason)-\(stamp)-pid\(pid).sample.txt"
        )
        log("SAMPLE START reason=\(reason) path=\(samplePath)")

        DispatchQueue.global(qos: .utility).async { [samplePath] in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/sample")
            process.arguments = [pid, "1", "-file", samplePath]
            process.standardOutput = nil
            process.standardError = nil
            process.terminationHandler = { proc in
                self.log("SAMPLE END status=\(proc.terminationStatus) path=\(samplePath)")
                self.pruneSamples()
                self.isSampling.withLock { $0 = false }
            }
            do {
                try process.run()
            } catch {
                self.log("SAMPLE FAILED error=\(error) path=\(samplePath)")
                self.isSampling.withLock { $0 = false }
            }
        }
    }

    private func pruneSamples() {
        let fm = FileManager.default
        guard let urls = try? fm.contentsOfDirectory(
            at: URL(fileURLWithPath: samplesDir),
            includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else { return }

        let files = urls.compactMap { url -> (url: URL, date: Date, size: UInt64)? in
            guard url.pathExtension == "txt",
                  let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
            else { return nil }
            return (
                url,
                values.contentModificationDate ?? .distantPast,
                UInt64(values.fileSize ?? 0)
            )
        }
        .sorted { $0.date > $1.date }

        var totalBytes: UInt64 = 0
        for (index, file) in files.enumerated() {
            totalBytes += file.size
            if index >= maxSampleFiles || totalBytes > maxSampleBytes {
                try? fm.removeItem(at: file.url)
            }
        }
    }
}
