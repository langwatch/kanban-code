import Foundation
import KanbanCodeRemoteKit

/// Size and modification time of a transcript when the attention scan last
/// read it, and what it found there.
struct AttentionScanMark: Equatable {
    var size: UInt64
    var modified: Date
    var pending: PendingDecision?
    var lastLineAt: Date?
}

// MARK: - Attention: decisions agents wait on

extension MasterEngine {
    /// Cards whose session can raise attention requests here: owned by this
    /// master, Claude, live, not archived, and not a subagent of another card.
    func attentionCandidates() -> [(cardId: String, sessionId: String, path: String)] {
        let state = store.state
        return state.links.values.compactMap { link in
            guard !link.manuallyArchived, link.parentCardId == nil, state.isOwnedLocally(link),
                  link.effectiveAssistant == .claude,
                  let session = link.sessionLink, let path = session.sessionPath,
                  let tmux = link.tmuxLink?.sessionName, state.tmuxSessions.contains(tmux)
            else { return nil }
            return (link.id, session.sessionId, path)
        }
    }

    /// Runs until cancelled: raises a request for every question or plan a
    /// live session waits on, and resolves it once the session moved on.
    public func runAttentionMonitor(interval: Duration = .seconds(2)) async {
        while !Task.isCancelled {
            await scanAttention()
            pruneResolvedAttention()
            try? await Task.sleep(for: interval)
        }
    }

    func scanAttention() async {
        let candidates = attentionCandidates()
        var seenPaths = Set<String>()
        var liveSessions = Set<String>()
        for candidate in candidates {
            seenPaths.insert(candidate.path)
            liveSessions.insert(candidate.sessionId)
            let path = candidate.path
            guard let attributes = try? FileManager.default.attributesOfItem(atPath: path),
                  let size = (attributes[.size] as? NSNumber)?.uint64Value,
                  let modified = attributes[.modificationDate] as? Date
            else { continue }
            var mark = attentionScanMarks[path]
            if mark?.size != size || mark?.modified != modified {
                let (pending, lastLineAt) = await Task.detached(priority: .utility) {
                    let lines = AttentionDetector.tailLines(path: path)
                    return (AttentionDetector.pendingDecision(inLines: lines), AttentionDetector.lastTimestamp(inLines: lines))
                }.value
                mark = AttentionScanMark(size: size, modified: modified, pending: pending, lastLineAt: lastLineAt)
                attentionScanMarks[path] = mark
            }
            reconcileAttention(cardId: candidate.cardId, sessionId: candidate.sessionId, mark: mark)
            reconcileRushPermission(cardId: candidate.cardId, sessionId: candidate.sessionId)
        }
        attentionScanMarks = attentionScanMarks.filter { seenPaths.contains($0.key) }
        // A session that ended or a card that left the board waits on nothing.
        for request in store.state.openAttentionRequests where request.kind != .vaultApproval {
            guard request.machineId == nil || request.machineId == store.state.localMachineId else { continue }
            if let sessionId = request.sessionId, !liveSessions.contains(sessionId) {
                store.dispatch(.attentionResolved(id: request.id, resolution: nil, by: "session"))
            }
        }
    }

    func reconcileAttention(cardId: String, sessionId: String, mark: AttentionScanMark?) {
        let open = store.state.openAttentionRequests.filter { $0.sessionId == sessionId }
        let pending = mark?.pending
        for request in open {
            switch request.kind {
            case .question, .planApproval:
                if request.id != pending?.requestId {
                    store.dispatch(.attentionResolved(id: request.id, resolution: nil, by: "session"))
                }
            case .permission:
                // The transcript moving past the prompt means it was answered.
                if let last = mark?.lastLineAt, last > request.createdAt.addingTimeInterval(1) {
                    store.dispatch(.attentionResolved(id: request.id, resolution: nil, by: "session"))
                }
            case .vaultApproval:
                break
            }
        }
        guard let pending, store.state.attentionRequests[pending.requestId] == nil else { return }
        store.dispatch(.attentionRaised(AttentionRequest(
            id: pending.requestId, cardId: cardId, kind: pending.kind, title: pending.title,
            body: pending.body, options: pending.options, createdAt: pending.askedAt ?? Date(),
            sessionId: sessionId, machineId: store.state.localMachineId.isEmpty ? nil : store.state.localMachineId)))
    }

    /// A rush session blocked on a tool call raises a permission request,
    /// which ends once rush says it waits on nothing. Questions and plans
    /// come from the transcript instead.
    func reconcileRushPermission(cardId: String, sessionId: String) {
        guard let session = store.state.links[cardId]?.tmuxLink?.sessionName, RushSessionName.isRush(session) else { return }
        let need = store.state.rushNeeds[session].flatMap(Self.rushPermissionNeed)
        if let need {
            raisePermissionRequest(sessionId: sessionId, message: need, at: Date())
            return
        }
        // The scan behind `rushNeeds` can lag a hook that raised it just now.
        let settled = Date().addingTimeInterval(-20)
        for request in store.state.openAttentionRequests
        where request.sessionId == sessionId && request.kind == .permission && request.createdAt < settled {
            store.dispatch(.attentionResolved(id: request.id, resolution: nil, by: "session"))
        }
    }

