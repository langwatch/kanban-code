import Foundation
import KanbanCodeRemoteKit

/// Turns the app's cards into the wire cards of the remote control API.
public enum RemoteBoardMapper {

    public static func board(
        cards: [KanbanCodeCard],
        projects: [Project],
        liveSessions: Set<String>,
        agtopQueues: [String: [String]] = [:],
        generatedAt: Date = Date()
    ) -> RemoteBoard {
        RemoteBoard(
            cards: cards.map { card($0, liveSessions: liveSessions, agtopQueues: agtopQueues) }.sorted(by: order),
            projects: projects.map { RemoteProject(path: $0.path, name: $0.name) },
            generatedAt: generatedAt
        )
    }

    /// Newest activity first, so clients that show a flat list need no sort.
    static func order(_ a: RemoteCard, _ b: RemoteCard) -> Bool {
        let da = a.lastActivity ?? a.updatedAt
        let db = b.lastActivity ?? b.updatedAt
        if da != db { return da > db }
        return a.id < b.id
    }

    /// `agtopQueues` holds the queues of live agtop hosts by session name:
    /// an agtop card lists its host's queue ahead of any prompt the app
    /// itself holds for it.
    public static func card(_ card: KanbanCodeCard, liveSessions: Set<String>,
                            agtopQueues: [String: [String]] = [:]) -> RemoteCard {
        let link = card.link
        let hostQueue = link.tmuxLink.flatMap { agtopQueues[$0.sessionName] } ?? []
        let queued = hostQueue.enumerated().map { RemoteQueuedPrompt(id: agtopPromptId(index: $0.offset, text: $0.element), text: $0.element) }
            + (link.queuedPrompts ?? []).map {
                RemoteQueuedPrompt(id: $0.id, text: $0.body, imageCount: $0.imagePaths?.count ?? 0)
            }
        return RemoteCard(
            id: link.id,
            title: card.displayTitle,
            column: RemoteColumn(rawValue: link.column.rawValue) ?? .backlog,
            projectPath: link.projectPath ?? card.session?.projectPath,
            projectName: card.projectName,
            branch: link.worktreeLink?.branch ?? link.discoveredBranches?.first,
            worktreePath: link.worktreeLink?.path,
            assistant: link.effectiveAssistant.rawValue,
            runtime: runtime(of: link),
            isLive: isLive(link, liveSessions: liveSessions),
            isBusy: card.activityState == .activelyWorking || link.isLaunching == true,
            sessionId: link.sessionLink?.sessionId,
            terminals: terminals(of: link),
            prs: link.prLinks.map(pr),
            queuedPromptCount: queued.count,
            queuedPrompts: queued,
            parentCardId: link.parentCardId,
            archived: link.manuallyArchived,
            lastActivity: link.lastActivity,
            updatedAt: link.updatedAt
        )
    }

    /// The id of a message queued in an agtop host: its place and a hash of
    /// its text, so it can be found again after the queue moved.
    public static func agtopPromptId(index: Int, text: String) -> String {
        "agtop-\(index)-\(String(fnv1a(text), radix: 16))"
    }

    /// The place in `queue` of the message `id` names, preferring the place
    /// it had; nil when it is no longer queued or `id` is not an agtop one.
    public static func agtopQueueIndex(of id: String, in queue: [String]) -> Int? {
        let parts = id.split(separator: "-")
        guard parts.count == 3, parts[0] == "agtop", let index = Int(parts[1]) else { return nil }
        let hash = String(parts[2])
        let matches = { (i: Int) in String(fnv1a(queue[i]), radix: 16) == hash }
        if queue.indices.contains(index), matches(index) { return index }
        return queue.indices.first(where: matches)
    }

    static func fnv1a(_ text: String) -> UInt32 {
        var hash: UInt32 = 2_166_136_261
        for byte in text.utf8 {
            hash ^= UInt32(byte)
            hash = hash &* 16_777_619
        }
        return hash
    }

    /// Where the card's main session runs.
    public static func runtime(of link: Link) -> RemoteRuntime {
        guard let tmux = link.tmuxLink, tmux.isShellOnly != true else {
            return link.remote != nil ? .machine : .none
        }
        if AgtopSessionName.isAgtop(tmux.sessionName) { return .agtop }
        if link.remote != nil { return .machine }
        return .tmux
    }

    /// The assistant session of the card is running (tmux, agtop or a machine).
    public static func isLive(_ link: Link, liveSessions: Set<String>) -> Bool {
        guard let tmux = link.tmuxLink, tmux.isShellOnly != true, tmux.isPrimaryDead != true else { return false }
        return liveSessions.contains(tmux.sessionName)
    }

    /// The session prompts go to, when it is live.
    public static func liveAssistantSession(_ link: Link, liveSessions: Set<String>) -> String? {
        isLive(link, liveSessions: liveSessions) ? link.tmuxLink?.sessionName : nil
    }

    public static func terminals(of link: Link) -> [RemoteTerminal] {
        guard let tmux = link.tmuxLink else { return [] }
        var out: [RemoteTerminal] = []
        if tmux.isPrimaryDead != true {
            let label = tmux.tabNames?[tmux.sessionName]
                ?? (tmux.isShellOnly == true ? "Shell" : link.effectiveAssistant.displayName)
            out.append(RemoteTerminal(sessionName: tmux.sessionName, label: label, isPrimary: true))
        }
        for (i, name) in (tmux.extraSessions ?? []).enumerated() {
            let label = tmux.tabNames?[name] ?? "Shell \(i + 1)"
            out.append(RemoteTerminal(sessionName: name, label: label, isPrimary: false))
        }
        return out
    }

    static func pr(_ pr: PRLink) -> RemotePR {
        let status: String?
        switch pr.status {
        case .merged: status = "merged"
        case .closed: status = "closed"
        case nil: status = nil
        default: status = "open"
        }
        return RemotePR(number: pr.number, url: pr.url, title: pr.title, status: status)
    }

    /// A project by path, then by name (case-insensitive, also the folder name).
    public static func resolveProject(_ reference: String, in projects: [Project]) -> Project? {
        let trimmed = reference.trimmingCharacters(in: .whitespaces)
        let expanded = (trimmed as NSString).expandingTildeInPath
        let normalized = expanded.hasSuffix("/") && expanded.count > 1 ? String(expanded.dropLast()) : expanded
        if let byPath = projects.first(where: { $0.path == normalized }) { return byPath }
        let key = trimmed.lowercased()
        return projects.first { $0.name.lowercased() == key }
            ?? projects.first { ($0.path as NSString).lastPathComponent.lowercased() == key }
    }
}
