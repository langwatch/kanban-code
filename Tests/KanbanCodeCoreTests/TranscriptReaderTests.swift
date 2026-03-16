import Testing
import Foundation
@testable import KanbanCodeCore

@Suite("TranscriptReader")
struct TranscriptReaderTests {
    func makeTempDir() throws -> String {
        let dir = NSTemporaryDirectory() + "kanban-code-transcript-test-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        return dir
    }

    func cleanup(_ dir: String) {
        try? FileManager.default.removeItem(atPath: dir)
    }

    @Test("Reads user and assistant turns")
    func readTurns() async throws {
        let dir = try makeTempDir()
        defer { cleanup(dir) }

        let path = (dir as NSString).appendingPathComponent("test.jsonl")
        try [
            #"{"type":"user","sessionId":"s1","message":{"content":"Hello"},"cwd":"/test","timestamp":"2026-01-01T00:00:00Z"}"#,
            #"{"type":"assistant","sessionId":"s1","message":{"content":[{"type":"text","text":"Hi there! How can I help?"}]}}"#,
            #"{"type":"user","sessionId":"s1","message":{"content":"Fix the bug"},"cwd":"/test"}"#,
        ].joined(separator: "\n").write(toFile: path, atomically: true, encoding: .utf8)

        let turns = try await TranscriptReader.readTurns(from: path)
        #expect(turns.count == 3)
        #expect(turns[0].role == "user")
        #expect(turns[0].textPreview == "Hello")
        #expect(turns[0].timestamp == "2026-01-01T00:00:00Z")
        #expect(turns[1].role == "assistant")
        #expect(turns[1].textPreview == "Hi there! How can I help?")
        #expect(turns[2].role == "user")
        #expect(turns[2].textPreview == "Fix the bug")
    }

    @Test("Skips non-message lines")
    func skipsNonMessages() async throws {
        let dir = try makeTempDir()
        defer { cleanup(dir) }

        let path = (dir as NSString).appendingPathComponent("test.jsonl")
        try [
            #"{"type":"file-history-snapshot","data":"lots of data"}"#,
            #"{"type":"user","sessionId":"s1","message":{"content":"Hello"},"cwd":"/test"}"#,
            #"{"type":"progress","data":"loading"}"#,
        ].joined(separator: "\n").write(toFile: path, atomically: true, encoding: .utf8)

        let turns = try await TranscriptReader.readTurns(from: path)
        #expect(turns.count == 1)
        #expect(turns[0].textPreview == "Hello")
    }

    @Test("Returns empty for nonexistent file")
    func nonexistent() async throws {
        let turns = try await TranscriptReader.readTurns(from: "/nonexistent/path.jsonl")
        #expect(turns.isEmpty)
    }

    @Test("Handles tool-use-only assistant responses")
    func toolUseOnly() async throws {
        let dir = try makeTempDir()
        defer { cleanup(dir) }

        let path = (dir as NSString).appendingPathComponent("test.jsonl")
        try [
            #"{"type":"assistant","sessionId":"s1","message":{"content":[{"type":"tool_use","name":"Read","input":{}}]}}"#,
        ].joined(separator: "\n").write(toFile: path, atomically: true, encoding: .utf8)

        let turns = try await TranscriptReader.readTurns(from: path)
        #expect(turns.count == 1)
        #expect(turns[0].textPreview == "[tool: Read]")
    }

    @Test("Line numbers (byte offsets) are stable and increasing")
    func lineNumbers() async throws {
        let dir = try makeTempDir()
        defer { cleanup(dir) }

        let path = (dir as NSString).appendingPathComponent("test.jsonl")
        try [
            #"{"type":"file-history-snapshot","data":"stuff"}"#,
            #"{"type":"user","sessionId":"s1","message":{"content":"Hello"},"cwd":"/test"}"#,
            #"{"type":"assistant","sessionId":"s1","message":{"content":[{"type":"text","text":"Hi"}]}}"#,
        ].joined(separator: "\n").write(toFile: path, atomically: true, encoding: .utf8)

        let turns = try await TranscriptReader.readTurns(from: path)
        #expect(turns[0].lineNumber > 0) // byte offset, not sequential
        #expect(turns[1].lineNumber > turns[0].lineNumber) // strictly increasing
    }

