import Foundation
import Observation
import AppKit

/// Per-channel share state. Owns the `kanban channel share` child process,
/// parses its stdout protocol (4 metadata lines), and exposes the public
/// URL + countdown for the UI to render. Tears down on `stop()`, on app
/// quit, or when the process exits on its own (duration expiry).
///
/// Stdout protocol (from `cli/src/share-cli.ts:runShare`):
///     url: https://<sub>.trycloudflare.com/?token=tk_<hex>
///     token: tk_<hex>
///     port: <int>
///     expiresAt: <iso>
@MainActor
@Observable
final class ChannelShareController {
    struct ActiveShare: Equatable {
        let channelName: String
        let url: String
        let token: String
        let port: Int
        let expiresAt: Date
        let startedAt: Date
    }

    enum Phase: Equatable {
        case idle
        case starting
        case active(ActiveShare)
        case failed(String)
    }

    /// Public phase by channel name.
    private(set) var phases: [String: Phase] = [:]

    /// Child processes, keyed by channel name.
    private var processes: [String: Process] = [:]

    func phase(for channel: String) -> Phase {
        phases[channel] ?? .idle
    }

    /// Start a share. Resolves once the CLI has emitted all four metadata
    /// lines (URL/token/port/expiresAt). Throws if cloudflared fails to
    /// publish a URL or the process exits before then.
    func start(channel: String, duration: ShareDuration) async throws -> ActiveShare {
        // Stop any existing share for this channel first. Idempotent.
        if case .active = phases[channel] { await stop(channel: channel) }

        phases[channel] = .starting

        guard let resourceURL = Bundle.main.resourceURL else {
            let msg = "app resources not available"
            phases[channel] = .failed(msg)
            throw ShareError.notBundled(msg)
        }
        let cliJS = resourceURL.appendingPathComponent("cli/dist/kanban.js").path
        let webDist = resourceURL.appendingPathComponent("share-web").path

        let proc = Process()
        // Find node — Xcode/Finder-launched apps have a minimal PATH.
        let nodePath = Self.findNode() ?? "/usr/bin/env"
        proc.executableURL = URL(fileURLWithPath: nodePath == "/usr/bin/env" ? "/usr/bin/env" : nodePath)
        if nodePath == "/usr/bin/env" {
            proc.arguments = ["node", cliJS, "channel", "share", channel, "--duration", duration.cliArg, "--web-dist", webDist]
        } else {
            proc.arguments = [cliJS, "channel", "share", channel, "--duration", duration.cliArg, "--web-dist", webDist]
        }
        var env = ProcessInfo.processInfo.environment
        // Swift apps launched from Finder have a minimal PATH; make sure npx /
        // node / npm are reachable so `npx -y cloudflared` works the first
        // time a share is started. We deliberately do NOT ship cloudflared:
        // a bundled copy gets quarantined by macOS Gatekeeper (unsigned origin
        // binary) which blocks its outbound network. npx-downloaded copies
        // under ~/.npm/_npx/ don't carry the quarantine xattr.
        env["PATH"] = (env["PATH"] ?? "") + ":/usr/local/bin:/opt/homebrew/bin:/usr/bin"
        proc.environment = env

        let stdout = Pipe()
        let stderr = Pipe()
        let stdin = Pipe()
        proc.standardOutput = stdout
        proc.standardError = stderr
        proc.standardInput = stdin

        let stdoutHandle = stdout.fileHandleForReading
        let stderrHandle = stderr.fileHandleForReading

        do {
            try proc.run()
        } catch {
            phases[channel] = .failed("failed to launch kanban CLI: \(error)")
            throw error
        }
        processes[channel] = proc

        // Log stderr for diagnostics (also drains the pipe so it doesn't block).
        Self.drainStderr(stderrHandle, tag: "[share:\(channel)]")

        // Parse the four metadata lines.
        do {
            let share = try await Self.readMetadata(from: stdoutHandle, channelName: channel)
            phases[channel] = .active(share)
            // Continue draining stdout after handshake so the pipe doesn't back up.
            Self.drainStdout(stdoutHandle, tag: "[share:\(channel)]")
            // Watch for unexpected process exit.
            watchExit(channel: channel, process: proc)
            return share
        } catch {
            phases[channel] = .failed(error.localizedDescription)
            await stop(channel: channel)
            throw error
        }
    }

    /// Stop a share. Idempotent.
    func stop(channel: String) async {
        guard let proc = processes[channel] else {
            phases[channel] = .idle
            return
        }
        processes.removeValue(forKey: channel)
        // SIGTERM — our CLI handles it and shuts cloudflared down cleanly.
        if proc.isRunning { proc.terminate() }
        // Give it up to 2s, then SIGKILL.
        await withCheckedContinuation { cont in
            let deadline = DispatchTime.now() + .seconds(2)
            DispatchQueue.global().asyncAfter(deadline: deadline) {
                if proc.isRunning {
                    kill(proc.processIdentifier, SIGKILL)
                }
                cont.resume()
            }
        }
        phases[channel] = .idle
    }

    /// Stop every active share — call on app quit.
    func stopAll() async {
        for name in Array(processes.keys) {
            await stop(channel: name)
        }
    }

    /// Remaining time for a channel's share (0 if none or expired).
    func remaining(for channel: String) -> TimeInterval {
        guard case .active(let s) = phases[channel] else { return 0 }
        return max(0, s.expiresAt.timeIntervalSinceNow)
    }

