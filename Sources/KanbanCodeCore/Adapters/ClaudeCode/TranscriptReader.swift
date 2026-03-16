import Foundation

/// Reads conversation turns from a .jsonl transcript file.
public enum TranscriptReader {

    /// Result of a paginated read: turns + whether more exist before these.
    public struct ReadResult: Sendable {
        public let turns: [ConversationTurn]
        public let totalLineCount: Int
        public let hasMore: Bool

        public init(turns: [ConversationTurn], totalLineCount: Int, hasMore: Bool) {
            self.turns = turns
            self.totalLineCount = totalLineCount
            self.hasMore = hasMore
        }
    }

    /// Read all conversation turns from a .jsonl file (legacy — use readTail for large files).
    public static func readTurns(from filePath: String) async throws -> [ConversationTurn] {
        let result = try await readTail(from: filePath, maxTurns: Int.max)
        return result.turns
    }

    /// Read the last `maxTurns` conversation turns from a .jsonl file.
    /// Always reads from the tail of the file — seeks to end minus estimated bytes,
    /// drops the first partial line, and parses from there.
    public static func readTail(from filePath: String, maxTurns: Int = 80) async throws -> ReadResult {
        guard FileManager.default.fileExists(atPath: filePath) else {
            return ReadResult(turns: [], totalLineCount: 0, hasMore: false)
        }

        let url = URL(fileURLWithPath: filePath)
        let attrs = try FileManager.default.attributesOfItem(atPath: filePath)
        let fileSize = (attrs[.size] as? UInt64) ?? 0

        guard fileSize > 0 else {
            return ReadResult(turns: [], totalLineCount: 0, hasMore: false)
        }

        // ~20KB per turn estimate, clamped to prevent overflow
        let clampedTurns = UInt64(min(maxTurns, 10_000))
        let tailSize = min(clampedTurns * 20 * 1024, fileSize)

        return try await readTailBytes(url: url, fileSize: fileSize, tailSize: tailSize, maxTurns: maxTurns)
    }

    /// Fast tail read: seek to end - tailSize, read lines from there.
    /// Uses byte offset in the file as lineNumber for stable identity across reloads.
    private static func readTailBytes(url: URL, fileSize: UInt64, tailSize: UInt64, maxTurns: Int) async throws -> ReadResult {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }

        let seekPos = fileSize - tailSize
        try handle.seek(toOffset: seekPos)
        let tailData = handle.readDataToEndOfFile()

        guard let tailString = String(data: tailData, encoding: .utf8) else {
            return ReadResult(turns: [], totalLineCount: 0, hasMore: false)
        }

        // Split into lines, tracking byte offsets for stable IDs
        var turnLineInfos: [(byteOffset: Int, line: String)] = []
        var bytePos = Int(seekPos)

        // First line is likely partial (we seeked mid-line), skip it
        var lines = tailString.components(separatedBy: "\n")
        if seekPos > 0 && !lines.isEmpty {
            bytePos += lines[0].utf8.count + 1 // +1 for \n
            lines.removeFirst()
        }

        for line in lines {
            let lineByteOffset = bytePos
            bytePos += line.utf8.count + 1 // +1 for \n

            guard !line.isEmpty, line.contains("\"type\"") else { continue }
            guard let data = line.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let type = obj["type"] as? String,
                  type == "user" || type == "assistant" else { continue }
            if type == "user" && JsonlParser.isCaveatMessage(obj) { continue }
            turnLineInfos.append((lineByteOffset, line))
        }

        // Keep only last maxTurns
        let kept = turnLineInfos.suffix(maxTurns)
        var turns: [ConversationTurn] = []
        turns.reserveCapacity(kept.count)

