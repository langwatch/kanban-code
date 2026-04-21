import Foundation

/// Discovers Codex CLI sessions by scanning `~/.codex/sessions/**/*.jsonl`
/// and merging `~/.codex/session_index.jsonl` thread names.
public final class CodexSessionDiscovery: SessionDiscovery, @unchecked Sendable {
    private let codexDir: String
    private var cachedSessions: [String: Session] = [:]
    private var fileMtimes: [String: Date] = [:]

    public init(codexDir: String? = nil) {
        self.codexDir = codexDir
            ?? (NSHomeDirectory() as NSString).appendingPathComponent(".codex")
    }

    public func discoverSessions() async throws -> [Session] {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: codexDir) else { return [] }

        let index = readSessionIndex()
        let files = Self.sessionFiles(codexDir: codexDir)
        let seenFiles = Set(files)

        for removedPath in Set(fileMtimes.keys).subtracting(seenFiles) {
            fileMtimes.removeValue(forKey: removedPath)
            cachedSessions = cachedSessions.filter { $0.value.jsonlPath != removedPath }
        }

        for filePath in files {
            guard let attrs = try? fileManager.attributesOfItem(atPath: filePath),
                  let mtime = attrs[.modificationDate] as? Date else { continue }

            if let cachedMtime = fileMtimes[filePath],
               cachedMtime == mtime,
               let cached = cachedSessions.values.first(where: { $0.jsonlPath == filePath }) {
                if let name = index[cached.id], cached.name != name {
                    var updated = cached
                    updated.name = name
                    cachedSessions[cached.id] = updated
                }
                continue
            }

            fileMtimes[filePath] = mtime

            guard let metadata = try? await CodexSessionParser.extractMetadata(from: filePath) else {
                continue
            }

            cachedSessions[metadata.sessionId] = Session(
                id: metadata.sessionId,
                name: index[metadata.sessionId],
                firstPrompt: metadata.firstPrompt,
                projectPath: metadata.projectPath,
                gitBranch: metadata.gitBranch,
                messageCount: metadata.messageCount,
                modifiedTime: mtime,
                jsonlPath: filePath,
                assistant: .codex
            )
        }

        return cachedSessions.values.sorted { $0.modifiedTime > $1.modifiedTime }
    }

    public func discoverNewOrModified(since: Date) async throws -> [Session] {
        try await discoverSessions()
    }

    public static func sessionFiles(codexDir: String? = nil) -> [String] {
        let root = codexDir ?? (NSHomeDirectory() as NSString).appendingPathComponent(".codex")
        let sessionsDir = (root as NSString).appendingPathComponent("sessions")
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: sessionsDir),
              let enumerator = fileManager.enumerator(atPath: sessionsDir) else {
            return []
        }

        var files: [String] = []
        for case let relativePath as String in enumerator {
            guard relativePath.hasSuffix(".jsonl") else { continue }
            files.append((sessionsDir as NSString).appendingPathComponent(relativePath))
        }
        return files
    }

    // MARK: - Session Index

    private struct SessionIndexEntry: Codable {
        let id: String
        let threadName: String?

        enum CodingKeys: String, CodingKey {
            case id
            case threadName = "thread_name"
        }
    }

    private func readSessionIndex() -> [String: String] {
        let indexPath = (codexDir as NSString).appendingPathComponent("session_index.jsonl")
        guard let handle = FileHandle(forReadingAtPath: indexPath) else { return [:] }
        defer { try? handle.close() }

        var result: [String: String] = [:]
        let decoder = JSONDecoder()
        let data = handle.readDataToEndOfFile()
        guard let text = String(data: data, encoding: .utf8) else { return [:] }

        for line in text.components(separatedBy: "\n") {
            guard !line.isEmpty, let lineData = line.data(using: .utf8),
                  let entry = try? decoder.decode(SessionIndexEntry.self, from: lineData),
                  let name = entry.threadName,
                  !name.isEmpty else { continue }
            result[entry.id] = name
        }
        return result
    }
}
