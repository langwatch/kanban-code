import Foundation

/// Discovers Claude Code sessions by scanning the `projects/` folder of every
/// Claude config folder (`~/.claude` and the configured accounts, see
/// `ClaudeConfigDirectories`). Merges sessions-index.json metadata with
/// .jsonl file scanning.
///
/// Caching strategy: keeps the full result from the last scan. On subsequent
/// scans, only re-processes project directories whose own mtime changed (i.e.
/// files were added/removed/renamed). Within unchanged directories, per-file
/// mtime checks skip re-parsing unchanged .jsonl files.
public final class ClaudeCodeSessionDiscovery: SessionDiscovery, @unchecked Sendable {
    private let projectsDirectories: @Sendable () -> [String]
    private var lastScanTime: Date?

    /// Cache: sessionId → parsed session (from all dirs combined)
    private var cachedSessions: [String: Session] = [:]
    /// Per-directory mtime to skip unchanged directories entirely, by full
    /// path: two config folders can each hold a folder of the same name.
    private var dirMtimes: [String: Date] = [:]
    /// Per-file mtime to skip unchanged .jsonl files within changed directories
    private var fileMtimes: [String: Date] = [:]
    /// Track which sessions came from which directory for eviction
    private var dirSessionIds: [String: Set<String>] = [:]
    /// Headless sessions whose project is excluded, by directory: never
    /// read again, whatever their mtime, until the exclusions change.
    private var dirSkippedIds: [String: Set<String>] = [:]
    private var headlessExclusion: PathExclusion = .none

    /// `claudeDir` scans that one projects folder; nil scans the projects
    /// folders of `ClaudeConfigDirectories.current`, as they are at each scan.
    public convenience init(claudeDir: String? = nil) {
        if let claudeDir {
            self.init(projectsDirectories: { [claudeDir] })
        } else {
            self.init(projectsDirectories: { ClaudeConfigDirectories.current.projectsDirectories })
        }
    }

    public init(projectsDirectories: @escaping @Sendable () -> [String]) {
        self.projectsDirectories = projectsDirectories
    }

    public func setHeadlessExclusion(_ exclusion: PathExclusion) {
        guard exclusion != headlessExclusion else { return }
        headlessExclusion = exclusion
        // Rescan every directory: sessions a removed entry excluded come
        // back, and cached ones a new entry excludes go.
        dirMtimes = [:]
        dirSkippedIds = [:]
        for (id, session) in cachedSessions where isExcludedHeadless(session) {
            cachedSessions.removeValue(forKey: id)
        }
    }

    private func isExcludedHeadless(_ session: Session) -> Bool {
        session.isHeadless && headlessExclusion.matches(session.projectPath)
    }

    /// Drops a cached session whose transcript left `dirPath`. A transcript
    /// that moved to another project directory (the session entered a
    /// worktree) may already be cached at its new path, and stays.
    private func evict(_ sessionId: String, ifStoredIn dirPath: String) {
        if let path = cachedSessions[sessionId]?.jsonlPath,
           (path as NSString).deletingLastPathComponent != dirPath {
            return
        }
        cachedSessions.removeValue(forKey: sessionId)
        // Another folder may hold a copy `keep` passed over (a config
        // folder copied from another): the next scan reads it again.
        for (otherDir, ids) in dirSessionIds where otherDir != dirPath && ids.contains(sessionId) {
            dirMtimes.removeValue(forKey: otherDir)
        }
    }

    /// Caches `session`, unless the same session id is cached from another
    /// transcript that still exists and is at least as new: a config folder
    /// copied from another holds the same ids, and the card must not flip
    /// between the copies from one scan to the next.
    private func keep(_ session: Session) {
        if let cached = cachedSessions[session.id],
           let cachedPath = cached.jsonlPath, cachedPath != session.jsonlPath,
           cached.modifiedTime >= session.modifiedTime,
           FileManager.default.fileExists(atPath: cachedPath) {
            return
        }
        cachedSessions[session.id] = session
    }

