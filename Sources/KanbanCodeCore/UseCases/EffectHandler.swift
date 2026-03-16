import Foundation

/// Executes side effects produced by the Reducer.
/// All async operations (disk, network, tmux) go through here.
public actor EffectHandler {
    private let coordinationStore: CoordinationStore
    private let tmuxAdapter: TmuxManagerPort?
    private let setClipboardImage: (@Sendable (Data) -> Void)?

    public init(
        coordinationStore: CoordinationStore,
        tmuxAdapter: TmuxManagerPort? = nil,
        setClipboardImage: (@Sendable (Data) -> Void)? = nil
    ) {
        self.coordinationStore = coordinationStore
        self.tmuxAdapter = tmuxAdapter
        self.setClipboardImage = setClipboardImage
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
                if assistant.usesPastedPrompt {
                    try await tmuxAdapter?.pastePrompt(to: sessionName, text: promptBody)
                } else {
                    try await tmuxAdapter?.sendPrompt(to: sessionName, text: promptBody)
                }
            } catch {
                KanbanCodeLog.warn("effect", "sendPromptToTmux failed: \(error)")
            }

        case .sendPromptWithImagesToTmux(let sessionName, let promptBody, let imagePaths, let assistant):
            do {
                guard let tmux = tmuxAdapter, let setClipboard = setClipboardImage else { return }
                let images = imagePaths.compactMap { ImageAttachment.fromPath($0) }
                if !images.isEmpty {
                    let sender = ImageSender(tmux: tmux)
                    try await sender.waitForReady(sessionName: sessionName, assistant: assistant)
                    try await sender.sendImages(
                        sessionName: sessionName,
                        images: images,
                        assistant: assistant,
                        setClipboard: setClipboard
                    )
                }
                if assistant.usesPastedPrompt {
                    try await tmux.pastePrompt(to: sessionName, text: promptBody)
                } else {
                    try await tmux.sendPrompt(to: sessionName, text: promptBody)
                }
                for path in imagePaths {
                    try? FileManager.default.removeItem(atPath: path)
                }
            } catch {
                KanbanCodeLog.warn("effect", "sendPromptWithImagesToTmux failed: \(error)")
            }

        case .deleteFiles(let paths):
            for path in paths {
                try? FileManager.default.removeItem(atPath: path)
            }
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
