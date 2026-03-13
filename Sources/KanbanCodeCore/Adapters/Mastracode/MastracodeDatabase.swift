import Foundation
import SQLite3

struct MastracodeThreadRecord: Sendable {
    let id: String
    let title: String
    let metadata: String?
    let createdAt: String
    let updatedAt: String
    let messageCount: Int
    let firstUserContent: String?
}

struct MastracodeMessageRecord: Sendable {
    let role: String
    let type: String
    let content: String
    let createdAt: String
}

enum MastracodeDatabase {
    private static let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    static func readThreads(databasePath: String) throws -> [MastracodeThreadRecord] {
        try withDatabase(at: databasePath, readOnly: true) { db in
            let sql = """
            SELECT
              t.id,
              t.title,
              t.metadata,
              t.createdAt,
              t.updatedAt,
              (SELECT COUNT(*) FROM mastra_messages WHERE thread_id = t.id) AS messageCount,
              (SELECT content FROM mastra_messages
               WHERE thread_id = t.id AND role = 'user'
               ORDER BY createdAt ASC LIMIT 1) AS firstUserContent
            FROM mastra_threads t
            ORDER BY t.updatedAt DESC
            """

            var rows: [MastracodeThreadRecord] = []
            try query(db: db, sql: sql) { stmt in
                rows.append(
                    MastracodeThreadRecord(
                        id: text(stmt, index: 0) ?? "",
                        title: text(stmt, index: 1) ?? "",
                        metadata: text(stmt, index: 2),
                        createdAt: text(stmt, index: 3) ?? "",
                        updatedAt: text(stmt, index: 4) ?? "",
                        messageCount: Int(sqlite3_column_int64(stmt, 5)),
                        firstUserContent: text(stmt, index: 6)
                    )
                )
            }
            return rows
        }
    }

    static func readMessages(databasePath: String, threadId: String) throws -> [MastracodeMessageRecord] {
        try withDatabase(at: databasePath, readOnly: true) { db in
            let sql = """
            SELECT role, type, content, createdAt
            FROM mastra_messages
            WHERE thread_id = ?
            ORDER BY createdAt ASC, id ASC
            """
            var rows: [MastracodeMessageRecord] = []
            try query(db: db, sql: sql, bind: [.text(threadId)]) { stmt in
                rows.append(
                    MastracodeMessageRecord(
                        role: text(stmt, index: 0) ?? "",
                        type: text(stmt, index: 1) ?? "",
                        content: text(stmt, index: 2) ?? "",
                        createdAt: text(stmt, index: 3) ?? ""
                    )
                )
            }
            return rows
        }
    }

    static func readUpdatedAt(databasePath: String, threadId: String) throws -> String? {
        try withDatabase(at: databasePath, readOnly: true) { db in
            let sql = "SELECT updatedAt FROM mastra_threads WHERE id = ? LIMIT 1"
            var value: String?
            try query(db: db, sql: sql, bind: [.text(threadId)]) { stmt in
                value = text(stmt, index: 0)
            }
            return value
        }
    }

    static func writeSession(
        databasePath: String,
        threadId: String,
        title: String,
        projectPath: String?,
        turns: [ConversationTurn]
    ) throws {
        try ensureSchema(databasePath: databasePath)

        try withDatabase(at: databasePath, readOnly: false) { db in
            try exec(db: db, sql: "BEGIN IMMEDIATE TRANSACTION")
            do {
                let firstTimestamp = turns.first?.timestamp ?? isoNow()
                let lastTimestamp = turns.last?.timestamp ?? firstTimestamp
                let metadata = try jsonString(["projectPath": projectPath ?? ""])

                try exec(
                    db: db,
                    sql: """
                    INSERT OR REPLACE INTO mastra_threads (id, resourceId, title, metadata, createdAt, updatedAt)
                    VALUES (?, ?, ?, ?, ?, ?)
                    """,
                    bind: [
                        .text(threadId),
                        .text(projectPath ?? (threadId as NSString).lastPathComponent),
                        .text(title),
                        .text(metadata),
                        .text(firstTimestamp),
                        .text(lastTimestamp),
                    ]
                )

                try exec(
                    db: db,
                    sql: "DELETE FROM mastra_messages WHERE thread_id = ?",
                    bind: [.text(threadId)]
                )

                for (index, turn) in turns.enumerated() {
                    let messageId = "msg-\(threadId)-\(index)"
                    let payload = try messagePayload(for: turn)
                    try exec(
                        db: db,
                        sql: """
                        INSERT INTO mastra_messages (id, thread_id, content, role, type, createdAt, resourceId)
                        VALUES (?, ?, ?, ?, ?, ?, ?)
                        """,
                        bind: [
                            .text(messageId),
                            .text(threadId),
                            .text(payload.json),
                            .text(payload.role),
                            .text(payload.type),
                            .text(turn.timestamp ?? isoNow()),
                            .text(projectPath),
                        ]
                    )
                }

                try exec(db: db, sql: "COMMIT")
            } catch {
                try? exec(db: db, sql: "ROLLBACK")
                throw error
            }
        }
    }

