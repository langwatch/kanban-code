import Foundation

/// Reads conversation turns from a .jsonl transcript file.
public enum TranscriptReader {

    /// Result of a paginated read: turns + whether more exist before these.
    public struct ReadResult: Sendable {
        public let turns: [ConversationTurn]
        public let totalLineCount: Int
        public let hasMore: Bool
        /// Byte offset just past the last complete line, for incremental reads.
        public let fileEnd: Int

        public init(turns: [ConversationTurn], totalLineCount: Int, hasMore: Bool, fileEnd: Int = 0) {
            self.turns = turns
            self.totalLineCount = totalLineCount
            self.hasMore = hasMore
            self.fileEnd = fileEnd
        }
    }

    /// Read all conversation turns from a .jsonl file (legacy — use readTail for large files).
    public static func readTurns(from filePath: String) async throws -> [ConversationTurn] {
        let result = try await readTail(from: filePath, maxTurns: Int.max)
        return result.turns
    }

    /// Read the last `maxTurns` conversation turns from a .jsonl file.
    ///
    /// Walks the file backwards in chunks and stops as soon as it holds enough
    /// turns, so the cost follows the size of those turns rather than the size
    /// of the file. `maxBytes` puts a hard ceiling on that cost for callers
    /// that fire in bursts and only need the recent end. Uses byte offset in
    /// the file as lineNumber for stable identity across reloads.
    public static func readTail(
        from filePath: String, maxTurns: Int = 80, maxBytes: Int? = nil
    ) async throws -> ReadResult {
        guard FileManager.default.fileExists(atPath: filePath) else {
            return ReadResult(turns: [], totalLineCount: 0, hasMore: false)
        }
        let attrs = try FileManager.default.attributesOfItem(atPath: filePath)
        let fileSize = (attrs[.size] as? Int) ?? 0

        var newestFirst: [(offset: Int, obj: [String: Any])] = []
        var hasMore = false
        try scanRecordsBackwards(filePath: filePath) { offset, line in
            if let maxBytes, fileSize - offset > maxBytes {
                hasMore = true
                return true
            }
            guard line.contains("\"type\""), let obj = candidateRecord(from: line) else {
                return false
            }
            if newestFirst.count >= maxTurns {
                hasMore = true
                return true
            }
            newestFirst.append((offset, obj))
            return false
        }

        var turns: [ConversationTurn] = []
        turns.reserveCapacity(newestFirst.count)
        for (i, record) in newestFirst.reversed().enumerated() {
            guard let turn = buildTurn(from: record.obj, index: i, byteOffset: record.offset)
            else { continue }
            turns.append(turn)
        }

        // Merge consecutive assistant entries — Claude Code splits thinking + response
        // into separate JSONL lines that are parts of the same message.
        let merged = mergeConsecutiveAssistantTurns(turns)

        return ReadResult(
            turns: merged,
            totalLineCount: -1, // unknown without full scan
            hasMore: hasMore,
            fileEnd: try offsetAfterLastNewline(filePath: filePath)
        )
    }

    /// Turns parsed from the bytes appended after a known point.
    public struct Appended: Sendable {
        public let turns: [ConversationTurn]
        public let fileEnd: Int
    }

    /// Parse only the bytes at and after `startOffset`, which must be an
    /// offset a line starts at.
    ///
    /// This is the read a file watcher event pays for: the last loaded turn's
    /// start is passed in, so lines appended since — including ones that grow
    /// that turn — come back as fresh turns to splice over it. Returns nil
    /// when the region is larger than `maxBytes`, which means the window is
    /// too far behind and a full tail read is the cheaper way back.
    public static func readAppended(
        from filePath: String, startOffset: Int, maxBytes: Int = 32 * 1024 * 1024
    ) async throws -> Appended? {
        guard FileManager.default.fileExists(atPath: filePath) else { return nil }
        let attrs = try FileManager.default.attributesOfItem(atPath: filePath)
        let fileSize = (attrs[.size] as? Int) ?? 0
        guard startOffset >= 0, startOffset <= fileSize, fileSize - startOffset <= maxBytes
        else { return nil }

        var records: [(offset: Int, obj: [String: Any])] = []
        try scanRecordsForward(filePath: filePath, from: startOffset) { offset, line in
            guard line.contains("\"type\""), let obj = candidateRecord(from: line) else {
                return false
            }
            records.append((offset, obj))
            return false
        }

        var turns: [ConversationTurn] = []
        turns.reserveCapacity(records.count)
        for (i, record) in records.enumerated() {
            guard let turn = buildTurn(from: record.obj, index: i, byteOffset: record.offset)
            else { continue }
            turns.append(turn)
        }
        return Appended(
            turns: mergeConsecutiveAssistantTurns(turns),
            fileEnd: try offsetAfterLastNewline(filePath: filePath)
        )
    }

