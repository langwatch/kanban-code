import Testing
import Foundation
@testable import KanbanCodeCore

// MARK: - PaneOutputParser Tests

@Suite("Pane Output Parser")
struct PaneOutputParserTests {

    @Test("counts zero images in empty output")
    func countImagesEmpty() {
        #expect(PaneOutputParser.countImages(in: "") == 0)
    }

    @Test("counts zero images in output with no image tags")
    func countImagesNone() {
        let output = """
        ❯ hello world
        some text here
        """
        #expect(PaneOutputParser.countImages(in: output) == 0)
    }

    @Test("counts one image")
    func countImagesOne() {
        let output = """
         [Image #1] (↑ to select)
        ────────────────────────────────────────────────────────────
        ❯
        """
        #expect(PaneOutputParser.countImages(in: output) == 1)
    }

    @Test("counts multiple images")
    func countImagesMultiple() {
        let output = """
         [Image #1] (↑ to select)
         [Image #2] (↑ to select)
         [Image #3] Delete to remove · Esc to cancel
        ────────────────────────────────────────────────────────────
        ❯
        """
        #expect(PaneOutputParser.countImages(in: output) == 3)
    }

    @Test("does not trust the image number, just counts occurrences")
    func countImagesIgnoresNumbers() {
        // Image numbers might not be sequential if user deleted some
        let output = """
         [Image #3] (↑ to select)
         [Image #7] Delete to remove · Esc to cancel
        ────────────────────────────────────────────────────────────
        ❯
        """
        #expect(PaneOutputParser.countImages(in: output) == 2)
    }

    @Test("counts multiple images on the same line")
    func countImagesSameLine() {
        let output = """
         [Image #6] [Image #7] (↑ to select)
        ────────────────────────────────────────────────────────────
        ❯
        """
        #expect(PaneOutputParser.countImages(in: output) == 2)
    }

    @Test("only counts lines that also contain 'to select' or 'to remove'")
    func countImagesRequiresContext() {
        // A user might type "[Image" in their prompt — don't count it
        let output = """
        ❯ please look at [Image handling code
         [Image #1] (↑ to select)
        """
        #expect(PaneOutputParser.countImages(in: output) == 1)
    }

    @Test("detects Claude ready prompt")
    func isClaudeReady() {
        let output = """
        ────────────────────────────────────────────────────────────
        ❯
        ────────────────────────────────────────────────────────────
          ⏵⏵ bypass permissions on (shift+tab to cycle)
        """
        #expect(PaneOutputParser.isClaudeReady(output) == true)
    }

    @Test("detects Claude not ready during startup")
    func isClaudeNotReady() {
        let output = """
        Starting Claude Code...
        Loading session...
        """
        #expect(PaneOutputParser.isClaudeReady(output) == false)
    }

    @Test("detects Claude ready even with content above")
    func isClaudeReadyWithHistory() {
        let output = """
        ⏺ I made the changes you requested.

        ✻ Worked for 12s

        ────────────────────────────────────────────────────────────
        ❯
        ────────────────────────────────────────────────────────────
        """
        #expect(PaneOutputParser.isClaudeReady(output) == true)
    }
}

// MARK: - ImageAttachment Tests

@Suite("Image Attachment")
struct ImageAttachmentTests {

    @Test("creates attachment with PNG data")
    func createAttachment() {
        let data = Data([0x89, 0x50, 0x4E, 0x47]) // PNG magic bytes
        let attachment = ImageAttachment(data: data)
        #expect(!attachment.id.isEmpty)
        #expect(attachment.data == data)
        #expect(attachment.tempPath == nil)
    }

    @Test("saves to temp file and loads back")
    func saveTempFile() throws {
        let data = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
        var attachment = ImageAttachment(data: data)
        let path = try attachment.saveToTemp()
        defer { try? FileManager.default.removeItem(atPath: path) }

        #expect(attachment.tempPath == path)
        #expect(FileManager.default.fileExists(atPath: path))

        let loaded = try Data(contentsOf: URL(fileURLWithPath: path))
        #expect(loaded == data)
    }

    @Test("loads from temp path")
    func loadFromPath() throws {
        let data = Data([0x89, 0x50, 0x4E, 0x47])
        let path = "/tmp/kanban-code-test-\(UUID().uuidString).png"
        try data.write(to: URL(fileURLWithPath: path))
        defer { try? FileManager.default.removeItem(atPath: path) }

        let attachment = ImageAttachment.fromPath(path)
        #expect(attachment != nil)
        #expect(attachment?.data == data)
        #expect(attachment?.tempPath == path)
    }
}

// MARK: - ImageSender Tests (with mock tmux)

@Suite("Image Sender")
struct ImageSenderTests {

