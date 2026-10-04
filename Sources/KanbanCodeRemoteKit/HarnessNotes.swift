import Foundation

/// A transcript record with the user role that the harness wrote itself.
/// The chat shows it as a note, not as a message of the human.
public enum HarnessNote: Equatable, Sendable {
    /// The summary Claude Code writes in place of the conversation it
    /// compacted. The note reads `compactedTitle` and opens to the summary.
    case compactionSummary
    /// The `/compact` command as the session records it, with the
    /// instructions given to it.
    case compactCommand(String)

    /// What the note of a compaction summary reads.
    public static let compactedTitle = "Conversation compacted"

    static let summaryPrefix = "This session is being continued from a previous conversation"
    static let compactCommandName = "/compact"

    /// The note a user record's text is, or nil for a message.
    public static func classify(_ text: String) -> HarnessNote? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix(summaryPrefix) { return .compactionSummary }
        let firstLine = trimmed.prefix { !$0.isNewline }
        let word = firstLine.prefix { !$0.isWhitespace }
        if word == compactCommandName {
            return .compactCommand(firstLine.trimmingCharacters(in: .whitespaces))
        }
        return nil
    }

    /// The one line the note shows.
    public var title: String {
        switch self {
        case .compactionSummary: Self.compactedTitle
        case .compactCommand(let line): line
        }
    }
}