    /// Turns parsed from a byte range, and where the parse stopped.
    public struct RangeRead: Sendable {
        public let turns: [ConversationTurn]
        /// Line-start offset of the first byte not parsed. Equal to the
        /// requested end when the whole range was read; earlier when
        /// `maxVisible` stopped the read at a turn boundary.
        public let consumedEnd: Int
    }

    /// Parse the turns whose lines start inside `[startOffset, endOffset)`.
    ///
    /// With `maxVisible`, the read stops at the first turn that would begin
    /// once that many rows are already in hand, and reports where it stopped,
    /// so a large collapsed stretch opens a page at a time. The stop lands on
    /// a merge boundary, never inside a merged assistant turn.
    public static func readRange(
        from filePath: String, startOffset: Int, endOffset: Int, maxVisible: Int? = nil
    ) async throws -> RangeRead {
        var turns: [ConversationTurn] = []
        var consumedEnd = endOffset
        var visibleCount = 0
        var prevIsAssistant = false
        var runCounted = false

        try scanRecordsForward(filePath: filePath, from: startOffset, to: endOffset) {
            offset, line in
            guard line.contains("\"type\""), let obj = candidateRecord(from: line),
                let turn = buildTurn(from: obj, index: turns.count, byteOffset: offset)
            else { return false }

            let isAssistant = turn.role == "assistant"
            let startsNewTurn = !(isAssistant && prevIsAssistant)
            if let cap = maxVisible, startsNewTurn, visibleCount >= cap {
                consumedEnd = offset
                return true
            }
            if startsNewTurn { runCounted = false }
            if turn.hasVisibleChatContent {
                if isAssistant {
                    if !runCounted {
                        visibleCount += 1
                        runCounted = true
                    }
                } else {
                    visibleCount += 1
                }
            }
            prevIsAssistant = isAssistant
            turns.append(turn)
            return false
        }

        return RangeRead(turns: mergeConsecutiveAssistantTurns(turns), consumedEnd: consumedEnd)
    }

    /// Count the rows the chat would draw for the lines starting inside
    /// `[startOffset, endOffset)`, without keeping any of them.
    ///
    /// Tool result lines — the bulk of a transcript's bytes — are recognised
    /// by their top-level `toolUseResult` key and skipped without JSON
    /// parsing. The key can only appear unescaped at the top level, because
    /// inside a JSON string its quotes would be escaped.
    public static func countVisibleTurns(
        from filePath: String, startOffset: Int, endOffset: Int
    ) async throws -> Int {
        var visibleCount = 0
        var prevIsAssistant = false
        var runCounted = false

        try scanRecordsForward(filePath: filePath, from: startOffset, to: endOffset) { _, line in
            guard line.contains("\"type\"") else { return false }
            if line.contains("\"type\":\"user\""), line.contains("\"toolUseResult\"") {
                // A tool result turn: never visible, but it does end a merged
                // assistant run, the same way it does when parsed.
                prevIsAssistant = false
                return false
            }
            guard let obj = candidateRecord(from: line),
                let turn = buildTurn(from: obj, index: 0, byteOffset: 0)
            else { return false }

            let isAssistant = turn.role == "assistant"
            if !(isAssistant && prevIsAssistant) { runCounted = false }
            if turn.hasVisibleChatContent {
                if isAssistant {
                    if !runCounted {
                        visibleCount += 1
                        runCounted = true
                    }
                } else {
                    visibleCount += 1
                }
            }
            prevIsAssistant = isAssistant
            return false
        }
        return visibleCount
    }

    /// A typed user message found by scanning backwards, and where its line ends.
    public struct PreviousUserTurn: Sendable {
        public let turn: ConversationTurn
        public let endOffset: Int
    }

