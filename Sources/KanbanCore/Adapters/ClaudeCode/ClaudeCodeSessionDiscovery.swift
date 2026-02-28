import Foundation

/// Discovers Claude Code sessions by scanning ~/.claude/projects/.
/// Merges sessions-index.json metadata with .jsonl file scanning.
public final class ClaudeCodeSessionDiscovery: SessionDiscovery, @unchecked Sendable {
    private let claudeDir: String
    private var lastScanTime: Date?

    public init(claudeDir: String? = nil) {
        self.claudeDir = claudeDir
            ?? (NSHomeDirectory() as NSString).appendingPathComponent(".claude/projects")
    }

    public func discoverSessions() async throws -> [Session] {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: claudeDir) else { return [] }

        let projectDirs = try fileManager.contentsOfDirectory(atPath: claudeDir)
        var sessionsById: [String: Session] = [:]

        for dirName in projectDirs {
            let dirPath = (claudeDir as NSString).appendingPathComponent(dirName)
            var isDir: ObjCBool = false
            guard fileManager.fileExists(atPath: dirPath, isDirectory: &isDir), isDir.boolValue else {
                continue
            }

            // Read index file for summaries
            let indexPath = (dirPath as NSString).appendingPathComponent("sessions-index.json")
            let indexEntries = (try? SessionIndexReader.readIndex(at: indexPath, directoryName: dirName)) ?? []

            for entry in indexEntries {
                if sessionsById[entry.sessionId] == nil {
                    sessionsById[entry.sessionId] = Session(
                        id: entry.sessionId,
                        name: entry.summary,
                        projectPath: entry.projectPath
                    )
                }
            }

            // Scan .jsonl files directly
            let contents = (try? fileManager.contentsOfDirectory(atPath: dirPath)) ?? []
            let jsonlFiles = contents.filter { $0.hasSuffix(".jsonl") }

            for jsonlFile in jsonlFiles {
                let filePath = (dirPath as NSString).appendingPathComponent(jsonlFile)
                let sessionId = jsonlFile.replacingOccurrences(of: ".jsonl", with: "")

                // Get file modification time
                guard let attrs = try? fileManager.attributesOfItem(atPath: filePath),
                      let mtime = attrs[.modificationDate] as? Date else {
                    continue
                }

                // Parse .jsonl for metadata
                if let metadata = try? await JsonlParser.extractMetadata(from: filePath) {
                    var session = sessionsById[sessionId] ?? Session(id: sessionId)
                    session.jsonlPath = filePath
                    session.modifiedTime = mtime
                    session.messageCount = metadata.messageCount

                    // .jsonl data fills in blanks, doesn't overwrite index data
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

                    sessionsById[sessionId] = session
                } else {
                    // File exists but couldn't parse — still record if we have index data
                    if var session = sessionsById[sessionId] {
                        session.jsonlPath = filePath
                        session.modifiedTime = mtime
                        sessionsById[sessionId] = session
                    }
                }
            }
        }

        // Filter out sessions with zero messages
        let sessions = sessionsById.values
            .filter { $0.messageCount > 0 }
            .sorted { $0.modifiedTime > $1.modifiedTime }

        lastScanTime = Date()
        return Array(sessions)
    }

    public func discoverNewOrModified(since: Date) async throws -> [Session] {
        // For incremental scan, we still scan all directories but skip
        // files older than `since`. Full implementation later — for now, full scan.
        return try await discoverSessions()
    }
}
