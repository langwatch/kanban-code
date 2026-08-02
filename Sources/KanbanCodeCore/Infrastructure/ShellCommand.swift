import Foundation

/// Runs shell commands and returns their output.
public enum ShellCommand {

    public struct Result: Sendable {
        public let exitCode: Int32
        public let stdout: String
        public let stderr: String

        public var succeeded: Bool { exitCode == 0 }
    }

    /// Cached user login-shell environment, resolved once on first use.
    /// .app bundles get a minimal environment (TMPDIR=/var/folders/..., PATH=/usr/bin:/bin)
    /// which causes tmux socket mismatches, missing binaries, etc. We resolve the real
    /// environment from the user's login shell and inject it into every subprocess.
    private static let userEnvironment: [String: String] = {
        // Run the user's login shell to dump its environment
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: shell)
        proc.arguments = ["-l", "-c", "env"]
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = Pipe()
        do {
            try proc.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            proc.waitUntilExit()
            guard proc.terminationStatus == 0,
                  let output = String(data: data, encoding: .utf8) else {
                return ProcessInfo.processInfo.environment
            }
            var env: [String: String] = [:]
            for line in output.components(separatedBy: "\n") {
                guard let eq = line.firstIndex(of: "=") else { continue }
                let key = String(line[..<eq])
                let value = String(line[line.index(after: eq)...])
                env[key] = value
            }
            return env.isEmpty ? ProcessInfo.processInfo.environment : env
        } catch {
            return ProcessInfo.processInfo.environment
        }
    }()

    /// Background queue for blocking process I/O — never touches the main thread.
    private static let processQueue = DispatchQueue(label: "kanban.shell", qos: .userInitiated, attributes: .concurrent)

    /// Separate from `processQueue` so pipe readers can never be starved by the
    /// waiters they are supposed to release.
    private static let drainQueue = DispatchQueue(label: "kanban.shell.drain", qos: .userInitiated, attributes: .concurrent)

    /// Collects a pipe's bytes from a reader thread for the waiter to pick up.
    private final class OutputBuffer: @unchecked Sendable {
        private let lock = NSLock()
        private var data = Data()

        func store(_ bytes: Data) {
            lock.lock()
            data = bytes
            lock.unlock()
        }

        var value: Data {
            lock.lock()
            defer { lock.unlock() }
            return data
        }
    }

    /// Run a command and capture its output. All blocking I/O runs on a background
    /// dispatch queue so the Swift cooperative thread pool (and main thread) stays free.
    public static func run(
        _ executable: String,
        arguments: [String] = [],
        currentDirectory: String? = nil,
        stdin: String? = nil,
        timeout: TimeInterval = 300
    ) async throws -> Result {
        let env = userEnvironment
        return try await withCheckedThrowingContinuation { continuation in
            processQueue.async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: executable)
                process.arguments = arguments
                process.environment = env

                if let dir = currentDirectory {
                    process.currentDirectoryURL = URL(fileURLWithPath: dir)
                }

                let stdoutPipe = Pipe()
                let stderrPipe = Pipe()
                process.standardOutput = stdoutPipe
                process.standardError = stderrPipe

                if let stdin, let data = stdin.data(using: .utf8) {
                    let stdinPipe = Pipe()
                    process.standardInput = stdinPipe
                    stdinPipe.fileHandleForWriting.write(data)
                    stdinPipe.fileHandleForWriting.closeFile()
                }

                do {
                    try process.run()
                } catch {
                    continuation.resume(throwing: error)
                    return
                }

                // Drain both pipes before waiting, and drain them concurrently:
                // reading stdout to EOF first deadlocks whenever the child fills
                // the ~64KB stderr buffer, because it then blocks writing and
                // never closes stdout.
                let stdoutBuffer = OutputBuffer()
                let stderrBuffer = OutputBuffer()
                let drained = DispatchGroup()
                for (pipe, buffer) in [(stdoutPipe, stdoutBuffer), (stderrPipe, stderrBuffer)] {
                    drained.enter()
                    drainQueue.async {
                        buffer.store(pipe.fileHandleForReading.readDataToEndOfFile())
                        drained.leave()
                    }
                }

                // A child that never exits would otherwise strand this call, and
                // with it whatever the app was doing: a launch whose prompt never
                // gets submitted, a pane that never refreshes.
                if drained.wait(timeout: .now() + timeout) == .timedOut {
                    process.terminate()
                    _ = drained.wait(timeout: .now() + 5)
                    continuation.resume(throwing: ShellCommandError.timedOut(
                        command: ([executable] + arguments).joined(separator: " "),
                        seconds: timeout
                    ))
                    return
                }

                process.waitUntilExit()

                let result = Result(
                    exitCode: process.terminationStatus,
                    stdout: String(data: stdoutBuffer.value, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "",
                    stderr: String(data: stderrBuffer.value, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                )
                continuation.resume(returning: result)
            }
        }
    }

    /// Check if a command is available on the system.
    public static func isAvailable(_ command: String) async -> Bool {
        findExecutable(command) != nil
    }

    /// Resolve a command name to an absolute path by checking common locations
    /// plus the user's login-shell PATH (which includes nvm, volta, fnm, etc.).
    /// macOS .app bundles have a minimal PATH (/usr/bin:/bin:/usr/sbin:/sbin),
    /// so Homebrew and other tools aren't found via `env` or `which`.
    /// Returns nil if the command isn't found anywhere.
    public static func findExecutable(_ command: String) -> String? {
        let home = NSHomeDirectory()
        var searchPaths = [
            "\(home)/.claude/local",   // Claude Code managed install
            "\(home)/.local/bin",      // XDG local bin / claude installer
            "/opt/homebrew/bin",       // Homebrew (Apple Silicon)
            "/usr/local/bin",          // Homebrew (Intel) / npm global
            "/usr/bin",                // System binaries
            "/bin",                    // Core system binaries
        ]

        // Also search the user's real PATH (resolved from login shell).
        // This picks up nvm, volta, fnm, and other version-managed installs.
        if let userPath = userEnvironment["PATH"] {
            for dir in userPath.components(separatedBy: ":") where !dir.isEmpty {
                if !searchPaths.contains(dir) {
                    searchPaths.append(dir)
                }
            }
        }

        for dir in searchPaths {
            let path = "\(dir)/\(command)"
            if FileManager.default.isExecutableFile(atPath: path) {
                return path
            }
        }
        return nil
    }
}

public enum ShellCommandError: Error, LocalizedError {
    case timedOut(command: String, seconds: TimeInterval)

    public var errorDescription: String? {
        switch self {
        case .timedOut(let command, let seconds):
            "`\(command)` did not finish within \(Int(seconds))s and was terminated"
        }
    }
}