    /// The nearest message the person typed strictly above `offset`, which
    /// must be an offset a line starts at.
    ///
    /// Walks the file backwards. Tool result lines are skipped by their
    /// top-level `toolUseResult` key without JSON parsing, so the scan moves
    /// through a wall of tool output at read speed.
    public static func findPreviousTypedUserTurn(
        in filePath: String, before offset: Int
    ) async throws -> PreviousUserTurn? {
        var found: PreviousUserTurn?
        try scanRecordsBackwards(filePath: filePath, from: offset) { lineOffset, line in
            guard line.contains("\"type\":\"user\"") || line.contains("\"type\":\"queue-operation\"")
            else { return false }
            if line.contains("\"toolUseResult\"") { return false }
            guard let obj = candidateRecord(from: line),
                let turn = buildTurn(from: obj, index: 0, byteOffset: lineOffset),
                turn.role == "user",
                TranscriptClassifier.isTypedMessage(turn)
            else { return false }
            found = PreviousUserTurn(turn: turn, endOffset: lineOffset + line.utf8.count + 1)
            return true
        }
        return found
    }

    // MARK: - Line scanning

    /// Whether a parsed record is one the history displays. Applies the same
    /// filter everywhere a line becomes a turn: user and assistant records,
    /// queued prompts, and nothing marked as harness metadata.
    private static func candidateRecord(from line: String) -> [String: Any]? {
        guard let data = line.data(using: .utf8),
            let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let type = obj["type"] as? String
        else { return nil }
        switch type {
        case "user":
            return JsonlParser.isCaveatMessage(obj) ? nil : obj
        case "assistant":
            return obj
        case "queue-operation":
            guard let op = obj["operation"] as? String, op == "enqueue",
                let content = obj["content"] as? String, !content.isEmpty
            else { return nil }
            return obj
        default:
            return nil
        }
    }

    /// Walk a file's lines newest first, in chunks, carrying the byte offset
    /// each line starts at. The handler returns true to stop. `endOffset`
    /// bounds the scan: only lines starting before it are visited.
    static func scanRecordsBackwards(
        filePath: String,
        from endOffset: Int? = nil,
        handler: (_ byteOffset: Int, _ line: String) -> Bool
    ) throws {
        guard FileManager.default.fileExists(atPath: filePath) else { return }
        let attrs = try FileManager.default.attributesOfItem(atPath: filePath)
        let fileSize = (attrs[.size] as? Int) ?? 0
        var end = min(endOffset ?? fileSize, fileSize)
        guard end > 0 else { return }

        let handle = try FileHandle(forReadingFrom: URL(fileURLWithPath: filePath))
        defer { try? handle.close() }

        let chunkSize = 1 << 20
        let newline = UInt8(ascii: "\n")
        // Bytes of a line whose end was seen but whose start lies in a chunk
        // not read yet. Never contains a newline.
        var carry: [UInt8] = []

        while end > 0 {
            let start = max(0, end - chunkSize)
            try handle.seek(toOffset: UInt64(start))
            let chunkData = try handle.read(upToCount: end - start) ?? Data()
            var bytes = [UInt8](chunkData)
            let chunkCount = bytes.count
            bytes.append(contentsOf: carry)

            var starts: [Int] = []
            for i in 0..<chunkCount where bytes[i] == newline { starts.append(i + 1) }

            if starts.isEmpty && start > 0 {
                carry = bytes
                end = start
                continue
            }

            // Complete lines, newest first. Each start pairs with the next
            // newline; the last runs into the carry, which holds the rest of
            // the line the later chunk cut through.
            for (k, lineStart) in starts.enumerated().reversed() {
                let lineEnd = k + 1 < starts.count ? starts[k + 1] - 1 : bytes.count
                guard lineEnd > lineStart,
                    let line = String(bytes: bytes[lineStart..<lineEnd], encoding: .utf8)
                else { continue }
                if handler(start + lineStart, line) { return }
            }

            if start == 0 {
                let lineEnd = starts.first.map { $0 - 1 } ?? bytes.count
                if lineEnd > 0, let line = String(bytes: bytes[0..<lineEnd], encoding: .utf8),
                    handler(0, line) {
                    return
                }
            } else {
                carry = Array(bytes[0..<(starts[0] - 1)])
            }
            end = start
        }
    }

