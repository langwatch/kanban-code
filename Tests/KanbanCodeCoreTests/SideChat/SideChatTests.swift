import Foundation
import Testing
import KanbanCodeRemoteKit
@testable import KanbanCodeCore

@Suite("Side chat: catch-up scope, index and prompts")
struct CatchUpScopeTests {
    private func session() -> TranscriptBuilder {
        var t = TranscriptBuilder()
        t.user("an older request")                                                 // 0
        t.assistant("an older answer")                                             // 1
        t.user("fix the login redirect and tell me when it is merged")             // 2
        t.toolCall("Bash")                                                         // 3, 4
        t.assistant(String(repeating: "The redirect is fixed. ", count: 40))       // 5
        t.user("[Message from @reviewer]: please add a changelog line")            // 6
        t.assistant("Added the changelog line.")                                   // 7
        t.user("<task-notification>\n<task-id>b1</task-id>\n<status>completed</status>\n<summary>CI finished</summary>\n</task-notification>",
               extra: ["origin": ["kind": "task-notification"]])                   // 8
        t.assistant("CI is green.")                                                // 9
        return t
    }

    @Test func theIndexStartsAtHisLastMessageAndNamesEachSender() async throws {
        let t = session()
        let path = try t.write()
        let scope = try await CatchUpScope.read(transcriptPath: path, sessionId: nil, record: [], rushRecord: nil, queuedTexts: [])
        #expect(scope.since?.text == "fix the login redirect and tell me when it is merged")
        #expect(scope.since?.offset == t.offset(2))
        #expect(scope.refs.first?.ref == "m1")
        #expect(scope.refs.first?.role == "you")
        #expect(scope.refs.first?.offset == t.offset(2))
        // Nothing from before his message, and no tool calls.
        #expect(!scope.refs.contains { $0.preview.contains("older") })
        #expect(!scope.refs.contains { $0.preview.contains("ls") })
        let roles = scope.refs.map(\.role)
        #expect(roles.contains("message from @reviewer"))
        #expect(roles.filter { $0 == "assistant" }.count == 3)
        // Every ref points at a row of the chat: the offset of a turn.
        let offsets = Set([2, 5, 6, 7, 8, 9].map(t.offset))
        #expect(scope.refs.allSatisfy { offsets.contains($0.offset) })
        // The delivered message reads without its marker; the long report shows its length.
        #expect(scope.refs.first { $0.role == "message from @reviewer" }?.preview == "please add a changelog line")
        let report = try #require(scope.refs.first { $0.offset == t.offset(5) })
        #expect(report.preview.hasPrefix("(919 characters) The redirect is fixed."))
        #expect(report.preview.hasSuffix("…"))
    }

    @Test func aLongStretchWithoutHisMessageIsCaughtUpFromItsRecentEndOnly() async throws {
        var t = TranscriptBuilder()
        t.user("fix the login redirect")                       // 0: beyond the window
        for i in 0..<40 { t.assistant("step \(i) " + String(repeating: "w", count: 2_000)) }
        let path = try t.write()
        let size = try #require(try FileManager.default.attributesOfItem(atPath: path)[.size] as? Int)
        let window = 10_000

        #expect(HumanMessageFinder.find(transcriptPath: path, scanBytes: window) == nil)
        let scope = try await CatchUpScope.read(
            transcriptPath: path, sessionId: nil, record: [], rushRecord: nil, queuedTexts: [], scanBytes: window)
        #expect(scope.since == nil)
        #expect(!scope.coversWholeSession)
        #expect(!scope.refs.isEmpty)
        #expect(scope.refs.allSatisfy { $0.offset >= size - window })
        #expect(!scope.refs.contains { $0.preview.contains("login redirect") })
        let prompt = SideChatPrompt.catchUp(humanText: nil, index: CatchUpIndex.text(scope.refs), fromStart: scope.coversWholeSession)
        #expect(!prompt.contains("since it started"))
    }

    @Test func aSessionTheHumanNeverWroteInIsCaughtUpFromItsStart() async throws {
        var t = TranscriptBuilder()
        t.user("You are running as subagent card card_9.\nPost the summary")
        t.assistant("posted")
        let path = try t.write()
        let scope = try await CatchUpScope.read(transcriptPath: path, sessionId: nil, record: [], rushRecord: nil, queuedTexts: [])
        #expect(scope.since == nil)
        #expect(scope.refs.count == 2)
        #expect(scope.refs[0].role == "message from the parent agent that started this subagent")
        let prompt = SideChatPrompt.catchUp(humanText: nil, index: CatchUpIndex.text(scope.refs))
        #expect(prompt.contains("in this session since it started"))
    }

