import Foundation

/// Launches a coding assistant session inside a tmux session.
/// Does NOT manage Link records — the caller owns link lifecycle.
public final class LaunchSession: SessionLauncher, @unchecked Sendable {
    private let tmux: TmuxManagerPort

    public init(tmux: TmuxManagerPort) {
        self.tmux = tmux
    }

    public func launch(
        sessionName: String,
        projectPath: String,
        prompt: String,
        worktreeName: String?,
        shellOverride: String?,
        extraEnv: [String: String] = [:],
        commandOverride: String? = nil,
        skipPermissions: Bool = false,
        preamble: String? = nil,
        assistant: CodingAssistant = .claude
    ) async throws -> String {

        let cmd: String
        if let commandOverride, !commandOverride.isEmpty {
            // User provided a custom command — use it as-is
            cmd = commandOverride
        } else {
            // Build the CLI command (prompt is sent via send-keys after assistant is ready)
            var built = assistant.cliCommand
            if skipPermissions { built += " \(assistant.autoApproveFlag)" }
            if assistant.supportsWorktree, let worktreeName {
                if worktreeName.isEmpty {
                    built += " --worktree"
                } else {
                    built += " --worktree \(worktreeName)"
                }
            }

            // Prepend environment variables (SHELL override + KANBAN_CODE_* vars)
            let envPrefix = buildEnvPrefix(shellOverride: shellOverride, extraEnv: extraEnv)
            if !envPrefix.isEmpty {
                built = envPrefix + " " + built
            }
            cmd = built
        }

        // Prepend cd to ensure we're in the right directory even if zshrc changes it
        var fullCmd = "cd \(shellEscape(projectPath))"
        if let preamble, !preamble.isEmpty {
            fullCmd += " && \(preamble)"
        }
        fullCmd += " && \(cmd)"

        // Kill any stale session with the same name before launching.
        // This handles disconnected cards where the old tmux session lingers.
        try? await tmux.killSession(name: sessionName)

        try await tmux.createSession(name: sessionName, path: projectPath, command: fullCmd)
        return sessionName
    }

    public func resume(
        sessionId: String,
        projectPath: String,
        shellOverride: String?,
        extraEnv: [String: String] = [:],
        commandOverride: String? = nil,
        skipPermissions: Bool = false,
        preamble: String? = nil,
        assistant: CodingAssistant = .claude
    ) async throws -> String {
        // Kill stale tmux session if one exists — we always want a fresh resume
        let existing = try await tmux.listSessions()
        if let match = existing.first(where: { $0.name.contains(String(sessionId.prefix(8))) }) {
            try? await tmux.killSession(name: match.name)
        }

        // Create new tmux session with resume command
        let sessionName = "\(assistant.cliCommand)-\(String(sessionId.prefix(8)))"
        let cmd: String
        if let commandOverride, !commandOverride.isEmpty {
            cmd = commandOverride
        } else {
            var built = assistant.cliCommand
            if skipPermissions { built += " \(assistant.autoApproveFlag)" }
            if let resumeFlag = assistant.resumeFlag {
                built += " \(resumeFlag) \(sessionId)"
            }
            let envPrefix = buildEnvPrefix(shellOverride: shellOverride, extraEnv: extraEnv)
            if !envPrefix.isEmpty {
                built = envPrefix + " " + built
            }
            cmd = built
        }

        // Prepend cd to ensure we're in the right directory even if zshrc changes it
        var fullCmd = "cd \(shellEscape(projectPath))"
        if let preamble, !preamble.isEmpty {
            fullCmd += " && \(preamble)"
        }
        fullCmd += " && \(cmd)"

        try await tmux.createSession(name: sessionName, path: projectPath, command: fullCmd)
        return sessionName
    }

    // MARK: - Private

    /// Build a string of VAR=value assignments to prepend to the command.
    private func buildEnvPrefix(shellOverride: String?, extraEnv: [String: String]) -> String {
        var parts: [String] = []

        if let shellOverride {
            parts.append("SHELL=\(shellOverride)")
        }

        // Sort for deterministic output
        for key in extraEnv.keys.sorted() {
            if let value = extraEnv[key] {
                if value.contains("$") {
                    // Use double quotes so shell variables like $PATH get expanded
                    let escaped = value.replacingOccurrences(of: "\"", with: "\\\"")
                    parts.append("\(key)=\"\(escaped)\"")
                } else {
                    parts.append("\(key)=\(shellEscape(value))")
                }
            }
        }

        return parts.joined(separator: " ")
    }

    public static func tmuxSessionName(project: String, worktree: String?) -> String {
        let projectName = (project as NSString).lastPathComponent
        if let worktree {
            return "\(projectName)-\(worktree)"
        }
        return projectName
    }

    private func shellEscape(_ str: String) -> String {
        "'" + str.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