    /// Walk a file's complete lines oldest first from `startOffset`, in
    /// chunks, carrying the byte offset each line starts at. Only lines
    /// starting before `stopOffset` are visited. A final line without a
    /// newline is delivered too. The handler returns true to stop.
    static func scanRecordsForward(
        filePath: String,
        from startOffset: Int,
        to stopOffset: Int? = nil,
        handler: (_ byteOffset: Int, _ line: String) -> Bool
    ) throws {
        guard FileManager.default.fileExists(atPath: filePath) else { return }
        let attrs = try FileManager.default.attributesOfItem(atPath: filePath)
        let fileSize = (attrs[.size] as? Int) ?? 0
        let stop = min(stopOffset ?? fileSize, fileSize)
        guard startOffset >= 0, startOffset < stop else { return }

        let handle = try FileHandle(forReadingFrom: URL(fileURLWithPath: filePath))
        defer { try? handle.close() }
        try handle.seek(toOffset: UInt64(startOffset))

        let chunkSize = 1 << 20
        let newline = UInt8(ascii: "\n")
        var carry: [UInt8] = []
        var carryOffset = startOffset
        var pos = startOffset

        while pos < fileSize {
            let readCount = min(chunkSize, fileSize - pos)
            let chunkData = try handle.read(upToCount: readCount) ?? Data()
            guard !chunkData.isEmpty else { break }
            pos += chunkData.count

            var bytes = carry
            bytes.append(contentsOf: chunkData)
            var lineStart = 0
            var i = carry.count
            while i < bytes.count {
                if bytes[i] == newline {
                    let offset = carryOffset + lineStart
                    if offset >= stop { return }
                    if i > lineStart,
                        let line = String(bytes: bytes[lineStart..<i], encoding: .utf8),
                        handler(offset, line) {
                        return
                    }
                    lineStart = i + 1
                    // The next line starts past the bound: done, without
                    // reading on just to find where that line ends.
                    if carryOffset + lineStart >= stop { return }
                }
                i += 1
            }
            carry = Array(bytes[lineStart...])
            carryOffset += lineStart
        }

        if !carry.isEmpty, carryOffset < stop,
            let line = String(bytes: carry, encoding: .utf8) {
            _ = handler(carryOffset, line)
        }
    }

