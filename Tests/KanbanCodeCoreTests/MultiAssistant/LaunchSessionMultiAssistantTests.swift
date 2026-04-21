import Testing
import Foundation
@testable import KanbanCodeCore

@Suite("LaunchSession Multi-Assistant")
struct LaunchSessionMultiAssistantTests {

    // MARK: - Mock

    final class RecordingTmux: TmuxManagerPort, @unchecked Sendable {
        var lastCommand: String?
        var lastSessionName: String?
        var killedSessions: [String] = []
        var sessions: [TmuxSession] = []

        func createSession(name: String, path: String, command: String?) async throws {
            lastCommand = command
            lastSessionName = name
        }
        func killSession(name: String) async throws {
            killedSessions.append(name)
        }
        func listSessions() async throws -> [TmuxSession] { sessions }
        func sendPrompt(to sessionName: String, text: String) async throws {}
        func pastePrompt(to sessionName: String, text: String) async throws {}
        func capturePane(sessionName: String) async throws -> String { "" }
        func sendBracketedPaste(to sessionName: String) async throws {}
        func findSessionForWorktree(sessions: [TmuxSession], worktreePath: String, branch: String?) -> TmuxSession? { nil }
        func isAvailable() async -> Bool { true }
    }

    // MARK: - Launch with Claude

    @Test("Launch with Claude uses 'claude' command")
    func launchClaude() async throws {
        let mock = RecordingTmux()
        let launcher = LaunchSession(tmux: mock)

        _ = try await launcher.launch(
            sessionName: "test",
            projectPath: "/tmp/project",
            prompt: "fix bug",
            worktreeName: nil,
            shellOverride: nil,
            skipPermissions: true,
            assistant: .claude
        )

        let cmd = mock.lastCommand ?? ""
        #expect(cmd.contains("claude"))
        #expect(cmd.contains("--dangerously-skip-permissions"))
        #expect(!cmd.contains("gemini"))
        #expect(!cmd.contains("--yolo"))
    }

    // MARK: - Launch with Gemini

    @Test("Launch with Gemini uses 'gemini' command")
    func launchGemini() async throws {
        let mock = RecordingTmux()
        let launcher = LaunchSession(tmux: mock)

        _ = try await launcher.launch(
            sessionName: "test",
            projectPath: "/tmp/project",
            prompt: "fix bug",
            worktreeName: nil,
            shellOverride: nil,
            skipPermissions: true,
            assistant: .gemini
        )

        let cmd = mock.lastCommand ?? ""
        #expect(cmd.contains("gemini"))
        #expect(cmd.contains("--yolo"))
        #expect(!cmd.contains("claude"))
        #expect(!cmd.contains("--dangerously-skip-permissions"))
    }

    @Test("Launch with Gemini skips worktree even when provided")
    func launchGeminiNoWorktree() async throws {
        let mock = RecordingTmux()
        let launcher = LaunchSession(tmux: mock)

        _ = try await launcher.launch(
            sessionName: "test",
            projectPath: "/tmp/project",
            prompt: "fix bug",
            worktreeName: "feat-x",
            shellOverride: nil,
            skipPermissions: false,
            assistant: .gemini
        )

        let cmd = mock.lastCommand ?? ""
        #expect(!cmd.contains("--worktree"))
    }

    // MARK: - Launch with Codex

    @Test("Launch with Codex uses codex command and tmux-friendly flags")
    func launchCodex() async throws {
        let mock = RecordingTmux()
        let launcher = LaunchSession(tmux: mock)

        _ = try await launcher.launch(
            sessionName: "test",
            projectPath: "/tmp/project",
            prompt: "fix bug",
            worktreeName: nil,
            shellOverride: nil,
            skipPermissions: true,
            assistant: .codex
        )

        let cmd = mock.lastCommand ?? ""
        #expect(cmd.contains("codex"))
        #expect(cmd.contains("--no-alt-screen"))
        #expect(cmd.contains("--dangerously-bypass-approvals-and-sandbox"))
        #expect(!cmd.contains("--yolo"))
        #expect(!cmd.contains("--dangerously-skip-permissions"))
    }

    @Test("Launch with Codex skips worktree even when provided")
    func launchCodexNoWorktree() async throws {
        let mock = RecordingTmux()
        let launcher = LaunchSession(tmux: mock)

        _ = try await launcher.launch(
            sessionName: "test",
            projectPath: "/tmp/project",
            prompt: "fix bug",
            worktreeName: "feat-x",
            shellOverride: nil,
            skipPermissions: false,
            assistant: .codex
        )

        let cmd = mock.lastCommand ?? ""
        #expect(!cmd.contains("--worktree"))
    }

    @Test("Launch with Claude includes worktree flag")
    func launchClaudeWithWorktree() async throws {
        let mock = RecordingTmux()
        let launcher = LaunchSession(tmux: mock)

        _ = try await launcher.launch(
            sessionName: "test",
            projectPath: "/tmp/project",
            prompt: "fix bug",
            worktreeName: "feat-login",
            shellOverride: nil,
            skipPermissions: false,
            assistant: .claude
        )

        let cmd = mock.lastCommand ?? ""
        #expect(cmd.contains("--worktree feat-login"))
    }