    // MARK: - Rich content block tests

    @Test("Parses Bash tool_use blocks")
    func bashToolUse() async throws {
        let dir = try makeTempDir()
        defer { cleanup(dir) }

        let path = (dir as NSString).appendingPathComponent("test.jsonl")
        try [
            #"{"type":"assistant","sessionId":"s1","message":{"content":[{"type":"tool_use","name":"Bash","input":{"command":"ls -la","description":"List files"}}]}}"#,
        ].joined(separator: "\n").write(toFile: path, atomically: true, encoding: .utf8)

        let turns = try await TranscriptReader.readTurns(from: path)
        #expect(turns.count == 1)
        #expect(turns[0].contentBlocks.count == 1)
        let block = turns[0].contentBlocks[0]
        if case .toolUse(let name, let input, _) = block.kind {
            #expect(name == "Bash")
            #expect(input["command"] == "ls -la")
            #expect(input["description"] == "List files")
        } else {
            Issue.record("Expected toolUse block")
        }
        #expect(block.text == "Bash(List files)")
    }

    @Test("Parses Read tool_use blocks")
    func readToolUse() async throws {
        let dir = try makeTempDir()
        defer { cleanup(dir) }

        let path = (dir as NSString).appendingPathComponent("test.jsonl")
        try [
            #"{"type":"assistant","sessionId":"s1","message":{"content":[{"type":"tool_use","name":"Read","input":{"file_path":"/Users/test/src/main.swift"}}]}}"#,
        ].joined(separator: "\n").write(toFile: path, atomically: true, encoding: .utf8)

        let turns = try await TranscriptReader.readTurns(from: path)
        let block = turns[0].contentBlocks[0]
        if case .toolUse(let name, let input, _) = block.kind {
            #expect(name == "Read")
            #expect(input["file_path"] == "/Users/test/src/main.swift")
        } else {
            Issue.record("Expected toolUse block")
        }
        #expect(block.text.contains("main.swift"))
    }

    @Test("Parses Edit tool_use blocks")
    func editToolUse() async throws {
        let dir = try makeTempDir()
        defer { cleanup(dir) }

        let path = (dir as NSString).appendingPathComponent("test.jsonl")
        try [
            #"{"type":"assistant","sessionId":"s1","message":{"content":[{"type":"tool_use","name":"Edit","input":{"file_path":"/src/app.swift","old_string":"foo","new_string":"bar"}}]}}"#,
        ].joined(separator: "\n").write(toFile: path, atomically: true, encoding: .utf8)

        let turns = try await TranscriptReader.readTurns(from: path)
        let block = turns[0].contentBlocks[0]
        if case .toolUse(let name, let input, _) = block.kind {
            #expect(name == "Edit")
            #expect(input["file_path"] == "/src/app.swift")
        } else {
            Issue.record("Expected toolUse block")
        }
        #expect(block.text.contains("app.swift"))
    }

    @Test("Parses multiple content blocks in one message")
    func multipleBlocks() async throws {
        let dir = try makeTempDir()
        defer { cleanup(dir) }

        let path = (dir as NSString).appendingPathComponent("test.jsonl")
        try [
            #"{"type":"assistant","sessionId":"s1","message":{"content":[{"type":"text","text":"Let me read the file."},{"type":"tool_use","name":"Read","input":{"file_path":"/test.swift"}}]}}"#,
        ].joined(separator: "\n").write(toFile: path, atomically: true, encoding: .utf8)

        let turns = try await TranscriptReader.readTurns(from: path)
        #expect(turns[0].contentBlocks.count == 2)
        if case .text = turns[0].contentBlocks[0].kind {
            #expect(turns[0].contentBlocks[0].text == "Let me read the file.")
        } else {
            Issue.record("Expected text block")
        }
        if case .toolUse(let name, _, _) = turns[0].contentBlocks[1].kind {
            #expect(name == "Read")
        } else {
            Issue.record("Expected toolUse block")
        }
    }

