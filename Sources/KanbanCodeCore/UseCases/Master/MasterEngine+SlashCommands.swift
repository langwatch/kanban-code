import Foundation
import KanbanCodeRemoteKit

// MARK: - Slash commands of a card's chat

extension MasterEngine {
    /// What the chat composer of the card offers after `/`: the chat's own
    /// commands, the agent's, and the skills and custom commands the
    /// session can run. They are read from the disk of the master that
    /// owns the card, so a card another master owns is asked there; while
    /// that master is away the list is the last one it gave, else what
    /// needs no disk.
    ///
    /// A list is kept for 30 seconds per card.
    public func slashCommands(cardId: String) async throws -> [RemoteSlashCommand] {
        guard let link = store.state.links[cardId] else { throw RemoteHostError.notFound("no card \(cardId)") }
        if let cached = slashCommandCache.read(cardId: cardId) { return cached }
        let assistant = link.effectiveAssistant
        let sessionName = link.tmuxLink?.sessionName
        let onMachine = sessionName.flatMap { platform.machineForSession($0) } != nil
        let sideChat = assistant == .claude && !onMachine

        if let owner = await ownerClient(forCard: cardId) {
            if let commands = try? await owner.slashCommands(cardId: cardId) {
                slashCommandCache.write(cardId: cardId, commands)
                return commands
            }
            return slashCommandCache.last(cardId: cardId)
                ?? SlashCommandCatalog.merged(assistant: assistant, sideChat: sideChat, disk: [])
        }
        // A session on an ssh or boxd machine reads that machine's disk.
        guard assistant == .claude, !onMachine else {
            return SlashCommandCatalog.merged(assistant: assistant, sideChat: sideChat, disk: [])
        }

        let transcript = ConversationExportCommand.transcriptPath(for: link, kanbanHome: platform.kanbanHome)
        let folders = [link.worktreeLink?.path, link.projectPath].compactMap { $0 }
        let isRush = sessionName.flatMap(RushSessionName.rushId(fromName:)) != nil
        let commands = await Task.detached(priority: .userInitiated) {
            let cwd = SlashCommandSession.folder(transcriptPath: transcript, candidates: folders)
            let config = SlashCommandSession.claudeConfigDirectory(transcriptPath: transcript, isRush: isRush)
            let disk = ClaudeCommandFiles.commands(configDirectory: config, cwd: cwd)
            return SlashCommandCatalog.merged(assistant: assistant, sideChat: sideChat, disk: disk)
        }.value
        slashCommandCache.write(cardId: cardId, commands)
        return commands
    }

    /// Reads the card's list and puts it in the board state, for the chat
    /// composer on this master. A failed read keeps what the state holds.
    public func refreshSlashCommands(cardId: String) {
        Task { [weak self] in
            guard let self, let commands = try? await self.slashCommands(cardId: cardId) else { return }
            self.store.dispatch(.slashCommandsLoaded(cardId: cardId, commands: commands))
        }
    }

    /// What the composer shows before the first read: what needs no disk.
    public func slashCommandsShown(cardId: String, assistant: CodingAssistant) -> [RemoteSlashCommand] {
        store.state.slashCommands[cardId]
            ?? SlashCommandCatalog.merged(assistant: assistant, sideChat: assistant == .claude, disk: [])
    }
}

/// Where a card's session runs, for reading its skills.
public enum SlashCommandSession {
    /// The session's folder: the one its transcript is filed under, else
    /// the first of the card's folders that exists.
    public static func folder(transcriptPath: String?, candidates: [String]) -> String? {
        if let transcriptPath, let folder = SideChatSession.folder(transcriptPath: transcriptPath, candidates: candidates) {
            return folder
        }
        return candidates.first { ClaudeCommandFiles.isDirectory($0) }
    }

    /// The `CLAUDE_CONFIG_DIR` the session's Claude Code runs with, or nil
    /// for `~/.claude`: the rush account in use for a rush card, the
    /// folder the transcript sits in, else this process's own variable.
    public static func claudeConfigDirectory(
        transcriptPath: String?, isRush: Bool, home: String = NSHomeDirectory(),
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> String? {
        if let directory = SideChatSession.claudeConfigDirectory(
            transcriptPath: transcriptPath ?? "", isRush: isRush, home: home) {
            return directory
        }
        if transcriptPath != nil { return nil }
        return environment["CLAUDE_CONFIG_DIR"].flatMap { $0.isEmpty ? nil : $0 }
    }
}

/// The lists read lately, by card.
final class SlashCommandCache: @unchecked Sendable {
    private struct Entry {
        var at: Date
        var commands: [RemoteSlashCommand]
    }

    private let lock = NSLock()
    private var entries: [String: Entry] = [:]
    let lifetime: TimeInterval

    init(lifetime: TimeInterval = 30) {
        self.lifetime = lifetime
    }

    func read(cardId: String, now: Date = .now) -> [RemoteSlashCommand]? {
        lock.withLock {
            guard let entry = entries[cardId], now.timeIntervalSince(entry.at) < lifetime else { return nil }
            return entry.commands
        }
    }

    /// The card's last list, whatever its age.
    func last(cardId: String) -> [RemoteSlashCommand]? {
        lock.withLock { entries[cardId]?.commands }
    }

    func write(cardId: String, _ commands: [RemoteSlashCommand], now: Date = .now) {
        lock.withLock {
            entries = entries.filter { now.timeIntervalSince($0.value.at) < 24 * 3600 }
            entries[cardId] = Entry(at: now, commands: commands)
        }
    }
}
