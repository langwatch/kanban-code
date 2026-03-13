import Foundation
import SQLite3

enum MastracodeTestHelpers {
    private static let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    static func makeTempDatabase() throws -> String {
        let dir = "/tmp/kanban-test-mastracode-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let dbPath = (dir as NSString).appendingPathComponent("mastra.db")
        try createSchema(at: dbPath)
        return dbPath
    }

    static func cleanupDatabase(at dbPath: String) {
        let dir = (dbPath as NSString).deletingLastPathComponent
        try? FileManager.default.removeItem(atPath: dir)
    }

    static func insertThread(
        dbPath: String,
        id: String,
        resourceId: String = "proj-1",
        title: String = "",
        metadata: [String: Any]? = nil,
        createdAt: String = "2026-03-09T10:00:00Z",
        updatedAt: String = "2026-03-09T10:05:00Z"
    ) throws {
        let metadataText = try metadata.map(jsonString) ?? ""
        try execute(
            dbPath: dbPath,
            sql: """
            INSERT INTO mastra_threads (id, resourceId, title, metadata, createdAt, updatedAt)
            VALUES (?, ?, ?, ?, ?, ?)
            """,
            bind: [
                .text(id),
                .text(resourceId),
                .text(title),
                .text(metadataText),
                .text(createdAt),
                .text(updatedAt),
            ]
        )
    }

    static func insertMessage(
        dbPath: String,
        id: String = UUID().uuidString,
        threadId: String,
        role: String,
        type: String = "message",
        content: [String: Any],
        createdAt: String
    ) throws {
        try execute(
            dbPath: dbPath,
            sql: """
            INSERT INTO mastra_messages (id, thread_id, content, role, type, createdAt, resourceId)
            VALUES (?, ?, ?, ?, ?, ?, ?)
            """,
            bind: [
                .text(id),
                .text(threadId),
                .text(try jsonString(content)),
                .text(role),
                .text(type),
                .text(createdAt),
                .text(nil),
            ]
        )
    }

    static func userContent(_ text: String) -> [String: Any] {
        [
            "format": 2,
            "parts": [["type": "text", "text": text]],
            "content": text,
        ]
    }

    static func assistantContent(
        reasoning: String? = nil,
        toolName: String? = nil,
        toolArgs: [String: String]? = nil,
        toolResult: String? = nil,
        text: String? = nil
    ) -> [String: Any] {
        var parts: [[String: Any]] = []
        if let reasoning {
            parts.append([
                "type": "reasoning",
                "reasoning": reasoning,
                "details": [["type": "text", "text": reasoning]],
            ])
        }
        if let toolName {
            var toolInvocation: [String: Any] = [
                "state": toolResult == nil ? "pending" : "result",
                "toolName": toolName,
                "args": toolArgs ?? [:],
            ]
            if let toolResult {
                toolInvocation["result"] = ["content": toolResult]
            }
            parts.append([
                "type": "tool-invocation",
                "toolInvocation": toolInvocation,
            ])
        }
        if let text {
            parts.append(["type": "text", "text": text])
        }
        return [
            "format": 2,
            "parts": parts,
            "content": text ?? "",
        ]
    }

    static func systemContent(_ text: String) -> [String: Any] {
        [
            "format": 2,
            "parts": [["type": "text", "text": text]],
            "content": text,
        ]
    }

    private enum SQLiteValue {
        case text(String?)
    }

    private static func createSchema(at dbPath: String) throws {
        try execute(
            dbPath: dbPath,
            sql: """
            CREATE TABLE mastra_threads (
              id TEXT NOT NULL PRIMARY KEY,
              resourceId TEXT NOT NULL,
              title TEXT NOT NULL,
              metadata TEXT,
              createdAt TEXT NOT NULL,
              updatedAt TEXT NOT NULL
            );
            """,
            bind: []
        )
        try execute(
            dbPath: dbPath,
            sql: """
            CREATE TABLE mastra_messages (
              id TEXT NOT NULL PRIMARY KEY,
              thread_id TEXT NOT NULL,
              content TEXT NOT NULL,
              role TEXT NOT NULL,
              type TEXT NOT NULL,
              createdAt TEXT NOT NULL,
              resourceId TEXT
            );
            """,
            bind: []
        )
    }

    private static func execute(dbPath: String, sql: String, bind: [SQLiteValue]) throws {
        var db: OpaquePointer?
        guard sqlite3_open(dbPath, &db) == SQLITE_OK, let db else {
            throw NSError(domain: "sqlite", code: 1)
        }
        defer { sqlite3_close(db) }

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else {
            throw sqliteError(db)
        }
        defer { sqlite3_finalize(stmt) }

        for (index, value) in bind.enumerated() {
            switch value {
            case .text(let text):
                if let text {
                    sqlite3_bind_text(stmt, Int32(index + 1), text, -1, sqliteTransient)
                } else {
                    sqlite3_bind_null(stmt, Int32(index + 1))
                }
            }
        }

        guard sqlite3_step(stmt) == SQLITE_DONE else {
            throw sqliteError(db)
        }
    }

    private static func jsonString(_ object: [String: Any]) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        guard let string = String(data: data, encoding: .utf8) else {
            throw NSError(domain: "json", code: 1)
        }
        return string
    }

    private static func sqliteError(_ db: OpaquePointer?) -> NSError {
        NSError(
            domain: "sqlite",
            code: Int(sqlite3_errcode(db)),
            userInfo: [NSLocalizedDescriptionKey: String(cString: sqlite3_errmsg(db))]
        )
    }
}