    @Test("Parses tool_result blocks in user messages")
    func toolResultBlocks() async throws {
        let dir = try makeTempDir()
        defer { cleanup(dir) }

        let path = (dir as NSString).appendingPathComponent("test.jsonl")
        try [
            #"{"type":"user","sessionId":"s1","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"toolu_123","content":"file contents here\nline 2\nline 3"}]}}"#,
        ].joined(separator: "\n").write(toFile: path, atomically: true, encoding: .utf8)

        let turns = try await TranscriptReader.readTurns(from: path)
        #expect(turns.count == 1)
        #expect(turns[0].contentBlocks.count == 1)
        if case .toolResult(_, let toolUseId) = turns[0].contentBlocks[0].kind {
            // Full content preserved (not truncated), toolUseId threaded
            #expect(turns[0].contentBlocks[0].text == "file contents here\nline 2\nline 3")
            #expect(toolUseId == "toolu_123")
        } else {
            Issue.record("Expected toolResult block")
        }
    }

    @Test("Mixed text and tool_use — textPreview only from text blocks")
    func textPreviewFromTextOnly() async throws {
        let dir = try makeTempDir()
        defer { cleanup(dir) }

        let path = (dir as NSString).appendingPathComponent("test.jsonl")
        try [
            #"{"type":"assistant","sessionId":"s1","message":{"content":[{"type":"text","text":"I will fix this."},{"type":"tool_use","name":"Edit","input":{"file_path":"/test.swift"}}]}}"#,
        ].joined(separator: "\n").write(toFile: path, atomically: true, encoding: .utf8)

        let turns = try await TranscriptReader.readTurns(from: path)
        #expect(turns[0].textPreview == "I will fix this.")
        // textPreview should NOT contain "Edit" tool name
        #expect(!turns[0].textPreview.contains("Edit"))
    }

    @Test("Parses thinking blocks")
    func thinkingBlocks() async throws {
        let dir = try makeTempDir()
        defer { cleanup(dir) }

        let path = (dir as NSString).appendingPathComponent("test.jsonl")
        try [
            #"{"type":"assistant","sessionId":"s1","message":{"content":[{"type":"thinking","thinking":"Let me analyze this..."},{"type":"text","text":"Here is my answer."}]}}"#,
        ].joined(separator: "\n").write(toFile: path, atomically: true, encoding: .utf8)

        let turns = try await TranscriptReader.readTurns(from: path)
        #expect(turns[0].contentBlocks.count == 2)
        if case .thinking = turns[0].contentBlocks[0].kind {
            #expect(turns[0].contentBlocks[0].text == "Let me analyze this...")
        } else {
            Issue.record("Expected thinking block")
        }
        #expect(turns[0].textPreview == "Here is my answer.")
    }

    @Test("Grep tool input extraction")
    func grepToolInput() async throws {
        let dir = try makeTempDir()
        defer { cleanup(dir) }

        let path = (dir as NSString).appendingPathComponent("test.jsonl")
        try [
            #"{"type":"assistant","sessionId":"s1","message":{"content":[{"type":"tool_use","name":"Grep","input":{"pattern":"TODO","path":"/Users/test/src/"}}]}}"#,
        ].joined(separator: "\n").write(toFile: path, atomically: true, encoding: .utf8)

        let turns = try await TranscriptReader.readTurns(from: path)
        let block = turns[0].contentBlocks[0]
        if case .toolUse(let name, let input, _) = block.kind {
            #expect(name == "Grep")
            #expect(input["pattern"] == "TODO")
            #expect(input["path"] == "/Users/test/src/")
        } else {
            Issue.record("Expected toolUse block")
        }
        #expect(block.text.contains("\"TODO\""))
    }

