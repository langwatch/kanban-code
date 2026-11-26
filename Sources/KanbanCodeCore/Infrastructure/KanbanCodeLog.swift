import Foundation

/// Centralized logging for Kanban Code — writes to ~/.kanban-code/logs/kanban-code.log.
/// Thread-safe, fire-and-forget. Use from anywhere in KanbanCodeCore or Kanban.
public enum KanbanCodeLog {

    /// Max log file size before rotation (10 MB).
    private static let maxLogSize: UInt64 = 10 * 1024 * 1024
    /// Keep this many bytes after rotation (5 MB tail).
    private static let keepAfterRotation: Int = 5 * 1024 * 1024

    private static let logDir: String = {
        let dir = (NSHomeDirectory() as NSString).appendingPathComponent(".kanban-code/logs")
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        return dir
    }()

    /// Test runs log to their own file, so the app's log only holds what
    /// the app did.
    static let isTestRun: Bool = {
        let env = ProcessInfo.processInfo.environment
        let name = ProcessInfo.processInfo.processName
        return env["XCTestConfigurationFilePath"] != nil || env["XCTestBundlePath"] != nil
            || name == "xctest" || name.hasSuffix("PackageTests") || name.hasSuffix("PackageTests.xctest") || name == "swiftpm-testing-helper"
            || Bundle.main.bundlePath.hasSuffix(".xctest")
    }()

    private static let logPath: String = {
        let path = (logDir as NSString).appendingPathComponent(isTestRun ? "kanban-code-tests.log" : "kanban-code.log")
        rotateIfNeeded(path: path)
        return path
    }()

    private static let queue = DispatchQueue(label: "kanban-code.log", qos: .utility)
    public static let debugEnabled: Bool = {
        let env = ProcessInfo.processInfo.environment
        return env["KANBAN_CODE_DEBUG_LOGS"] == "1" || env["KANBAN_DEBUG"] == "1"
    }()

    /// On startup, if the log file exceeds maxLogSize, keep only the tail.
    private static func rotateIfNeeded(path: String) {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: path),
              let size = attrs[.size] as? UInt64,
              size > maxLogSize else { return }
        guard let data = FileManager.default.contents(atPath: path) else { return }
        let tail = data.suffix(keepAfterRotation)
        // Find the first newline in the tail to avoid a partial line
        if let newlineIndex = tail.firstIndex(of: UInt8(ascii: "\n")) {
            let clean = tail[tail.index(after: newlineIndex)...]
            try? Data(clean).write(to: URL(fileURLWithPath: path))
        } else {
            try? Data(tail).write(to: URL(fileURLWithPath: path))
        }
    }

    /// Log a message with a subsystem tag.
    /// Example: `KanbanCodeLog.info("reconciler", "Matched session \(id) to card \(cardId)")`
    public nonisolated static func info(_ subsystem: String, _ message: String) {
        write("INFO", subsystem, message)
    }

    /// Log a warning.
    public nonisolated static func warn(_ subsystem: String, _ message: String) {
        write("WARN", subsystem, message)
    }

    /// Log an error.
    public nonisolated static func error(_ subsystem: String, _ message: String) {
        write("ERROR", subsystem, message)
    }

    /// Log verbose diagnostics. Disabled by default; set KANBAN_CODE_DEBUG_LOGS=1.
    public nonisolated static func debug(_ subsystem: String, _ message: @autoclosure () -> String) {
        guard debugEnabled else { return }
        write("DEBUG", subsystem, message())
    }

    private nonisolated static func write(_ level: String, _ subsystem: String, _ message: String) {
        let date = Date()

        queue.async {
            let timestamp = ISO8601DateFormatter().string(from: date)
            let line = "[\(timestamp)] [\(level)] [\(subsystem)] \(message)\n"
            // Use the Swift-throwing FileHandle API (seekToEnd / write(contentsOf:)
            // / close), NOT the legacy Obj-C methods (seekToEndOfFile, write(_:),
            // closeFile). The legacy ones raise NSException on any I/O hiccup
            // (stale fd after inode replacement, truncated file, disk full) and
            // Swift can't catch NSException — the process aborts. Seen in the
            // wild on channel actions that happened to log while the file was
            // being touched externally:
            //   ~/Library/Logs/DiagnosticReports/KanbanCode-*.ips
            do {
                let data = Data(line.utf8)
                let url = URL(fileURLWithPath: logPath)
                if !FileManager.default.fileExists(atPath: logPath) {
                    FileManager.default.createFile(atPath: logPath, contents: nil)
                }
                let handle = try FileHandle(forWritingTo: url)
                defer { try? handle.close() }
                try handle.seekToEnd()
                try handle.write(contentsOf: data)
            } catch {
                // Logging is fire-and-forget — dropping a line on a transient
                // I/O failure is vastly preferable to crashing the UI.
            }
        }
    }
}
