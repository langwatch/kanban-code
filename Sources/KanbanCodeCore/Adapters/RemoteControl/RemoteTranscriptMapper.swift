import Foundation
import KanbanCodeRemoteKit

/// Turns transcript turns (Claude, Codex, Gemini) into the chat messages of
/// the remote control API, and pages them.
public enum RemoteTranscriptMapper {
    /// A tool line is cut to this many characters.
    static let toolLineLimit = 200

    /// Messages of the given turns, oldest first. A user turn is one message;
    /// an assistant turn is its text, with one `tool` message per tool call.
    /// Thinking and tool results are left out. A user turn the harness
    /// wrote (a compaction summary, the `/compact` command) is a `system`
    /// note.
    public static func messages(from turns: [ConversationTurn]) -> [RemoteMessage] {
        var out: [RemoteMessage] = []
        for turn in turns {
            let at = turn.timestamp.flatMap(parseDate)
            var index = 0
            func add(_ role: RemoteMessage.Role, _ text: String, detail: String? = nil) {
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { return }
                out.append(RemoteMessage(id: "\(turn.lineNumber).\(index)", role: role, text: trimmed, at: at, detail: detail))
                index += 1
            }
            func addUser(_ text: String) {
                switch HarnessNote.classify(text) {
                case .compactionSummary?:
                    add(.system, HarnessNote.compactedTitle, detail: text.trimmingCharacters(in: .whitespacesAndNewlines))
                case .compactCommand(let line)?:
                    add(.system, line)
                case nil:
                    add(.user, text)
                }
            }

            if turn.role == "user" {
                if turn.contentBlocks.isEmpty {
                    addUser(PromptImageLayout.replacingMarkdownImagesWithMarkers(in: turn.textPreview))
                    continue
                }
                let onlyToolResults = turn.contentBlocks.allSatisfy {
                    if case .toolResult = $0.kind { return true }
                    return false
                }
                if onlyToolResults { continue }
                var text = userText(turn.contentBlocks.filter { $0.kind == .text }.map(\.text))
                if turn.imageCount > 0 && !PromptImageLayout.marksEveryImage(text, imageCount: turn.imageCount) {
                    let images = turn.imageCount == 1 ? "[image]" : "[\(turn.imageCount) images]"
                    text = text.isEmpty ? images : text + "\n\n" + images
                }
                addUser(text)
                continue
            }

            if turn.contentBlocks.isEmpty {
                add(turn.role == "assistant" ? .assistant : .system, turn.textPreview)
                continue
            }
            var pending: [String] = []
            func flush() {
                if !pending.isEmpty { add(.assistant, pending.joined(separator: "\n\n")) }
                pending = []
            }
            for block in turn.contentBlocks {
                switch block.kind {
                case .text:
                    pending.append(block.text)
                case .toolUse(let name, _, _):
                    flush()
                    add(.tool, toolLine(name: name, text: block.text))
                case .agentCall(let description, let subagentType, _):
                    flush()
                    add(.tool, toolLine(name: "Agent", text: [subagentType, description].compactMap { $0 }.joined(separator: ": ")))
                case .planModeEnter:
                    flush()
                    add(.tool, "Entered plan mode")
                case .planModeExit(let plan):
                    flush()
                    add(.assistant, "Plan:\n\n" + plan)
                case .askUserQuestion(let questions, _):
                    flush()
                    let lines = questions.map { q -> String in
                        let options = q.options.map { "- \($0.label)" }.joined(separator: "\n")
                        return options.isEmpty ? q.question : q.question + "\n" + options
                    }
                    add(.assistant, lines.joined(separator: "\n\n"))
                case .thinking, .toolResult:
                    break
                }
            }
            flush()
        }
        return out
    }

    /// A user turn's text blocks as one text. An image sent at its
    /// [Image #N] marker splits the text there, so a block ending in a
    /// marker runs on into the next; images sent by path read as markers.
    static func userText(_ blocks: [String]) -> String {
        var out = ""
        for block in blocks {
            if !out.isEmpty && !endsWithMarker(out) { out += "\n\n" }
            out += block
        }
        return PromptImageLayout.replacingMarkdownImagesWithMarkers(in: out)
    }

    private static func endsWithMarker(_ text: String) -> Bool {
        guard text.hasSuffix("]"), let start = text.range(of: PromptImageLayout.markerPrefix, options: .backwards) else { return false }
        return Int(text[start.upperBound..<text.index(before: text.endIndex)]) != nil
    }

    static func toolLine(name: String, text: String) -> String {
        let firstLine = text.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: true).first.map(String.init) ?? ""
        var line = firstLine.isEmpty || firstLine == name ? name : (firstLine.hasPrefix(name) ? firstLine : "\(name) \(firstLine)")
        if line.count > toolLineLimit { line = String(line.prefix(toolLineLimit - 1)) + "…" }
        return line
    }

    static func parseDate(_ s: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: s) ?? ISO8601DateFormatter().date(from: s)
    }

    /// Loads the newest `maxTurns` turns and whether older ones exist.
    public typealias TailLoader = @Sendable (_ maxTurns: Int) async throws -> (turns: [ConversationTurn], hasMore: Bool)

    /// The newest `limit` messages older than the message `before` (the
    /// `olderCursor` of the previous page), oldest first. Reads more of the
    /// tail until it holds enough messages.
    public static func page(cardId: String, limit: Int, before: String?, load: TailLoader) async throws -> RemoteTranscript {
        var maxTurns = max(limit, 20)
        while true {
            let (turns, hasMore) = try await load(maxTurns)
            let all = messages(from: turns)
            var end = all.count
            if let before {
                if let i = all.firstIndex(where: { $0.id == before }) {
                    end = i
                } else if hasMore {
                    maxTurns *= 2
                    continue
                } else {
                    throw RemoteHostError.badRequest("unknown cursor \(before)")
                }
            }
            if end < limit && hasMore {
                maxTurns *= 2
                continue
            }
            let start = max(0, end - limit)
            let slice = Array(all[start..<end])
            let more = start > 0 || hasMore
            return RemoteTranscript(cardId: cardId, messages: slice, olderCursor: more ? slice.first?.id : nil)
        }
    }
}