    /// Byte offset just past the file's last newline: everything before it is
    /// complete lines, everything after is a line still being written.
    static func offsetAfterLastNewline(filePath: String) throws -> Int {
        let attrs = try FileManager.default.attributesOfItem(atPath: filePath)
        let fileSize = (attrs[.size] as? Int) ?? 0
        guard fileSize > 0 else { return 0 }

        let handle = try FileHandle(forReadingFrom: URL(fileURLWithPath: filePath))
        defer { try? handle.close() }

        let chunkSize = 1 << 16
        var end = fileSize
        while end > 0 {
            let start = max(0, end - chunkSize)
            try handle.seek(toOffset: UInt64(start))
            let bytes = [UInt8](try handle.read(upToCount: end - start) ?? Data())
            if let i = bytes.lastIndex(of: UInt8(ascii: "\n")) { return start + i + 1 }
            end = start
        }
        return 0
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
                    var pendingAssistant: ConversationTurn?

                    for try await line in handle.blockLines {
                        if Task.isCancelled { break }
                        lineNumber += 1
                        guard !line.isEmpty, line.contains("\"type\"") else { continue }

                        guard let data = line.data(using: .utf8),
                              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                              let type = obj["type"] as? String,
                              type == "user" || type == "assistant" || type == "queue-operation" else { continue }

                        // Skip caveat wrapper messages entirely
                        if type == "user" && JsonlParser.isCaveatMessage(obj) { continue }

                        // Stdout responses display as assistant-style turns
                        let role = (type == "user" && JsonlParser.isLocalCommandStdout(obj)) ? "assistant" : (type == "queue-operation" ? "user" : type)

                        let blocks: [ContentBlock]
                        let textPreview: String

                        if type == "queue-operation" {
                            guard let op = obj["operation"] as? String,
                                  op == "enqueue",
                                  let content = obj["content"] as? String,
                                  !content.isEmpty else { continue }
                            if content.contains("<task-notification>") {
                                guard let summary = Self.parseTaskNotification(content) else { continue }
                                blocks = [ContentBlock(kind: .text, text: summary)]
                                textPreview = summary
                            } else {
                                blocks = [ContentBlock(kind: .text, text: content)]
                                textPreview = content
                            }
                        } else if type == "user" {
                            blocks = extractUserBlocks(from: obj)
                            textPreview = buildTextPreview(blocks: blocks, role: role)
                        } else {
                            blocks = extractAssistantBlocks(from: obj)
                            textPreview = buildTextPreview(blocks: blocks, role: role)
                        }

                        let timestamp = obj["timestamp"] as? String

                        let turn = ConversationTurn(
                            index: turnIndex,
                            lineNumber: lineNumber,
                            role: role,
                            textPreview: textPreview,
                            timestamp: timestamp,
                            contentBlocks: blocks
                        )

                        // Merge consecutive assistant turns (thinking + response)
                        if role == "assistant", var pending = pendingAssistant {
                            pending = ConversationTurn(
                                index: pending.index,
                                lineNumber: pending.lineNumber,
                                role: pending.role,
                                textPreview: pending.textPreview == "(empty)" ? textPreview : pending.textPreview,
                                timestamp: pending.timestamp ?? timestamp,
                                contentBlocks: pending.contentBlocks + blocks,
                                imageCount: pending.imageCount + turn.imageCount,
                                endLineNumber: turn.endLineNumber
                            )
                            pendingAssistant = pending
                        } else {
                            if let pending = pendingAssistant {
                                continuation.yield(pending)
                                turnIndex += 1
                            }
                            if role == "assistant" {
                                pendingAssistant = turn
                            } else {
                                pendingAssistant = nil
                                continuation.yield(turn)
                                turnIndex += 1
                            }
                        }
                    }
                    // Flush last pending assistant
                    if let pending = pendingAssistant {
                        continuation.yield(pending)
                    }
                } catch {
                    // File read error — just finish the stream
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Scan for matching turns using the same content extraction as the reader.
    /// Yields the byte offset of each matching turn as it is found. Matches
    /// against the same text fields the chat displays (textPreview +
    /// contentBlocks[].text).
    ///
    /// Offsets rather than turn numbers, because a turn number means something
    /// different to every reader here: the tail reader numbers from the start of
    /// the window it loaded, which is not the start of the file. A byte offset
    /// is the same number to all of them, and is what a loaded turn already
    /// carries as its identity.
    public static func scanForMatchOffsets(
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

                    let queryLower = query.lowercased()

                    for try await record in handle.blockLineRecords {
                        if Task.isCancelled { break }
                        let line = record.text
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
                            continuation.yield(record.byteOffset)
                        }
                    }
                } catch { }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Turns loaded around a byte offset, and the byte region they came from.
    public struct AroundRead: Sendable {
        public let turns: [ConversationTurn]
        /// Line-start offset of the first line the read consumed.
        public let regionStart: Int
        /// Offset just past the last line the read consumed.
        public let regionEnd: Int
    }

    /// Load the turns surrounding a byte offset, for jumping to a search match
    /// that sits outside the window currently loaded.
    ///
    /// Turns carry the byte offset they start at as their identity, which is
    /// what makes a chunk from here line up with one from ``readTail(from:maxTurns:)``.
    /// Seeks straight to the offset: the context above comes from a backward
    /// scan, so the cost follows the window, not the file.
    public static func readAround(
        from filePath: String,
        byteOffset: Int,
        before: Int = 40,
        after: Int = 40
    ) async throws -> AroundRead {
        guard FileManager.default.fileExists(atPath: filePath) else {
            return AroundRead(turns: [], regionStart: byteOffset, regionEnd: byteOffset)
        }
        let attrs = try FileManager.default.attributesOfItem(atPath: filePath)
        let fileSize = (attrs[.size] as? Int) ?? 0

        var leadingNewestFirst: [(offset: Int, obj: [String: Any])] = []
        try scanRecordsBackwards(filePath: filePath, from: byteOffset) { offset, line in
            guard line.contains("\"type\""), let obj = candidateRecord(from: line) else {
                return false
            }
            leadingNewestFirst.append((offset, obj))
            return leadingNewestFirst.count >= before
        }

        var trailing: [(offset: Int, obj: [String: Any])] = []
        var regionEnd = byteOffset
        try scanRecordsForward(filePath: filePath, from: byteOffset) { offset, line in
            regionEnd = min(offset + line.utf8.count + 1, fileSize)
            guard line.contains("\"type\""), let obj = candidateRecord(from: line) else {
                return false
            }
            trailing.append((offset, obj))
            return trailing.count >= after
        }

        let kept = leadingNewestFirst.reversed() + trailing
        var turns: [ConversationTurn] = []
        turns.reserveCapacity(kept.count)
        for (i, record) in kept.enumerated() {
            guard let turn = buildTurn(from: record.obj, index: i, byteOffset: record.offset)
            else { continue }
            turns.append(turn)
        }
        return AroundRead(
            turns: mergeConsecutiveAssistantTurns(turns),
            regionStart: leadingNewestFirst.last?.offset ?? byteOffset,
            regionEnd: max(regionEnd, byteOffset)
        )
    }

