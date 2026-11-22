import Foundation

/// Claude Code's Code Mode, read back for the chat.
///
/// In Code Mode the model has one `REPL` tool and writes JavaScript that calls
/// the other tools. The transcript records that as:
/// - an assistant `REPL` tool call whose input is `{code, description?}`;
/// - its tool result, either the script's output wrapped in `<repl-output>`,
///   or `(dispatched #N)` when the script runs on in the background;
/// - every tool the script called as its own assistant record, with an id
///   starting `repl_` and a `<synthetic>` model;
/// - the outcome of a dispatched script later, as an `<event kind="repl-eval"
///   eval="N" ...>` envelope: in the result of a `Poll` call, or as a queued
///   user message when it lands mid-turn.
///
/// ``fold(_:)`` turns that back into one row per script: the calls it made as
/// its summary, and its outcome as its result.
public enum CodeModeTranscript {
    public static let replToolName = "REPL"
    static let pollToolName = "Poll"

    /// The keys of a folded `REPL` call's input map.
    public enum InputKey {
        public static let code = "code"
        public static let description = "description"
        /// The calls the script made, one per line, as ``callLine(name:input:)`` writes them.
        public static let calls = "calls"
    }

    // MARK: - Envelopes

    /// One `<event>` the harness delivered.
    public struct Event: Sendable, Equatable {
        public var kind: String
        public var evalId: Int?
        public var ms: Int?
        public var status: String?
        public var body: String
    }

    /// Whether a user text is an event delivery the harness wrote, not words
    /// someone typed.
    public static func isEventEnvelope(_ text: String) -> Bool {
        let trimmed = text.drop { $0.isWhitespace }
        return trimmed.hasPrefix("<event nonce=") || trimmed.hasPrefix("<event kind=")
            || trimmed.hasPrefix("<system>authentic event nonces")
    }

    /// The events in a delivery, in order.
    public static func events(in text: String) -> [Event] {
        let nonces = authenticNonces(in: text)
        var starts: [String.Index] = []
        var search = text.startIndex
        while let r = text.range(of: "<event ", range: search..<text.endIndex) {
            let rest = text[r.lowerBound...]
            let header = rest[..<(rest.firstIndex(of: ">") ?? rest.endIndex)]
            if nonces.isEmpty || nonces.contains(where: { header.contains("nonce=\"\($0)\"") }) {
                starts.append(r.lowerBound)
            }
            search = r.upperBound
        }
        var events: [Event] = []
        for (i, start) in starts.enumerated() {
            let end = i + 1 < starts.count ? starts[i + 1] : text.endIndex
            guard let headerEnd = text.range(of: ">", range: start..<end) else { continue }
            var header = String(text[text.index(start, offsetBy: 7)..<headerEnd.lowerBound])
            let selfClosing = header.hasSuffix("/")
            if selfClosing { header.removeLast() }
            let attrs = attributes(header)
            var body = selfClosing ? "" : String(text[headerEnd.upperBound..<end])
            if let close = body.range(of: "</event>", options: .backwards) {
                body = String(body[..<close.lowerBound])
            }
            events.append(Event(
                kind: attrs["kind"] ?? "event",
                evalId: attrs["eval"].flatMap(Int.init),
                ms: attrs["ms"].flatMap(Int.init),
                status: attrs["status"],
                body: body.trimmingCharacters(in: .whitespacesAndNewlines)
            ))
        }
        return events
    }

    /// A delivery cut down for keeping: each event with its body capped, so
    /// one long result does not push the events after it out of the text.
    public static func compactDelivery(_ text: String, bodyLimit: Int = 10_240) -> String {
        let events = events(in: text)
        guard !events.isEmpty else { return String(text.prefix(bodyLimit)) }
        return events.map { event in
            var attrs = "kind=\"\(event.kind)\""
            if let n = event.evalId { attrs += " eval=\"\(n)\"" }
            if let ms = event.ms { attrs += " ms=\"\(ms)\"" }
            if let status = event.status { attrs += " status=\"\(status)\"" }
            return "<event \(attrs)>\n\(event.body.prefix(bodyLimit))\n</event>"
        }.joined(separator: "\n")
    }