    private func watchExit(channel: String, process: Process) {
        Task.detached { [weak self] in
            // Process exits emit via terminationHandler, but our isolation
            // is @MainActor — polling + a brief sleep keeps this simple.
            await withTaskCancellationHandler {
                while !Task.isCancelled {
                    if !process.isRunning { break }
                    try? await Task.sleep(for: .seconds(1))
                }
                await MainActor.run { [weak self] in
                    guard let self else { return }
                    // If we still thought the share was active, transition back to idle.
                    if case .active = self.phases[channel] {
                        self.phases[channel] = .idle
                        self.processes.removeValue(forKey: channel)
                    }
                }
            } onCancel: { }
        }
    }

    // ── helpers ──────────────────────────────────────────────────────

    /// Read up to 4 metadata lines (url/token/port/expiresAt) from the child's
    /// stdout. Hard deadline of 90s — allows `npx -y cloudflared` to fetch the
    /// cloudflared npm package + binary on first run (~30s on typical
    /// connections) *plus* cloudflared's own ~20s handshake.
    private static func readMetadata(
        from handle: FileHandle,
        channelName: String,
        timeout: TimeInterval = 90
    ) async throws -> ActiveShare {
        let task = Task.detached { () -> ActiveShare in
            var buffer = ""
            var url: String?, token: String?, port: Int?, expiresAt: Date?
            let iso = ISO8601DateFormatter()
            iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

            while url == nil || token == nil || port == nil || expiresAt == nil {
                try Task.checkCancellation()
                let data = handle.availableData
                if data.isEmpty {
                    // EOF before we got everything.
                    throw ShareError.handshakeFailed("kanban CLI exited before publishing a URL")
                }
                buffer += String(data: data, encoding: .utf8) ?? ""
                while let nl = buffer.firstIndex(of: "\n") {
                    let line = String(buffer[..<nl])
                    buffer.removeSubrange(...nl)
                    if let rest = line.stripPrefix("url: ") { url = rest }
                    else if let rest = line.stripPrefix("token: ") { token = rest }
                    else if let rest = line.stripPrefix("port: "), let n = Int(rest) { port = n }
                    else if let rest = line.stripPrefix("expiresAt: "), let d = iso.date(from: rest) { expiresAt = d }
                }
            }
            return ActiveShare(
                channelName: channelName,
                url: url!,
                token: token!,
                port: port!,
                expiresAt: expiresAt!,
                startedAt: Date()
            )
        }

        return try await withThrowingTaskGroup(of: ActiveShare.self) { group in
            group.addTask { try await task.value }
            group.addTask {
                try await Task.sleep(for: .seconds(timeout))
                task.cancel()
                throw ShareError.handshakeFailed("timed out waiting for cloudflared URL")
            }
            guard let result = try await group.next() else {
                throw ShareError.handshakeFailed("no metadata")
            }
            group.cancelAll()
            return result
        }
    }

    private static func drainStderr(_ handle: FileHandle, tag: String) {
        DispatchQueue.global(qos: .utility).async {
            while true {
                let data = handle.availableData
                if data.isEmpty { return }
                if let s = String(data: data, encoding: .utf8) {
                    FileHandle.standardError.write(Data("\(tag) \(s)".utf8))
                }
            }
        }
    }

    private static func drainStdout(_ handle: FileHandle, tag: String) {
        DispatchQueue.global(qos: .utility).async {
            while true {
                let data = handle.availableData
                if data.isEmpty { return }
                _ = String(data: data, encoding: .utf8)
            }
        }
    }

    private static func findNode() -> String? {
        // Search a few common install locations. Swift app launched from
        // Finder has a minimal PATH.
        let candidates = [
            "/usr/local/bin/node",
            "/opt/homebrew/bin/node",
            "/usr/bin/node",
        ]
        for c in candidates where FileManager.default.isExecutableFile(atPath: c) {
            return c
        }
        return nil
    }
}

enum ShareError: LocalizedError {
    case notBundled(String)
    case handshakeFailed(String)

    var errorDescription: String? {
        switch self {
        case .notBundled(let m), .handshakeFailed(let m): return m
        }
    }
}

/// Duration choices exposed in the UI picker. `cliArg` matches the CLI's
/// `parseDuration` grammar (e.g. "15m", "6h").
enum ShareDuration: String, CaseIterable, Identifiable, Equatable {
    case m5, m10, m15, m30, m45, h1, h6

    var id: String { rawValue }
    var label: String {
        switch self {
        case .m5: return "5 min"
        case .m10: return "10 min"
        case .m15: return "15 min"
        case .m30: return "30 min"
        case .m45: return "45 min"
        case .h1: return "1 hour"
        case .h6: return "6 hours"
        }
    }
    var cliArg: String {
        switch self {
        case .m5: return "5m"; case .m10: return "10m"; case .m15: return "15m"
        case .m30: return "30m"; case .m45: return "45m"
        case .h1: return "1h"; case .h6: return "6h"
        }
    }
    static var `default`: ShareDuration { .m15 }
}

private extension String {
    /// If `self` starts with `prefix`, returns the tail; otherwise nil.
    func stripPrefix(_ prefix: String) -> String? {
        guard hasPrefix(prefix) else { return nil }
        return String(dropFirst(prefix.count))
    }
}
