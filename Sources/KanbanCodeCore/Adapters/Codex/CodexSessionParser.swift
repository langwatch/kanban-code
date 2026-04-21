import Foundation

/// Parses Codex CLI session JSONL files.
///
/// Codex stores sessions under `~/.codex/sessions/**/rollout-*.jsonl`.
/// Each line has a top-level `type`, `timestamp`, and `payload`. Conversation
/// content is primarily stored in `response_item` payloads.
public enum CodexSessionParser {

    public struct SessionMetadata: Sendable {
        public let sessionId: String
        public var firstPrompt: String?
        public var projectPath: String?
        public var gitBranch: String?
        public var messageCount: Int

        public init(
            sessionId: String,
            firstPrompt: String? = nil,
            projectPath: String? = nil,
            gitBranch: String? = nil,
            messageCount: Int = 0
        ) {
            self.sessionId = sessionId
            self.firstPrompt = firstPrompt
            self.projectPath = projectPath
            self.gitBranch = gitBranch
            self.messageCount = messageCount
        }
    }

    public static func extractMetadata(from filePath: String) async throws -> SessionMetadata? {
        guard FileManager.default.fileExists(atPath: filePath) else { return nil }

        var metadata = SessionMetadata(sessionId: fallbackSessionId(from: filePath))
        var sawConversationItem = false

        let handle = try FileHandle(forReadingFrom: URL(fileURLWithPath: filePath))
        defer { try? handle.close() }

        for try await line in handle.bytes.lines {
            guard let obj = parseJSONLine(line),
                  let type = obj["type"] as? String else { continue }

            if type == "session_meta", let payload = obj["payload"] as? [String: Any] {
                if let id = payload["id"] as? String, !id.isEmpty {
                    metadata = SessionMetadata(
                        sessionId: id,
                        firstPrompt: metadata.firstPrompt,
                        projectPath: metadata.projectPath,
                        gitBranch: metadata.gitBranch,
                        messageCount: metadata.messageCount
                    )
                }
                if metadata.projectPath == nil {
                    metadata.projectPath = payload["cwd"] as? String
                }
                if metadata.gitBranch == nil,
                   let git = payload["git"] as? [String: Any],
                   let branch = git["branch"] as? String {
                    metadata.gitBranch = branch
                }
                continue
            }

            guard type == "response_item",
                  let payload = obj["payload"] as? [String: Any],
                  let itemType = payload["type"] as? String else { continue }

            switch itemType {
            case "message":
                guard let role = payload["role"] as? String,
                      role == "user" || role == "assistant" else { continue }
                metadata.messageCount += 1
                sawConversationItem = true
                if role == "user", metadata.firstPrompt == nil {
                    let text = textParts(from: payload["content"]).joined(separator: "\n")
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    if !text.isEmpty {
                        metadata.firstPrompt = String(text.prefix(500))
                    }
                }
            case "function_call", "function_call_output", "reasoning":
                metadata.messageCount += 1
                sawConversationItem = true
            default:
                continue
            }

            if metadata.messageCount >= 5, metadata.firstPrompt != nil {
                break
            }
        }

        guard sawConversationItem else { return nil }
        return metadata
    }

    public static func extractSessionId(from filePath: String) async -> String? {
        guard FileManager.default.fileExists(atPath: filePath),
              let handle = FileHandle(forReadingAtPath: filePath) else {
            return nil
        }
        defer { try? handle.close() }

        do {
            for try await line in handle.bytes.lines {
                guard let obj = parseJSONLine(line),
                      obj["type"] as? String == "session_meta",
                      let payload = obj["payload"] as? [String: Any],
                      let id = payload["id"] as? String,
                      !id.isEmpty else { continue }
                return id
            }
        } catch {
            return nil
        }

        let fallback = fallbackSessionId(from: filePath)
        return fallback.isEmpty ? nil : fallback
    }

