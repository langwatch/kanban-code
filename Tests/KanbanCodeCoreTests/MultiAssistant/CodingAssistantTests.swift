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

    @Test("Mastra display name")
    func mastraDisplayName() {
        #expect(CodingAssistant.mastracode.displayName == "Mastra Code")
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

    @Test("Mastra CLI command")
    func mastraCliCommand() {
        #expect(CodingAssistant.mastracode.cliCommand == "mastracode")
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

    @Test("Mastra prompt character")
    func mastraPromptCharacter() {
        #expect(CodingAssistant.mastracode.promptCharacter == "> ")
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

    @Test("Mastra auto-approve command")
    func mastraAutoApproveFlag() {
        #expect(CodingAssistant.mastracode.autoApproveFlag == "/yolo")
    }

    // MARK: - Resume Flag

    @Test("Resume flags match assistant behavior")
    func resumeFlag() {
        #expect(CodingAssistant.claude.resumeFlag == "--resume")
        #expect(CodingAssistant.gemini.resumeFlag == "--resume")
        #expect(CodingAssistant.mastracode.resumeFlag == nil)
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

    @Test("Mastra does not support worktrees")
    func mastraNoWorktree() {
        #expect(CodingAssistant.mastracode.supportsWorktree == false)
    }

    @Test("Claude supports image upload")
    func claudeSupportsImageUpload() {
        #expect(CodingAssistant.claude.supportsImageUpload == true)
    }

    @Test("Gemini does not support image upload")
    func geminiNoImageUpload() {
        #expect(CodingAssistant.gemini.supportsImageUpload == false)
    }

    @Test("Mastra does not support image upload")
    func mastraNoImageUpload() {
        #expect(CodingAssistant.mastracode.supportsImageUpload == false)
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

    @Test("Mastra config dir")
    func mastraConfigDir() {
        #expect(CodingAssistant.mastracode.configDirName == "Library/Application Support/mastracode")
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

    @Test("Mastra install command")
    func mastraInstallCommand() {
        #expect(CodingAssistant.mastracode.installCommand.contains("mastracode"))
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
        let data = try JSONEncoder().encode(CodingAssistant.mastracode)
        let json = String(data: data, encoding: .utf8)!
        #expect(json == "\"mastracode\"")
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
        #expect(all.contains(.mastracode))
        #expect(all.count == 3)
    }
}