    // MARK: - Resume with different assistants

    @Test("Resume with Claude uses claude command and prefix")
    func resumeClaude() async throws {
        let mock = RecordingTmux()
        let launcher = LaunchSession(tmux: mock)

        let sessionName = try await launcher.resume(
            sessionId: "sess_abcdef12-rest",
            projectPath: "/tmp/project",
            shellOverride: nil,
            skipPermissions: true,
            assistant: .claude
        )

        #expect(sessionName == "claude-sess_abc")
        let cmd = mock.lastCommand ?? ""
        #expect(cmd.contains("claude"))
        #expect(cmd.contains("--resume sess_abcdef12-rest"))
        #expect(cmd.contains("--dangerously-skip-permissions"))
    }

    @Test("Resume with Gemini uses gemini command and prefix")
    func resumeGemini() async throws {
        let mock = RecordingTmux()
        let launcher = LaunchSession(tmux: mock)

        let sessionName = try await launcher.resume(
            sessionId: "sess_xyz12345-rest",
            projectPath: "/tmp/project",
            shellOverride: nil,
            skipPermissions: true,
            assistant: .gemini
        )

        #expect(sessionName == "gemini-sess_xyz")
        let cmd = mock.lastCommand ?? ""
        #expect(cmd.contains("gemini"))
        #expect(cmd.contains("--resume sess_xyz12345-rest"))
        #expect(cmd.contains("--yolo"))
    }

    @Test("Resume with Codex uses resume subcommand and prefix")
    func resumeCodex() async throws {
        let mock = RecordingTmux()
        let launcher = LaunchSession(tmux: mock)

        let sessionName = try await launcher.resume(
            sessionId: "019da64f-874c-7a03-bde4-7660c09931f2",
            projectPath: "/tmp/project",
            shellOverride: nil,
            skipPermissions: true,
            assistant: .codex
        )

        #expect(sessionName == "codex-019da64f")
        let cmd = mock.lastCommand ?? ""
        #expect(cmd.contains("codex resume"))
        #expect(cmd.contains("--no-alt-screen"))
        #expect(cmd.contains("--dangerously-bypass-approvals-and-sandbox"))
        #expect(cmd.contains("019da64f-874c-7a03-bde4-7660c09931f2"))
        #expect(!cmd.contains("--resume"))
    }

    @Test("Resume without skip permissions omits flag")
    func resumeNoSkipPermissions() async throws {
        let mock = RecordingTmux()
        let launcher = LaunchSession(tmux: mock)

        _ = try await launcher.resume(
            sessionId: "sess_test1234",
            projectPath: "/tmp",
            shellOverride: nil,
            skipPermissions: false,
            assistant: .gemini
        )

        let cmd = mock.lastCommand ?? ""
        #expect(!cmd.contains("--yolo"))
        #expect(cmd.contains("gemini"))
        #expect(cmd.contains("--resume"))
    }

    // MARK: - Shell override

    @Test("Launch with shell override prepends SHELL=")
    func launchWithShellOverride() async throws {
        let mock = RecordingTmux()
        let launcher = LaunchSession(tmux: mock)

        _ = try await launcher.launch(
            sessionName: "test",
            projectPath: "/tmp",
            prompt: "test",
            worktreeName: nil,
            shellOverride: "~/.kanban-code/remote/zsh",
            skipPermissions: false,
            assistant: .gemini
        )

        let cmd = mock.lastCommand ?? ""
        #expect(cmd.contains("SHELL=~/.kanban-code/remote/zsh"))
        #expect(cmd.contains("gemini"))
    }

    // MARK: - Command override

    @Test("Command override is used as-is for both assistants")
    func commandOverride() async throws {
        for assistant in CodingAssistant.allCases {
            let mock = RecordingTmux()
            let launcher = LaunchSession(tmux: mock)

            _ = try await launcher.launch(
                sessionName: "test",
                projectPath: "/tmp",
                prompt: "test",
                worktreeName: nil,
                shellOverride: nil,
                commandOverride: "echo 'custom-cmd'",
                skipPermissions: false,
                assistant: assistant
            )

            let cmd = mock.lastCommand ?? ""
            #expect(cmd.contains("echo 'custom-cmd'"))
            // Should NOT contain the assistant's CLI command since override is used
            #expect(!cmd.contains("\(assistant.cliCommand) "))
        }
    }

    // MARK: - Default assistant

    @Test("Launch defaults to Claude when no assistant specified")
    func launchDefaultsClaude() async throws {
        let mock = RecordingTmux()
        let launcher = LaunchSession(tmux: mock)

        _ = try await launcher.launch(
            sessionName: "test",
            projectPath: "/tmp",
            prompt: "test",
            worktreeName: nil,
            shellOverride: nil,
            skipPermissions: false
        )

        let cmd = mock.lastCommand ?? ""
        #expect(cmd.contains("claude"))
    }
}