    /// A permission prompt for AskUserQuestion or ExitPlanMode (rush asks
    /// them through permissions): the transcript raises those as a question
    /// or a plan already.
    nonisolated static func isQuestionOrPlan(_ text: String) -> Bool {
        text.contains("AskUserQuestion") || text.contains("ExitPlanMode")
    }

    /// The tool call a rush `needs` line asks permission for; nil for a
    /// question or a plan, which the transcript raises.
    nonisolated static func rushPermissionNeed(_ needs: String) -> String? {
        let need = needs.trimmingCharacters(in: .whitespacesAndNewlines)
        if need.isEmpty || need.hasPrefix("asks:") || need == "has a question"
            || need.hasPrefix("ExitPlanMode") || need.hasPrefix("AskUserQuestion") { return nil }
        return need
    }

    /// Raises a permission request for a session the hooks reported as
    /// waiting on a permission prompt. The body opens with one plain line
    /// (what notifications show); the tool call follows for the detail sheet.
    public func raisePermissionRequest(sessionId: String, message: String?, at time: Date) {
        guard let link = store.state.links.values.first(where: { $0.sessionLink?.sessionId == sessionId }),
              store.state.isOwnedLocally(link), link.parentCardId == nil, !link.manuallyArchived
        else { return }
        if store.state.openAttentionRequests.contains(where: { $0.sessionId == sessionId && $0.kind == .permission }) { return }
        if let message, Self.isQuestionOrPlan(message) { return }
        let tool = link.sessionLink?.sessionPath.flatMap {
            AttentionDetector.pendingToolCall(inLines: AttentionDetector.tailLines(path: $0, bytes: 256 * 1024))
        }
        if let tool, Self.isQuestionOrPlan(tool.name) { return }
        let body = Self.permissionBody(message: message, tool: tool)
        let id = "perm_\(sessionId.prefix(8))_\(Int(time.timeIntervalSince1970))"
        store.dispatch(.attentionRaised(AttentionRequest(
            id: id, cardId: link.id, kind: .permission, title: "Permission needed",
            body: AttentionDetector.clipped(body, 1500), options: AttentionDetector.permissionOptions,
            createdAt: time, sessionId: sessionId,
            machineId: store.state.localMachineId.isEmpty ? nil : store.state.localMachineId)))
    }