    public func discoverSessions() async throws -> [Session] {
        let fileManager = FileManager.default
        var seenDirs: Set<String> = []

        for claudeDir in projectsDirectories() {
            guard let projectDirs = try? fileManager.contentsOfDirectory(atPath: claudeDir) else { continue }

            for dirName in projectDirs {
                let dirPath = (claudeDir as NSString).appendingPathComponent(dirName)
                var isDir: ObjCBool = false
                guard fileManager.fileExists(atPath: dirPath, isDirectory: &isDir), isDir.boolValue else {
                    continue
                }
                seenDirs.insert(dirPath)

                // Check directory mtime — skip entirely if unchanged
                let dirAttrs = try? fileManager.attributesOfItem(atPath: dirPath)
                let dirMtime = dirAttrs?[.modificationDate] as? Date
                if let cached = dirMtimes[dirPath], dirMtime == cached {
                    continue // No files added/removed in this directory
                }
                dirMtimes[dirPath] = dirMtime

                // Directory changed — re-scan it
                var dirSessions: Set<String> = []
                var skipped = dirSkippedIds[dirPath] ?? []
                let mayBeExcluded = headlessExclusion.mayMatchClaudeProjectDir(dirName)

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
                    if skipped.contains(sessionId) {
                        dirSessions.insert(sessionId)
                        continue
                    }
                    dirSessions.insert(sessionId)

                    guard let attrs = try? fileManager.attributesOfItem(atPath: filePath),
                          let mtime = attrs[.modificationDate] as? Date else {
                        continue
                    }

                    // Skip if file mtime unchanged and we have a cached session
                    if let cachedMtime = fileMtimes[filePath],
                       mtime == cachedMtime,
                       cachedSessions[sessionId] != nil {
                        // Still merge index data in case index was updated,
                        // from this folder's index for this folder's copy.
                        if let entry = indexById[sessionId], var session = cachedSessions[sessionId],
                           session.jsonlPath.map({ ($0 as NSString).deletingLastPathComponent }) == dirPath {
                            if session.name == nil { session.name = entry.summary }
                            if session.projectPath == nil { session.projectPath = entry.projectPath }
                            cachedSessions[sessionId] = session
                        }
                        continue
                    }
                    if mayBeExcluded, cachedSessions[sessionId] == nil,
                       let launch = try? await JsonlParser.extractLaunchContext(from: filePath),
                       launch.entrypoint == Session.headlessEntrypoint,
                       headlessExclusion.matches(indexById[sessionId]?.projectPath
                           ?? launch.cwd ?? JsonlParser.decodeDirectoryName(dirName)) {
                        skipped.insert(sessionId)
                        fileMtimes.removeValue(forKey: filePath)
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

                        if isExcludedHeadless(session) {
                            skipped.insert(sessionId)
                            // Only this transcript's entry: another folder
                            // may hold the same id.
                            if cachedSessions[sessionId]?.jsonlPath == filePath {
                                cachedSessions.removeValue(forKey: sessionId)
                            }
                            fileMtimes.removeValue(forKey: filePath)
                            continue
                        }
                        keep(session)
                    } else if let entry = indexEntry {
                        // File couldn't parse but we have index data
                        if var session = cachedSessions[sessionId] ?? Session(id: sessionId) as Session? {
                            session.name = session.name ?? entry.summary
                            session.projectPath = session.projectPath ?? entry.projectPath
                            session.jsonlPath = filePath
                            session.modifiedTime = mtime
                            keep(session)
                        }
                    }
                }

                // Evict sessions from this dir that no longer exist
                if let oldIds = dirSessionIds[dirPath] {
                    for removedId in oldIds.subtracting(dirSessions) {
                        evict(removedId, ifStoredIn: dirPath)
                    }
                }
                dirSessionIds[dirPath] = dirSessions
                skipped.formIntersection(dirSessions)
                dirSkippedIds[dirPath] = skipped.isEmpty ? nil : skipped
            }
        }

        // Evict entire directories that were removed, also those of a
        // config folder that is gone or no longer configured.
        for removedDir in Set(dirMtimes.keys).union(dirSessionIds.keys).subtracting(seenDirs) {
            dirMtimes.removeValue(forKey: removedDir)
            dirSkippedIds.removeValue(forKey: removedDir)
            if let ids = dirSessionIds.removeValue(forKey: removedDir) {
                for id in ids { evict(id, ifStoredIn: removedDir) }
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
