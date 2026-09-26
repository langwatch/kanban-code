import Foundation

/// Discovers Claude Code sessions by scanning ~/.claude/projects/.
/// Merges sessions-index.json metadata with .jsonl file scanning.
///
/// Caching strategy: keeps the full result from the last scan. On subsequent
/// scans, only re-processes project directories whose own mtime changed (i.e.
/// files were added/removed/renamed). Within unchanged directories, per-file
/// mtime checks skip re-parsing unchanged .jsonl files.
public final class ClaudeCodeSessionDiscovery: SessionDiscovery, @unchecked Sendable {
    private let claudeDir: String
    private var lastScanTime: Date?

    /// Cache: sessionId → parsed session (from all dirs combined)
    private var cachedSessions: [String: Session] = [:]
    /// Per-directory mtime to skip unchanged directories entirely
    private var dirMtimes: [String: Date] = [:]
    /// Per-file mtime to skip unchanged .jsonl files within changed directories
    private var fileMtimes: [String: Date] = [:]
    /// Track which sessions came from which directory for eviction
    private var dirSessionIds: [String: Set<String>] = [:]

    public init(claudeDir: String? = nil) {
        self.claudeDir = claudeDir
            ?? (NSHomeDirectory() as NSString).appendingPathComponent(".claude/projects")
    }

    public func discoverSessions() async throws -> [Session] {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: claudeDir) else { return [] }

        let projectDirs = try fileManager.contentsOfDirectory(atPath: claudeDir)
        var seenDirs: Set<String> = []

        for dirName in projectDirs {
            let dirPath = (claudeDir as NSString).appendingPathComponent(dirName)
            var isDir: ObjCBool = false
            guard fileManager.fileExists(atPath: dirPath, isDirectory: &isDir), isDir.boolValue else {
                continue
            }
            seenDirs.insert(dirName)

            // Check directory mtime — skip entirely if unchanged
            let dirAttrs = try? fileManager.attributesOfItem(atPath: dirPath)
            let dirMtime = dirAttrs?[.modificationDate] as? Date
            if let cached = dirMtimes[dirName], dirMtime == cached {
                continue // No files added/removed in this directory
            }
            dirMtimes[dirName] = dirMtime

            // Directory changed — re-scan it
            var dirSessions: Set<String> = []

            // Read index file for summaries
            let indexPath = (dirPath as NSString).appendingPathComponent("sessions-index.json")
            let indexEntries = (try? SessionIndexReader.readIndex(at: indexPath, directoryName: dirName)) ?? []

            var indexById: [String: SessionIndexReader.IndexEntry] = [:]
            for entry in indexEntries {
                indexById[entry.sessionId] = entry
            }

            // Scan .jsonl files
            let contents = (try? fileManager.contentsOfDirectory(atPath: dirPath)) ?? []
            let jsonlFiles = contents.filter { $0.hasSuffix(".jsonl") }

            for jsonlFile in jsonlFiles {
                let filePath = (dirPath as NSString).appendingPathComponent(jsonlFile)
                let sessionId = jsonlFile.replacingOccurrences(of: ".jsonl", with: "")
                dirSessions.insert(sessionId)

                guard let attrs = try? fileManager.attributesOfItem(atPath: filePath),
                      let mtime = attrs[.modificationDate] as? Date else {
                    continue
                }

                // Skip if file mtime unchanged and we have a cached session
                if let cachedMtime = fileMtimes[filePath],
                   mtime == cachedMtime,
                   cachedSessions[sessionId] != nil {
                    // Still merge index data in case index was updated
                    if let entry = indexById[sessionId], var session = cachedSessions[sessionId] {
                        if session.name == nil { session.name = entry.summary }
                        if session.projectPath == nil { session.projectPath = entry.projectPath }
                        cachedSessions[sessionId] = session
                    }
                    continue
                }
                fileMtimes[filePath] = mtime

                // Parse .jsonl for metadata
                let indexEntry = indexById[sessionId]
                if let metadata = try? await JsonlParser.extractMetadata(from: filePath) {
                    var session = Session(id: sessionId)
                    session.name = indexEntry?.summary
                    session.projectPath = indexEntry?.projectPath
                    session.jsonlPath = filePath
                    session.modifiedTime = mtime
                    session.messageCount = metadata.messageCount
                    session.entrypoint = metadata.entrypoint

                    if session.firstPrompt == nil {
                        session.firstPrompt = metadata.firstPrompt
                    }
                    if session.projectPath == nil {
                        session.projectPath = metadata.projectPath
                            ?? JsonlParser.decodeDirectoryName(dirName)
                    }
                    if session.gitBranch == nil {
                        session.gitBranch = metadata.gitBranch
                    }

                    cachedSessions[sessionId] = session
                } else if let entry = indexEntry {
                    // File couldn't parse but we have index data
                    if var session = cachedSessions[sessionId] ?? Session(id: sessionId) as Session? {
                        session.name = session.name ?? entry.summary
                        session.projectPath = session.projectPath ?? entry.projectPath
                        session.jsonlPath = filePath
                        session.modifiedTime = mtime
                        cachedSessions[sessionId] = session
                    }
                }
            }

            // Evict sessions from this dir that no longer exist
            if let oldIds = dirSessionIds[dirName] {
                for removedId in oldIds.subtracting(dirSessions) {
                    cachedSessions.removeValue(forKey: removedId)
                }
            }
            dirSessionIds[dirName] = dirSessions
        }

        // Evict entire directories that were removed
        for removedDir in Set(dirMtimes.keys).subtracting(seenDirs) {
            dirMtimes.removeValue(forKey: removedDir)
            if let ids = dirSessionIds.removeValue(forKey: removedDir) {
                for id in ids { cachedSessions.removeValue(forKey: id) }
            }
        }

        let sessions = cachedSessions.values
            .filter { $0.messageCount > 0 }
            .sorted { $0.modifiedTime > $1.modifiedTime }

        lastScanTime = Date()
        return Array(sessions)
    }

    public func discoverNewOrModified(since: Date) async throws -> [Session] {
        return try await discoverSessions()
    }
}