    @Test("Existing contentBlocks field defaults to empty for backward compat")
    func backwardCompat() async throws {
        let turn = ConversationTurn(index: 0, lineNumber: 1, role: "user", textPreview: "hello")
        #expect(turn.contentBlocks.isEmpty)
    }

    @Test("Path shortening for display")
    func pathShortening() {
        let short = TranscriptReader.shortenPath("/Users/test/Projects/remote/kanban/Sources/Kanban/App.swift")
        #expect(short == ".../Sources/Kanban/App.swift")

        let alreadyShort = TranscriptReader.shortenPath("/src/main.swift")
        #expect(alreadyShort == "/src/main.swift")
    }

    // MARK: - Metadata filtering

    @Test("Hides caveat messages from history")
    func hidesCaveatFromHistory() async throws {
        let dir = try makeTempDir()
        defer { cleanup(dir) }

        let path = (dir as NSString).appendingPathComponent("test.jsonl")
        try [
            #"{"type":"user","isMeta":true,"sessionId":"s1","message":{"content":"<local-command-caveat>wrapped</local-command-caveat>"},"cwd":"/test"}"#,
            #"{"type":"user","sessionId":"s1","message":{"content":"Real prompt"},"cwd":"/test"}"#,
            #"{"type":"assistant","sessionId":"s1","message":{"content":[{"type":"text","text":"OK"}]}}"#,
        ].joined(separator: "\n").write(toFile: path, atomically: true, encoding: .utf8)

        let turns = try await TranscriptReader.readTurns(from: path)
        // Caveat message should be completely hidden — only 2 turns
        #expect(turns.count == 2)
        #expect(turns[0].role == "user")
        #expect(turns[0].textPreview == "Real prompt")
        #expect(turns[1].role == "assistant")
    }

    @Test("Shows /clear command cleanly in history")
    func showsCommandCleanly() async throws {
        let dir = try makeTempDir()
        defer { cleanup(dir) }

        let path = (dir as NSString).appendingPathComponent("test.jsonl")
        try [
            #"{"type":"user","sessionId":"s1","message":{"content":"<command-name>/clear</command-name><command-message></command-message><command-args></command-args>"},"cwd":"/test"}"#,
            #"{"type":"user","sessionId":"s1","message":{"content":"Next prompt"},"cwd":"/test"}"#,
        ].joined(separator: "\n").write(toFile: path, atomically: true, encoding: .utf8)

        let turns = try await TranscriptReader.readTurns(from: path)
        #expect(turns.count == 2)
        #expect(turns[0].textPreview == "/clear")
        #expect(turns[1].textPreview == "Next prompt")
    }

    @Test("Shows command stdout as assistant-style turn in history")
    func showsStdoutAsAssistant() async throws {
        let dir = try makeTempDir()
        defer { cleanup(dir) }

        let path = (dir as NSString).appendingPathComponent("test.jsonl")
        try [
            #"{"type":"user","sessionId":"s1","message":{"content":"<local-command-stdout>file contents here</local-command-stdout>"},"cwd":"/test"}"#,
        ].joined(separator: "\n").write(toFile: path, atomically: true, encoding: .utf8)

        let turns = try await TranscriptReader.readTurns(from: path)
        #expect(turns.count == 1)
        #expect(turns[0].role == "assistant")
        #expect(turns[0].textPreview == "file contents here")
    }

    // MARK: - Tail reading stability tests

    @Test("readTail returns stable lineNumbers (byte offsets) across reloads")
    func stableLineNumbers() async throws {
        let dir = try makeTempDir()
        defer { cleanup(dir) }

        let path = (dir as NSString).appendingPathComponent("test.jsonl")
        try [
            #"{"type":"user","sessionId":"s1","message":{"role":"user","content":"hello"}}"#,
            #"{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"world"}]}}"#,
            #"{"type":"user","sessionId":"s1","message":{"role":"user","content":"how are you"}}"#,
            #"{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"fine"}]}}"#,
        ].joined(separator: "\n").write(toFile: path, atomically: true, encoding: .utf8)

        let result1 = try await TranscriptReader.readTail(from: path, maxTurns: 10)
        let result2 = try await TranscriptReader.readTail(from: path, maxTurns: 10)

        // Same file, same content → same lineNumbers
        #expect(result1.turns.count == result2.turns.count)
        for (t1, t2) in zip(result1.turns, result2.turns) {
            #expect(t1.lineNumber == t2.lineNumber, "lineNumber should be stable across reloads")
        }
    }