    /// Builds one turn from one parsed record, or nothing when the record does
    /// not display as a turn. The record must have passed ``candidateRecord(from:)``.
    private static func buildTurn(
        from obj: [String: Any], index: Int, byteOffset: Int
    ) -> ConversationTurn? {
        guard let type = obj["type"] as? String else { return nil }

        let role: String
        let blocks: [ContentBlock]
        let textPreview: String
        if type == "queue-operation" {
            guard let content = obj["content"] as? String, !content.isEmpty else { return nil }
            role = "user"
            if content.contains("<task-notification>") {
                guard let summary = Self.parseTaskNotification(content) else { return nil }
                blocks = [ContentBlock(kind: .text, text: summary)]
                textPreview = summary
            } else {
                blocks = [ContentBlock(kind: .text, text: content)]
                textPreview = content
            }
        } else if type == "user" {
            role = JsonlParser.isLocalCommandStdout(obj) ? "assistant" : type
            blocks = extractUserBlocks(from: obj)
            textPreview = Self.buildTextPreview(blocks: blocks, role: role)
        } else {
            role = type
            blocks = extractAssistantBlocks(from: obj)
            textPreview = Self.buildTextPreview(blocks: blocks, role: role)
        }

        return ConversationTurn(
            index: index,
            lineNumber: byteOffset,
            role: role,
            textPreview: textPreview,
            timestamp: obj["timestamp"] as? String,
            contentBlocks: blocks,
            imageCount: type == "user" ? Self.countImages(in: obj) : 0,
            modelName: (obj["message"] as? [String: Any])?["model"] as? String,
            isQueued: type == "queue-operation"
        )
    }

    // MARK: - Consecutive assistant merge

    /// Merge consecutive assistant turns into a single turn.
    /// Claude Code writes thinking + response as separate JSONL entries
    /// that are parts of the same message.
    /// Also drops queued prompts that were delivered later in `turns`.
    static func mergeConsecutiveAssistantTurns(_ turns: [ConversationTurn]) -> [ConversationTurn] {
        let turns = dropDeliveredQueuedPrompts(turns)
        guard turns.count > 1 else { return turns }
        var result: [ConversationTurn] = []
        var i = 0
        while i < turns.count {
            var current = turns[i]
            // Merge subsequent assistant turns into this one
            while i + 1 < turns.count
                    && current.role == "assistant"
                    && turns[i + 1].role == "assistant" {
                i += 1
                let next = turns[i]
                current = ConversationTurn(
                    index: current.index,
                    lineNumber: current.lineNumber,
                    role: current.role,
                    textPreview: current.textPreview == "(empty)" ? next.textPreview : current.textPreview,
                    timestamp: current.timestamp ?? next.timestamp,
                    contentBlocks: current.contentBlocks + next.contentBlocks,
                    imageCount: current.imageCount + next.imageCount,
                    modelName: current.modelName ?? next.modelName,
                    endLineNumber: next.endLineNumber
                )
            }
            result.append(current)
            i += 1
        }
        return result
    }