    /// What a script's output says, as plain text: its log, then its result,
    /// error or refusal. Works on an event body and on a `<repl-output>`.
    public static func outputText(_ raw: String) -> String {
        var body = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if body.hasPrefix("<repl-output>") {
            body = String(body.dropFirst("<repl-output>".count))
            if let close = body.range(of: "</repl-output>", options: .backwards) {
                body = String(body[..<close.lowerBound])
            }
        }
        body = removing(tag: "tools-used-before-summary", from: body)
        var parts: [String] = []
        for tag in ["log", "refused", "error", "result"] {
            guard let value = tagContent(tag, in: body) else { continue }
            let text = unescape(value).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            switch tag {
            case "result": parts.append(text)
            default: parts.append("\(tag):\n\(text)")
            }
        }
        if parts.isEmpty {
            let hasTags = ["log", "refused", "error", "result"].contains { body.contains("<\($0)") }
            return hasTags ? "" : unescape(body).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return parts.joined(separator: "\n\n")
    }

    /// The result row of a script: how it ended, how long it took, and what
    /// it gave back.
    public static func resultText(status: String?, ms: Int?, output: String) -> String {
        var head: [String] = []
        if let status { head.append(status) }
        if let ms { head.append("\(ms) ms") }
        let header = head.joined(separator: " · ")
        let text = output.isEmpty ? "(no result)" : output
        return header.isEmpty ? text : "\(header)\n\n\(text)"
    }

    // MARK: - Call lines

    /// One tool call as a short line, `Bash git status` or `Read Foo.swift`.
    public static func callLine(name: String, input: [String: Any]) -> String {
        func string(_ key: String) -> String? {
            guard let value = input[key] as? String else { return nil }
            let line = value.split(separator: "\n", omittingEmptySubsequences: true).first.map(String.init) ?? ""
            return line.isEmpty ? nil : line
        }
        let target: String?
        switch name {
        case "Bash": target = string("command").map(droppingLeadingCd) ?? string("description")
        case "Read", "Write", "Edit", "NotebookEdit":
            target = (string("file_path") ?? string("notebook_path")).map { ($0 as NSString).lastPathComponent }
        case "Grep": target = string("pattern").map { "\"\($0)\"" }
        case "Glob": target = string("pattern")
        case "WebFetch": target = string("url").map { URL(string: $0)?.host ?? $0 }
        case "WebSearch": target = string("query")
        case "Agent": target = string("description")
        case "Skill": target = string("skill")
        default: target = nil
        }
        guard let target else { return name }
        let short = target.count > 120 ? String(target.prefix(119)) + "…" : target
        return "\(name) \(short)"
    }

    /// The one line a script stands behind in the chat: the calls it made, or
    /// what it says it does, or the start of its code.
    public static func summary(calls: [String], description: String?, code: String) -> String {
        if !calls.isEmpty {
            let shown = calls.prefix(3).joined(separator: " · ")
            return calls.count > 3 ? "\(shown) · +\(calls.count - 3) more" : shown
        }
        if let description, !description.isEmpty { return description }
        let firstLine = code.split(separator: "\n", omittingEmptySubsequences: true).first.map(String.init) ?? ""
        return firstLine.trimmingCharacters(in: .whitespaces)
    }

    // MARK: - Fold

    /// Whether any turn holds Code Mode records, so the fold can be skipped.
    public static func containsCodeMode(_ turns: [ConversationTurn]) -> Bool {
        turns.contains { turn in
            turn.contentBlocks.contains { block in
                switch block.kind {
                case .toolUse(let name, _, let id):
                    return name == replToolName || isInnerCallId(id)
                case .toolResult(let name, _):
                    return name == replToolName
                default:
                    return false
                }
            }
        }
    }

    /// The turns with every script as one call: the tools it called folded
    /// into its summary, `Poll` calls gone, and its outcome as its result.
    /// Turns left with nothing in them are dropped; nothing else changes.
    public static func fold(_ turns: [ConversationTurn]) -> [ConversationTurn] {
        guard containsCodeMode(turns) else { return turns }

        var replIds: Set<String> = []
        var pollIds: Set<String> = []
        var calls: [String: [String]] = [:]
        var evalToRepl: [Int: String] = [:]
        var outcome: [String: String] = [:]
        /// The newest script. A script that runs in place has its calls
        /// recorded between it and its result.
        var newest: String?
        /// The scripts whose outcome was just delivered. The calls a background
        /// script made are recorded right after its outcome, until the model
        /// writes again.
        var justDelivered: [String] = []
        /// The turn and block a script's result goes in.
        var resultSlot: [String: (turn: Int, block: Int)] = [:]
        var eventSlots: [(turn: Int, block: Int, events: [Event])] = []

        for (t, turn) in turns.enumerated() {
            for (b, block) in turn.contentBlocks.enumerated() {
                switch block.kind {
                case .toolUse(let name, _, let id) where isInnerCallId(id):
                    let owner = justDelivered.last ?? newest
                    if let owner {
                        calls[owner, default: []].append(callLine(name: name, input: decode(block.rawInputJSON)))
                    }
                case .toolUse(let name, _, let id?) where name == replToolName:
                    replIds.insert(id)
                    newest = id
                    justDelivered = []
                case .toolUse(let name, _, let id?) where name == pollToolName:
                    pollIds.insert(id)
                    justDelivered = []
                case .toolResult(_, let id?) where replIds.contains(id):
                    if resultSlot[id] == nil { resultSlot[id] = (t, b) }
                    if let n = dispatchedEvalId(block.text) {
                        evalToRepl[n] = id
                    } else {
                        outcome[id] = resultText(status: nil, ms: nil, output: outputText(block.text))
                    }
                case .toolResult(let name, let id):
                    let isPoll = id.map { pollIds.contains($0) } ?? false
                    guard isPoll || (name == replToolName && id == nil) else { continue }
                    let events = events(in: block.text)
                    eventSlots.append((t, b, events))
                    var delivered: [String] = []
                    for event in events where event.kind == "repl-eval" {
                        guard let n = event.evalId, let owner = evalToRepl[n] else { continue }
                        outcome[owner] = resultText(status: event.status, ms: event.ms, output: outputText(event.body))
                        delivered.append(owner)
                    }
                    if !delivered.isEmpty { justDelivered = delivered }
                default:
                    if turn.role == "assistant" { justDelivered = [] }
                }
            }
        }

        // A script whose outcome came with no result record of its own in view
        // takes the place of the event that brought it.
        for slot in eventSlots {
            for event in slot.events where event.kind == "repl-eval" {
                guard let n = event.evalId, let owner = evalToRepl[n], resultSlot[owner] == nil else { continue }
                resultSlot[owner] = (slot.turn, slot.block)
            }
        }
        var resultAt: [Int: [Int: String]] = [:]
        for (id, slot) in resultSlot { resultAt[slot.turn, default: [:]][slot.block] = id }

        var out: [ConversationTurn] = []
        out.reserveCapacity(turns.count)
        for (t, turn) in turns.enumerated() {
            var blocks: [ContentBlock] = []
            var changed = false
            for (b, block) in turn.contentBlocks.enumerated() {
                if let id = resultAt[t]?[b] {
                    let text = outcome[id] ?? "running"
                    blocks.append(ContentBlock(kind: .toolResult(toolName: replToolName, toolUseId: id), text: text))
                    changed = true
                    continue
                }
                switch block.kind {
                case .toolUse(let name, let input, let id?) where name == replToolName && replIds.contains(id):
                    let raw = decode(block.rawInputJSON)
                    let code = raw["code"] as? String ?? input[InputKey.code] ?? ""
                    let description = raw["description"] as? String
                    let lines = calls[id] ?? []
                    var map: [String: String] = [InputKey.code: code]
                    if let description { map[InputKey.description] = description }
                    if !lines.isEmpty { map[InputKey.calls] = lines.joined(separator: "\n") }
                    blocks.append(ContentBlock(
                        kind: .toolUse(name: name, input: map, id: id),
                        text: summary(calls: lines, description: description, code: code),
                        rawInputJSON: block.rawInputJSON,
                        isBackground: block.isBackground
                    ))
                    changed = true
                case .toolUse(_, _, let id) where isInnerCallId(id):
                    changed = true
                case .toolUse(let name, _, _) where name == pollToolName:
                    changed = true
                case .toolResult(let name, let id):
                    let folds = id.map { replIds.contains($0) || pollIds.contains($0) || isInnerCallId($0) } ?? (name == replToolName)
                    if folds { changed = true } else { blocks.append(block) }
                default:
                    blocks.append(block)
                }
            }
            if !changed {
                out.append(turn)
                continue
            }
            if blocks.isEmpty { continue }
            out.append(ConversationTurn(
                index: turn.index,
                lineNumber: turn.lineNumber,
                role: turn.role,
                textPreview: turn.textPreview,
                timestamp: turn.timestamp,
                contentBlocks: blocks,
                imageCount: turn.imageCount,
                modelName: turn.modelName,
                endLineNumber: turn.endLineNumber,
                isQueued: turn.isQueued
            ))
        }
        return out
    }

    /// Whether ``fold(_:)`` takes this call out of its turn: a call a script
    /// made, or a `Poll`.
    public static func isFoldedAway(_ block: ContentBlock) -> Bool {
        guard case .toolUse(let name, _, let id) = block.kind else { return false }
        return name == pollToolName || isInnerCallId(id)
    }

    // MARK: - Helpers

    /// `cd <dir> && git status` as `git status`: scripts run most commands
    /// from a worktree, and its path is all a short line would show.
    static func droppingLeadingCd(_ command: String) -> String {
        guard command.hasPrefix("cd ") else { return command }
        var quote: Character?
        var index = command.index(command.startIndex, offsetBy: 3)
        while index < command.endIndex {
            let c = command[index]
            if let q = quote {
                if c == q { quote = nil }
            } else if c == "'" || c == "\"" {
                quote = c
            } else if c == "&" || c == ";" {
                var rest = command[index...].drop { $0 == "&" || $0 == ";" }
                rest = rest.drop { $0.isWhitespace }
                return rest.isEmpty ? command : String(rest)
            }
            index = command.index(after: index)
        }
        return command
    }

    /// Ids Code Mode gives the calls a script makes.
    static func isInnerCallId(_ id: String?) -> Bool {
        guard let id else { return false }
        return id.hasPrefix("repl_") || id.hasPrefix("repl-")
    }

    static func dispatchedEvalId(_ text: String) -> Int? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("(dispatched #"), trimmed.hasSuffix(")") else { return nil }
        return Int(trimmed.dropFirst("(dispatched #".count).dropLast())
    }

