import Foundation

/// Answers true when a prompt that is waiting to be submitted is not wanted
/// any more, for example a context warning after the agent compacted itself.
public typealias PromptAbortCheck = @Sendable () async -> Bool

/// Manages tmux sessions via the tmux CLI.
public final class TmuxAdapter: TmuxManagerPort, @unchecked Sendable {
    private let transport: any TmuxTransport

    public init(tmuxPath: String? = nil) {
        self.transport = LocalTmuxTransport(tmuxPath: tmuxPath)
    }

    /// Drives tmux through `transport`, on this Mac or on a remote machine.
    public init(transport: any TmuxTransport) {
        self.transport = transport
    }

    /// tmux commands are sub-second in practice, so a long stall means a wedged
    /// server rather than slow work. Bounding them stops one from stranding a
    /// launch on a prompt that never gets submitted.
    private func runTmux(
        _ arguments: [String],
        timeout: TimeInterval = 20
    ) async throws -> ShellCommand.Result {
        try await transport.run(arguments, timeout: timeout)
    }

    /// Runs one tmux command on the server this adapter talks to. For the
    /// commands the terminal sends on its own, such as copy-mode navigation.
    public func run(_ arguments: [String], timeout: TimeInterval = 20) async throws -> ShellCommand.Result {
        try await runTmux(arguments, timeout: timeout)
    }

    /// Field separator of the session list. A printable sequence, because
    /// tmux on Linux replaces control characters such as a tab in its
    /// format output with `_`.
    static let listSeparator = "<|>"

    public func listSessions() async throws -> [TmuxSession] {
        let separator = Self.listSeparator
        let result = try await runTmux(["list-sessions", "-F", "#{session_name}\(separator)#{session_path}\(separator)#{session_attached}"])

        // tmux returns exit code 1 with "no server running" when there are no sessions
        guard result.succeeded, !result.stdout.isEmpty else { return [] }

        return result.stdout.components(separatedBy: "\n").compactMap { line -> TmuxSession? in
            let parts = line.components(separatedBy: separator)
            guard parts.count >= 3 else { return nil }
            return TmuxSession(
                name: parts[0],
                path: parts[1],
                attached: parts[2] == "1"
            )
        }
    }

    public func createSession(name: String, path: String, command: String?) async throws {
        try await createSession(name: name, path: path, command: command, environment: [:])
    }

    /// Arguments of `tmux new-session` for a detached session whose
    /// processes get `environment` (`-e`, tmux 3.2 and later).
    public static func newSessionArguments(name: String, path: String, environment: [String: String]) -> [String] {
        var args = ["new-session", "-d", "-s", name, "-c", path]
        for key in environment.keys.sorted() { args += ["-e", "\(key)=\(environment[key]!)"] }
        return args
    }