    public static func readTurns(from filePath: String) async throws -> [ConversationTurn] {
        guard FileManager.default.fileExists(atPath: filePath) else { return [] }

        var responseTurns: [ConversationTurn] = []
        var fallbackTurns: [ConversationTurn] = []
        var callNames: [String: String] = [:]
        var sawResponseItem = false
        var physicalLine = 0

        let handle = try FileHandle(forReadingFrom: URL(fileURLWithPath: filePath))
        defer { try? handle.close() }

        for try await line in handle.bytes.lines {
            physicalLine += 1
            guard let obj = parseJSONLine(line),
                  let type = obj["type"] as? String else { continue }
            let timestamp = obj["timestamp"] as? String

            if type == "response_item",
               let payload = obj["payload"] as? [String: Any],
               let itemType = payload["type"] as? String {
                sawResponseItem = true
                switch itemType {
                case "message":
                    guard let role = payload["role"] as? String,
                          role == "user" || role == "assistant" else { continue }
                    let blocks = textParts(from: payload["content"])
                        .map { ContentBlock(kind: .text, text: $0) }
                    guard !blocks.isEmpty else { continue }
                    appendTurn(
                        role: role,
                        lineNumber: physicalLine,
                        timestamp: timestamp,
                        blocks: blocks,
                        to: &responseTurns
                    )

                case "reasoning":
                    let blocks = reasoningTextParts(from: payload)
                        .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
                        .map { ContentBlock(kind: .thinking, text: String($0.prefix(500))) }
                    guard !blocks.isEmpty else { continue }
                    appendTurn(
                        role: "assistant",
                        lineNumber: physicalLine,
                        timestamp: timestamp,
                        blocks: blocks,
                        to: &responseTurns
                    )

                case "function_call":
                    let callId = payload["call_id"] as? String
                    let name = payload["name"] as? String ?? "tool"
                    if let callId { callNames[callId] = name }
                    let (input, rawInputJSON) = parseArguments(payload["arguments"])
                    let description = input.isEmpty
                        ? name
                        : "\(name)(\(input.map { "\($0.key): \($0.value)" }.sorted().joined(separator: ", ")))"
                    appendTurn(
                        role: "assistant",
                        lineNumber: physicalLine,
                        timestamp: timestamp,
                        blocks: [
                            ContentBlock(
                                kind: .toolUse(name: name, input: input, id: callId),
                                text: description,
                                rawInputJSON: rawInputJSON
                            )
                        ],
                        to: &responseTurns
                    )

                case "function_call_output":
                    let callId = payload["call_id"] as? String
                    let output = payload["output"] as? String ?? ""
                    appendTurn(
                        role: "assistant",
                        lineNumber: physicalLine,
                        timestamp: timestamp,
                        blocks: [
                            ContentBlock(
                                kind: .toolResult(toolName: callId.flatMap { callNames[$0] }, toolUseId: callId),
                                text: output
                            )
                        ],
                        to: &responseTurns
                    )

                default:
                    continue
                }
            } else if type == "event_msg",
                      let payload = obj["payload"] as? [String: Any],
                      let eventType = payload["type"] as? String {
                let role: String
                switch eventType {
                case "user_message": role = "user"
                case "agent_message": role = "assistant"
                default: continue
                }
                let text = fallbackEventText(from: payload)
                guard !text.isEmpty else { continue }
                appendTurn(
                    role: role,
                    lineNumber: physicalLine,
                    timestamp: timestamp,
                    blocks: [ContentBlock(kind: .text, text: text)],
                    to: &fallbackTurns
                )
            }
        }

        return sawResponseItem ? responseTurns : fallbackTurns
    }

    /// Scan Codex function calls for git branch activity.
    public static func extractPushedBranches(
        from filePath: String,
        startOffset: Int? = nil
    ) async throws -> [JsonlParser.DiscoveredBranch] {
        guard FileManager.default.fileExists(atPath: filePath) else { return [] }

        let handle = try FileHandle(forReadingFrom: URL(fileURLWithPath: filePath))
        defer { try? handle.close() }
        if let startOffset, startOffset > 0 {
            handle.seek(toFileOffset: UInt64(startOffset))
        }

        let pushRegex = /git\s+push\s+(?:-[^\s]+\s+)*(?:origin|upstream)\s+(\S+)/
        let checkoutBranchRegex = /git\s+checkout\s+-[bB]\s+(\S+)/
        let switchCreateRegex = /git\s+switch\s+(?:-c|--create)\s+(\S+)/
        let worktreeAddRegex = /git\s+worktree\s+add\s+\S+\s+-b\s+(\S+)/
        var branches = Set<JsonlParser.DiscoveredBranch>()

        for try await line in handle.bytes.lines {
            guard line.contains("\"function_call\""),
                  let obj = parseJSONLine(line),
                  obj["type"] as? String == "response_item",
                  let payload = obj["payload"] as? [String: Any],
                  payload["type"] as? String == "function_call",
                  let name = payload["name"] as? String,
                  name == "exec_command" || name == "shell" || name == "bash" else { continue }

            let (input, _) = parseArguments(payload["arguments"])
            guard let command = input["cmd"] ?? input["command"] else { continue }
            let repoPath = input["workdir"]

            func addBranch(_ branch: String) {
                if branch != "main" && branch != "master" && !branch.hasPrefix("-") {
                    branches.insert(JsonlParser.DiscoveredBranch(branch: branch, repoPath: repoPath))
                }
            }

            for match in command.matches(of: pushRegex) { addBranch(String(match.output.1)) }
            for match in command.matches(of: checkoutBranchRegex) { addBranch(String(match.output.1)) }
            for match in command.matches(of: switchCreateRegex) { addBranch(String(match.output.1)) }
            for match in command.matches(of: worktreeAddRegex) { addBranch(String(match.output.1)) }
        }

        return Array(branches).sorted { $0.branch < $1.branch }
    }

