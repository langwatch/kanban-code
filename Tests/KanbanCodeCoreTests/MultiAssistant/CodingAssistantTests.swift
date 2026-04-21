import Testing
import Foundation
@testable import KanbanCodeCore

@Suite("CodingAssistant Enum")
struct CodingAssistantTests {

    // MARK: - Display Names

    @Test("Claude display name")
    func claudeDisplayName() {
        #expect(CodingAssistant.claude.displayName == "Claude Code")
    }

    @Test("Gemini display name")
    func geminiDisplayName() {
        #expect(CodingAssistant.gemini.displayName == "Gemini CLI")
    }

    @Test("Codex display name")
    func codexDisplayName() {
        #expect(CodingAssistant.codex.displayName == "Codex CLI")
    }

    // MARK: - CLI Commands

    @Test("Claude CLI command")
    func claudeCliCommand() {
        #expect(CodingAssistant.claude.cliCommand == "claude")
    }

    @Test("Gemini CLI command")
    func geminiCliCommand() {
        #expect(CodingAssistant.gemini.cliCommand == "gemini")
    }

    @Test("Codex CLI command")
    func codexCliCommand() {
        #expect(CodingAssistant.codex.cliCommand == "codex")
    }

    // MARK: - Prompt Characters

    @Test("Claude prompt character is ❯")
    func claudePromptCharacter() {
        #expect(CodingAssistant.claude.promptCharacter == "❯")
    }

    @Test("Gemini prompt character detects input prompt")
    func geminiPromptCharacter() {
        #expect(CodingAssistant.gemini.promptCharacter == "Type your message")
    }

    @Test("Codex prompt character is ›")
    func codexPromptCharacter() {
        #expect(CodingAssistant.codex.promptCharacter == "›")
    }

    // MARK: - Auto-Approve Flags

    @Test("Claude auto-approve flag")
    func claudeAutoApproveFlag() {
        #expect(CodingAssistant.claude.autoApproveFlag == "--dangerously-skip-permissions")
    }

    @Test("Gemini auto-approve flag")
    func geminiAutoApproveFlag() {
        #expect(CodingAssistant.gemini.autoApproveFlag == "--yolo")
    }

    @Test("Codex auto-approve flag")
    func codexAutoApproveFlag() {
        #expect(CodingAssistant.codex.autoApproveFlag == "--dangerously-bypass-approvals-and-sandbox")
    }

    // MARK: - Resume Flag

    @Test("Assistant resume flags match CLI syntax")
    func resumeFlag() {
        #expect(CodingAssistant.claude.resumeFlag == "--resume")
        #expect(CodingAssistant.gemini.resumeFlag == "--resume")
        #expect(CodingAssistant.codex.resumeFlag == "resume")
    }

    // MARK: - Capabilities

    @Test("Claude supports worktrees")
    func claudeSupportsWorktree() {
        #expect(CodingAssistant.claude.supportsWorktree == true)
    }

    @Test("Gemini does not support worktrees")
    func geminiNoWorktree() {
        #expect(CodingAssistant.gemini.supportsWorktree == false)
    }

    @Test("Codex does not support worktrees")
    func codexNoWorktree() {
        #expect(CodingAssistant.codex.supportsWorktree == false)
    }

    @Test("Claude supports image upload")
    func claudeSupportsImageUpload() {
        #expect(CodingAssistant.claude.supportsImageUpload == true)
    }

    @Test("Gemini does not support image upload")
    func geminiNoImageUpload() {
        #expect(CodingAssistant.gemini.supportsImageUpload == false)
    }

    @Test("Codex does not support image upload")
    func codexNoImageUpload() {
        #expect(CodingAssistant.codex.supportsImageUpload == false)
    }

    @Test("Codex uses paste submission and file polling")
    func codexPromptAndHooks() {
        #expect(CodingAssistant.codex.submitsPromptWithPaste)
        #expect(!CodingAssistant.codex.supportsHooks)
    }

    // MARK: - Config Directory

    @Test("Claude config dir")
    func claudeConfigDir() {
        #expect(CodingAssistant.claude.configDirName == ".claude")
    }

    @Test("Gemini config dir")
    func geminiConfigDir() {
        #expect(CodingAssistant.gemini.configDirName == ".gemini")
    }

    @Test("Codex config dir")
    func codexConfigDir() {
        #expect(CodingAssistant.codex.configDirName == ".codex")
    }

    // MARK: - Install Command

    @Test("Claude install command")
    func claudeInstallCommand() {
        #expect(CodingAssistant.claude.installCommand.contains("claude-code"))
    }

    @Test("Gemini install command")
    func geminiInstallCommand() {
        #expect(CodingAssistant.gemini.installCommand.contains("gemini-cli"))
    }

    @Test("Codex install command")
    func codexInstallCommand() {
        #expect(CodingAssistant.codex.installCommand.contains("@openai/codex"))
    }

    // MARK: - Command Building

    @Test("Codex launch command includes no alternate screen")
    func codexLaunchCommand() {
        let command = CodingAssistant.codex.launchCommand(skipPermissions: true, worktreeName: "ignored")
        #expect(command.contains("codex"))
        #expect(command.contains("--no-alt-screen"))
        #expect(command.contains("--dangerously-bypass-approvals-and-sandbox"))
        #expect(!command.contains("--worktree"))
    }

    @Test("Codex resume command uses resume subcommand")
    func codexResumeCommand() {
        let command = CodingAssistant.codex.resumeCommand(sessionId: "session-123", skipPermissions: true)
        #expect(command == "codex resume --dangerously-bypass-approvals-and-sandbox --no-alt-screen session-123")
    }

    // MARK: - Codable

    @Test("CodingAssistant Codable round-trip")
    func codableRoundTrip() throws {
        for assistant in CodingAssistant.allCases {
            let data = try JSONEncoder().encode(assistant)
            let decoded = try JSONDecoder().decode(CodingAssistant.self, from: data)
            #expect(decoded == assistant)
        }
    }

    @Test("CodingAssistant raw value encoding")
    func rawValueEncoding() throws {
        let data = try JSONEncoder().encode(CodingAssistant.gemini)
        let json = String(data: data, encoding: .utf8)!
        #expect(json == "\"gemini\"")
    }

    @Test("CodingAssistant decodes from raw string")
    func decodeFromString() throws {
        let json = "\"claude\""
        let decoded = try JSONDecoder().decode(CodingAssistant.self, from: json.data(using: .utf8)!)
        #expect(decoded == .claude)
    }

    // MARK: - CaseIterable

    @Test("CaseIterable includes all known assistants")
    func caseIterable() {
        let all = CodingAssistant.allCases
        #expect(all.contains(.claude))
        #expect(all.contains(.gemini))
        #expect(all.contains(.codex))
        #expect(all.count == 3)
    }
}
