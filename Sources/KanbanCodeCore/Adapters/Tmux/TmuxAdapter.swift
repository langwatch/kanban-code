import Foundation

/// Manages tmux sessions via the tmux CLI.
public final class TmuxAdapter: TmuxManagerPort, @unchecked Sendable {
    private let tmuxPath: String

    public init(tmuxPath: String? = nil) {
        self.tmuxPath = tmuxPath ?? ShellCommand.findExecutable("tmux") ?? "tmux"
    }

    public func listSessions() async throws -> [TmuxSession] {
        let result = try await ShellCommand.run(
            tmuxPath,
            arguments: ["list-sessions", "-F", "#{session_name}\t#{session_path}\t#{session_attached}"]
        )

        // tmux returns exit code 1 with "no server running" when there are no sessions
        guard result.succeeded, !result.stdout.isEmpty else { return [] }

        return result.stdout.components(separatedBy: "\n").compactMap { line -> TmuxSession? in
            let parts = line.components(separatedBy: "\t")
            guard parts.count >= 3 else { return nil }
            return TmuxSession(
                name: parts[0],
                path: parts[1],
                attached: parts[2] == "1"
            )
        }
    }

    public func createSession(name: String, path: String, command: String?) async throws {
        // If a session with this name already exists, reuse it.
        // This prevents killing an active extra terminal whose SwiftTerm view
        // has already attached via the retry loop — killing it would clear the
        // terminal contents (the user sees a blank shell).
        let check = try await ShellCommand.run(tmuxPath, arguments: ["has-session", "-t", name])
        if check.succeeded {
            return
        }

        // Create session with a shell (no command argument).
        // Then send the command via send-keys so the shell stays alive
        // if the command exits — the user can see errors and take charge.
        let args = ["new-session", "-d", "-s", name, "-c", path]
        let result = try await ShellCommand.run(tmuxPath, arguments: args)
        if !result.succeeded {
            throw TmuxError.createFailed(name: name, message: result.stderr)
        }

        if let command, !command.isEmpty {
            if command.contains("\n") {
                // Multi-line commands break tmux send-keys (newlines become Enter
                // presses, splitting the command). Write to a temp file and source
                // it — the shell parser handles newlines inside quoted strings correctly.
                let tempFile = "/tmp/kanban-code-launch-\(name).sh"
                try command.write(toFile: tempFile, atomically: true, encoding: .utf8)
                let sendResult = try await ShellCommand.run(
                    tmuxPath,
                    arguments: ["send-keys", "-t", name, ". '\(tempFile)' ; rm -f '\(tempFile)'", "Enter"]
                )
                if !sendResult.succeeded {
                    KanbanCodeLog.error("tmux", "send-keys (source) failed for \(name): \(sendResult.stderr)")
                }
            } else {
                let sendResult = try await ShellCommand.run(
                    tmuxPath,
                    arguments: ["send-keys", "-t", name, command, "Enter"]
                )
                if !sendResult.succeeded {
                    KanbanCodeLog.error("tmux", "send-keys failed for \(name): \(sendResult.stderr)")
                }
            }
        }
    }

    public func killSession(name: String) async throws {
        let result = try await ShellCommand.run(
            tmuxPath,
            arguments: ["kill-session", "-t", name]
        )
        if !result.succeeded {
            throw TmuxError.killFailed(name: name, message: result.stderr)
        }
    }

    /// Send Ctrl+C to interrupt the running process in a tmux session.
    public func sendInterrupt(sessionName: String) async throws {
        let _ = try await ShellCommand.run(
            tmuxPath, arguments: ["send-keys", "-t", sessionName, "C-c"]
        )
    }

    /// Exit tmux copy/scroll mode if active, so send-keys reaches the application.
    public func exitScrollMode(sessionName: String) async throws {
        // Send 'q' to exit copy mode. If not in copy mode, 'q' is harmless
        // (Claude Code ignores it, Gemini CLI ignores it at the prompt).
        // We use cancel-copy-mode which is a no-op if not in copy mode.
        let _ = try? await ShellCommand.run(
            tmuxPath,
            arguments: ["send-keys", "-t", sessionName, "-X", "cancel"]
        )
    }

    public func sendPrompt(to sessionName: String, text: String) async throws {
        try await exitScrollMode(sessionName: sessionName)
        // Use bracketed paste for reliability — send-keys -l can fail with long text
        // because Claude Code shows "[Pasted text #N +M lines]" and needs Enter.
        let tempFile = "/tmp/kanban-code-send-\(ProcessInfo.processInfo.processIdentifier).txt"
        try text.write(toFile: tempFile, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(atPath: tempFile) }

        let _ = try await ShellCommand.run(
            tmuxPath, arguments: ["load-buffer", tempFile]
        )
        let _ = try await ShellCommand.run(
            tmuxPath, arguments: ["paste-buffer", "-p", "-t", sessionName]
        )
        // Press Enter to submit
        let _ = try await ShellCommand.run(
            tmuxPath, arguments: ["send-keys", "-t", sessionName, "Enter"]
        )
        // Verify the prompt was accepted — if text is still on the prompt line,
        // send Enter again (Claude sometimes needs a moment to process the paste)
        try await ensurePromptSent(sessionName: sessionName)
    }