    /// Claude Code logs a queued prompt as an `enqueue` record, and once the
    /// prompt is taken from the queue it logs it again as a user message.
    /// Every prompt of a `claude -p` session goes through the queue. The
    /// queued copy stays only while no later user message has its text.
    static func dropDeliveredQueuedPrompts(_ turns: [ConversationTurn]) -> [ConversationTurn] {
        guard turns.contains(where: \.isQueued) else { return turns }
        var delivered: [String: Int] = [:]
        var kept: [ConversationTurn] = []
        kept.reserveCapacity(turns.count)
        func text(_ turn: ConversationTurn) -> String {
            turn.contentBlocks.filter { $0.kind == .text }.map(\.text).joined(separator: "\n")
        }
        for turn in turns.reversed() {
            if turn.isQueued {
                if let n = delivered[text(turn)], n > 0 {
                    delivered[text(turn)] = n - 1
                    continue
                }
            } else if turn.role == "user" {
                delivered[text(turn), default: 0] += 1
            }
            kept.append(turn)
        }
        return kept.reversed()
    }

    // MARK: - User message parsing

    /// Parse `<task-notification>` XML into a clean summary string.
    static func parseTaskNotification(_ text: String) -> String? {
        func extractTag(_ tag: String) -> String? {
            guard let start = text.range(of: "<\(tag)>"),
                  let end = text.range(of: "</\(tag)>") else { return nil }
            return String(text[start.upperBound..<end.lowerBound])
        }
        let status = extractTag("status") ?? "unknown"
        let summary = extractTag("summary")
        let icon = status == "completed" ? "✓" : "⏳"
        if let summary {
            return "\(icon) \(summary)"
        }
        return "\(icon) Background task \(status)"
    }

    /// Load base64-encoded images from a user turn at a specific byte offset.
    /// Returns an array of PNG Data for each image in the turn.
    public static func loadImagesAtOffset(from filePath: String, byteOffset: Int) async throws -> [Data] {
        let url = URL(fileURLWithPath: filePath)
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }

        handle.seek(toFileOffset: UInt64(byteOffset))
        // Read in chunks until we find the newline — avoids loading the entire file
        var lineBytes = Data()
        let chunkSize = 256 * 1024 // 256KB chunks
        while true {
            let chunk = handle.readData(ofLength: chunkSize)
            guard !chunk.isEmpty else { break }
            if let nlIndex = chunk.firstIndex(of: UInt8(ascii: "\n")) {
                lineBytes.append(chunk[chunk.startIndex..<nlIndex])
                break
            }
            lineBytes.append(chunk)
        }

        guard !lineBytes.isEmpty,
              let obj = try? JSONSerialization.jsonObject(with: lineBytes) as? [String: Any],
              let message = obj["message"] as? [String: Any],
              let content = message["content"] as? [[String: Any]] else { return [] }

        var images: [Data] = []
        for block in content {
            guard (block["type"] as? String) == "image",
                  let source = block["source"] as? [String: Any],
                  (source["type"] as? String) == "base64",
                  let b64 = source["data"] as? String,
                  let data = Data(base64Encoded: b64) else { continue }
            images.append(data)
        }
        return images
    }

    static func countImages(in obj: [String: Any]) -> Int {
        guard let message = obj["message"] as? [String: Any],
              let content = message["content"] as? [[String: Any]] else { return 0 }
        return content.filter { ($0["type"] as? String) == "image" }.count
    }

    static func extractUserBlocks(from obj: [String: Any]) -> [ContentBlock] {
        // Hide caveat wrapper messages entirely
        if JsonlParser.isCaveatMessage(obj) { return [] }

        // User text can be at top level or inside message.content
        if let text = JsonlParser.extractTextContent(from: obj) {
            // Show slash commands cleanly (e.g. "/clear")
            if let command = JsonlParser.parseLocalCommandDisplay(text) {
                return [ContentBlock(kind: .text, text: command)]
            }
            // Show command stdout as plain text
            if let stdout = JsonlParser.parseLocalCommandStdout(text) {
                return [ContentBlock(kind: .text, text: stdout)]
            }
            // Parse task notifications (background command completions)
            if text.contains("<task-notification>") {
                if let summary = Self.parseTaskNotification(text) {
                    return [ContentBlock(kind: .text, text: summary)]
                }
                return [] // Hide malformed task notifications
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
                    result.append(ContentBlock(kind: .thinking, text: thinking))
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
