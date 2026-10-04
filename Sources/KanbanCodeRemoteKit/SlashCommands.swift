import Foundation

/// A command the chat composer offers once the text starts with `/`.
/// `GET /v1/cards/{id}/slash-commands` returns an array of them.
public struct RemoteSlashCommand: Codable, Sendable, Equatable, Identifiable {
    /// Where a command comes from.
    public enum Source {
        /// Handled by the Kanban chat itself (`/btw`, `/catchup`).
        public static let kanban = "kanban"
        /// A command of the coding agent (`/compact`, `/clear`).
        public static let agent = "agent"
        /// A skill or command of the session's project folder.
        public static let project = "project"
        /// A skill or command of the user's agent configuration.
        public static let user = "user"
        /// A skill or command of an enabled plugin, named `plugin:name`.
        public static let plugin = "plugin"
    }

    /// Without the leading slash: `catchup`, `posthog:signals`.
    public var name: String
    /// One line.
    public var description: String
    /// A `Source` value.
    public var source: String

    public var id: String { name }

    public init(name: String, description: String, source: String) {
        self.name = name
        self.description = description
        self.source = source
    }

    /// What the Kanban chat handles itself; nothing reaches the session.
    public static let kanban: [RemoteSlashCommand] = [
        RemoteSlashCommand(name: "catchup", description: "Sum up what happened since your last message, in a side panel",
                           source: Source.kanban),
        RemoteSlashCommand(name: "btw", description: "Ask about this session in a side panel, without writing into it",
                           source: Source.kanban),
    ]

    /// What the list shows next to the command, or nil for none.
    public var sourceLabel: String? {
        switch source {
        case Source.kanban: "Kanban"
        case Source.agent: nil
        case Source.project: "project"
        case Source.user: "skill"
        case Source.plugin: "plugin"
        default: source
        }
    }
}

/// The list over the composer: when it shows, what it holds and what the
/// keys do. Pure, shared by the Mac chat and the phone.
public enum SlashCommandMenu {
    /// The command name being typed, lowercased, or nil when the text is
    /// not one: the text has to start with `/` and hold no whitespace. A
    /// second slash makes it a path.
    public static func query(in text: String) -> String? {
        guard text.hasPrefix("/") else { return nil }
        let rest = text.dropFirst()
        guard !rest.contains(where: { $0.isWhitespace || $0 == "/" }) else { return nil }
        return rest.lowercased()
    }

    /// The commands matching `query`, best first: the exact name, names
    /// that start with it, names with a part that starts with it (after
    /// `:` or `-`), then names that contain it. Each group keeps the
    /// order of `commands`.
    public static func matches(query: String, in commands: [RemoteSlashCommand]) -> [RemoteSlashCommand] {
        let query = query.lowercased()
        guard !query.isEmpty else { return commands }
        var ranked: [(rank: Int, index: Int, command: RemoteSlashCommand)] = []
        for (index, command) in commands.enumerated() {
            guard let rank = rank(of: command.name.lowercased(), for: query) else { continue }
            ranked.append((rank, index, command))
        }
        return ranked.sorted { ($0.rank, $0.index) < ($1.rank, $1.index) }.map(\.command)
    }

    static func rank(of name: String, for query: String) -> Int? {
        if name == query { return 0 }
        if name.hasPrefix(query) { return 1 }
        guard name.contains(query) else { return nil }
        let parts = name.split { $0 == ":" || $0 == "-" || $0 == "_" }
        return parts.contains { $0.hasPrefix(query) } ? 2 : 3
    }

    /// The composer text after picking `command`.
    public static func completion(for command: RemoteSlashCommand) -> String {
        "/\(command.name) "
    }

    /// What Return or Tab puts in the composer for the selected command,
    /// or nil when the key keeps its usual meaning. Tab always completes.
    /// Return completes too, except on the command already typed in full,
    /// which it sends.
    public static func replacement(text: String, selected: RemoteSlashCommand?, isReturn: Bool) -> String? {
        guard let selected, let query = query(in: text) else { return nil }
        if isReturn, selected.name.lowercased() == query { return nil }
        return completion(for: selected)
    }

    /// The selection after an arrow key, wrapping around.
    public static func move(_ selection: Int, by delta: Int, count: Int) -> Int {
        guard count > 0 else { return 0 }
        return ((selection + delta) % count + count) % count
    }
}
