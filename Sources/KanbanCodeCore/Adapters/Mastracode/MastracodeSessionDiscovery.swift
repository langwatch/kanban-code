import Foundation

public final class MastracodeSessionDiscovery: SessionDiscovery, @unchecked Sendable {
    private let databasePath: String

    public init(databasePath: String? = nil) {
        self.databasePath = databasePath
            ?? (NSHomeDirectory() as NSString).appendingPathComponent("Library/Application Support/mastracode/mastra.db")
    }

    public func discoverSessions() async throws -> [Session] {
        guard FileManager.default.fileExists(atPath: databasePath) else { return [] }

        let threads = try MastracodeDatabase.readThreads(databasePath: databasePath)
        return threads.map { thread in
            Session(
                id: thread.id,
                name: thread.title.isEmpty ? nil : thread.title,
                firstPrompt: MastracodeDatabase.extractUserText(from: thread.firstUserContent),
                projectPath: MastracodeDatabase.extractProjectPath(from: thread.metadata),
                messageCount: thread.messageCount,
                modifiedTime: parseDate(thread.updatedAt) ?? .distantPast,
                jsonlPath: MastracodeSessionPath.encode(databasePath: databasePath, threadId: thread.id),
                assistant: .mastracode
            )
        }
    }

    public func discoverNewOrModified(since: Date) async throws -> [Session] {
        try await discoverSessions().filter { $0.modifiedTime >= since }
    }

    private func parseDate(_ value: String) -> Date? {
        makeFractionalISO8601Formatter().date(from: value)
            ?? ISO8601DateFormatter().date(from: value)
    }
}

func makeFractionalISO8601Formatter() -> ISO8601DateFormatter {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return formatter
}