    @Test("readTail appending new turns does not duplicate existing ones")
    func noDuplicatesOnAppend() async throws {
        let dir = try makeTempDir()
        defer { cleanup(dir) }

        let path = (dir as NSString).appendingPathComponent("test.jsonl")
        let line1 = #"{"type":"user","sessionId":"s1","message":{"role":"user","content":"hello"}}"#
        let line2 = #"{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"world"}]}}"#
        try [line1, line2].joined(separator: "\n").write(toFile: path, atomically: true, encoding: .utf8)

        let result1 = try await TranscriptReader.readTail(from: path, maxTurns: 10)
        #expect(result1.turns.count == 2)
        let lastLineNumber = result1.turns.last!.lineNumber

        // Append a new turn
        let line3 = #"{"type":"user","sessionId":"s1","message":{"role":"user","content":"more"}}"#
        let handle = try FileHandle(forWritingTo: URL(fileURLWithPath: path))
        handle.seekToEndOfFile()
        handle.write(Data(("\n" + line3).utf8))
        try handle.close()

        let result2 = try await TranscriptReader.readTail(from: path, maxTurns: 10)
        // New turns should have lineNumber > lastLineNumber
        let newTurns = result2.turns.filter { $0.lineNumber > lastLineNumber }
        #expect(newTurns.count == 1, "Should find exactly 1 new turn")
        #expect(newTurns[0].textPreview == "more")
    }

