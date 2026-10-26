import Foundation
import KanbanCodeRemoteKit
#if canImport(UserNotifications)
import UserNotifications
#endif

/// Executes side effects produced by the Reducer.
/// All async operations (disk, network, tmux) go through here.
public actor EffectHandler {
    private static let channelMessageTailLimit = 200

    private let coordinationStore: CoordinationStore
    private let tmuxAdapter: TmuxManagerPort?
    private let setClipboardImage: (@Sendable (Data) -> Void)?
    private let channelsStore: ChannelsStore
    private let notifier: NotifierPort?
    private let queuedPromptJournal: QueuedPromptJournal
    private let humanMessageLog: HumanMessageLog
    private let conversationStore: ConversationStore
    private let remoteMachines: (any RemoteMachineControl)?
    /// The channels home when it is another master: channel writes go there.
    private var channelsHome: (@Sendable () async -> ChannelsHomeRoute?)?

    public func setChannelsHome(_ route: (@Sendable () async -> ChannelsHomeRoute?)?) {
        channelsHome = route
    }

    /// Delivers attention requests to the Mac and the phone.
    private var attentionDelivery: (any AttentionDelivering)?

    public func setAttentionDelivery(_ delivery: (any AttentionDelivering)?) {
        attentionDelivery = delivery
    }

    /// Creates a session on a machine, and reconnects the machine once when
    /// it answers no longer: the app can hold a machine as paused while it
    /// runs again, and the shell of the user must not fail for that.
    private func createRemoteSession(machineName: String, name: String, path: String) async throws {
        do {
            try await tmuxAdapter?.createSession(name: name, path: path, command: nil)
        } catch {
            guard await remoteMachines?.reconnectIfRunning(machineName: machineName) == true else { throw error }
            try await tmuxAdapter?.createSession(name: name, path: path, command: nil)
        }
    }

    /// A shell that fails takes only its own tab. A session of a card that
    /// fails takes the tmux link with it, so the card can be launched again.
    static func terminalFailure(cardId: String, sessionName: String, isExtra: Bool, error: any Error) -> Action {
        isExtra
            ? .extraTerminalFailed(cardId: cardId, sessionName: sessionName, error: error.localizedDescription)
            : .terminalFailed(cardId: cardId, error: error.localizedDescription)
    }

    // MARK: - Chat notification burst throttler
    //
    // When N messages arrive in the same channel / DM within a short window,
    // collapse them into one summary notification instead of spamming the
    // system banner N times. First message fires immediately; subsequent
    // arrivals within the window are buffered and flushed as a single
    // "@sender sent K messages in #channel" banner when the window closes.
    private struct Burst {
        var windowEnd: Date
        var extraCount: Int
        var lastSender: String
        var lastBody: String
        var userInfo: [String: String]
        var title: String // pre-computed for summary
    }
    private var bursts: [String: Burst] = [:]
    private let burstWindow: TimeInterval = 2.0

    public init(
        coordinationStore: CoordinationStore,
        tmuxAdapter: TmuxManagerPort? = nil,
        setClipboardImage: (@Sendable (Data) -> Void)? = nil,
        channelsStore: ChannelsStore? = nil,
        notifier: NotifierPort? = nil,
        queuedPromptJournal: QueuedPromptJournal? = nil,
        remoteMachines: (any RemoteMachineControl)? = nil,
        humanMessageLog: HumanMessageLog? = nil,
        conversationStore: ConversationStore? = nil
    ) {
        self.coordinationStore = coordinationStore
        self.tmuxAdapter = tmuxAdapter
        self.setClipboardImage = setClipboardImage
        self.channelsStore = channelsStore ?? ChannelsStore()
        self.notifier = notifier
        self.queuedPromptJournal = queuedPromptJournal ?? QueuedPromptJournal()
        self.humanMessageLog = humanMessageLog ?? HumanMessageLog()
        self.conversationStore = conversationStore ?? ConversationStore()
        self.remoteMachines = remoteMachines
    }

    public func execute(_ effect: Effect, dispatch: @MainActor @Sendable (Action) -> Void) async {
        if let argvAndImages = Self.channelsHomeCommand(for: effect), let route = await channelsHome?() {
            await runOnChannelsHome(argvAndImages, effect: effect, route: route, dispatch: dispatch)
            return
        }
        switch effect {
        case .persistLinks(let links):
            do {
                try await coordinationStore.writeLinks(links)
            } catch {
                KanbanCodeLog.warn("effect", "persistLinks failed: \(error)")
            }

        case .upsertLink(let link):
            do {
                try await coordinationStore.upsertLink(link)
            } catch {
                KanbanCodeLog.warn("effect", "upsertLink failed: \(error)")
            }

        case .removeLink(let id):
            do {
                try await coordinationStore.removeLink(id: id)
            } catch {
                KanbanCodeLog.warn("effect", "removeLink failed: \(error)")
            }

        case .persistTombstones(let tombstones):
            do {
                try await coordinationStore.writeTombstones(tombstones)
            } catch {
                KanbanCodeLog.warn("effect", "persistTombstones failed: \(error)")
            }

        case .createTmuxSession(let cardId, let name, let path, let isExtra):
            do {
                try await tmuxAdapter?.createSession(name: name, path: path, command: nil)
                await dispatch(.terminalCreated(cardId: cardId, tmuxName: name))
            } catch {
                await dispatch(Self.terminalFailure(
                    cardId: cardId, sessionName: name, isExtra: isExtra, error: error))
            }

        case .createRemoteTmuxSession(let cardId, let machineName, let name, let path, let isExtra):
            await remoteMachines?.assignSession(name, to: machineName)
            do {
                try await createRemoteSession(machineName: machineName, name: name, path: path)
                // The terminal waits for this marker before it attaches, the
                // same way it does for the session of the card.
                await remoteMachines?.markSessionReady(name, on: machineName)
                await dispatch(.terminalCreated(cardId: cardId, tmuxName: name))
            } catch {
                await dispatch(Self.terminalFailure(
                    cardId: cardId, sessionName: name, isExtra: isExtra, error: error))
            }

        case .killTmuxSession(let name):
            try? await tmuxAdapter?.killSession(name: name)

        case .killTmuxSessions(let names):
            for name in names {
                try? await tmuxAdapter?.killSession(name: name)
            }

        case .stopRemoteMachine(let machineName, let reason):
            await remoteMachines?.stop(machineName: machineName, reason: reason)

        case .destroyRemoteMachine(let machineName):
            do {
                try await remoteMachines?.destroy(machineName: machineName)
                await dispatch(.remoteMachineDestroyed(machineName: machineName))
            } catch {
                KanbanCodeLog.warn("effect", "destroyRemoteMachine \(machineName) failed: \(error)")
                await dispatch(.setError("Could not destroy machine \(machineName): \(error.localizedDescription)"))
            }

        case .deleteSessionFile(let path):
            try? FileManager.default.removeItem(atPath: path)

        case .cleanupTerminalCache(let sessionNames):
            await MainActor.run {
                for name in sessionNames {
                    TerminalCacheRelay.remove(name)
                }
            }

        case .cleanupBrowserCache(let cardId):
            await MainActor.run {
                BrowserTabCacheRelay.removeAll(cardId: cardId)
            }

        case .refreshDiscovery:
            // This is handled by the orchestrator, not here
            break

        case .updateSessionIndex(let sessionId, let name):
            try? SessionIndexReader.updateSummary(sessionId: sessionId, summary: name)

        case .moveSessionFile(let cardId, let sessionId, let oldPath, let newProjectPath):
            do {
                let newPath = try SessionFileMover.moveSession(
                    sessionId: sessionId,
                    fromPath: oldPath,
                    toProjectPath: newProjectPath
                )
                // Update the link's sessionPath to the new location
                try await coordinationStore.updateLink(id: cardId) { link in
                    link.sessionLink?.sessionPath = newPath
                }
                KanbanCodeLog.info("effect", "Moved session \(sessionId.prefix(8)) → \(newPath)")
            } catch {
                KanbanCodeLog.warn("effect", "moveSessionFile failed: \(error)")
                await dispatch(.setError("Move failed: \(error.localizedDescription)"))
            }
        case .journalQueuedPrompt(let cardId, let prompt, let reason):
            await queuedPromptJournal.append(
                QueuedPromptJournalEntry(
                    cardId: cardId,
                    promptId: prompt.id,
                    reason: reason,
                    body: prompt.body,
                    imagePaths: prompt.imagePaths,
                    sendAutomatically: prompt.sendAutomatically
                )
            )

        case .appendConversationEvents(let cardId, let events):
            do {
                try conversationStore.append(cardId: cardId, events)
                let summaries = conversationStore.threads(cardId: cardId).map(\.summary)
                await dispatch(.conversationsLoaded(cardId: cardId, conversations: summaries))
            } catch {
                KanbanCodeLog.warn("conversations", "card \(cardId.prefix(12)): append failed: \(error)")
            }

        case .recordHumanMessage(let cardId, let text, let at, let sessionId):
            humanMessageLog.append(cardId: cardId, HumanMessageRecord(at: at, text: text, sessionId: sessionId))

        case .sendPromptToTmux(let sessionName, let promptBody, let assistant, let human):
            do {
                // A prompt to a session on a paused machine brings the
                // machine back first; the prompt itself never wakes it.
                guard await remoteMachines?.resumeMachine(forSession: sessionName) != false else {
                    KanbanCodeLog.warn("effect", "sendPromptToTmux: the machine of \(sessionName) did not come back")
                    return
                }
                if human, let rushId = RushSessionName.rushId(fromName: sessionName),
                   let rush = try (tmuxAdapter as? RoutingTmuxAdapter)?.rush(forSession: sessionName) {
                    // rush keeps its own record of what the human typed.
                    try await rush.send(id: rushId, text: promptBody, human: true)
                    return
                }
                if assistant.submitsPromptWithPaste {
                    try await tmuxAdapter?.pastePrompt(to: sessionName, text: promptBody)
                } else {
                    try await tmuxAdapter?.sendPrompt(to: sessionName, text: promptBody)
                }
            } catch {
                KanbanCodeLog.warn("effect", "sendPromptToTmux failed: \(error)")
            }

        case .sendPromptWithImagesToTmux(let sessionName, let promptBody, let imagePaths, let assistant, let human):
            do {
                guard let tmux = tmuxAdapter else { return }
                guard await remoteMachines?.resumeMachine(forSession: sessionName) != false else {
                    KanbanCodeLog.warn("effect", "sendPromptWithImagesToTmux: the machine of \(sessionName) did not come back")
                    return
                }
                if let rushId = RushSessionName.rushId(fromName: sessionName),
                   let rush = try (tmux as? RoutingTmuxAdapter)?.rush(forSession: sessionName) {
                    // rush takes the images as files and puts each right
                    // after its [Image #N] marker in the text.
                    try await rush.send(id: rushId, text: promptBody, imagePaths: imagePaths, human: human)
                    return
                }
                let images = assistant.supportsImageUpload
                    ? imagePaths.compactMap { ImageAttachment.fromPath($0) }
                    : []
                if !images.isEmpty,
                   let remotePaths = try await remoteMachines?.uploadImages(sessionName: sessionName, imagePaths: imagePaths) {
                    // The clipboard does not reach the machine: the images go
                    // over the bridge and the prompt points at them by path.
                    let body = PromptImageLayout.replacingMarkersWithMarkdown(in: promptBody, imagePaths: remotePaths)
                    if assistant.submitsPromptWithPaste {
                        try await tmux.pastePrompt(to: sessionName, text: body)
                    } else {
                        try await tmux.sendPrompt(to: sessionName, text: body)
                    }
                } else if !images.isEmpty {
                    guard let setClipboard = setClipboardImage else { return }
                    let sender = ImageSender(tmux: tmux)
                    try await sender.waitForReady(sessionName: sessionName, assistant: assistant)
                    try await sender.sendPromptWithImages(
                        sessionName: sessionName,
                        prompt: promptBody,
                        images: images,
                        assistant: assistant,
                        setClipboard: setClipboard
                    )
                } else if assistant.submitsPromptWithPaste {
                    let body = PromptImageLayout.replacingMarkersWithMarkdown(in: promptBody, imagePaths: imagePaths)
                    try await tmux.pastePrompt(to: sessionName, text: body)
                } else {
                    let body = PromptImageLayout.replacingMarkersWithMarkdown(in: promptBody, imagePaths: imagePaths)
                    try await tmux.sendPrompt(to: sessionName, text: body)
                }
                if assistant.supportsImageUpload {
                    for path in imagePaths {
                        try? FileManager.default.removeItem(atPath: path)
                    }
                }
            } catch {
                KanbanCodeLog.warn("effect", "sendPromptWithImagesToTmux failed: \(error)")
            }

        case .deleteFiles(let paths):
            for path in paths {
                try? FileManager.default.removeItem(atPath: path)
            }

        case .deliverAttention(let request):
            await attentionDelivery?.deliver(request)

        case .updateAttention(let request):
            await attentionDelivery?.update(request)

        case .withdrawAttention(let request):
            await attentionDelivery?.withdraw(request)

        case .loadChannels:
            let channels = await channelsStore.loadChannels()
            await dispatch(.channelsLoaded(channels: channels))

        case .loadChannelMessages(let name):
            let msgs = await channelsStore.loadMessages(channel: name, limit: Self.channelMessageTailLimit)
            await dispatch(.channelMessagesLoaded(channelName: name, messages: msgs))

        case .createChannelOnDisk(let name, let by):
            do {
                _ = try await channelsStore.createChannel(name: name, by: by)
            } catch {
                KanbanCodeLog.warn("effect", "createChannelOnDisk failed: \(error)")
                await dispatch(.setError("Failed to create channel: \(error.localizedDescription)"))
            }

        case .persistChannels(let channels):
            do {
                try await channelsStore.saveChannels(channels)
            } catch {
                KanbanCodeLog.warn("effect", "persistChannels failed: \(error)")
            }

        case .deleteChannelOnDisk(let name):
            do {
                try await channelsStore.deleteChannel(name: name)
            } catch {
                KanbanCodeLog.warn("effect", "deleteChannelOnDisk failed: \(error)")
            }

        case .renameChannelOnDisk(let old, let new):
            do {
                try await channelsStore.renameChannel(old: old, new: new)
            } catch {
                KanbanCodeLog.warn("effect", "renameChannelOnDisk failed: \(error)")
                await dispatch(.setError("Rename failed: \(error.localizedDescription)"))
            }

        case .leaveChannelOnDisk(let name, let member):
            do {
                _ = try await channelsStore.leave(channel: name, member: member)
            } catch {
                KanbanCodeLog.warn("effect", "leaveChannelOnDisk failed: \(error)")
                await dispatch(.setError("Couldn't remove @\(member.handle) from #\(name): \(error.localizedDescription)"))
            }

        case .sendChannelMessageToDisk(let channelName, let from, let body, let imagePaths, let memberTargets):
            do {
                let msg = try await channelsStore.send(
                    channel: channelName,
                    from: from,
                    body: body,
                    imagePaths: imagePaths
                )
                await dispatch(.channelMessageAppended(channelName: channelName, message: msg))
                let persistedImages = msg.imagePaths ?? []
                let bodyText = "[Message from #\(channelName) @\(from.handle)]: \(body)"
                for target in memberTargets {
                    await fanOutOneMessage(target: target, body: bodyText, imagePaths: persistedImages, dispatch: dispatch)
                }
            } catch {
                KanbanCodeLog.warn("effect", "sendChannelMessageToDisk failed: \(error)")
                await dispatch(.setError("Failed to send: \(error.localizedDescription)"))
            }

        case .loadChannelReadState:
            let state = await channelsStore.loadReadState()
            await dispatch(.channelReadStateLoaded(channels: state.channels, dms: state.dms))

        case .persistChannelReadState(let channels, let dms):
            do {
                try await channelsStore.saveReadState(
                    ChannelsStore.ReadState(channels: channels, dms: dms)
                )
            } catch {
                KanbanCodeLog.warn("effect", "persistChannelReadState failed: \(error)")
            }

        case .loadDrafts:
            let drafts = await channelsStore.loadDrafts()
            await dispatch(.draftsLoaded(channels: drafts.channels, dms: drafts.dms))

        case .persistDrafts(let channels, let dms):
            do {
                try await channelsStore.saveDrafts(
                    ChannelsStore.DraftsState(channels: channels, dms: dms)
                )
            } catch {
                KanbanCodeLog.warn("effect", "persistDrafts failed: \(error)")
            }

        case .loadDMMessages(let self_, let other):
            let msgs = await channelsStore.loadDMMessages(between: self_, and: other, limit: Self.channelMessageTailLimit)
            await dispatch(.dmMessagesLoaded(other: other, messages: msgs))

        case .notifyDMReceived(let fromHandle, let body):
            await notifyThrottled(
                key: "dm:\(fromHandle)",
                title: "DM from @\(fromHandle)",
                sender: fromHandle,
                body: body,
                userInfo: ["chatKind": "dm", "dmHandle": fromHandle]
            )

        case .notifyChannelMessage(let channel, let fromHandle, let body):
            await notifyThrottled(
                key: "channel:\(channel)",
                title: "#\(channel) · @\(fromHandle)",
                sender: fromHandle,
                body: body,
                userInfo: ["chatKind": "channel", "channelName": channel]
            )

        case .sendDMToDisk(let from, let to, let body, let imagePaths, let toTarget):
            do {
                let msg = try await channelsStore.sendDirectMessage(
                    from: from,
                    to: to,
                    body: body,
                    imagePaths: imagePaths
                )
                await dispatch(.dmMessageAppended(other: to, message: msg))
                if let target = toTarget {
                    let persistedImages = msg.imagePaths ?? []
                    let bodyText = "[DM from @\(from.handle)]: \(body)"
                    await fanOutOneMessage(target: target, body: bodyText, imagePaths: persistedImages, dispatch: dispatch)
                }
            } catch {
                KanbanCodeLog.warn("effect", "sendDMToDisk failed: \(error)")
                await dispatch(.setError("Failed to DM: \(error.localizedDescription)"))
            }
        }
    }

    // MARK: - Channels on another master

    /// The `kanban` command that makes a channel write on the channels home,
    /// with the images it attaches; nil for effects that are not channel
    /// writes. Channel order is this master's own (it is not sent).
    static func channelsHomeCommand(for effect: Effect) -> (argv: [String], images: [String], human: String?)? {
        func speaker(_ p: ChannelParticipant) -> (args: [String], human: String?) {
            if let cardId = p.cardId { return (["--as", p.handle, "--as-card-id", cardId], nil) }
            return (["--as-user"], p.handle)
        }
        func imageArgs(_ paths: [String]) -> [String] {
            paths.flatMap { ["--image", "/images/proxy/\(($0 as NSString).lastPathComponent)"] }
        }
        switch effect {
        case .createChannelOnDisk(let name, let by):
            let who = speaker(by)
            return (["channel", "create", name] + who.args, [], who.human)
        case .deleteChannelOnDisk(let name):
            return (["channel", "delete", name], [], nil)
        case .renameChannelOnDisk(let old, let new):
            return (["channel", "rename", old, new], [], nil)
        case .leaveChannelOnDisk(let name, let member):
            let who = speaker(member)
            return (["channel", "leave", name] + who.args, [], who.human)
        case .sendChannelMessageToDisk(let channelName, let from, let body, let imagePaths, _):
            let who = speaker(from)
            return (["channel", "send", channelName] + who.args + imageArgs(imagePaths) + ["--", body], imagePaths, who.human)
        case .sendDMToDisk(let from, let to, let body, let imagePaths, _):
            let who = speaker(from)
            let target = to.cardId.map { ["--to-card-id", $0] } ?? []
            return (["dm", "send", to.handle] + target + who.args + imageArgs(imagePaths) + ["--", body], imagePaths, who.human)
        case .persistChannels:
            return ([], [], nil)
        default:
            return nil
        }
    }

    private func runOnChannelsHome(
        _ command: (argv: [String], images: [String], human: String?),
        effect: Effect,
        route: ChannelsHomeRoute,
        dispatch: @MainActor @Sendable (Action) -> Void
    ) async {
        guard !command.argv.isEmpty else { return }
        let id = UUID().uuidString.lowercased()
        let images = command.images.compactMap { path -> RemoteCLIRequest.Image? in
            guard let data = FileManager.default.contents(atPath: path) else { return nil }
            return RemoteCLIRequest.Image(name: (path as NSString).lastPathComponent, base64: data.base64EncodedString())
        }
        let argv = command.argv.map { $0.hasPrefix("/images/proxy/") ? "~/.kanban-code/images/proxy/\(id)/" + ($0 as NSString).lastPathComponent : $0 }
        var env: [String: String] = [:]
        if let human = command.human { env["KANBAN_HUMAN_HANDLE"] = human }
        let request = RemoteCLIRequest(id: id, argv: argv, env: env, images: images.isEmpty ? nil : images)
        do {
            let result = try await route.client.runCLI(request)
            if result.code != 0 {
                let reason = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
                await dispatch(.setError("\(route.name): \(reason.isEmpty ? "kanban \(command.argv.prefix(2).joined(separator: " ")) failed" : reason)"))
            }
        } catch {
            await dispatch(.setError("Channels live on \(route.name), which did not answer: \(error.localizedDescription)"))
        }
        route.poke()
        await dispatch(.refreshChannels)
        switch effect {
        case .sendChannelMessageToDisk(let channelName, _, _, _, _):
            await dispatch(.refreshChannelMessages(channelName: channelName))
        default:
            break
        }
    }

    /// Fan out a single chat message to one target tmux session. When images
    /// are attached AND the assistant supports image upload, stage the body
    /// text first, paste images at `[Image #N]` marker positions, then submit
    /// once. Assistants that don't support image upload receive markdown image
    /// refs at those same marker positions.
    private func fanOutOneMessage(target: ChannelMemberTarget, body: String, imagePaths: [String],
                                  dispatch: @MainActor @Sendable (Action) -> Void) async {
        let canSendImages = target.assistant.supportsImageUpload && !imagePaths.isEmpty
        let bodyWithMarkdownImages = PromptImageLayout.replacingMarkersWithMarkdown(in: body, imagePaths: imagePaths)
        if let cardId = target.foreignCardId {
            // The owner master queues it (sent at once when the card is idle).
            await dispatch(.addQueuedPrompt(cardId: cardId, prompt: QueuedPrompt(body: bodyWithMarkdownImages, sendAutomatically: true), placement: .back))
            return
        }
        do {
            if canSendImages, let tmux = tmuxAdapter,
               let remotePaths = try await remoteMachines?.uploadImages(sessionName: target.sessionName, imagePaths: imagePaths) {
                // The images go over the bridge; the prompt points at them by path.
                let remoteBody = PromptImageLayout.replacingMarkersWithMarkdown(in: body, imagePaths: remotePaths)
                try await tmux.pastePrompt(to: target.sessionName, text: remoteBody)
            } else if canSendImages, let tmux = tmuxAdapter, let setClipboard = setClipboardImage {
                let images = imagePaths.compactMap { ImageAttachment.fromPath($0) }
                if !images.isEmpty {
                    let sender = ImageSender(tmux: tmux)
                    try await sender.waitForReady(sessionName: target.sessionName, assistant: target.assistant)
                    try await sender.sendPromptWithImages(
                        sessionName: target.sessionName,
                        prompt: body,
                        images: images,
                        assistant: target.assistant,
                        setClipboard: setClipboard
                    )
                } else {
                    try await tmux.pastePrompt(to: target.sessionName, text: bodyWithMarkdownImages)
                }
            } else {
                try await tmuxAdapter?.pastePrompt(to: target.sessionName, text: bodyWithMarkdownImages)
            }
        } catch {
            KanbanCodeLog.warn("effect", "fanout to \(target.sessionName) failed: \(error)")
        }
    }

    /// Per-key burst-throttler for chat notifications. First message fires
    /// immediately; subsequent ones within `burstWindow` are buffered and
    /// flushed as one summary notification.
    private func notifyThrottled(
        key: String,
        title: String,
        sender: String,
        body: String,
        userInfo: [String: String]
    ) async {
        let now = Date()
        if let existing = bursts[key], existing.windowEnd > now {
            // Inside an active window: buffer, don't fire. A scheduled flush
            // already exists — it'll pick up the new count.
            var updated = existing
            updated.extraCount += 1
            updated.lastSender = sender
            updated.lastBody = body
            bursts[key] = updated
            return
        }

        // Fire the immediate banner for the first message of a new window.
        await Self.postChatNotification(title: title, body: body, userInfo: userInfo)
        bursts[key] = Burst(
            windowEnd: now.addingTimeInterval(burstWindow),
            extraCount: 0,
            lastSender: sender,
            lastBody: body,
            userInfo: userInfo,
            title: title
        )
        // Schedule a flush shortly after window-end; if nothing accumulated
        // in the meantime, it's a no-op that just clears the entry.
        let windowDuration = burstWindow
        Task.detached { [weak self] in
            try? await Task.sleep(for: .seconds(windowDuration + 0.05))
            await self?.flushBurst(key: key)
        }
    }

    private func flushBurst(key: String) {
        guard let b = bursts.removeValue(forKey: key) else { return }
        guard b.extraCount > 0 else { return }
        let total = b.extraCount + 1
        let summaryBody = "\(total) new messages — latest from @\(b.lastSender): \(b.lastBody)"
        Task.detached { [title = b.title, userInfo = b.userInfo, summaryBody] in
            await Self.postChatNotification(title: title, body: summaryBody, userInfo: userInfo)
        }
    }

    /// Post a native macOS notification carrying enough routing info for the
    /// delegate to open the right drawer when the user taps it.
    ///
    /// The identifier is derived per-channel/dm so the summary banner emitted
    /// by `flushBurst` REPLACES the immediate banner in Notification Center
    /// rather than stacking — which would otherwise look like a duplicate.
    nonisolated static func postChatNotification(
        title: String,
        body: String,
        userInfo: [String: String]
    ) async {
        #if canImport(UserNotifications)
        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()
        guard settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional else {
            KanbanCodeLog.info("notify", "chat notification skipped: authorization=\(settings.authorizationStatus.rawValue)")
            return
        }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        content.userInfo = userInfo
        // Use a key stable for the same chat target so the system dedups the
        // immediate + summary banners within a burst window.
        let kind = userInfo["chatKind"] ?? "chat"
        let key = userInfo["channelName"] ?? userInfo["dmHandle"] ?? "unknown"
        let identifier = "kanban-chat-\(kind)-\(key)"
        let req = UNNotificationRequest(identifier: identifier, content: content, trigger: nil)
        do { try await center.add(req) } catch {
            KanbanCodeLog.info("notify", "chat notification failed: \(error)")
        }
        #endif
    }
}

/// Relay to avoid importing Kanban (UI) target from KanbanCodeCore.
/// The actual TerminalCache is in the Kanban target and registers itself on app launch.
@MainActor
public enum TerminalCacheRelay {
    public static var removeHandler: ((String) -> Void)?

    public static func remove(_ sessionName: String) {
        removeHandler?(sessionName)
    }
}

/// Relay for BrowserTabCache cleanup from KanbanCodeCore (same pattern as TerminalCacheRelay).
@MainActor
public enum BrowserTabCacheRelay {
    public static var removeAllHandler: ((String) -> Void)?

    public static func removeAll(cardId: String) {
        removeAllHandler?(cardId)
    }
}