    public func createSession(name: String, path: String, command: String?, environment: [String: String]) async throws {
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
        await dropInheritedServerEnvironment()
        let result = try await runTmux(Self.newSessionArguments(name: name, path: path, environment: environment))
        if !result.succeeded {
            throw TmuxError.createFailed(name: name, message: result.stderr)
        }

        if let command, !command.isEmpty {
            if command.contains("\n") {
                // Multi-line commands break tmux send-keys (newlines become Enter
                // presses, splitting the command). Write to a temp file and source
                // it — the shell parser handles newlines inside quoted strings correctly.
                let tempFile = try await transport.writeTempFile(name: "launch-\(name).sh", contents: command)
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

    /// Fails quietly when no server runs yet: the server new-session starts
    /// then gets this process's own environment, already scrubbed.
    private func dropInheritedServerEnvironment() async {
        let tmp = try? await runTmux(["show-environment", "-g", "TMPDIR"])
        let value = tmp.flatMap { $0.succeeded ? $0.stdout : nil }?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .split(separator: "=", maxSplits: 1).dropFirst().first.map(String.init)
        let marker = try? await runTmux(["show-environment", "-g", InheritedSessionEnvironment.accountMarker])
        let prefix = InheritedSessionEnvironment.accountMarker + "="
        let markerValue = marker.flatMap { $0.succeeded && $0.stdout.hasPrefix(prefix) ? $0.stdout : nil }
            .map { String($0.dropFirst(prefix.count)).trimmingCharacters(in: .whitespacesAndNewlines) }
        _ = try? await runTmux(InheritedSessionEnvironment.tmuxUnsetArguments(serverTMPDIR: value, accountMarker: markerValue))
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
        let tempFile = try await transport.writeTempFile(
            name: "send-\(ProcessInfo.processInfo.processIdentifier).txt", contents: text)
        defer { Task { [transport] in await transport.removeTempFile(tempFile) } }

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

    /// Erases what is waiting in the composer. Claude and Codex both map Ctrl+U
    /// to "clear the input line", so text that was pasted but never submitted
    /// does not stay there for a later stray Enter. Returns false when the pane
    /// still shows unsent text after `attempts` tries.
    @discardableResult
    public func clearComposer(sessionName: String, attempts: Int = 3) async throws -> Bool {
        for _ in 0..<max(1, attempts) {
            let _ = try await runTmux(["send-keys", "-t", sessionName, "C-u"])
            try await Task.sleep(for: .milliseconds(150))
            let output = try await capturePane(sessionName: sessionName)
            if !Self.paneHasUnsentPrompt(output) { return true }
        }
        return false
    }

    /// Poll pane output to verify the prompt was accepted, pressing Enter again
    /// while it is still sitting in the composer. A cold assistant can take
    /// several seconds to attach its input handler and silently drops keystrokes
    /// that arrive before then, so the window is generous and the delay grows
    /// rather than hammering the pane. Failing to submit throws so callers can
    /// requeue the prompt instead of leaving a card parked on unsent text.
    private func ensurePromptSent(
        sessionName: String,
        timeout: Duration = .seconds(30),
        abortIf: PromptAbortCheck? = nil
    ) async throws {
        let start = ContinuousClock.now
        var delay = Duration.milliseconds(300)
        var attempts = 0
        while ContinuousClock.now - start < timeout {
            try await Task.sleep(for: delay)
            delay = min(delay * 3 / 2, .seconds(2))
            let output = try await capturePane(sessionName: sessionName)
            if !Self.paneHasUnsentPrompt(output) { return }
            if let abortIf, await abortIf() {
                KanbanCodeLog.info("send", "Prompt no longer wanted for \(sessionName), clearing the composer")
                let _ = try? await clearComposer(sessionName: sessionName)
                return
            }
            attempts += 1
            KanbanCodeLog.info("send", "Unsent text detected on attempt \(attempts), pressing Enter again")
            let _ = try await runTmux(["send-keys", "-t", sessionName, "Enter"])
        }
        KanbanCodeLog.warn("send", "ensurePromptSent gave up after \(attempts) attempts for \(sessionName), clearing the composer")
        let cleared = (try? await clearComposer(sessionName: sessionName)) ?? false
        if !cleared {
            KanbanCodeLog.warn("send", "Composer of \(sessionName) still holds unsent text after the clear")
        }
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
        try await pastePrompt(to: sessionName, text: text, abortIf: nil)
    }

    /// Pastes and submits `text`, and gives up on it when `abortIf` turns true
    /// while the assistant is still busy. A context warning is only true for as
    /// long as the context is big: when the agent compacts mid-retry the text is
    /// cleared instead of pressed into the composer again.
    public func pastePrompt(
        to sessionName: String,
        text: String,
        timeout: Duration = .seconds(30),
        abortIf: PromptAbortCheck?
    ) async throws {
        try await pasteText(to: sessionName, text: text)
        try await submitPrompt(to: sessionName, timeout: timeout, abortIf: abortIf)
    }

    /// Stop whatever the assistant is doing, then submit `text`. Steering waits
    /// for the current turn to end; this cuts it short, which is what the last
    /// context threshold needs when a runaway turn is the thing burning tokens.
    /// Escape leaves the composer usable again after a short beat.
    public func interruptPrompt(to sessionName: String, text: String) async throws {
        try await interruptPrompt(to: sessionName, text: text, abortIf: nil)
    }

    public func interruptPrompt(
        to sessionName: String,
        text: String,
        timeout: Duration = .seconds(30),
        abortIf: PromptAbortCheck?
    ) async throws {
        try await sendEscape(sessionName: sessionName)
        try await Task.sleep(for: .milliseconds(400))
        try await pastePrompt(to: sessionName, text: text, timeout: timeout, abortIf: abortIf)
    }

    public func pasteText(to sessionName: String, text: String) async throws {
        try await exitScrollMode(sessionName: sessionName)
        // Use load-buffer + paste-buffer -p to bypass readline special char handling.
        // The -p flag wraps the paste in bracketed paste codes (\e[200~ … \e[201~),
        // telling the application (Gemini CLI) to treat the text literally and not
        // interpret special characters like ? (help) or ! (shell escape).
        let tempFile = try await transport.writeTempFile(
            name: "paste-\(ProcessInfo.processInfo.processIdentifier).txt", contents: text)
        defer { Task { [transport] in await transport.removeTempFile(tempFile) } }

        let _ = try await runTmux(["load-buffer", tempFile])
        let _ = try await runTmux(["paste-buffer", "-p", "-t", sessionName])
        // Give the terminal app time to process the bracketed paste
        try await Task.sleep(for: .milliseconds(100))
    }

    public func submitPrompt(to sessionName: String) async throws {
        try await submitPrompt(to: sessionName, abortIf: nil)
    }

    public func submitPrompt(
        to sessionName: String,
        timeout: Duration = .seconds(30),
        abortIf: PromptAbortCheck?
    ) async throws {
        // Press Enter to submit
        let _ = try await runTmux(["send-keys", "-t", sessionName, "Enter"])
        try await ensurePromptSent(sessionName: sessionName, timeout: timeout, abortIf: abortIf)
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
        await transport.isAvailable()
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
