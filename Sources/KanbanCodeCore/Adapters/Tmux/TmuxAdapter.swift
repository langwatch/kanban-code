import Foundation

/// Manages tmux sessions via the tmux CLI.
public final class TmuxAdapter: TmuxManagerPort, @unchecked Sendable {
    private let tmuxPath: String

    public init(tmuxPath: String? = nil) {
        self.tmuxPath = tmuxPath ?? ShellCommand.findExecutable("tmux") ?? "tmux"
    }

    /// tmux commands are sub-second in practice, so a long stall means a wedged
    /// server rather than slow work. Bounding them stops one from stranding a
    /// launch on a prompt that never gets submitted.
    private func runTmux(
        _ arguments: [String],
        timeout: TimeInterval = 20
    ) async throws -> ShellCommand.Result {
        try await ShellCommand.run(tmuxPath, arguments: arguments, timeout: timeout)
    }

    public func listSessions() async throws -> [TmuxSession] {
        let result = try await runTmux(["list-sessions", "-F", "#{session_name}\t#{session_path}\t#{session_attached}"])

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
        let check = try await runTmux(["has-session", "-t", name])
        if check.succeeded {
            return
        }

        // Create session with a shell (no command argument).
        // Then send the command via send-keys so the shell stays alive
        // if the command exits — the user can see errors and take charge.
        let args = ["new-session", "-d", "-s", name, "-c", path]
        let result = try await runTmux(args)
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
                let sendResult = try await runTmux(["send-keys", "-t", name, ". '\(tempFile)' ; rm -f '\(tempFile)'", "Enter"])
                if !sendResult.succeeded {
                    KanbanCodeLog.error("tmux", "send-keys (source) failed for \(name): \(sendResult.stderr)")
                }
            } else {
                let sendResult = try await runTmux(["send-keys", "-t", name, command, "Enter"])
                if !sendResult.succeeded {
                    KanbanCodeLog.error("tmux", "send-keys failed for \(name): \(sendResult.stderr)")
                }
            }
        }
    }

    public func killSession(name: String) async throws {
        let result = try await runTmux(["kill-session", "-t", name])
        if !result.succeeded {
            throw TmuxError.killFailed(name: name, message: result.stderr)
        }
    }

    /// Send Ctrl+C to interrupt the running process in a tmux session.
    public func sendInterrupt(sessionName: String) async throws {
        let _ = try await runTmux(["send-keys", "-t", sessionName, "C-c"])
    }

    public func sendEscape(sessionName: String) async throws {
        let _ = try await runTmux(["send-keys", "-t", sessionName, "Escape"])
    }

    /// Exit tmux copy/scroll mode if active, so send-keys reaches the application.
    public func exitScrollMode(sessionName: String) async throws {
        // Send 'q' to exit copy mode. If not in copy mode, 'q' is harmless
        // (Claude Code ignores it, Gemini CLI ignores it at the prompt).
        // We use cancel-copy-mode which is a no-op if not in copy mode.
        let _ = try? await runTmux(["send-keys", "-t", sessionName, "-X", "cancel"])
    }

    public func sendPrompt(to sessionName: String, text: String) async throws {
        try await exitScrollMode(sessionName: sessionName)
        // Use bracketed paste for reliability — send-keys -l can fail with long text
        // because Claude Code shows "[Pasted text #N +M lines]" and needs Enter.
        let tempFile = "/tmp/kanban-code-send-\(ProcessInfo.processInfo.processIdentifier).txt"
        try text.write(toFile: tempFile, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(atPath: tempFile) }

        let _ = try await runTmux(["load-buffer", tempFile])
        let _ = try await runTmux(["paste-buffer", "-p", "-t", sessionName])
        // Give the terminal app time to process the bracketed paste
        // before sending Enter — without this, Enter can arrive before
        // the paste event is fully handled, causing it to be lost.
        try await Task.sleep(for: .milliseconds(100))
        let _ = try await runTmux(["send-keys", "-t", sessionName, "Enter"])
        // Verify the prompt was accepted — if text is still on the prompt line,
        // send Enter again (Claude sometimes needs a moment to process the paste)
        try await ensurePromptSent(sessionName: sessionName)
    }

    /// Poll pane output to verify the prompt was accepted, pressing Enter again
    /// while it is still sitting in the composer. A cold assistant can take
    /// several seconds to attach its input handler and silently drops keystrokes
    /// that arrive before then, so the window is generous and the delay grows
    /// rather than hammering the pane. Failing to submit throws so callers can
    /// requeue the prompt instead of leaving a card parked on unsent text.
    private func ensurePromptSent(
        sessionName: String,
        timeout: Duration = .seconds(30)
    ) async throws {
        let start = ContinuousClock.now
        var delay = Duration.milliseconds(300)
        var attempts = 0
        while ContinuousClock.now - start < timeout {
            try await Task.sleep(for: delay)
            delay = min(delay * 3 / 2, .seconds(2))
            let output = try await capturePane(sessionName: sessionName)
            if !Self.paneHasUnsentPrompt(output) { return }
            attempts += 1
            KanbanCodeLog.info("send", "Unsent text detected on attempt \(attempts), pressing Enter again")
            let _ = try await runTmux(["send-keys", "-t", sessionName, "Enter"])
        }
        KanbanCodeLog.warn("send", "ensurePromptSent gave up after \(attempts) attempts for \(sessionName)")
        throw TmuxError.promptNotSubmitted(sessionName: sessionName)
    }

    /// Detects text still waiting in the composer: the `[Pasted text …]` chip, or
    /// anything typed after Claude's `❯` prompt character.
    /// Codex renders submitted prompts as historical `› text` lines, so treating
    /// `›` as unsent input causes duplicate Enter presses.
    public nonisolated static func paneHasUnsentPrompt(_ output: String) -> Bool {
        if output.contains("[Pasted text") || output.contains("[Pasted Text") { return true }
        guard let promptRange = output.range(of: "\u{276F}", options: .backwards) else { return false }
        let sameLine = output[promptRange.upperBound...].prefix { $0 != "\n" }
        return !sameLine.trimmingCharacters(in: .whitespaces).isEmpty
    }

    public func pastePrompt(to sessionName: String, text: String) async throws {
        try await pasteText(to: sessionName, text: text)
        try await submitPrompt(to: sessionName)
    }

    /// Stop whatever the assistant is doing, then submit `text`. Steering waits
    /// for the current turn to end; this cuts it short, which is what the last
    /// context threshold needs when a runaway turn is the thing burning tokens.
    /// Escape leaves the composer usable again after a short beat.
    public func interruptPrompt(to sessionName: String, text: String) async throws {
        try await sendEscape(sessionName: sessionName)
        try await Task.sleep(for: .milliseconds(400))
        try await pastePrompt(to: sessionName, text: text)
    }

    public func pasteText(to sessionName: String, text: String) async throws {
        try await exitScrollMode(sessionName: sessionName)
        // Use load-buffer + paste-buffer -p to bypass readline special char handling.
        // The -p flag wraps the paste in bracketed paste codes (\e[200~ … \e[201~),
        // telling the application (Gemini CLI) to treat the text literally and not
        // interpret special characters like ? (help) or ! (shell escape).
        let tempFile = "/tmp/kanban-code-paste-\(ProcessInfo.processInfo.processIdentifier).txt"
        try text.write(toFile: tempFile, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(atPath: tempFile) }

        let _ = try await runTmux(["load-buffer", tempFile])
        let _ = try await runTmux(["paste-buffer", "-p", "-t", sessionName])
        // Give the terminal app time to process the bracketed paste
        try await Task.sleep(for: .milliseconds(100))
    }

    public func submitPrompt(to sessionName: String) async throws {
        // Press Enter to submit
        let _ = try await runTmux(["send-keys", "-t", sessionName, "Enter"])
        try await ensurePromptSent(sessionName: sessionName)
    }

    public func capturePane(sessionName: String) async throws -> String {
        let result = try await runTmux(["capture-pane", "-p", "-t", sessionName])
        return result.stdout
    }

    public func sendBracketedPaste(to sessionName: String) async throws {
        // Send empty bracketed paste: \e[200~ \e[201~
        // Claude Code detects the paste event and checks the system clipboard for images.
        let _ = try await runTmux(["send-keys", "-t", sessionName, "\u{1b}[200~\u{1b}[201~"])
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
    case promptNotSubmitted(sessionName: String)

    public var errorDescription: String? {
        switch self {
        case .createFailed(let name, let message): "Failed to create tmux session '\(name)': \(message)"
        case .killFailed(let name, let message): "Failed to kill tmux session '\(name)': \(message)"
        case .promptNotSubmitted(let sessionName): "The prompt stayed in the composer of '\(sessionName)' after repeated Enter presses"
        }
    }
}