    static func backupAndDeleteSession(databasePath: String, threadId: String) throws -> String {
        let thread = try readThreads(databasePath: databasePath).first { $0.id == threadId }
        let messages = try readMessages(databasePath: databasePath, threadId: threadId)

        let backupPath = databasePath + ".\(threadId).bak.json"
        let backup: [String: Any] = [
            "thread": [
                "id": thread?.id ?? threadId,
                "title": thread?.title ?? "",
                "metadata": thread?.metadata ?? "",
                "createdAt": thread?.createdAt ?? "",
                "updatedAt": thread?.updatedAt ?? "",
            ],
            "messages": messages.map {
                [
                    "role": $0.role,
                    "type": $0.type,
                    "content": $0.content,
                    "createdAt": $0.createdAt,
                ]
            },
        ]
        let backupData = try JSONSerialization.data(withJSONObject: backup, options: [.prettyPrinted, .sortedKeys])
        try backupData.write(to: URL(fileURLWithPath: backupPath))

        try withDatabase(at: databasePath, readOnly: false) { db in
            try exec(db: db, sql: "BEGIN IMMEDIATE TRANSACTION")
            do {
                try exec(db: db, sql: "DELETE FROM mastra_messages WHERE thread_id = ?", bind: [.text(threadId)])
                try exec(db: db, sql: "DELETE FROM mastra_threads WHERE id = ?", bind: [.text(threadId)])
                try exec(db: db, sql: "COMMIT")
            } catch {
                try? exec(db: db, sql: "ROLLBACK")
                throw error
            }
        }

        return backupPath
    }

    static func ensureSchema(databasePath: String) throws {
        let parentDir = (databasePath as NSString).deletingLastPathComponent
        try FileManager.default.createDirectory(atPath: parentDir, withIntermediateDirectories: true)

        try withDatabase(at: databasePath, readOnly: false) { db in
            try exec(
                db: db,
                sql: """
                CREATE TABLE IF NOT EXISTS mastra_threads (
                  id TEXT NOT NULL PRIMARY KEY,
                  resourceId TEXT NOT NULL,
                  title TEXT NOT NULL,
                  metadata TEXT,
                  createdAt TEXT NOT NULL,
                  updatedAt TEXT NOT NULL
                );
                """
            )
            try exec(
                db: db,
                sql: """
                CREATE TABLE IF NOT EXISTS mastra_messages (
                  id TEXT NOT NULL PRIMARY KEY,
                  thread_id TEXT NOT NULL,
                  content TEXT NOT NULL,
                  role TEXT NOT NULL,
                  type TEXT NOT NULL,
                  createdAt TEXT NOT NULL,
                  resourceId TEXT
                );
                """
            )
        }
    }

    static func extractProjectPath(from metadata: String?) -> String? {
        guard let metadata, !metadata.isEmpty else { return nil }

        if let object = jsonObject(from: metadata),
           let projectPath = findString(in: object, matchingKeys: ["projectPath", "cwd", "workingDirectory", "workspaceRoot", "repositoryRoot"]),
           !projectPath.isEmpty {
            return projectPath
        }

        let text = metadata.unicodeScalars.map { scalar in
            CharacterSet.controlCharacters.contains(scalar) ? " " : String(scalar)
        }.joined()
        guard let keyRange = text.range(of: "projectPath") else { return nil }
        let suffix = text[keyRange.upperBound...]
        guard let pathStart = suffix.firstIndex(where: { $0 == "/" || $0 == "~" }) else { return nil }
        let path = suffix[pathStart...].prefix { character in
            character.unicodeScalars.allSatisfy { scalar in
                !CharacterSet.controlCharacters.contains(scalar) && !CharacterSet.whitespacesAndNewlines.contains(scalar)
            }
        }
        return path.isEmpty ? nil : String(path)
    }

    static func extractUserText(from content: String?) -> String? {
        guard let content, let object = jsonObject(from: content) else { return nil }
        if let text = object["content"] as? String, !text.isEmpty {
            return text
        }
        if let parts = object["parts"] as? [[String: Any]] {
            let textParts = parts.compactMap { part -> String? in
                guard (part["type"] as? String) == "text" else { return nil }
                return part["text"] as? String
            }
            let joined = textParts.joined(separator: "\n")
            return joined.isEmpty ? nil : joined
        }
        return nil
    }

