import Foundation
import KanbanCodeRemoteKit

/// The messages of a session since the human's last one, numbered so a
/// catch-up can cite them (`[m7]`).
public enum CatchUpIndex {
    /// Characters of a message shown in the index.
    public static let previewLimit = 100
    /// The index keeps its first `head` and last `tail` messages when a
    /// session wrote more than both together.
    public static let head = 40
    public static let tail = 360

    /// One entry per turn the chat draws as a message: what the human and
    /// other senders wrote, and what the assistant said. Tool calls and
    /// their results are left out.
    /// - Parameter humanOffset: where the human's own message is, so it
    ///   reads as `you`.
    public static func build(turns: [ConversationTurn], humanOffset: Int?) -> [RemoteSideChatRef] {
        var kept: [(offset: Int, role: String, at: Date?, text: String)] = []
        for turn in turns where !turn.isQueued {
            let text = turn.contentBlocks.isEmpty
                ? turn.textPreview
                : turn.contentBlocks.compactMap { block -> String? in
                    if case .text = block.kind { return block.text }
                    return nil
                }.joined(separator: "\n")
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            let role: String
            var shown = trimmed
            if turn.role == "assistant" {
                role = "assistant"
            } else if turn.lineNumber == humanOffset {
                role = "you"
            } else {
                switch CardPromptReader.entry(text: trimmed) {
                case .delivered(let delivered)?:
                    role = "message from \(delivered.from)"
                    shown = delivered.text
                case .typed?:
                    role = "message delivered to the session"
                case nil:
                    role = "notification"
                }
            }
            kept.append((turn.lineNumber, role, turn.timestamp.flatMap(HumanMessageFinder.parseDate), shown))
        }
        if kept.count > head + tail {
            kept = Array(kept.prefix(head)) + Array(kept.suffix(tail))
        }
        return kept.enumerated().map { index, entry in
            RemoteSideChatRef(ref: "m\(index + 1)", offset: entry.offset, role: entry.role, at: entry.at,
                              preview: preview(entry.text, role: entry.role))
        }
    }

    /// The first characters of a message on one line; an assistant message
    /// carries its length, so the long final report stands out.
    static func preview(_ text: String, role: String) -> String {
        let flat = text.split(whereSeparator: \.isNewline).joined(separator: " ")
        let cut = flat.count > previewLimit ? String(flat.prefix(previewLimit)) + "…" : flat
        guard role == "assistant", text.count > 600 else { return cut }
        return "(\(text.count) characters) " + cut
    }

    /// The index as the side model reads it, one message per line:
    /// `[m7] 14:02 assistant: first 100 chars…`.
    public static func text(_ refs: [RemoteSideChatRef], timeZone: TimeZone = .current) -> String {
        let time = DateFormatter()
        time.locale = Locale(identifier: "en_US_POSIX")
        time.timeZone = timeZone
        time.dateFormat = "HH:mm"
        let day = DateFormatter()
        day.locale = Locale(identifier: "en_US_POSIX")
        day.timeZone = timeZone
        day.dateFormat = "MMM d HH:mm"
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let firstDay = refs.first?.at.map { calendar.startOfDay(for: $0) }
        return refs.map { ref in
            var stamp = ""
            if let at = ref.at {
                let sameDay = firstDay == calendar.startOfDay(for: at)
                stamp = " " + (sameDay ? time : day).string(from: at)
            }
            return "[\(ref.ref)]\(stamp) \(ref.role): \(ref.preview)"
        }.joined(separator: "\n")
    }
}

/// The prompts a side run gets.
public enum SideChatPrompt {
    /// Characters of the human's last message quoted to the side model.
    public static let quoteLimit = 200

    static let preamble = """
        This is a side request, apart from the conversation. Answer it and stop. \
        Answer from what this conversation already holds. Do not use tools, do not continue or change any task.
        """

    public static func quote(_ text: String) -> String {
        let flat = text.split(whereSeparator: \.isNewline).joined(separator: " ")
            .trimmingCharacters(in: .whitespaces)
        return flat.count > quoteLimit ? String(flat.prefix(quoteLimit)) + "…" : flat
    }

    private static func history(_ exchanges: [RemoteSideChatExchange]) -> String {
        guard !exchanges.isEmpty else { return "" }
        var lines = ["Earlier in this side chat:"]
        for exchange in exchanges {
            lines.append("I asked: " + exchange.question)
            lines.append("You answered: " + exchange.answer)
        }
        return lines.joined(separator: "\n") + "\n\n"
    }

    /// A side question about the session.
    public static func btw(question: String, history: [RemoteSideChatExchange] = []) -> String {
        """
        \(preamble) Keep it short and plain.

        \(self.history(history))Question: \(question.trimmingCharacters(in: .whitespacesAndNewlines))
        """
    }

    /// The catch-up since the human's last message. `index` is
    /// `CatchUpIndex.text` of the messages since then.
    /// `humanText` is nil for a session the human never wrote in.
    /// `fromStart` false: the index covers only the session's recent end,
    /// with no message of his in it.
    public static func catchUp(humanText: String?, index: String, fromStart: Bool = true) -> String {
        let since = humanText.map { "since I sent this message: \"\(quote($0))\"" }
            ?? (fromStart ? "since it started" : "recently (the index covers only the latest part of a long session)")
        return """
        \(preamble)

        I have been away. Catch me up on what happened in this session \(since)

        This is the index of the messages since then. Each has an id such as [m7]:

        \(index.isEmpty ? "(no messages since then)" : index)

        Write the catch-up as JSON Lines: one JSON object per line and nothing else, no code fence, no text around it. \
        Each line is {"section": "<id>", "text": "<one short sentence>", "refs": ["m7"]}.

        The sections, in this order. Leave a section out when it has nothing:
        - "asked": what I asked, one line.
        - "status": where it stands now: done, in progress or stopped. One or two lines.
        - "report": one line, only when you wrote a long final report of the main task: \
        {"section": "report", "text": "Full report", "refs": ["<that message>"]}. Link to it, do not restate it.
        - "facts": the key facts I should pay attention to in the result.
        - "waiting": what waits on me: actions and decisions only I can take.
        - "blocked": what is blocked or failed.
        - "other": what else happened since (messages from other agents, monitors, pull request babysitting, \
        background tasks), one line each. Lowest priority, keep it short.

        Rules: very condensed. Plain language, short sentences, no jargon, no em-dashes. \
        Every line cites at least one message in "refs", using only ids from the index.
        """
    }
}