        for (i, info) in kept.enumerated() {
            guard let data = info.line.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let type = obj["type"] as? String else { continue }

            let role = (type == "user" && JsonlParser.isLocalCommandStdout(obj)) ? "assistant" : type
            let blocks: [ContentBlock]
            let textPreview: String
            if type == "user" {
                blocks = extractUserBlocks(from: obj)
                textPreview = Self.buildTextPreview(blocks: blocks, role: role)
            } else {
                blocks = extractAssistantBlocks(from: obj)
                textPreview = Self.buildTextPreview(blocks: blocks, role: role)
            }
            let timestamp = obj["timestamp"] as? String
            turns.append(ConversationTurn(
                index: i,
                lineNumber: info.byteOffset, // stable: byte offset in original file
                role: role,
                textPreview: textPreview,
                timestamp: timestamp,
                contentBlocks: blocks
            ))
        }

        return ReadResult(
            turns: turns,
            totalLineCount: -1, // unknown without full scan
            hasMore: turnLineInfos.count > maxTurns || seekPos > 0
        )
    }

    /// Stream all conversation turns from a .jsonl file, yielding each turn as it's parsed.
    /// Callers receive turns incrementally without waiting for the full file to load.
    public static func streamAllTurns(from filePath: String) -> AsyncStream<ConversationTurn> {
        AsyncStream { continuation in
            let task = Task.detached {
                guard FileManager.default.fileExists(atPath: filePath) else {
                    continuation.finish()
                    return
                }
                do {
                    let url = URL(fileURLWithPath: filePath)
                    let handle = try FileHandle(forReadingFrom: url)
                    defer { try? handle.close() }

                    var lineNumber = 0
                    var turnIndex = 0

                    for try await line in handle.bytes.lines {
                        if Task.isCancelled { break }
                        lineNumber += 1
                        guard !line.isEmpty, line.contains("\"type\"") else { continue }

                        guard let data = line.data(using: .utf8),
                              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                              let type = obj["type"] as? String,
                              type == "user" || type == "assistant" else { continue }

                        // Skip caveat wrapper messages entirely
                        if type == "user" && JsonlParser.isCaveatMessage(obj) { continue }

                        // Stdout responses display as assistant-style turns
                        let role = (type == "user" && JsonlParser.isLocalCommandStdout(obj)) ? "assistant" : type

                        let blocks: [ContentBlock]
                        let textPreview: String

                        if type == "user" {
                            blocks = extractUserBlocks(from: obj)
                            textPreview = buildTextPreview(blocks: blocks, role: role)
                        } else {
                            blocks = extractAssistantBlocks(from: obj)
                            textPreview = buildTextPreview(blocks: blocks, role: role)
                        }

                        let timestamp = obj["timestamp"] as? String

                        continuation.yield(ConversationTurn(
                            index: turnIndex,
                            lineNumber: lineNumber,
                            role: role,
                            textPreview: textPreview,
                            timestamp: timestamp,
                            contentBlocks: blocks
                        ))
                        turnIndex += 1
                    }
                } catch {
                    // File read error — just finish the stream
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Scan for matching turn indices using the same content extraction as the reader.
    /// Yields each matching turn index as found. Matches against the same text fields
    /// that TurnBlockView displays (textPreview + contentBlocks[].text).
    public static func scanForMatches(
        from filePath: String,
        query: String
    ) -> AsyncStream<Int> {
        AsyncStream { continuation in
            let task = Task.detached {
                guard FileManager.default.fileExists(atPath: filePath) else {
                    continuation.finish()
                    return
                }
                do {
                    let url = URL(fileURLWithPath: filePath)
                    let handle = try FileHandle(forReadingFrom: url)
                    defer { try? handle.close() }

                    var turnIndex = 0
                    let queryLower = query.lowercased()

                    for try await line in handle.bytes.lines {
                        if Task.isCancelled { break }
                        guard !line.isEmpty, line.contains("\"type\"") else { continue }

                        guard let data = line.data(using: .utf8),
                              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                              let type = obj["type"] as? String,
                              type == "user" || type == "assistant" else { continue }

                        // Skip caveat wrapper messages entirely
                        if type == "user" && JsonlParser.isCaveatMessage(obj) { continue }

                        // Stdout responses display as assistant-style turns
                        let role = (type == "user" && JsonlParser.isLocalCommandStdout(obj)) ? "assistant" : type

                        // Extract content the same way the reader/frontend does
                        let blocks: [ContentBlock]
                        if type == "user" {
                            blocks = extractUserBlocks(from: obj)
                        } else {
                            blocks = extractAssistantBlocks(from: obj)
                        }
                        let textPreview = buildTextPreview(blocks: blocks, role: role)

                        // Match against the same fields TurnBlockView.isSearchMatch checks
                        if textPreview.lowercased().contains(queryLower)
                            || blocks.contains(where: { $0.text.lowercased().contains(queryLower) }) {
                            continuation.yield(turnIndex)
                        }
                        turnIndex += 1
                    }
                } catch { }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Load earlier turns before the current set (for "load more" pagination).
    public static func readRange(from filePath: String, turnRange: Range<Int>) async throws -> [ConversationTurn] {
        guard FileManager.default.fileExists(atPath: filePath) else { return [] }

        let url = URL(fileURLWithPath: filePath)
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }

        var turns: [ConversationTurn] = []
        var lineNumber = 0
        var turnIndex = 0

        for try await line in handle.bytes.lines {
            lineNumber += 1
            guard !line.isEmpty, line.contains("\"type\"") else { continue }

            guard let data = line.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let type = obj["type"] as? String,
                  type == "user" || type == "assistant" else { continue }

            // Skip caveat wrapper messages entirely
            if type == "user" && JsonlParser.isCaveatMessage(obj) { continue }

            // Stdout responses display as assistant-style turns
            let role = (type == "user" && JsonlParser.isLocalCommandStdout(obj)) ? "assistant" : type

            defer { turnIndex += 1 }

            // Skip turns outside our range
            guard turnRange.contains(turnIndex) else {
                if turnIndex >= turnRange.upperBound { break }
                continue
            }

            let blocks: [ContentBlock]
            let textPreview: String

            if type == "user" {
                blocks = extractUserBlocks(from: obj)
                textPreview = Self.buildTextPreview(blocks: blocks, role: role)
            } else {
                blocks = extractAssistantBlocks(from: obj)
                textPreview = Self.buildTextPreview(blocks: blocks, role: role)
            }

            let timestamp = obj["timestamp"] as? String

            turns.append(ConversationTurn(
                index: turnIndex,
                lineNumber: lineNumber,
                role: role,
                textPreview: textPreview,
                timestamp: timestamp,
                contentBlocks: blocks
            ))
        }

        return turns
    }

    // MARK: - User message parsing

    static func extractUserBlocks(from obj: [String: Any]) -> [ContentBlock] {
        // Hide caveat wrapper messages entirely
        if JsonlParser.isCaveatMessage(obj) { return [] }

        // User text can be at top level or inside message.content
        if let text = JsonlParser.extractTextContent(from: obj) {
            // Show slash commands cleanly (e.g. "/clear")
            if let command = JsonlParser.parseLocalCommand(text) {
                return [ContentBlock(kind: .text, text: command)]
            }
            // Show command stdout as plain text
            if let stdout = JsonlParser.parseLocalCommandStdout(text) {
                return [ContentBlock(kind: .text, text: stdout)]
            }
            // Strip any remaining metadata tags from mixed-content messages
            let cleaned = JsonlParser.stripMetadataTags(text)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !cleaned.isEmpty {
                return [ContentBlock(kind: .text, text: cleaned)]
            }
            return []
        }

        // Check for tool_result blocks in message.content
        guard let message = obj["message"] as? [String: Any],
              let content = message["content"] as? [[String: Any]] else {
            return []
        }

        var blocks: [ContentBlock] = []
        for block in content {
            guard let blockType = block["type"] as? String else { continue }
            switch blockType {
            case "text":
                if let text = block["text"] as? String, !text.isEmpty {
                    blocks.append(ContentBlock(kind: .text, text: text))
                }
            case "tool_result":
                let toolUseId = block["tool_use_id"] as? String
                let resultText: String
                if let content = block["content"] as? String {
                    // Keep full content (up to 10KB) for chat view; history view truncates via lineLimit
                    resultText = String(content.prefix(10_240))
                } else if let contentArr = block["content"] as? [[String: Any]] {
                    resultText = contentArr.compactMap { $0["text"] as? String }.joined(separator: "\n").prefix(10_240).description
                } else {
                    resultText = "Result"
                }
                blocks.append(ContentBlock(kind: .toolResult(toolName: nil, toolUseId: toolUseId), text: resultText))
            default:
                break
            }
        }
        return blocks
    }

    // MARK: - Assistant message parsing

    static func extractAssistantBlocks(from obj: [String: Any]) -> [ContentBlock] {
        guard let message = obj["message"] as? [String: Any],
              let content = message["content"] else {
            return []
        }

        // Simple string content
        if let text = content as? String {
            return text.isEmpty ? [] : [ContentBlock(kind: .text, text: text)]
        }

        // Array of content blocks
        guard let blocks = content as? [[String: Any]] else { return [] }

        var result: [ContentBlock] = []
        for block in blocks {
            guard let blockType = block["type"] as? String else { continue }
            switch blockType {
            case "text":
                if let text = block["text"] as? String, !text.isEmpty {
                    result.append(ContentBlock(kind: .text, text: text))
                }
            case "tool_use":
                result.append(parseToolUse(block))
            case "thinking":
                if let thinking = block["thinking"] as? String, !thinking.isEmpty {
                    result.append(ContentBlock(kind: .thinking, text: String(thinking.prefix(500))))
                }
            default:
                break
            }
        }
        return result
    }

    // MARK: - Preview text

    /// Build a descriptive text preview for a conversation turn.
    static func buildTextPreview(blocks: [ContentBlock], role: String) -> String {
        let textOnly = blocks.filter { if case .text = $0.kind { true } else { false } }
            .map(\.text).joined(separator: "\n")

        if !textOnly.isEmpty {
            return String(textOnly.prefix(500))
        }

        if blocks.isEmpty { return "(empty)" }

        if role == "user" {
            // User messages with tool_result blocks
            let resultCount = blocks.filter { if case .toolResult = $0.kind { true } else { false } }.count
            if resultCount > 0 {
                return "[tool result x\(resultCount)]"
            }
        } else {
            // Assistant messages with tool_use blocks — list tool names
            let toolNames = blocks.compactMap { block -> String? in
                switch block.kind {
                case .toolUse(let name, _, _): return name
                case .agentCall: return "Agent"
                case .planModeEnter: return "EnterPlanMode"
                case .planModeExit: return "ExitPlanMode"
                case .askUserQuestion: return "AskUserQuestion"
                default: return nil
                }
            }
            if !toolNames.isEmpty {
                let unique = Array(NSOrderedSet(array: toolNames)) as! [String]
                return "[tool: \(unique.joined(separator: ", "))]"
            }
        }

        return "(empty)"
    }

    // MARK: - Tool use parsing

    static func parseToolUse(_ block: [String: Any]) -> ContentBlock {
        let name = block["name"] as? String ?? "unknown"
        let input = block["input"] as? [String: Any] ?? [:]
        let toolId = block["id"] as? String
        let rawJSON = try? JSONSerialization.data(withJSONObject: input)

        // Special tool types with rich rendering
        switch name {
        case "EnterPlanMode":
            return ContentBlock(kind: .planModeEnter, text: "Entered plan mode")

        case "ExitPlanMode":
            let plan = input["plan"] as? String ?? ""
            return ContentBlock(kind: .planModeExit(plan: plan), text: plan, rawInputJSON: rawJSON)

        case "AskUserQuestion":
            let questions = parseAskQuestions(input)
            return ContentBlock(kind: .askUserQuestion(questions: questions, id: toolId), text: "Question", rawInputJSON: rawJSON)

        case "Agent":
            let desc = input["description"] as? String ?? String((input["prompt"] as? String ?? "").prefix(80))
            let subType = input["subagent_type"] as? String
            return ContentBlock(kind: .agentCall(description: desc, subagentType: subType, id: toolId), text: desc, rawInputJSON: rawJSON)

        default:
            break
        }

        let (displayText, inputMap) = extractToolInfo(name: name, input: input)
        let isBackground = input["run_in_background"] as? Bool ?? false

        return ContentBlock(
            kind: .toolUse(name: name, input: inputMap, id: toolId),
            text: displayText,
            rawInputJSON: rawJSON,
            isBackground: isBackground
        )
    }

    /// Parse AskUserQuestion questions array from tool input.
    static func parseAskQuestions(_ input: [String: Any]) -> [AskQuestion] {
        guard let questionsArray = input["questions"] as? [[String: Any]] else { return [] }
        return questionsArray.compactMap { q in
            guard let question = q["question"] as? String else { return nil }
            let header = q["header"] as? String
            let multiSelect = q["multiSelect"] as? Bool ?? false
            let options: [AskQuestionOption] = (q["options"] as? [[String: Any]] ?? []).compactMap { opt in
                guard let label = opt["label"] as? String else { return nil }
                return AskQuestionOption(label: label, description: opt["description"] as? String)
            }
            return AskQuestion(header: header, question: question, options: options, multiSelect: multiSelect)
        }
    }

    /// Extract display text and key input fields for each tool type.
    static func extractToolInfo(name: String, input: [String: Any]) -> (String, [String: String]) {
        var inputMap: [String: String] = [:]

        switch name {
        case "Bash":
            let command = input["command"] as? String ?? ""
            let desc = input["description"] as? String
            inputMap["command"] = command
            if let desc { inputMap["description"] = desc }
            let display = desc ?? String(command.prefix(200))
            return ("\(name)(\(display))", inputMap)

        case "Read":
            let path = input["file_path"] as? String ?? ""
            inputMap["file_path"] = path
            return ("\(name)(\(shortenPath(path)))", inputMap)

        case "Write":
            let path = input["file_path"] as? String ?? ""
            inputMap["file_path"] = path
            return ("\(name)(\(shortenPath(path)))", inputMap)

        case "Edit":
            let path = input["file_path"] as? String ?? ""
            inputMap["file_path"] = path
            return ("\(name)(\(shortenPath(path)))", inputMap)

        case "Grep":
            let pattern = input["pattern"] as? String ?? ""
            let path = input["path"] as? String
            inputMap["pattern"] = pattern
            if let path { inputMap["path"] = path }
            let pathPart = path.map { " in \(shortenPath($0))" } ?? ""
            return ("\(name)(\"\(pattern)\"\(pathPart))", inputMap)

        case "Glob":
            let pattern = input["pattern"] as? String ?? ""
            inputMap["pattern"] = pattern
            return ("\(name)(\(pattern))", inputMap)

        case "Agent":
            let prompt = input["prompt"] as? String ?? ""
            let desc = input["description"] as? String ?? String(prompt.prefix(80))
            inputMap["prompt"] = String(prompt.prefix(200))
            return ("\(name)(\(desc))", inputMap)

        case "Skill":
            let skill = input["skill"] as? String ?? ""
            inputMap["skill"] = skill
            return ("\(name)(\(skill))", inputMap)

        case "TaskCreate":
            let subject = input["subject"] as? String ?? ""
            inputMap["subject"] = subject
            return ("\(name)(\(subject))", inputMap)

        case "TaskUpdate":
            let taskId = input["taskId"] as? String ?? ""
            let status = input["status"] as? String
            inputMap["taskId"] = taskId
            if let status { inputMap["status"] = status }
            let detail = status.map { "\(taskId): \($0)" } ?? taskId
            return ("\(name)(\(detail))", inputMap)

        default:
            return (name, inputMap)
        }
    }

    /// Shorten a file path for display — keep last 2-3 components.
    static func shortenPath(_ path: String) -> String {
        let components = path.components(separatedBy: "/").filter { !$0.isEmpty }
        if components.count <= 3 { return path }
        return ".../" + components.suffix(3).joined(separator: "/")
    }
}
