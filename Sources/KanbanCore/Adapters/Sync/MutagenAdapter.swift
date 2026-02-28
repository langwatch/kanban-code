import Foundation

/// Manages Mutagen sync sessions via the mutagen CLI.
public final class MutagenAdapter: SyncManagerPort, @unchecked Sendable {
    private let label: String

    public init(label: String = "kanban") {
        self.label = label
    }

    public func startSync(localPath: String, remotePath: String, name: String) async throws {
        let result = try await ShellCommand.run(
            "/usr/bin/env",
            arguments: [
                "mutagen", "sync", "create",
                localPath, remotePath,
                "--name", name,
                "--label", "\(label)=true",
                "--sync-mode", "two-way-resolved",
                "--default-file-mode-beta", "0644",
                "--default-directory-mode-beta", "0755",
                "--ignore-vcs",
            ]
        )
        if !result.succeeded {
            throw MutagenError.createFailed(name: name, message: result.stderr)
        }
    }

    public func stopSync(name: String) async throws {
        let result = try await ShellCommand.run(
            "/usr/bin/env",
            arguments: ["mutagen", "sync", "terminate", "--name", name]
        )
        if !result.succeeded {
            throw MutagenError.terminateFailed(name: name, message: result.stderr)
        }
    }

    public func flushSync() async throws {
        let result = try await ShellCommand.run(
            "/usr/bin/env",
            arguments: ["mutagen", "sync", "flush", "--label-selector", "\(label)=true"]
        )
        if !result.succeeded {
            throw MutagenError.flushFailed(message: result.stderr)
        }
    }

    public func status() async throws -> [String: SyncStatus] {
        let result = try await ShellCommand.run(
            "/usr/bin/env",
            arguments: [
                "mutagen", "sync", "list",
                "--label-selector", "\(label)=true",
                "--output", "json",
            ]
        )

        guard result.succeeded, !result.stdout.isEmpty else { return [:] }
        guard let data = result.stdout.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let sessions = root["sessions"] as? [[String: Any]] else {
            return [:]
        }

        var statuses: [String: SyncStatus] = [:]
        for session in sessions {
            guard let name = session["name"] as? String,
                  let statusStr = session["status"] as? String else { continue }

            let status: SyncStatus
            switch statusStr.lowercased() {
            case "watching": status = .watching
            case "staging", "transitioning": status = .staging
            case "paused", "halted": status = .paused
            default: status = .error
            }
            statuses[name] = status
        }

        return statuses
    }

    public func isAvailable() async -> Bool {
        await ShellCommand.isAvailable("mutagen")
    }
}

public enum MutagenError: Error, LocalizedError {
    case createFailed(name: String, message: String)
    case terminateFailed(name: String, message: String)
    case flushFailed(message: String)

    public var errorDescription: String? {
        switch self {
        case .createFailed(let name, let msg): "Failed to create sync '\(name)': \(msg)"
        case .terminateFailed(let name, let msg): "Failed to terminate sync '\(name)': \(msg)"
        case .flushFailed(let msg): "Failed to flush sync: \(msg)"
        }
    }
}