    static func parseTurns(messages: [MastracodeMessageRecord]) -> [ConversationTurn] {
        messages.enumerated().map { index, message in
            let role: String
            switch message.role {
            case "user":
                role = "user"
            case "assistant":
                role = "assistant"
            default:
                role = "system"
            }

            let blocks = parseBlocks(content: message.content, role: role)
            let preview = buildTextPreview(blocks: blocks, fallback: extractUserText(from: message.content) ?? "")
            return ConversationTurn(
                index: index,
                lineNumber: index + 1,
                role: role,
                textPreview: preview.isEmpty ? message.type : preview,
                timestamp: message.createdAt,
                contentBlocks: blocks
            )
        }
    }

    private static func parseBlocks(content: String, role: String) -> [ContentBlock] {
        guard let object = jsonObject(from: content) else {
            return [ContentBlock(kind: .text, text: content)]
        }

        if role != "assistant" {
            if let text = extractUserText(from: content), !text.isEmpty {
                return [ContentBlock(kind: .text, text: text)]
            }
            return []
        }

        var blocks: [ContentBlock] = []
        let parts = object["parts"] as? [[String: Any]] ?? []
        for part in parts {
            switch part["type"] as? String {
            case "text":
                if let text = part["text"] as? String, !text.isEmpty {
                    blocks.append(ContentBlock(kind: .text, text: text))
                }
            case "reasoning":
                let reasoning = (part["reasoning"] as? String)
                    ?? ((part["details"] as? [[String: Any]])?.compactMap { $0["text"] as? String }.joined(separator: "\n"))
                if let reasoning, !reasoning.isEmpty {
                    blocks.append(ContentBlock(kind: .thinking, text: String(reasoning.prefix(500))))
                }
            case "tool-invocation":
                if let toolInvocation = part["toolInvocation"] as? [String: Any] {
                    let name = (toolInvocation["toolName"] as? String) ?? "unknown"
                    let args = stringifyMap(toolInvocation["args"] as? [String: Any] ?? [:])
                    blocks.append(ContentBlock(kind: .toolUse(name: name, input: args), text: name))
                    if let resultText = toolResultText(from: toolInvocation["result"]), !resultText.isEmpty {
                        blocks.append(ContentBlock(kind: .toolResult(toolName: name), text: resultText))
                    }
                }
            default:
                continue
            }
        }

        if blocks.isEmpty, let text = object["content"] as? String, !text.isEmpty {
            blocks.append(ContentBlock(kind: .text, text: text))
        }

        return blocks
    }

    private static func buildTextPreview(blocks: [ContentBlock], fallback: String) -> String {
        for block in blocks {
            switch block.kind {
            case .text, .thinking, .toolResult:
                if !block.text.isEmpty { return block.text }
            case .toolUse(let name, _):
                return name
            }
        }
        return fallback
    }

    private static func messagePayload(for turn: ConversationTurn) throws -> (json: String, role: String, type: String) {
        switch turn.role {
        case "user":
            let text = extractText(turn: turn)
            return (try jsonString([
                "format": 2,
                "parts": [["type": "text", "text": text]],
                "content": text,
            ]), "user", "message")
        case "assistant":
            var parts: [[String: Any]] = []
            var lastToolIndex: Int?

            for block in turn.contentBlocks {
                switch block.kind {
                case .text:
                    parts.append(["type": "text", "text": block.text])
                case .thinking:
                    parts.append([
                        "type": "reasoning",
                        "reasoning": block.text,
                        "details": [["type": "text", "text": block.text]],
                    ])
                case .toolUse(let name, let input):
                    parts.append([
                        "type": "tool-invocation",
                        "toolInvocation": [
                            "state": "pending",
                            "toolName": name,
                            "args": input,
                        ],
                    ])
                    lastToolIndex = parts.count - 1
                case .toolResult:
                    if let lastToolIndex,
                       var toolPart = parts[lastToolIndex]["toolInvocation"] as? [String: Any] {
                        toolPart["state"] = "result"
                        toolPart["result"] = ["content": block.text]
                        parts[lastToolIndex]["toolInvocation"] = toolPart
                    } else {
                        parts.append(["type": "text", "text": block.text])
                    }
                }
            }

            let text = extractText(turn: turn)
            return (try jsonString([
                "format": 2,
                "parts": parts,
                "content": text,
            ]), "assistant", "message")
        default:
            let text = extractText(turn: turn)
            return (try jsonString([
                "format": 2,
                "parts": [["type": "text", "text": text]],
                "content": text,
            ]), "system", "notification")
        }
    }

