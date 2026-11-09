import Foundation

/// Reads sessions-index.json files from Claude's project directories.
public enum SessionIndexReader {

    /// An entry from sessions-index.json.
    public struct IndexEntry: Sendable {
        public let sessionId: String
        public let summary: String?
        public let projectPath: String
        public let directoryName: String
    }

    /// Update the summary for a session in its sessions-index.json.
    /// Best-effort: finds the index file containing this session and updates the summary field.
    /// With no `claudeDir`, looks in the projects folder of every Claude
    /// config folder.
    public static func updateSummary(
        sessionId: String, summary: String, claudeDir: String? = nil,
        layout: ClaudeConfigLayout = ClaudeConfigDirectories.current
    ) throws {
        for baseDir in claudeDir.map({ [$0] }) ?? layout.projectsDirectories {
            // A folder that cannot be read does not stop the others.
            if claudeDir != nil {
                if try updateSummary(sessionId: sessionId, summary: summary, in: baseDir) { return }
            } else if (try? updateSummary(sessionId: sessionId, summary: summary, in: baseDir)) == true {
                return
            }
        }
    }

    /// True once the session's entry was found and updated.
    private static func updateSummary(sessionId: String, summary: String, in baseDir: String) throws -> Bool {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: baseDir) else { return false }

        let projectDirs = try fileManager.contentsOfDirectory(atPath: baseDir)
        for dirName in projectDirs {
            let dirPath = (baseDir as NSString).appendingPathComponent(dirName)
            let indexPath = (dirPath as NSString).appendingPathComponent("sessions-index.json")
            guard fileManager.fileExists(atPath: indexPath) else { continue }

            let data = try Data(contentsOf: URL(fileURLWithPath: indexPath))
            guard var root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                continue
            }

            // Format: { "version": 1, "entries": [ { "sessionId": "...", "summary": "...", ... } ] }
            if var entries = root["entries"] as? [[String: Any]] {
                guard let idx = entries.firstIndex(where: { $0["sessionId"] as? String == sessionId }) else {
                    continue
                }
                entries[idx]["summary"] = summary
                root["entries"] = entries

                let updatedData = try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys])
                try updatedData.write(to: URL(fileURLWithPath: indexPath))
                return true // Found and updated
            }
        }
        return false
    }

    /// Read all index entries from a sessions-index.json file.
    public static func readIndex(at path: String, directoryName: String) throws -> [IndexEntry] {
        guard FileManager.default.fileExists(atPath: path) else { return [] }

        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return []
        }

        let projectPath = JsonlParser.decodeDirectoryName(directoryName)
        var entries: [IndexEntry] = []

        // sessions-index.json has various formats; handle the common ones
        // Format 1: { "sessions": [ { "sessionId": "...", "summary": "..." } ] }
        if let sessions = root["sessions"] as? [[String: Any]] {
            for session in sessions {
                guard let sessionId = session["sessionId"] as? String else { continue }
                let summary = session["summary"] as? String
                entries.append(IndexEntry(
                    sessionId: sessionId,
                    summary: summary,
                    projectPath: projectPath,
                    directoryName: directoryName
                ))
            }
        }

        // Format 2: top-level keys are session IDs
        // { "uuid-1": { "summary": "..." }, "uuid-2": { ... } }
        if entries.isEmpty {
            for (key, value) in root {
                // Skip non-UUID-looking keys
                guard key.count >= 32, key.contains("-") else { continue }
                let summary: String?
                if let dict = value as? [String: Any] {
                    summary = dict["summary"] as? String
                } else {
                    summary = nil
                }
                entries.append(IndexEntry(
                    sessionId: key,
                    summary: summary,
                    projectPath: projectPath,
                    directoryName: directoryName
                ))
            }
        }

        return entries
    }
}
