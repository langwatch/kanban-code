import Foundation
import UserNotifications

/// Executes side effects produced by the Reducer.
/// All async operations (disk, network, tmux) go through here.
public actor EffectHandler {
    private let coordinationStore: CoordinationStore
    private let tmuxAdapter: TmuxManagerPort?
    private let setClipboardImage: (@Sendable (Data) -> Void)?
    private let channelsStore: ChannelsStore
    private let notifier: NotifierPort?

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
        notifier: NotifierPort? = nil
    ) {
        self.coordinationStore = coordinationStore
        self.tmuxAdapter = tmuxAdapter
        self.setClipboardImage = setClipboardImage
        self.channelsStore = channelsStore ?? ChannelsStore()
        self.notifier = notifier
    }

    public func execute(_ effect: Effect, dispatch: @MainActor @Sendable (Action) -> Void) async {
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

        case .createTmuxSession(let cardId, let name, let path):
            do {
                try await tmuxAdapter?.createSession(name: name, path: path, command: nil)
                await dispatch(.terminalCreated(cardId: cardId, tmuxName: name))
            } catch {
                await dispatch(.terminalFailed(cardId: cardId, error: error.localizedDescription))
            }

        case .killTmuxSession(let name):
            try? await tmuxAdapter?.killSession(name: name)

        case .killTmuxSessions(let names):
            for name in names {
                try? await tmuxAdapter?.killSession(name: name)
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
        case .sendPromptToTmux(let sessionName, let promptBody, let assistant):
            do {
                if assistant.submitsPromptWithPaste {
                    try await tmuxAdapter?.pastePrompt(to: sessionName, text: promptBody)
                } else {
                    try await tmuxAdapter?.sendPrompt(to: sessionName, text: promptBody)
                }
            } catch {
                KanbanCodeLog.warn("effect", "sendPromptToTmux failed: \(error)")
            }

        case .sendPromptWithImagesToTmux(let sessionName, let promptBody, let imagePaths, let assistant):
            do {
                guard let tmux = tmuxAdapter else { return }
                let images = assistant.supportsImageUpload
                    ? imagePaths.compactMap { ImageAttachment.fromPath($0) }
                    : []
                if !images.isEmpty {
                    guard let setClipboard = setClipboardImage else { return }
                    let sender = ImageSender(tmux: tmux)
                    try await sender.waitForReady(sessionName: sessionName, assistant: assistant)
                    try await sender.sendImages(
                        sessionName: sessionName,
                        images: images,
                        assistant: assistant,
                        setClipboard: setClipboard
                    )
                }
                if assistant.submitsPromptWithPaste {
                    try await tmux.pastePrompt(to: sessionName, text: promptBody)
                } else {
                    try await tmux.sendPrompt(to: sessionName, text: promptBody)
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

        case .loadChannels:
            let channels = await channelsStore.loadChannels()
            await dispatch(.channelsLoaded(channels: channels))

        case .loadChannelMessages(let name):
            let msgs = await channelsStore.loadMessages(channel: name)
            await dispatch(.channelMessagesLoaded(channelName: name, messages: msgs))

        case .createChannelOnDisk(let name, let by):
            do {
                _ = try await channelsStore.createChannel(name: name, by: by)
            } catch {
                KanbanCodeLog.warn("effect", "createChannelOnDisk failed: \(error)")
                await dispatch(.setError("Failed to create channel: \(error.localizedDescription)"))
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
                    await fanOutOneMessage(target: target, body: bodyText, imagePaths: persistedImages)
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
            let msgs = await channelsStore.loadDMMessages(between: self_, and: other)
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
                    await fanOutOneMessage(target: target, body: bodyText, imagePaths: persistedImages)
                }
            } catch {
                KanbanCodeLog.warn("effect", "sendDMToDisk failed: \(error)")
                await dispatch(.setError("Failed to DM: \(error.localizedDescription)"))
            }
        }
    }

    /// Fan out a single chat message to one target tmux session. When images
    /// are attached AND the assistant supports image upload, paste each image
    /// (via `ImageSender`) first, then paste the body text — mirrors the
    /// chat-mode behaviour used inside a card. Assistants that don't support
    /// image upload get the body text plus a "[N image(s) attached]" hint so
    /// they know something was sent, even if they can't see it.
    private func fanOutOneMessage(target: ChannelMemberTarget, body: String, imagePaths: [String]) async {
        let canSendImages = target.assistant.supportsImageUpload && !imagePaths.isEmpty
        // Text suffix: markdown image refs so the recipient can also Read() the
        // persisted file (kept in sync with CLI's formatChannelBroadcast). This
        // is redundant with the clipboard paste for Claude, but the markdown
        // path is the ONLY way Gemini (and any other assistant that can't
        // receive binary pastes) can see what was attached.
        let imageRefs = imagePaths.isEmpty ? "" : "\n" + imagePaths.map { "![](\($0))" }.joined(separator: "\n")
        do {
            if canSendImages, let tmux = tmuxAdapter, let setClipboard = setClipboardImage {
                let images = imagePaths.compactMap { ImageAttachment.fromPath($0) }
                if !images.isEmpty {
                    let sender = ImageSender(tmux: tmux)
                    try await sender.waitForReady(sessionName: target.sessionName, assistant: target.assistant)
                    try await sender.sendImages(
                        sessionName: target.sessionName,
                        images: images,
                        assistant: target.assistant,
                        setClipboard: setClipboard
                    )
                }
                try await tmux.pastePrompt(to: target.sessionName, text: body + imageRefs)
            } else {
                try await tmuxAdapter?.pastePrompt(to: target.sessionName, text: body + imageRefs)
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