    // MARK: - Helpers

    private static func appendTurn(
        role: String,
        lineNumber: Int,
        timestamp: String?,
        blocks: [ContentBlock],
        to turns: inout [ConversationTurn]
    ) {
        let preview = buildTextPreview(blocks: blocks, role: role)

        if role == "assistant", let last = turns.last, last.role == "assistant" {
            let mergedBlocks = last.contentBlocks + blocks
            turns[turns.count - 1] = ConversationTurn(
                index: last.index,
                lineNumber: last.lineNumber,
                role: last.role,
                textPreview: last.textPreview == "(empty)" ? preview : last.textPreview,
                timestamp: last.timestamp ?? timestamp,
                contentBlocks: mergedBlocks,
                imageCount: last.imageCount
            )
            return
        }

        turns.append(ConversationTurn(
            index: turns.count,
            lineNumber: lineNumber,
            role: role,
            textPreview: preview,
            timestamp: timestamp,
            contentBlocks: blocks
        ))
    }

    private static func parseJSONLine(_ line: String) -> [String: Any]? {
        guard !line.isEmpty,
              let data = line.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return obj
    }

    private static func textParts(from content: Any?) -> [String] {
        if let text = content as? String {
            return text.isEmpty ? [] : [text]
        }

        guard let blocks = content as? [[String: Any]] else { return [] }
        return blocks.compactMap { block in
            if let text = block["text"] as? String { return text }
            if let text = block["content"] as? String { return text }
            return nil
        }.filter { !$0.isEmpty }
    }

    private static func reasoningTextParts(from payload: [String: Any]) -> [String] {
        var texts: [String] = []
        texts.append(contentsOf: textParts(from: payload["summary"]))
        texts.append(contentsOf: textParts(from: payload["content"]))

        if let summaryBlocks = payload["summary"] as? [[String: Any]] {
            texts.append(contentsOf: summaryBlocks.compactMap { $0["text"] as? String })
        }
        if let contentBlocks = payload["content"] as? [[String: Any]] {
            texts.append(contentsOf: contentBlocks.compactMap { $0["text"] as? String })
        }
        return Array(NSOrderedSet(array: texts)) as? [String] ?? texts
    }

    private static func parseArguments(_ value: Any?) -> ([String: String], Data?) {
        let data: Data?
        if let string = value as? String {
            data = string.data(using: .utf8)
        } else if let value, JSONSerialization.isValidJSONObject(value) {
            data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
        } else {
            data = nil
        }

        guard let data,
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return ([:], data)
        }

        var result: [String: String] = [:]
        for (key, rawValue) in dict {
            result[key] = stringify(rawValue)
        }
        return (result, data)
    }

    private static func stringify(_ value: Any) -> String {
        if let string = value as? String { return string }
        if let number = value as? NSNumber { return number.stringValue }
        if JSONSerialization.isValidJSONObject(value),
           let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]),
           let string = String(data: data, encoding: .utf8) {
            return string
        }
        return "\(value)"
    }

    private static func fallbackEventText(from payload: [String: Any]) -> String {
        if let message = payload["message"] as? String { return message }
        if let text = payload["text"] as? String { return text }
        if let elements = payload["text_elements"] as? [String] {
            return elements.joined(separator: "\n")
        }
        return ""
    }

    private static func fallbackSessionId(from filePath: String) -> String {
        let stem = (filePath as NSString).lastPathComponent.replacingOccurrences(of: ".jsonl", with: "")
        if stem.hasPrefix("rollout-") {
            return String(stem.dropFirst("rollout-".count))
        }
        return stem
    }

    private static func buildTextPreview(blocks: [ContentBlock], role: String) -> String {
        let textOnly = blocks.filter { if case .text = $0.kind { true } else { false } }
            .map(\.text).joined(separator: "\n")
        if !textOnly.isEmpty {
            return String(textOnly.prefix(500))
        }

        if blocks.isEmpty { return "(empty)" }

        if role == "assistant" {
            let toolNames = blocks.compactMap { block -> String? in
                if case .toolUse(let name, _, _) = block.kind { return name }
                return nil
            }
            if !toolNames.isEmpty {
                let unique = Array(NSOrderedSet(array: toolNames)) as! [String]
                return "[tool: \(unique.joined(separator: ", "))]"
            }
            if blocks.contains(where: { if case .thinking = $0.kind { true } else { false } }) {
                return "[reasoning]"
            }
        }

        let resultCount = blocks.filter {
            if case .toolResult = $0.kind { true } else { false }
        }.count
        if resultCount > 0 {
            return "[tool result x\(resultCount)]"
        }

        return "(empty)"
    }
}