    private static func extractText(turn: ConversationTurn) -> String {
        let text = turn.contentBlocks.compactMap { block -> String? in
            if case .text = block.kind { return block.text }
            return nil
        }.joined(separator: "\n")
        return text.isEmpty ? turn.textPreview : text
    }

    private static func toolResultText(from result: Any?) -> String? {
        switch result {
        case let text as String:
            return text
        case let dict as [String: Any]:
            if let content = dict["content"] as? String { return content }
            if JSONSerialization.isValidJSONObject(dict),
               let data = try? JSONSerialization.data(withJSONObject: dict, options: [.sortedKeys]),
               let text = String(data: data, encoding: .utf8) {
                return text
            }
            return nil
        case let array as [Any]:
            if JSONSerialization.isValidJSONObject(array),
               let data = try? JSONSerialization.data(withJSONObject: array, options: [.sortedKeys]),
               let text = String(data: data, encoding: .utf8) {
                return text
            }
            return nil
        default:
            return nil
        }
    }

    private static func stringifyMap(_ dictionary: [String: Any]) -> [String: String] {
        dictionary.reduce(into: [String: String]()) { result, item in
            if let value = item.value as? String {
                result[item.key] = value
            } else if let number = item.value as? NSNumber {
                result[item.key] = number.stringValue
            } else if JSONSerialization.isValidJSONObject([item.key: item.value]),
                      let data = try? JSONSerialization.data(withJSONObject: item.value, options: [.sortedKeys]),
                      let text = String(data: data, encoding: .utf8) {
                result[item.key] = text
            }
        }
    }

    private static func jsonObject(from text: String) -> [String: Any]? {
        guard let data = text.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return object
    }

    private static func findString(in object: Any, matchingKeys keys: Set<String>) -> String? {
        if let dictionary = object as? [String: Any] {
            for (key, value) in dictionary {
                if keys.contains(key), let text = value as? String, !text.isEmpty {
                    return text
                }
                if let found = findString(in: value, matchingKeys: keys) {
                    return found
                }
            }
        } else if let array = object as? [Any] {
            for item in array {
                if let found = findString(in: item, matchingKeys: keys) {
                    return found
                }
            }
        }
        return nil
    }

    private enum SQLiteValue {
        case text(String?)
    }

    private static func withDatabase<T>(at path: String, readOnly: Bool, _ body: (OpaquePointer) throws -> T) throws -> T {
        var db: OpaquePointer?
        let flags = readOnly ? SQLITE_OPEN_READONLY : (SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE)
        guard sqlite3_open_v2(path, &db, flags, nil) == SQLITE_OK, let db else {
            throw sqliteError(db)
        }
        defer { sqlite3_close(db) }
        return try body(db)
    }

    private static func query(
        db: OpaquePointer,
        sql: String,
        bind: [SQLiteValue] = [],
        row: (OpaquePointer) throws -> Void
    ) throws {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else {
            throw sqliteError(db)
        }
        defer { sqlite3_finalize(stmt) }
        try bindValues(bind, to: stmt)

        while true {
            let step = sqlite3_step(stmt)
            if step == SQLITE_ROW {
                try row(stmt)
            } else if step == SQLITE_DONE {
                return
            } else {
                throw sqliteError(db)
            }
        }
    }

    private static func exec(db: OpaquePointer, sql: String, bind: [SQLiteValue] = []) throws {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else {
            throw sqliteError(db)
        }
        defer { sqlite3_finalize(stmt) }
        try bindValues(bind, to: stmt)

        guard sqlite3_step(stmt) == SQLITE_DONE else {
            throw sqliteError(db)
        }
    }

    private static func bindValues(_ values: [SQLiteValue], to stmt: OpaquePointer) throws {
        for (index, value) in values.enumerated() {
            switch value {
            case .text(let text):
                if let text {
                    sqlite3_bind_text(stmt, Int32(index + 1), text, -1, sqliteTransient)
                } else {
                    sqlite3_bind_null(stmt, Int32(index + 1))
                }
            }
        }
    }

    private static func text(_ stmt: OpaquePointer, index: Int32) -> String? {
        guard let pointer = sqlite3_column_text(stmt, index) else { return nil }
        return String(cString: pointer)
    }

    private static func isoNow() -> String {
        ISO8601DateFormatter().string(from: .now)
    }

    private static func jsonString(_ object: [String: Any]) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        guard let text = String(data: data, encoding: .utf8) else {
            throw SessionStoreError.writeNotSupported
        }
        return text
    }

    private static func sqliteError(_ db: OpaquePointer?) -> NSError {
        NSError(
            domain: "sqlite",
            code: Int(sqlite3_errcode(db)),
            userInfo: [NSLocalizedDescriptionKey: String(cString: sqlite3_errmsg(db))]
        )
    }
}