    private static func decode(_ data: Data?) -> [String: Any] {
        guard let data else { return [:] }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
    }

    private static func authenticNonces(in text: String) -> [String] {
        guard let start = text.range(of: "<system>authentic event nonces for this delivery:"),
              let end = text.range(of: "</system>", range: start.upperBound..<text.endIndex) else { return [] }
        let line = text[start.upperBound..<end.lowerBound]
        let list = line.split(separator: "\u{2014}", maxSplits: 1).first ?? line[...]
        return list.split(whereSeparator: { $0.isWhitespace }).map(String.init)
    }

    private static func attributes(_ header: String) -> [String: String] {
        var attrs: [String: String] = [:]
        var rest = Substring(header)
        while let eq = rest.range(of: "=\"") {
            let key = rest[..<eq.lowerBound].split(whereSeparator: { $0.isWhitespace }).last.map(String.init) ?? ""
            let afterQuote = rest[eq.upperBound...]
            guard let close = afterQuote.firstIndex(of: "\"") else { break }
            if !key.isEmpty { attrs[key] = String(afterQuote[..<close]) }
            rest = afterQuote[afterQuote.index(after: close)...]
        }
        return attrs
    }

    /// The text between the first `<tag>` and the last `</tag>`, or "" for
    /// `<tag/>`; nil when the tag is not there.
    private static func tagContent(_ tag: String, in text: String) -> String? {
        if let open = text.range(of: "<\(tag)>") {
            if let close = text.range(of: "</\(tag)>", options: .backwards, range: open.upperBound..<text.endIndex) {
                return String(text[open.upperBound..<close.lowerBound])
            }
            return String(text[open.upperBound...])
        }
        return text.contains("<\(tag)/>") ? "" : nil
    }

    private static func removing(tag: String, from text: String) -> String {
        guard let open = text.range(of: "<\(tag)>"),
              let close = text.range(of: "</\(tag)>", range: open.upperBound..<text.endIndex) else { return text }
        return String(text[..<open.lowerBound]) + String(text[close.upperBound...])
    }

    private static func unescape(_ text: String) -> String {
        guard text.contains("&") else { return text }
        return text
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#39;", with: "'")
            .replacingOccurrences(of: "&apos;", with: "'")
            .replacingOccurrences(of: "&amp;", with: "&")
    }
}