    /// A plain first line, then what exactly the tool runs. `message` is the
    /// hook's text or a rush need ("Bash <command>"); its first word names
    /// the tool when the transcript shows no pending call.
    nonisolated static func permissionBody(message: String?, tool: AttentionDetector.ToolCall?) -> String {
        if let tool {
            return tool.summary + "\n\n" + tool.text
        }
        let text = (message ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if let need = text.split(separator: " ", maxSplits: 1).first.map(String.init),
           need.first?.isUppercase == true, need.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" }),
           text.count > need.count, !text.hasPrefix("Claude ") {
            let call = AttentionDetector.ToolCall(name: need, detail: String(text.dropFirst(need.count)).trimmingCharacters(in: .whitespaces))
            return call.summary + "\n\n" + call.text
        }
        return text.isEmpty ? "Waiting for your permission" : text
    }

    /// Follows the hook events of attention: a permission prompt raises a
    /// request, a stop or a prompt ends it.
    public func handleAttentionHook(_ event: HookEvent) {
        switch HookManager.normalizeEventName(event.eventName) {
        case "Notification":
            raisePermissionRequest(sessionId: event.sessionId, message: event.message, at: event.timestamp)
        case "Stop", "UserPromptSubmit":
            sessionMovedOn(sessionId: event.sessionId)
        default:
            break
        }
    }

    /// A Stop or a prompt in the session: a permission prompt it showed is over.
    public func sessionMovedOn(sessionId: String) {
        for request in store.state.openAttentionRequests where request.sessionId == sessionId && request.kind == .permission {
            store.dispatch(.attentionResolved(id: request.id, resolution: nil, by: "session"))
        }
    }

    func pruneResolvedAttention() {
        let cutoff = Date().addingTimeInterval(-600)
        if store.state.attentionRequests.values.contains(where: { ($0.resolvedAt ?? .distantFuture) < cutoff }) {
            store.dispatch(.attentionPruned(before: cutoff))
        }
    }

    // MARK: Resolving

    /// Answers a request: in its session for questions, plans and
    /// permissions; for a vault approval the vault reads the resolution.
    /// A request another master raised is answered there.
    /// `unsealed` is what the answering device opened with its own key,
    /// for a vault approval that needs it. A refused vault request takes
    /// a `note` for the agent; with `noteFollows` the refusal waits for
    /// `noteAttention`, up to `DenialNote.window`.
    public func resolveAttention(id: String, resolution: String, by device: String, unsealed: VaultUnsealed? = nil,
                                 note: String? = nil, noteFollows: Bool = false) async throws {
        guard let request = store.state.attentionRequests[id] else {
            throw RemoteHostError.notFound(AttentionAnswerCopy.gone)
        }
        guard request.isOpen else {
            // The same answer sent again (a second tap, a retry) is fine.
            if request.resolution == resolution { return }
            throw RemoteHostError.conflict(AttentionAnswerCopy.alreadyAnswered(by: request.resolvedBy, resolution: request.resolution))
        }
        if request.needsDeviceKey, !AttentionCopy.isDenial(resolution), unsealed == nil {
            throw RemoteHostError.conflict(AttentionAnswerCopy.needsDeviceKey)
        }
        let takesNote = request.kind == .vaultApproval && AttentionCopy.isDenial(resolution)
        let note = takesNote ? DenialNote.clean(note) : nil
        let noteFollows = takesNote && note == nil && noteFollows
        let noteUntil = noteFollows ? Date().addingTimeInterval(DenialNote.window) : nil
        if let owner = request.machineId, !store.state.localMachineId.isEmpty, owner != store.state.localMachineId {
            guard let client = await peerClient(machineId: owner) else {
                throw RemoteHostError.conflict(AttentionAnswerCopy.ownerUnreachable)
            }
            do {
                try await client.resolveAttention(id: id, resolution: resolution, by: device, unsealed: unsealed,
                                                  note: note, noteFollows: noteFollows)
            } catch let error as RemoteClientError {
                // Settled on its own master already: it is over here too.
                switch error {
                case .conflict, .notFound:
                    store.dispatch(.attentionResolved(id: id, resolution: nil, by: "peer"))
                default:
                    break
                }
                throw MasterRemoteControlHost.hostError(error)
            }
            store.dispatch(.attentionResolved(id: id, resolution: resolution, by: device, note: note, noteUntil: noteUntil))
            return
        }
        if request.kind != .vaultApproval {
            try await answerInSession(request, resolution: resolution)
        } else if let unsealed {
            await vaultUnsealed?(id, unsealed)
        }
        store.dispatch(.attentionResolved(id: id, resolution: resolution, by: device, note: note, noteUntil: noteUntil))
    }

    /// The note of a refusal answered with `noteFollows`: the vault sends
    /// the refusal to the agent with it. Nil sends the refusal on without
    /// a note. `typing` sends no note: the owner is writing one, so the
    /// refusal waits `DenialNote.typingWindow` more, at most
    /// `DenialNote.maximumWait` in all. Refused once the refusal went out.
    public func noteAttention(id: String, note: String?, typing: Bool = false) async throws {
        guard let request = store.state.attentionRequests[id] else {
            throw RemoteHostError.notFound(AttentionAnswerCopy.gone)
        }
        guard !request.isOpen, let until = request.noteUntil, let deniedAt = request.resolvedAt,
              Date() <= until.addingTimeInterval(DenialNote.slack) else {
            throw RemoteHostError.conflict(AttentionAnswerCopy.noteTooLate)
        }
        let note = typing ? nil : DenialNote.clean(note)
        if let owner = request.machineId, !store.state.localMachineId.isEmpty, owner != store.state.localMachineId {
            guard let client = await peerClient(machineId: owner) else {
                throw RemoteHostError.conflict(AttentionAnswerCopy.ownerUnreachable)
            }
            do {
                try await client.noteAttention(id: id, note: note, typing: typing)
            } catch let error as RemoteClientError {
                store.dispatch(.attentionNoted(id: id, note: nil))
                throw MasterRemoteControlHost.hostError(error)
            }
        }
        if typing {
            store.dispatch(.attentionNoteAwaited(id: id, until: DenialNote.typingDeadline(deniedAt: deniedAt)))
        } else {
            store.dispatch(.attentionNoted(id: id, note: note))
        }
    }

    /// Answers the question or plan the card's session waits on, as the
    /// chat's answer buttons do: false when it waits on none, for the
    /// caller to send `answer` as a message. A plan card's digit picks
    /// that option.
    public func answerOpenRequest(cardId: String, answer: String, by device: String) async throws -> Bool {
        guard let request = store.state.openAttentionRequests
            .filter({ $0.cardId == cardId && ($0.kind == .question || $0.kind == .planApproval) })
            .max(by: { $0.createdAt < $1.createdAt })
        else { return false }
        var resolution = answer
        if request.kind == .planApproval, let digit = Int(answer), digit >= 1 {
            resolution = request.options[min(digit, request.options.count) - 1]
        }
        try await resolveAttention(id: request.id, resolution: resolution, by: device)
        return true
    }

    /// Answers in the session: rush settles the request it waits on, a tmux
    /// Claude gets the option's number key.
    func answerInSession(_ request: AttentionRequest, resolution: String) async throws {
        guard let cardId = request.cardId, let link = store.state.links[cardId],
              let session = link.tmuxLink?.sessionName, store.state.tmuxSessions.contains(session)
        else { throw RemoteHostError.conflict(AttentionAnswerCopy.sessionGone) }
        let index = request.options.firstIndex(of: resolution)
        if let rushId = RushSessionName.rushId(fromName: session) {
            let rush = try tmux.rush(forSession: session)
            let answer = Self.rushAnswer(for: request, resolution: resolution, optionIndex: index)
            do {
                if try await rush.answer(id: rushId, text: answer.text, deny: answer.deny, request: answer.toolUseId) { return }
            } catch let error as RushCommandFailed {
                throw RemoteHostError.conflict(error.message)
            }
            // A build without `session answer` takes the text as a message.
            try await rush.send(id: rushId, text: resolution)
            return
        }
        let adapter = try tmux.adapter(for: session)
        let keys = Self.tmuxKeys(for: request, resolution: resolution, optionIndex: index)
        if keys.isEmpty {
            try await tmux.sendPrompt(to: session, text: resolution)
            return
        }
        for key in keys {
            _ = try await adapter.run(["send-keys", "-t", session, key])
        }
    }

    /// What `rush session answer` gets for `resolution`: a question takes
    /// the text; a plan or a permission is allowed by its first option and
    /// declined otherwise, with typed words passed on as the reason.
    nonisolated static func rushAnswer(for request: AttentionRequest, resolution: String, optionIndex: Int?)
        -> (text: String, deny: Bool, toolUseId: String?) {
        let toolUseId = request.id.hasPrefix("att_") ? String(request.id.dropFirst(4)) : nil
        switch request.kind {
        case .question, .vaultApproval:
            return (resolution, false, toolUseId)
        case .planApproval, .permission:
            if optionIndex == 0 { return ("", false, toolUseId) }
            return (optionIndex == nil ? resolution : "", true, toolUseId)
        }
    }

    /// Keys that pick `resolution` in Claude's terminal prompt; empty when
    /// the answer is free text to type.
    nonisolated static func tmuxKeys(for request: AttentionRequest, resolution: String, optionIndex: Int?) -> [String] {
        switch request.kind {
        case .question:
            guard let optionIndex else { return [] }
            return [String(optionIndex + 1)]
        case .planApproval:
            // Claude's plan menu: 1 approves; Escape keeps planning.
            return optionIndex == 0 ? ["1"] : ["Escape"]
        case .permission:
            return optionIndex == 0 ? ["1"] : ["Escape"]
        case .vaultApproval:
            return []
        }
    }

    // MARK: Peers

    /// Runs until cancelled: shows here the open requests of the other
    /// masters, and tells them where the Mac user is.
    public func runAttentionPeerSync(interval: Duration = .seconds(4), presence: (@Sendable () async -> MacPresence?)? = nil) async {
        var lastPresenceSent = Date.distantPast
        while !Task.isCancelled {
            let peers = store.state.peerStatuses.values.compactMap { status -> String? in
                guard status.online, let id = status.machine?.id, id != store.state.localMachineId else { return nil }
                return id
            }
            let sendPresence = presence != nil && Date().timeIntervalSince(lastPresenceSent) >= 15
            let current = sendPresence ? await presence?() : nil
            if sendPresence { lastPresenceSent = Date() }
            for machineId in peers {
                guard let client = await peerClient(machineId: machineId) else { continue }
                if let current { try? await client.reportPresence(current) }
                guard let remote = try? await client.attention() else { continue }
                mergePeerAttention(machineId: machineId, remote: remote)
            }
            try? await Task.sleep(for: interval)
        }
    }

    /// Mirrors a peer's open requests: new ones are raised here, ones it no
    /// longer lists are resolved here.
    func mergePeerAttention(machineId: String, remote: [AttentionRequest]) {
        let remoteIds = Set(remote.map(\.id))
        for request in store.state.openAttentionRequests where request.machineId == machineId && !remoteIds.contains(request.id) {
            store.dispatch(.attentionResolved(id: request.id, resolution: nil, by: "peer"))
        }
        for var request in remote where request.isOpen {
            request.machineId = request.machineId ?? machineId
            if store.state.attentionRequests[request.id] == nil {
                store.dispatch(.attentionRaised(request))
            }
        }
    }
}
