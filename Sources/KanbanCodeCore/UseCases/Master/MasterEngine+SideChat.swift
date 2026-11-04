import Foundation
import KanbanCodeRemoteKit

// MARK: - Side chats: /btw and /catchup

extension MasterEngine {
    /// Starts a side chat run for the card: a question about its session
    /// (`btw`) or the catch-up since the human's last message (`catchup`).
    /// The run reads the session and never writes into it. A card another
    /// master owns runs it there.
    ///
    /// A catch-up is kept per card. Asked again while the session has no
    /// message after the last one it covers, the kept one comes back at
    /// once, finished, with the follow-ups of its side chat; `fresh` in
    /// the request runs a new one anyway.
    public func startSideChat(cardId: String, _ request: RemoteSideChatRequest) async throws -> RemoteSideChatRun {
        if let owner = await ownerClient(forCard: cardId) {
            return try await Self.forwardedSideChat { try await owner.startSideChat(cardId: cardId, request) }
        }
        guard let link = store.state.links[cardId] else { throw RemoteHostError.notFound("no card \(cardId)") }
        guard link.effectiveAssistant == .claude else {
            throw RemoteHostError.conflict("The side chat works with Claude Code sessions.")
        }
        let sessionName = link.tmuxLink?.sessionName
        if let sessionName, let machine = platform.machineForSession(sessionName) {
            throw RemoteHostError.conflict("The side chat is not available for a session on \(machine) yet.")
        }
        guard let sessionId = link.sessionLink?.sessionId, !sessionId.isEmpty,
              let transcript = ConversationExportCommand.transcriptPath(for: link, kanbanHome: platform.kanbanHome) else {
            throw RemoteHostError.conflict("This card has no conversation yet.")
        }
        let question = request.question?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if request.kind == .btw, question.isEmpty {
            throw RemoteHostError.badRequest("question is required for a btw side chat")
        }

        // rush knows the session's model and keeps its own record of what
        // the human typed.
        var model = link.modelOverride
        var rushRecord: [RushHumanMessage]?
        let rushId = sessionName.flatMap(RushSessionName.rushId(fromName:))
        if let rushId, let sessionName, let rush = try? tmux.rush(forSession: sessionName) {
            if let info = try? await rush.info(id: rushId), let hosted = info.model, !hosted.isEmpty { model = hosted }
            if request.kind == .catchup { rushRecord = await rush.humanMessages(id: rushId) }
        }
        let record = humanMessages.read(cardId: cardId)
        let queued = (link.queuedPrompts ?? []).filter(\.isHuman).map(\.body)
            + (sessionName.flatMap { store.state.rushQueues[$0] } ?? [])
        let folders = [link.worktreeLink?.path, link.projectPath].compactMap { $0 }
        let history = request.history ?? []
        let kind = request.kind

        let prepared = try await Task.detached(priority: .userInitiated) { () throws -> SideChatPrepared in
            guard let cwd = SideChatSession.folder(transcriptPath: transcript, candidates: folders) else {
                throw RemoteHostError.conflict("The session's folder is gone, so its conversation cannot be read.")
            }
            let config = SideChatSession.claudeConfigDirectory(transcriptPath: transcript, isRush: rushId != nil)
            var job = SideChatJob(sessionId: sessionId, cwd: cwd, prompt: "", model: model, configDirectory: config)
            guard kind == .catchup else {
                job.prompt = SideChatPrompt.btw(question: question, history: history)
                return SideChatPrepared(job: job, since: nil, refs: nil)
            }
            let scope = try await CatchUpScope.read(
                transcriptPath: transcript, sessionId: sessionId, record: record, rushRecord: rushRecord, queuedTexts: queued)
            job.prompt = SideChatPrompt.catchUp(
                humanText: scope.since?.text, index: CatchUpIndex.text(scope.refs), fromStart: scope.coversWholeSession)
            return SideChatPrepared(job: job, since: scope.since, refs: scope.refs)
        }.value

        let keep = catchUps
        guard kind == .catchup else {
            KanbanCodeLog.info("sidechat", "Starting btw for card=\(cardId.prefix(12)) session=\(sessionId.prefix(8))")
            let followsUp = request.catchUpId
            return await sideChat.start(cardId: cardId, kind: kind, job: prepared.job) { run in
                guard let followsUp else { return }
                keep.addFollowUp(cardId: cardId, catchUpId: followsUp,
                                 RemoteSideChatExchange(question: question, answer: run.text))
            }
        }
        let covered = KeptCatchUp.covered(since: prepared.since, refs: prepared.refs ?? [])
        if request.fresh != true, let kept = keep.read(cardId: cardId),
           kept.isCurrent(sessionId: sessionId, covered: covered) {
            KanbanCodeLog.info("sidechat", "Reopening catchup \(kept.run.id) for card=\(cardId.prefix(12)): nothing after offset \(covered)")
            return kept.reopenedRun
        }
        KanbanCodeLog.info("sidechat", "Starting catchup for card=\(cardId.prefix(12)) session=\(sessionId.prefix(8)) refs=\(prepared.refs?.count ?? 0)")
        return await sideChat.start(cardId: cardId, kind: kind, since: prepared.since, refs: prepared.refs, job: prepared.job) { run in
            keep.keep(cardId: cardId, KeptCatchUp(sessionId: sessionId, covered: covered, run: run))
        }
    }

    /// The run and its answer so far.
    public func sideChatRun(cardId: String, runId: String) async throws -> RemoteSideChatRun {
        if let run = await sideChat.run(id: runId) { return run }
        if let owner = await ownerClient(forCard: cardId) {
            return try await Self.forwardedSideChat { try await owner.sideChatRun(cardId: cardId, runId: runId) }
        }
        // A kept catch-up outlives the runs in memory.
        if let kept = catchUps.read(cardId: cardId), kept.run.id == runId { return kept.reopenedRun }
        throw RemoteHostError.notFound("no side chat run \(runId)")
    }