    @Test("readTail with maxTurns limits results from bottom")
    func tailLimiting() async throws {
        let dir = try makeTempDir()
        defer { cleanup(dir) }

        let path = (dir as NSString).appendingPathComponent("test.jsonl")
        var lines: [String] = []
        for i in 0..<20 {
            lines.append(#"{"type":"user","sessionId":"s1","message":{"role":"user","content":"msg \#(i)"}}"#)
            lines.append(#"{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"reply \#(i)"}]}}"#)
        }
        try lines.joined(separator: "\n").write(toFile: path, atomically: true, encoding: .utf8)

        let result = try await TranscriptReader.readTail(from: path, maxTurns: 4)
        #expect(result.turns.count == 4)
        #expect(result.hasMore == true)
        // Should be the LAST 4 turns
        #expect(result.turns.last!.textPreview == "reply 19")
    }

    // MARK: - Special tool parsing tests

    @Test("Parses EnterPlanMode as planModeEnter kind")
    func enterPlanMode() async throws {
        let dir = try makeTempDir()
        defer { cleanup(dir) }
        let path = (dir as NSString).appendingPathComponent("test.jsonl")
        try #"{"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","id":"toolu_1","name":"EnterPlanMode","input":{}}]}}"#
            .write(toFile: path, atomically: true, encoding: .utf8)
        let turns = try await TranscriptReader.readTurns(from: path)
        #expect(turns.count == 1)
        if case .planModeEnter = turns[0].contentBlocks[0].kind {
            #expect(turns[0].contentBlocks[0].text == "Entered plan mode")
        } else {
            Issue.record("Expected planModeEnter kind")
        }
    }

    @Test("Parses ExitPlanMode with plan content")
    func exitPlanMode() async throws {
        let dir = try makeTempDir()
        defer { cleanup(dir) }
        let path = (dir as NSString).appendingPathComponent("test.jsonl")
        let json = "{\"type\":\"assistant\",\"message\":{\"role\":\"assistant\",\"content\":[{\"type\":\"tool_use\",\"id\":\"toolu_2\",\"name\":\"ExitPlanMode\",\"input\":{\"plan\":\"# My Plan\"}}]}}"
        try json.write(toFile: path, atomically: true, encoding: .utf8)
        let turns = try await TranscriptReader.readTurns(from: path)
        #expect(turns.count == 1)
        if case .planModeExit(let plan) = turns[0].contentBlocks[0].kind {
            #expect(plan.contains("My Plan"))
        } else {
            Issue.record("Expected planModeExit kind")
        }
    }

    @Test("Parses AskUserQuestion with options")
    func askUserQuestion() async throws {
        let dir = try makeTempDir()
        defer { cleanup(dir) }
        let path = (dir as NSString).appendingPathComponent("test.jsonl")
        let json = #"{"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","id":"toolu_3","name":"AskUserQuestion","input":{"questions":[{"question":"Pick one","header":"Choice","options":[{"label":"Option A","description":"First option"},{"label":"Option B"}],"multiSelect":false}]}}]}}"#
        try json.write(toFile: path, atomically: true, encoding: .utf8)
        let turns = try await TranscriptReader.readTurns(from: path)
        #expect(turns.count == 1)
        if case .askUserQuestion(let questions, let id) = turns[0].contentBlocks[0].kind {
            #expect(questions.count == 1)
            #expect(questions[0].header == "Choice")
            #expect(questions[0].question == "Pick one")
            #expect(questions[0].options.count == 2)
            #expect(questions[0].options[0].label == "Option A")
            #expect(questions[0].options[0].description == "First option")
            #expect(questions[0].options[1].label == "Option B")
            #expect(questions[0].multiSelect == false)
            #expect(id == "toolu_3")
        } else {
            Issue.record("Expected askUserQuestion kind")
        }
    }

    @Test("Parses Agent tool_use as agentCall kind")
    func agentCall() async throws {
        let dir = try makeTempDir()
        defer { cleanup(dir) }
        let path = (dir as NSString).appendingPathComponent("test.jsonl")
        try #"{"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","id":"toolu_4","name":"Agent","input":{"description":"Search codebase","subagent_type":"Explore","prompt":"Find all uses of foo"}}]}}"#
            .write(toFile: path, atomically: true, encoding: .utf8)
        let turns = try await TranscriptReader.readTurns(from: path)
        #expect(turns.count == 1)
        if case .agentCall(let desc, let subType, let id) = turns[0].contentBlocks[0].kind {
            #expect(desc == "Search codebase")
            #expect(subType == "Explore")
            #expect(id == "toolu_4")
        } else {
            Issue.record("Expected agentCall kind")
        }
    }

    @Test("Parses Bash with run_in_background flag")
    func backgroundBash() async throws {
        let dir = try makeTempDir()
        defer { cleanup(dir) }
        let path = (dir as NSString).appendingPathComponent("test.jsonl")
        try #"{"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","id":"toolu_5","name":"Bash","input":{"command":"sleep 10","run_in_background":true}}]}}"#
            .write(toFile: path, atomically: true, encoding: .utf8)
        let turns = try await TranscriptReader.readTurns(from: path)
        #expect(turns.count == 1)
        let block = turns[0].contentBlocks[0]
        #expect(block.isBackground == true)
        if case .toolUse(let name, _, _) = block.kind {
            #expect(name == "Bash")
        } else {
            Issue.record("Expected toolUse kind for Bash")
        }
    }

    @Test("Regular Bash is not background")
    func regularBash() async throws {
        let dir = try makeTempDir()
        defer { cleanup(dir) }
        let path = (dir as NSString).appendingPathComponent("test.jsonl")
        try #"{"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","id":"toolu_6","name":"Bash","input":{"command":"ls"}}]}}"#
            .write(toFile: path, atomically: true, encoding: .utf8)
        let turns = try await TranscriptReader.readTurns(from: path)
        #expect(turns[0].contentBlocks[0].isBackground == false)
    }
}