    // Mock that records calls and returns configurable capture-pane output
    final class MockTmux: TmuxManagerPort, @unchecked Sendable {
        var capturedPaneOutputs: [String] = [] // sequence of outputs for polling
        var captureCallCount = 0
        var sentBracketedPastes: [String] = [] // session names
        var sentPrompts: [(session: String, text: String)] = []
        var pastedTexts: [(session: String, text: String)] = []
        var submittedPrompts: [String] = []
        var events: [String] = []
        var createdSessions: [(name: String, path: String, command: String?)] = []
        var killedSessions: [String] = []

        func capturePane(sessionName: String) async throws -> String {
            let index = min(captureCallCount, capturedPaneOutputs.count - 1)
            captureCallCount += 1
            return capturedPaneOutputs.isEmpty ? "" : capturedPaneOutputs[index]
        }

        func sendBracketedPaste(to sessionName: String) async throws {
            sentBracketedPastes.append(sessionName)
            events.append("image")
        }

        func sendPrompt(to sessionName: String, text: String) async throws {
            sentPrompts.append((session: sessionName, text: text))
        }

        func pastePrompt(to sessionName: String, text: String) async throws {
            sentPrompts.append((session: sessionName, text: text))
        }

        func pasteText(to sessionName: String, text: String) async throws {
            pastedTexts.append((session: sessionName, text: text))
            events.append("text:\(text)")
        }

        func submitPrompt(to sessionName: String) async throws {
            submittedPrompts.append(sessionName)
            events.append("submit")
        }

        func listSessions() async throws -> [TmuxSession] { [] }
        func createSession(name: String, path: String, command: String?) async throws {
            createdSessions.append((name: name, path: path, command: command))
        }
        func killSession(name: String) async throws {
            killedSessions.append(name)
        }
        func findSessionForWorktree(sessions: [TmuxSession], worktreePath: String, branch: String?) -> TmuxSession? { nil }
        func isAvailable() async -> Bool { true }
    }

    @Test("sends bracketed paste for each image and waits for confirmation")
    func sendImagesSuccess() async throws {
        let mock = MockTmux()
        // First poll: no images, second poll: 1 image confirmed
        mock.capturedPaneOutputs = [
            "❯ ",
            " [Image #1] (↑ to select)\n❯ ",
        ]

        let sender = ImageSender(tmux: mock)
        let image = ImageAttachment(data: Data([0x89, 0x50]))

        try await sender.sendImages(
            sessionName: "test-session",
            images: [image],
            setClipboard: { _ in }, // no-op for test
            pollInterval: .milliseconds(10),
            timeout: .seconds(5)
        )

        #expect(mock.sentBracketedPastes.count == 1)
        #expect(mock.sentBracketedPastes.first == "test-session")
    }

    @Test("sends multiple images sequentially")
    func sendMultipleImages() async throws {
        let mock = MockTmux()
        mock.capturedPaneOutputs = [
            "❯ ",                                              // before first image
            " [Image #1] (↑ to select)\n❯ ",                   // first confirmed
            " [Image #1] (↑ to select)\n❯ ",                   // before second (still 1)
            " [Image #1] (↑ to select)\n [Image #2] (↑ to select)\n❯ ", // second confirmed
        ]

        let sender = ImageSender(tmux: mock)
        let images = [
            ImageAttachment(data: Data([0x01])),
            ImageAttachment(data: Data([0x02])),
        ]

        try await sender.sendImages(
            sessionName: "test-session",
            images: images,
            setClipboard: { _ in },
            pollInterval: .milliseconds(10),
            timeout: .seconds(5)
        )

        #expect(mock.sentBracketedPastes.count == 2)
    }

    @Test("prompt with images stages text before image paste and submits once")
    func sendPromptWithImagesStagesTextFirst() async throws {
        let mock = MockTmux()
        mock.capturedPaneOutputs = [
            "❯ prompt text",
            "❯ prompt text\n [Image #1] (↑ to select)",
        ]

        let sender = ImageSender(tmux: mock)
        let image = ImageAttachment(data: Data([0x89, 0x50]))

        try await sender.sendPromptWithImages(
            sessionName: "test-session",
            prompt: "prompt text",
            images: [image],
            setClipboard: { _ in },
            pollInterval: .milliseconds(10),
            timeout: .seconds(5)
        )

        #expect(mock.pastedTexts.map(\.text) == ["prompt text"])
        #expect(mock.sentBracketedPastes == ["test-session"])
        #expect(mock.submittedPrompts == ["test-session"])
        #expect(mock.sentPrompts.isEmpty)
    }

