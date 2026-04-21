import Testing
import Foundation
@testable import KanbanCodeCore

@Suite("ImageSender Multi-Assistant")
struct ImageSenderMultiAssistantTests {

    // MARK: - Mock

    final class MockTmux: TmuxManagerPort, @unchecked Sendable {
        var capturedPaneOutputs: [String] = []
        private var captureIndex = 0
        var captureCallCount = 0

        func createSession(name: String, path: String, command: String?) async throws {}
        func killSession(name: String) async throws {}
        func listSessions() async throws -> [TmuxSession] { [] }
        func sendPrompt(to sessionName: String, text: String) async throws {}
        func pastePrompt(to sessionName: String, text: String) async throws {}
        func sendBracketedPaste(to sessionName: String) async throws {}
        func findSessionForWorktree(sessions: [TmuxSession], worktreePath: String, branch: String?) -> TmuxSession? { nil }
        func isAvailable() async -> Bool { true }

        func capturePane(sessionName: String) async throws -> String {
            captureCallCount += 1
            if capturedPaneOutputs.isEmpty { return "" }
            let idx = min(captureIndex, capturedPaneOutputs.count - 1)
            let result = capturedPaneOutputs[idx]
            if captureIndex < capturedPaneOutputs.count - 1 { captureIndex += 1 }
            return result
        }
    }

    // MARK: - waitForReady with Gemini

    @Test("waitForReady detects Gemini prompt")
    func waitForReadyGemini() async throws {
        let mock = MockTmux()
        mock.capturedPaneOutputs = [
            // Gemini startup: ASCII art, auth info
            """
             ███            █████████  ██████████
            Logged in with Google: user@example.com
            """,
            // Still loading
            "Plan: Gemini Code Assist\nLoading...",
            // Ready
            """
            YOLO ctrl+y
            ▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀
             *   Type your message or @path/to/file
            ▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄
            """,
        ]

        let sender = ImageSender(tmux: mock)
        try await sender.waitForReady(
            sessionName: "test-gemini",
            assistant: .gemini,
            pollInterval: .milliseconds(10),
            timeout: .seconds(5)
        )

        #expect(mock.captureCallCount == 3)
    }

    @Test("waitForReady detects Claude prompt")
    func waitForReadyClaude() async throws {
        let mock = MockTmux()
        mock.capturedPaneOutputs = [
            "Starting Claude Code...",
            "Loading session...",
            "────────────────\n❯ \n────────────────",
        ]

        let sender = ImageSender(tmux: mock)
        try await sender.waitForReady(
            sessionName: "test-claude",
            assistant: .claude,
            pollInterval: .milliseconds(10),
            timeout: .seconds(5)
        )

        #expect(mock.captureCallCount == 3)
    }

    @Test("waitForReady detects Codex prompt")
    func waitForReadyCodex() async throws {
        let mock = MockTmux()
        mock.capturedPaneOutputs = [
            "Starting Codex...",
            "model: gpt-5.4\ncwd: /tmp/project\n›",
        ]

        let sender = ImageSender(tmux: mock)
        try await sender.waitForReady(
            sessionName: "test-codex",
            assistant: .codex,
            pollInterval: .milliseconds(10),
            timeout: .seconds(5)
        )

        #expect(mock.captureCallCount == 2)
    }

    // MARK: - Timeout errors include assistant name

    @Test("Timeout error says 'Gemini CLI' for Gemini")
    func timeoutErrorGemini() async throws {
        let mock = MockTmux()
        mock.capturedPaneOutputs = ["Loading Gemini..."]

        let sender = ImageSender(tmux: mock)
        do {
            try await sender.waitForReady(
                sessionName: "test",
                assistant: .gemini,
                pollInterval: .milliseconds(10),
                timeout: .milliseconds(50)
            )
            Issue.record("Expected error to be thrown")
        } catch let error as ImageSendError {
            let message = error.errorDescription ?? ""
            #expect(message.contains("Gemini CLI"))
            #expect(!message.contains("Claude"))
        }
    }

    @Test("Timeout error says 'Claude Code' for Claude")
    func timeoutErrorClaude() async throws {
        let mock = MockTmux()
        mock.capturedPaneOutputs = ["Loading..."]

        let sender = ImageSender(tmux: mock)
        do {
            try await sender.waitForReady(
                sessionName: "test",
                assistant: .claude,
                pollInterval: .milliseconds(10),
                timeout: .milliseconds(50)
            )
            Issue.record("Expected error to be thrown")
        } catch let error as ImageSendError {
            let message = error.errorDescription ?? ""
            #expect(message.contains("Claude Code"))
            #expect(!message.contains("Gemini"))
        }
    }

    @Test("Timeout error says 'Codex CLI' for Codex")
    func timeoutErrorCodex() async throws {
        let mock = MockTmux()
        mock.capturedPaneOutputs = ["Loading Codex..."]

        let sender = ImageSender(tmux: mock)
        do {
            try await sender.waitForReady(
                sessionName: "test",
                assistant: .codex,
                pollInterval: .milliseconds(10),
                timeout: .milliseconds(50)
            )
            Issue.record("Expected error to be thrown")
        } catch let error as ImageSendError {
            let message = error.errorDescription ?? ""
            #expect(message.contains("Codex CLI"))
            #expect(!message.contains("Claude"))
            #expect(!message.contains("Gemini"))
        }
    }

    // MARK: - Default assistant is Claude

    @Test("waitForReady defaults to Claude")
    func defaultAssistantClaude() async throws {
        let mock = MockTmux()
        mock.capturedPaneOutputs = ["❯ "]

        let sender = ImageSender(tmux: mock)
        // No assistant param — should default to .claude and detect ❯
        try await sender.waitForReady(
            sessionName: "test",
            pollInterval: .milliseconds(10),
            timeout: .seconds(1)
        )
        #expect(mock.captureCallCount == 1)
    }

    @Test("waitForReady with default does not detect Gemini prompt")
    func defaultDoesNotDetectGemini() async throws {
        let mock = MockTmux()
        mock.capturedPaneOutputs = ["Type your message or @path/to/file"]

        let sender = ImageSender(tmux: mock)
        // Default is .claude, so Gemini's prompt should NOT be detected
        await #expect(throws: ImageSendError.self) {
            try await sender.waitForReady(
                sessionName: "test",
                pollInterval: .milliseconds(10),
                timeout: .milliseconds(50)
            )
        }
    }
}