    /// Stops the run and forgets it.
    public func cancelSideChat(cardId: String, runId: String) async {
        if await sideChat.run(id: runId) != nil {
            await sideChat.cancel(id: runId)
        } else if let owner = await ownerClient(forCard: cardId) {
            try? await owner.cancelSideChat(cardId: cardId, runId: runId)
        }
    }

    private nonisolated static func forwardedSideChat<T: Sendable>(_ call: @Sendable () async throws -> T) async throws -> T {
        do {
            return try await call()
        } catch let error as RemoteClientError {
            throw MasterRemoteControlHost.hostError(error)
        }
    }
}

struct SideChatPrepared: Sendable {
    var job: SideChatJob
    var since: RemoteSideChatSince?
    var refs: [RemoteSideChatRef]?
}

/// What a catch-up covers: the human's last message and the messages of
/// the session since then.
public struct CatchUpScope: Sendable, Equatable {
    /// Nil when the human never wrote in the session (an agent started it),
    /// or not within the stretch searched: the catch-up then covers the
    /// whole session, or its recent end when the session is long.
    public var since: RemoteSideChatSince?
    public var refs: [RemoteSideChatRef]
    /// Whether the scope runs from the session's first line. False when
    /// neither his message nor the start was within reach of the end.
    public var coversWholeSession: Bool = true

    public static func read(
        transcriptPath: String,
        sessionId: String?,
        record: [HumanMessageRecord],
        rushRecord: [RushHumanMessage]?,
        queuedTexts: [String],
        now: Date = .now,
        scanBytes: Int = HumanMessageFinder.scanBytes
    ) async throws -> CatchUpScope {
        let last = HumanMessageFinder.find(
            transcriptPath: transcriptPath, sessionId: sessionId, record: record, rushRecord: rushRecord,
            queuedTexts: queuedTexts, now: now, scanBytes: scanBytes)
        let size = ((try? FileManager.default.attributesOfItem(atPath: transcriptPath))?[.size] as? Int) ?? 0
        // Without his message the scope is the stretch the search covered:
        // the whole session when it is small, its recent end otherwise. A
        // read starting inside a line skips that partial line.
        let start = last?.scopeStart ?? max(0, size - scanBytes)
        let range = try await TranscriptReader.readRange(from: transcriptPath, startOffset: start, endOffset: size)
        let refs = CatchUpIndex.build(turns: range.turns, humanOffset: last?.offset)
        let since = last.map { RemoteSideChatSince(text: $0.text, at: $0.at, offset: $0.offset) }
        return CatchUpScope(since: since, refs: refs, coversWholeSession: last != nil || start == 0)
    }
}

/// Where a session's side run has to start to read it.
public enum SideChatSession {
    /// The folder Claude Code files the session under: the one whose
    /// encoded path is the transcript's directory. `candidates` are the
    /// card's own folders, tried after the folder the transcript names.
    public static func folder(transcriptPath: String, candidates: [String]) -> String? {
        let slug = ((transcriptPath as NSString).deletingLastPathComponent as NSString).lastPathComponent
        var all: [String] = []
        if let recorded = recordedFolder(transcriptPath: transcriptPath) { all.append(recorded) }
        all += candidates
        let existing = all.filter {
            var isDirectory: ObjCBool = false
            return FileManager.default.fileExists(atPath: $0, isDirectory: &isDirectory) && isDirectory.boolValue
        }
        return existing.first { SessionFileMover.encodeProjectPath($0) == slug } ?? existing.first
    }

    /// The `cwd` of the transcript's first record that has one.
    static func recordedFolder(transcriptPath: String) -> String? {
        guard let handle = FileHandle(forReadingAtPath: transcriptPath) else { return nil }
        defer { try? handle.close() }
        guard let head = try? handle.read(upToCount: 256 << 10), let text = String(data: head, encoding: .utf8)
                ?? String(data: head.dropLast(4), encoding: .utf8) else { return nil }
        guard let key = text.range(of: "\"cwd\":\"") else { return nil }
        let rest = text[key.upperBound...]
        guard let close = rest.firstIndex(of: "\"") else { return nil }
        let raw = "\"" + rest[..<close] + "\""
        return (try? JSONDecoder().decode(String.self, from: Data(raw.utf8))) ?? String(rest[..<close])
    }

    /// The `CLAUDE_CONFIG_DIR` the session's Claude Code runs with, or nil
    /// for `~/.claude`. rush runs Claude Code under its own account folder
    /// (`~/.config/rush/claude/<account>`), whose login the side run uses too.
    public static func claudeConfigDirectory(transcriptPath: String, isRush: Bool, home: String = NSHomeDirectory()) -> String? {
        let fm = FileManager.default
        if isRush {
            let accounts = (home as NSString).appendingPathComponent(".config/rush/claude")
            if let using = try? String(contentsOfFile: accounts + "/using", encoding: .utf8) {
                let account = (accounts as NSString).appendingPathComponent(using.trimmingCharacters(in: .whitespacesAndNewlines))
                if !using.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, fm.fileExists(atPath: account) { return account }
            }
        }
        // <config>/projects/<folder>/<session>.jsonl
        var config = transcriptPath as NSString
        for _ in 0..<2 { config = config.deletingLastPathComponent as NSString }
        guard config.lastPathComponent == "projects" else { return nil }
        let directory = config.deletingLastPathComponent
        let standard = (home as NSString).appendingPathComponent(".claude")
        return directory == standard ? nil : directory
    }
}
