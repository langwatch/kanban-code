import Testing
import Foundation
@testable import KanbanCodeCore

@Suite("PaneOutputParser Multi-Assistant")
struct PaneOutputParserMultiAssistantTests {

    // MARK: - isReady with Claude

    @Test("isReady detects Claude prompt character")
    func isReadyClaude() {
        let output = """
        ────────────────────────────────────────────────────────────
        ❯
        ────────────────────────────────────────────────────────────
        """
        #expect(PaneOutputParser.isReady(output, assistant: .claude) == true)
    }

    @Test("isReady does not detect Gemini prompt as Claude ready")
    func claudeNotReadyWithGeminiPrompt() {
        let output = " *   Type your message or @path/to/file"
        #expect(PaneOutputParser.isReady(output, assistant: .claude) == false)
    }

    // MARK: - isReady with Gemini

    @Test("isReady detects Gemini prompt")
    func isReadyGemini() {
        // Gemini shows "Type your message" when ready for input
        let output = """
        YOLO ctrl+y
        ▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀
         *   Type your message or @path/to/file
        ▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄
        """
        #expect(PaneOutputParser.isReady(output, assistant: .gemini) == true)
    }

    @Test("isReady does not detect Claude prompt as Gemini ready")
    func geminiNotReadyWithClaudePrompt() {
        let output = "❯"
        #expect(PaneOutputParser.isReady(output, assistant: .gemini) == false)
    }

    @Test("Gemini not ready during startup")
    func geminiNotReadyDuringStartup() {
        let output = "Loading Gemini CLI..."
        #expect(PaneOutputParser.isReady(output, assistant: .gemini) == false)
    }

    @Test("Gemini not ready when showing ASCII art banner")
    func geminiNotReadyDuringBanner() {
        let output = """
         ███            █████████  ██████████
        ░░░███         ███░░░░░███░░███░░░░░█
        Logged in with Google: user@example.com
        """
        #expect(PaneOutputParser.isReady(output, assistant: .gemini) == false)
    }

    // MARK: - isReady with Codex

    @Test("isReady detects Codex prompt")
    func isReadyCodex() {
        let output = """
        model: gpt-5.4
        cwd: /tmp/project
        ›
        """
        #expect(PaneOutputParser.isReady(output, assistant: .codex) == true)
    }

    @Test("isReady does not detect Claude prompt as Codex ready")
    func codexNotReadyWithClaudePrompt() {
        #expect(PaneOutputParser.isReady("❯", assistant: .codex) == false)
    }

    // MARK: - isClaudeReady backward compat

    @Test("isClaudeReady delegates to isReady with .claude")
    func isClaudeReadyBackwardCompat() {
        let readyOutput = "❯"
        let notReadyOutput = "loading..."
        #expect(PaneOutputParser.isClaudeReady(readyOutput) == true)
        #expect(PaneOutputParser.isClaudeReady(notReadyOutput) == false)
    }

    // MARK: - Edge cases

    @Test("Empty output is not ready for any assistant")
    func emptyOutputNotReady() {
        #expect(PaneOutputParser.isReady("", assistant: .claude) == false)
        #expect(PaneOutputParser.isReady("", assistant: .gemini) == false)
        #expect(PaneOutputParser.isReady("", assistant: .codex) == false)
    }
}