    @Test func theIndexReadsOneMessagePerLine() {
        let utc = TimeZone(identifier: "UTC")!
        let day = ISO8601DateFormatter().date(from: "2026-03-01T14:02:00Z")!
        let refs = [
            RemoteSideChatRef(ref: "m1", offset: 10, role: "you", at: day, preview: "fix the login"),
            RemoteSideChatRef(ref: "m2", offset: 20, role: "assistant", at: day.addingTimeInterval(300), preview: "on it"),
            RemoteSideChatRef(ref: "m3", offset: 30, role: "notification", at: day.addingTimeInterval(86_400), preview: "CI finished"),
            RemoteSideChatRef(ref: "m4", offset: 40, role: "assistant", at: nil, preview: "done"),
        ]
        #expect(CatchUpIndex.text(refs, timeZone: utc) == """
            [m1] 14:02 you: fix the login
            [m2] 14:07 assistant: on it
            [m3] Mar 2 14:02 notification: CI finished
            [m4] assistant: done
            """)
    }

    @Test func aVeryLongSessionKeepsItsStartAndItsEnd() {
        let turns = (0..<1000).map { ConversationTurn(index: $0, lineNumber: $0 * 10, role: "assistant", textPreview: "message \($0)") }
        let refs = CatchUpIndex.build(turns: turns, humanOffset: nil)
        #expect(refs.count == CatchUpIndex.head + CatchUpIndex.tail)
        #expect(refs.first?.preview == "message 0")
        #expect(refs.last?.preview == "message 999")
        #expect(refs.last?.ref == "m\(CatchUpIndex.head + CatchUpIndex.tail)")
    }

    @Test func theCatchUpPromptQuotesHisMessageAndAsksForCitedJSONLines() {
        let long = String(repeating: "word ", count: 80)
        let prompt = SideChatPrompt.catchUp(humanText: "line one\nline two " + long, index: "[m1] 14:02 you: line one")
        #expect(prompt.contains("since I sent this message: \"line one line two word"))
        #expect(prompt.contains("…\""))
        #expect(SideChatPrompt.quote(long).count == SideChatPrompt.quoteLimit + 1)
        #expect(prompt.contains("[m1] 14:02 you: line one"))
        for section in ["\"asked\"", "\"status\"", "\"report\"", "\"facts\"", "\"waiting\"", "\"blocked\"", "\"other\""] {
            #expect(prompt.contains(section))
        }
        #expect(prompt.contains("Do not use tools"))
        #expect(!prompt.contains("—"))
        #expect(SideChatPrompt.catchUp(humanText: "x", index: "").contains("(no messages since then)"))
    }

    @Test func aSideQuestionCarriesTheSideChatSoFar() {
        let first = SideChatPrompt.btw(question: "  why did CI fail?  ")
        #expect(first.hasSuffix("Question: why did CI fail?"))
        #expect(!first.contains("Earlier in this side chat"))
        let followUp = SideChatPrompt.btw(question: "and now?", history: [RemoteSideChatExchange(question: "why did CI fail?", answer: "A flaky test.")])
        #expect(followUp.contains("Earlier in this side chat:\nI asked: why did CI fail?\nYou answered: A flaky test.\n\nQuestion: and now?"))
    }
}

@Suite("Side chat: the forked run")
struct SideChatRunnerTests {
    @Test func theForkReadsTheSessionAndSavesNothing() {
        let job = SideChatJob(sessionId: "sid-1", cwd: "/tmp/p", prompt: "q", model: "claude-opus-5-5[1m]")
        let args = ClaudeSideChatRunner.arguments(job: job, settingsPath: "/tmp/s.json")
        #expect(args.starts(with: ["-p", "--resume", "sid-1", "--fork-session", "--no-session-persistence"]))
        #expect(args.contains("--include-partial-messages"))
        #expect(Array(args.suffix(4)) == ["--settings", "/tmp/s.json", "--model", "claude-opus-5-5[1m]"])
        #expect(!ClaudeSideChatRunner.arguments(job: SideChatJob(sessionId: "s", cwd: "/", prompt: ""), settingsPath: "x").contains("--model"))
        // The settings refuse every tool call and are valid JSON.
        let settings = try? JSONSerialization.jsonObject(with: Data(ClaudeSideChatRunner.settings.utf8)) as? [String: Any]
        let hooks = (settings?["hooks"] as? [String: Any])?["PreToolUse"] as? [[String: Any]]
        #expect(hooks?.first?["matcher"] as? String == "*")
        #expect(ClaudeSideChatRunner.settings.contains("permissionDecision\\\":\\\"deny"))
    }

    @Test func theForkRunsOnTheLoggedInPlanNeverAnAPIKey() {
        let base = [
            "PATH": "/usr/bin", "ANTHROPIC_API_KEY": "sk-test", "ANTHROPIC_AUTH_TOKEN": "t",
            "KANBAN_CARD_ID": "card_x", "CLAUDE_CODE_SESSION_ID": "parent", "RUSH_SESSION": "abc",
            "TMPDIR": "/Users/u/.config/rush/sessions/abc/tmp", "CLAUDE_CONFIG_DIR": "/somewhere/else",
        ]
        let plain = ClaudeSideChatRunner.environment(base: base, configDirectory: nil)
        #expect(plain["ANTHROPIC_API_KEY"] == nil)
        #expect(plain["ANTHROPIC_AUTH_TOKEN"] == nil)
        #expect(plain["KANBAN_CARD_ID"] == nil)
        #expect(plain["CLAUDE_CODE_SESSION_ID"] == nil)
        #expect(plain["RUSH_SESSION"] == nil)
        #expect(plain["TMPDIR"] == nil)
        #expect(plain["CLAUDE_CONFIG_DIR"] == nil)
        #expect(plain["PATH"] == "/usr/bin")
        #expect(plain[ClaudeSideChatRunner.environmentMarker] == "1")
        let rush = ClaudeSideChatRunner.environment(base: base, configDirectory: "/Users/u/.config/rush/claude/acct")
        #expect(rush["CLAUDE_CONFIG_DIR"] == "/Users/u/.config/rush/claude/acct")
    }

    @Test func theHookScriptLeavesAForkOutOfTheBoard() throws {
        let home = NSTemporaryDirectory() + "hook-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: home) }
        let script = home + "/hook.sh"
        try HookManager.install(claudeSettingsPath: home + "/settings.json", hookScriptPath: script)
        let content = try String(contentsOfFile: script, encoding: .utf8)
        #expect(content.contains("KANBAN_SIDE_CHAT"))
    }

    @Test func theAnswerStreamsFromClaudeCodeOutput() {
        var stream = SideChatStream()
        func line(_ object: [String: Any]) -> Data {
            try! JSONSerialization.data(withJSONObject: object) + Data([0x0A])
        }
        func delta(_ text: String) -> Data {
            line(["type": "stream_event", "parent_tool_use_id": NSNull(),
                  "event": ["type": "content_block_delta", "index": 1, "delta": ["type": "text_delta", "text": text]]])
        }
        do { let grew = stream.consume(line(["type": "system", "subtype": "init"])); #expect(!grew) }
        do { let grew = stream.consume(line(["type": "stream_event", "event": ["type": "content_block_delta", "delta": ["type": "thinking_delta", "thinking": "hm"]]])); #expect(!grew) }
        // A line split across two reads.
        let first = delta("Tests ")
        do { let grew = stream.consume(first.prefix(20)); #expect(!grew) }
        do { let grew = stream.consume(first.dropFirst(20)); #expect(grew) }
        #expect(stream.text == "Tests ")
        do { let grew = stream.consume(delta("are green.")); #expect(grew) }
        #expect(stream.text == "Tests are green.")
        // The whole message repeats what streamed: it is not added twice.
        do { let grew = stream.consume(line(["type": "assistant", "message": ["content": [["type": "text", "text": "Tests are green."]]]])); #expect(!grew) }
        do { let grew = stream.consume(line(["type": "stream_event", "event": ["type": "message_stop"]])); #expect(!grew) }
        do { let grew = stream.consume(line(["type": "result", "subtype": "success", "is_error": false, "result": "Tests are green."])); #expect(!grew) }
        stream.finish()
        #expect(stream.answer == "Tests are green.")
        #expect(stream.failure == nil)
    }

    @Test func aRunThatFailsReportsWhy() {
        var stream = SideChatStream()
        _ = stream.consume(Data(#"{"type":"result","subtype":"error_during_execution","is_error":true,"result":"No conversation found with session ID: x"}"#.utf8))
        stream.finish()
        #expect(stream.answer == nil)
        #expect(stream.failure == "No conversation found with session ID: x")

        // Without partial messages the answer comes from the whole message, or the result.
        var whole = SideChatStream()
        _ = whole.consume(Data((#"{"type":"assistant","message":{"content":[{"type":"text","text":"All good."}]}}"# + "\n").utf8))
        #expect(whole.answer == "All good.")
        var onlyResult = SideChatStream()
        _ = onlyResult.consume(Data((#"{"type":"result","is_error":false,"result":"From the result."}"# + "\n").utf8))
        #expect(onlyResult.answer == "From the result.")
    }

    @Test func theSessionFolderIsTheOneClaudeCodeFiledItUnder() throws {
        let root = NSTemporaryDirectory() + "side-folder-\(UUID().uuidString)"
        let project = root + "/work/my.project"
        let worktree = project + "/.claude/worktrees/feat"
        try FileManager.default.createDirectory(atPath: worktree, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: root) }
        let slug = SessionFileMover.encodeProjectPath(worktree)
        let projects = root + "/config/projects/" + slug
        try FileManager.default.createDirectory(atPath: projects, withIntermediateDirectories: true)
        let transcript = projects + "/sid.jsonl"
        // The first record names a folder that is gone; the card's worktree matches the directory.
        try (#"{"type":"user","cwd":"/gone/away","message":{"role":"user","content":"hi"}}"# + "\n").write(toFile: transcript, atomically: true, encoding: .utf8)
        #expect(SideChatSession.recordedFolder(transcriptPath: transcript) == "/gone/away")
        #expect(SideChatSession.folder(transcriptPath: transcript, candidates: [project, worktree]) == worktree)
        #expect(SideChatSession.folder(transcriptPath: transcript, candidates: ["/gone/too"]) == nil)
        // The folder the transcript names wins when it matches.
        try (#"{"type":"user","cwd":"\#(worktree)","message":{"role":"user","content":"hi"}}"# + "\n").write(toFile: transcript, atomically: true, encoding: .utf8)
        #expect(SideChatSession.folder(transcriptPath: transcript, candidates: [project]) == worktree)
    }

    @Test func theForkUsesTheLoginOfTheSession() throws {
        let home = NSTemporaryDirectory() + "side-home-\(UUID().uuidString)"
        defer { try? FileManager.default.removeItem(atPath: home) }
        let standard = home + "/.claude/projects/-p/sid.jsonl"
        #expect(SideChatSession.claudeConfigDirectory(transcriptPath: standard, isRush: false, home: home) == nil)
        // No rush account folder on this machine: a rush session uses ~/.claude too.
        #expect(SideChatSession.claudeConfigDirectory(transcriptPath: standard, isRush: true, home: home) == nil)
        let other = home + "/accounts/work/projects/-p/sid.jsonl"
        #expect(SideChatSession.claudeConfigDirectory(transcriptPath: other, isRush: false, home: home) == home + "/accounts/work")
        // rush runs Claude Code under the account it is using.
        let account = home + "/.config/rush/claude/acct-1"
        try FileManager.default.createDirectory(atPath: account, withIntermediateDirectories: true)
        try "acct-1\n".write(toFile: home + "/.config/rush/claude/using", atomically: true, encoding: .utf8)
        #expect(SideChatSession.claudeConfigDirectory(transcriptPath: standard, isRush: true, home: home) == account)
        #expect(SideChatSession.claudeConfigDirectory(transcriptPath: standard, isRush: false, home: home) == nil)
    }
}

private final class FakeSideChatRunner: SideChatRunning, @unchecked Sendable {
    let chunks: [String]
    let failure: String?
    private let lock = NSLock()
    private(set) var jobs: [SideChatJob] = []
    private(set) var cancelled: [String] = []
    var gate: AsyncStream<Void>?

    init(chunks: [String], failure: String? = nil) {
        self.chunks = chunks
        self.failure = failure
    }

    func run(id: String, _ job: SideChatJob, onText: @escaping @Sendable (String) -> Void) async throws -> String {
        lock.withLock { jobs.append(job) }
        var text = ""
        for chunk in chunks {
            text += chunk
            onText(text)
            try await Task.sleep(for: .milliseconds(20))
        }
        if let gate { for await _ in gate { break } }
        if let failure { throw SideChatFailed(failure) }
        return text
    }

    func cancel(id: String) async { lock.withLock { cancelled.append(id) } }
}

@Suite("Side chat: runs of a master")
struct SideChatServiceTests {
    private func wait(_ service: SideChatService, _ id: String, until done: (RemoteSideChatRun) -> Bool) async -> RemoteSideChatRun? {
        for _ in 0..<200 {
            if let run = await service.run(id: id), done(run) { return run }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return await service.run(id: id)
    }

    @Test func aRunIsReturnedAtOnceAndFillsAsTheAnswerStreams() async {
        let runner = FakeSideChatRunner(chunks: ["Tests ", "are ", "green."])
        let service = SideChatService(runner: runner)
        let since = RemoteSideChatSince(text: "fix it", offset: 10)
        let refs = [RemoteSideChatRef(ref: "m1", offset: 10, role: "you", preview: "fix it")]
        let started = await service.start(cardId: "card_1", kind: .catchup, since: since, refs: refs,
                                          job: SideChatJob(sessionId: "s", cwd: "/tmp", prompt: "p"))
        #expect(started.state == .running)
        #expect(started.text.isEmpty)
        #expect(started.since == since)
        #expect(started.refs == refs)
        let done = await wait(service, started.id) { $0.state == .done }
        #expect(done?.text == "Tests are green.")
        #expect(done?.kind == .catchup)
        #expect(done?.refs == refs)
        #expect(runner.jobs.map(\.prompt) == ["p"])
    }

    @Test func aRunThatFailsKeepsTheReason() async {
        let service = SideChatService(runner: FakeSideChatRunner(chunks: [], failure: "The session's folder is gone: /x"))
        let started = await service.start(cardId: "card_1", kind: .btw, job: SideChatJob(sessionId: "s", cwd: "/x", prompt: "p"))
        let failed = await wait(service, started.id) { $0.state == .failed }
        #expect(failed?.state == .failed)
        #expect(failed?.error == "The session's folder is gone: /x")
    }

    @Test func cancellingStopsTheRunAndForgetsIt() async {
        let runner = FakeSideChatRunner(chunks: ["partial"])
        runner.gate = AsyncStream { _ in }
        let service = SideChatService(runner: runner)
        let started = await service.start(cardId: "card_1", kind: .btw, job: SideChatJob(sessionId: "s", cwd: "/tmp", prompt: "p"))
        _ = await wait(service, started.id) { !$0.text.isEmpty }
        await service.cancel(id: started.id)
        #expect(await service.run(id: started.id) == nil)
        #expect(runner.cancelled == [started.id])
    }
}

/// Runs the real fork against a real session when asked to:
/// `KANBAN_SIDE_CHAT_LIVE=<transcript path> swift test --filter SideChatLiveTests`.
@Suite("Side chat: live")
struct SideChatLiveTests {
    @Test func aRealForkAnswersAndLeavesTheSessionUntouched() async throws {
        guard let transcript = ProcessInfo.processInfo.environment["KANBAN_SIDE_CHAT_LIVE"] else { return }
        let sessionId = ((transcript as NSString).lastPathComponent as NSString).deletingPathExtension
        let directory = (transcript as NSString).deletingLastPathComponent
        let before = try Data(contentsOf: URL(fileURLWithPath: transcript))
        let filesBefore = try FileManager.default.contentsOfDirectory(atPath: directory).sorted()

        let scope = try await CatchUpScope.read(transcriptPath: transcript, sessionId: sessionId, record: [], rushRecord: nil, queuedTexts: [])
        print("SINCE:", scope.since?.text ?? "-")
        print(CatchUpIndex.text(scope.refs))
        let cwd = try #require(SideChatSession.folder(transcriptPath: transcript, candidates: []))
        let job = SideChatJob(
            sessionId: sessionId, cwd: cwd,
            prompt: SideChatPrompt.catchUp(humanText: scope.since?.text, index: CatchUpIndex.text(scope.refs)),
            model: ProcessInfo.processInfo.environment["KANBAN_SIDE_CHAT_MODEL"],
            configDirectory: SideChatSession.claudeConfigDirectory(transcriptPath: transcript, isRush: false))
        let runner = ClaudeSideChatRunner(kanbanHome: NSTemporaryDirectory() + "side-live-\(UUID().uuidString)")
        let updates = Counter()
        let answer = try await runner.run(id: "live", job) { _ in updates.bump() }
        print("ANSWER:\n" + answer)
        print("UPDATES:", updates.value)
        #expect(CatchUpParser.parse(answer) != nil)
        #expect(updates.value > 0)
        #expect(try Data(contentsOf: URL(fileURLWithPath: transcript)) == before)
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory).sorted() == filesBefore)
    }
}

private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var value: Int { lock.withLock { count } }
    func bump() { lock.withLock { count += 1 } }
}