    @Test("prompt with inline image markers sends text and images in marker order")
    func sendPromptWithInlineImageMarkers() async throws {
        let mock = MockTmux()
        mock.capturedPaneOutputs = [
            "❯ before ",
            "❯ before \n [Image #1] (↑ to select)",
            "❯ before \n [Image #1] (↑ to select) after ",
            "❯ before \n [Image #1] (↑ to select) after \n [Image #2] (↑ to select)",
        ]

        let sender = ImageSender(tmux: mock)
        let images = [
            ImageAttachment(data: Data([0x01])),
            ImageAttachment(data: Data([0x02])),
        ]

        try await sender.sendPromptWithImages(
            sessionName: "test-session",
            prompt: "before [Image #1] after [Image #2] done",
            images: images,
            setClipboard: { _ in },
            pollInterval: .milliseconds(10),
            timeout: .seconds(5)
        )

        #expect(mock.events == [
            "text:before ",
            "image",
            "text: after ",
            "image",
            "text: done",
            "submit",
        ])
    }

    @Test("times out when image not confirmed")
    func sendImageTimeout() async throws {
        let mock = MockTmux()
        // Never returns image confirmation
        mock.capturedPaneOutputs = ["❯ "]

        let sender = ImageSender(tmux: mock)
        let image = ImageAttachment(data: Data([0x89]))

        await #expect(throws: ImageSendError.self) {
            try await sender.sendImages(
                sessionName: "test-session",
                images: [image],
                setClipboard: { _ in },
                pollInterval: .milliseconds(10),
                timeout: .milliseconds(50)
            )
        }
    }

    @Test("waits for Claude ready before sending prompt")
    func waitForClaudeReady() async throws {
        let mock = MockTmux()
        mock.capturedPaneOutputs = [
            "Starting Claude Code...",
            "Loading session...",
            "────────────────\n❯ \n────────────────",
        ]

        let sender = ImageSender(tmux: mock)
        try await sender.waitForReady(
            sessionName: "test-session",
            pollInterval: .milliseconds(10),
            timeout: .seconds(5)
        )

        #expect(mock.captureCallCount == 3)
    }

    @Test("times out waiting for Claude ready")
    func waitForClaudeReadyTimeout() async throws {
        let mock = MockTmux()
        mock.capturedPaneOutputs = ["Starting Claude Code..."]

        let sender = ImageSender(tmux: mock)
        await #expect(throws: ImageSendError.self) {
            try await sender.waitForReady(
                sessionName: "test-session",
                pollInterval: .milliseconds(10),
                timeout: .milliseconds(50)
            )
        }
    }
}

// MARK: - LaunchSession Send-Keys Mode Tests

@Suite("Launch Session Send-Keys Mode")
struct LaunchSessionSendKeysTests {

    final class RecordingTmux: TmuxManagerPort, @unchecked Sendable {
        var lastCommand: String?
        var killedSessions: [String] = []

        func createSession(name: String, path: String, command: String?) async throws {
            lastCommand = command
        }
        func killSession(name: String) async throws {
            killedSessions.append(name)
        }
        func listSessions() async throws -> [TmuxSession] { [] }
        func sendPrompt(to sessionName: String, text: String) async throws {}
        func pastePrompt(to sessionName: String, text: String) async throws {}
        func pasteText(to sessionName: String, text: String) async throws {}
        func submitPrompt(to sessionName: String) async throws {}
        func capturePane(sessionName: String) async throws -> String { "" }
        func sendBracketedPaste(to sessionName: String) async throws {}
        func findSessionForWorktree(sessions: [TmuxSession], worktreePath: String, branch: String?) -> TmuxSession? { nil }
        func isAvailable() async -> Bool { true }
    }

    @Test("launch does not include prompt in CLI command (sent via send-keys)")
    func launchWithoutPromptInCommand() async throws {
        let mock = RecordingTmux()
        let launcher = LaunchSession(tmux: mock)

        _ = try await launcher.launch(
            sessionName: "test",
            projectPath: "/tmp/project",
            prompt: "fix the bug",
            worktreeName: nil,
            shellOverride: nil,
            skipPermissions: true
        )

        let cmd = mock.lastCommand ?? ""
        #expect(cmd.contains("claude"))
        #expect(cmd.contains("--dangerously-skip-permissions"))
        #expect(!cmd.contains("fix the bug"))
    }

    @Test("launch with worktree includes --worktree flag")
    func launchWithWorktree() async throws {
        let mock = RecordingTmux()
        let launcher = LaunchSession(tmux: mock)

        _ = try await launcher.launch(
            sessionName: "test",
            projectPath: "/tmp/project",
            prompt: "",
            worktreeName: "my-feature",
            shellOverride: nil,
            skipPermissions: true
        )

        let cmd = mock.lastCommand ?? ""
        #expect(cmd.contains("--worktree my-feature"))
    }

    @Test("launch with empty worktree name uses --worktree without name")
    func launchWithAutoWorktree() async throws {
        let mock = RecordingTmux()
        let launcher = LaunchSession(tmux: mock)

        _ = try await launcher.launch(
            sessionName: "test",
            projectPath: "/tmp/project",
            prompt: "",
            worktreeName: "",
            shellOverride: nil,
            skipPermissions: false
        )

        let cmd = mock.lastCommand ?? ""
        #expect(cmd.contains("--worktree"))
        #expect(!cmd.contains("--dangerously-skip-permissions"))
    }
}