    /// Poll pane output to verify the prompt was sent. If text remains on the
    /// prompt line after Enter, send Enter again (up to 3 retries).
    /// Checks for: [Pasted text...] indicator, or text after the ❯ prompt character.
    private func ensurePromptSent(sessionName: String) async throws {
        for _ in 0..<5 {
            try await Task.sleep(for: .milliseconds(500))
            let output = try await capturePane(sessionName: sessionName)

            // Check if the prompt line still has unsent text
            let hasUnsentText: Bool
            if output.contains("[Pasted text") || output.contains("[Pasted Text") {
                hasUnsentText = true
            } else if let promptRange = output.range(of: "\u{276F}") {
                // Check if there's non-whitespace text after the ❯ prompt on the same line
                let afterPrompt = output[promptRange.upperBound...]
                let sameLine = afterPrompt.prefix(while: { $0 != "\n" })
                hasUnsentText = !sameLine.trimmingCharacters(in: .whitespaces).isEmpty
            } else {
                hasUnsentText = false
            }

            if hasUnsentText {
                let _ = try await ShellCommand.run(
                    tmuxPath, arguments: ["send-keys", "-t", sessionName, "Enter"]
                )
            } else {
                return
            }
        }
    }

    public func pastePrompt(to sessionName: String, text: String) async throws {
        try await exitScrollMode(sessionName: sessionName)
        // Use load-buffer + paste-buffer -p to bypass readline special char handling.
        // The -p flag wraps the paste in bracketed paste codes (\e[200~ … \e[201~),
        // telling the application (Gemini CLI) to treat the text literally and not
        // interpret special characters like ? (help) or ! (shell escape).
        let tempFile = "/tmp/kanban-code-paste-\(ProcessInfo.processInfo.processIdentifier).txt"
        try text.write(toFile: tempFile, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(atPath: tempFile) }

        let _ = try await ShellCommand.run(
            tmuxPath, arguments: ["load-buffer", tempFile]
        )
        let _ = try await ShellCommand.run(
            tmuxPath, arguments: ["paste-buffer", "-p", "-t", sessionName]
        )
        // Press Enter to submit
        let _ = try await ShellCommand.run(
            tmuxPath, arguments: ["send-keys", "-t", sessionName, "Enter"]
        )
        try await ensurePromptSent(sessionName: sessionName)
    }

    public func capturePane(sessionName: String) async throws -> String {
        let result = try await ShellCommand.run(
            tmuxPath,
            arguments: ["capture-pane", "-p", "-t", sessionName]
        )
        return result.stdout
    }

    public func sendBracketedPaste(to sessionName: String) async throws {
        // Send empty bracketed paste: \e[200~ \e[201~
        // Claude Code detects the paste event and checks the system clipboard for images.
        let _ = try await ShellCommand.run(
            tmuxPath,
            arguments: ["send-keys", "-t", sessionName, "\u{1b}[200~\u{1b}[201~"]
        )
    }

    public func findSessionForWorktree(
        sessions: [TmuxSession],
        worktreePath: String,
        branch: String?
    ) -> TmuxSession? {
        // Priority 1: Exact path match
        if let match = sessions.first(where: { $0.path == worktreePath }) {
            return match
        }

        // Priority 2: Session name matches directory name
        let dirName = (worktreePath as NSString).lastPathComponent
        if let match = sessions.first(where: { $0.name == dirName }) {
            return match
        }

        // Priority 3: Branch name match
        if let branch {
            if let match = sessions.first(where: { $0.name == branch }) {
                return match
            }

            // Priority 4: Branch with slashes replaced by dashes
            let dashBranch = branch.replacingOccurrences(of: "/", with: "-")
            if dashBranch != branch {
                if let match = sessions.first(where: { $0.name == dashBranch }) {
                    return match
                }
            }
        }

        return nil
    }

    public func isAvailable() async -> Bool {
        ShellCommand.findExecutable("tmux") != nil
    }
}

public enum TmuxError: Error, LocalizedError {
    case createFailed(name: String, message: String)
    case killFailed(name: String, message: String)

    public var errorDescription: String? {
        switch self {
        case .createFailed(let name, let message): "Failed to create tmux session '\(name)': \(message)"
        case .killFailed(let name, let message): "Failed to kill tmux session '\(name)': \(message)"
        }
    }
}
