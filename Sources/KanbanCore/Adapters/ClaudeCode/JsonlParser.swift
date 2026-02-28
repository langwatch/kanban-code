import Foundation

/// Parses Claude Code .jsonl files line-by-line using streaming.
/// Handles arbitrarily large lines (57KB+).
public enum JsonlParser {

    /// Metadata extracted from a session .jsonl file.
    public struct SessionMetadata: Sendable {
        public let sessionId: String
        public var firstPrompt: String?
        public var projectPath: String?
        public var gitBranch: String?
        public var messageCount: Int

        public init(
            sessionId: String,
            firstPrompt: String? = nil,
            projectPath: String? = nil,
            gitBranch: String? = nil,
            messageCount: Int = 0
        ) {
            self.sessionId = sessionId
            self.firstPrompt = firstPrompt
            self.projectPath = projectPath
            self.gitBranch = gitBranch
            self.messageCount = messageCount
        }
    }

    /// Extract session metadata by streaming through the .jsonl file.
    /// Stops early once the first user message is found (for efficiency).
    public static func extractMetadata(from filePath: String) async throws -> SessionMetadata? {
        let sessionId = (filePath as NSString).lastPathComponent.replacingOccurrences(of: ".jsonl", with: "")

        guard FileManager.default.fileExists(atPath: filePath) else { return nil }

        let url = URL(fileURLWithPath: filePath)
        var metadata = SessionMetadata(sessionId: sessionId)
        var foundFirstUserMessage = false

        // Stream line-by-line using FileHandle + AsyncBytes
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }

        for try await line in handle.bytes.lines {
            guard !line.isEmpty else { continue }

            // Quick pre-filter before JSON parsing
            guard line.contains("\"type\"") else { continue }

            guard let data = line.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                continue
            }

            guard let type = obj["type"] as? String else { continue }

            // Extract project path from cwd
            if metadata.projectPath == nil, let cwd = obj["cwd"] as? String {
                metadata.projectPath = cwd
            }

            if type == "user" || type == "assistant" {
                metadata.messageCount += 1
            }

            // Extract first user message
            if type == "user" && !foundFirstUserMessage {
                foundFirstUserMessage = true
                metadata.firstPrompt = extractTextContent(from: obj)
            }

            // Stop early — we only need first prompt + enough messages to confirm non-empty
            if metadata.messageCount >= 5 && foundFirstUserMessage {
                break
            }
        }

        guard metadata.messageCount > 0 else { return nil }
        return metadata
    }

    /// Extract text content from a message object.
    static func extractTextContent(from obj: [String: Any]) -> String? {
        guard let message = obj["message"] as? [String: Any],
              let content = message["content"] else {
            return nil
        }

        // Content can be a string or an array of content blocks
        if let text = content as? String {
            return text
        }

        if let blocks = content as? [[String: Any]] {
            let texts = blocks.compactMap { block -> String? in
                guard block["type"] as? String == "text" else { return nil }
                return block["text"] as? String
            }
            let joined = texts.joined(separator: "\n")
            return joined.isEmpty ? nil : joined
        }

        return nil
    }

    /// Decode a Claude projects directory name to a filesystem path.
    /// e.g., "-Users-rchaves-Projects-remote-langwatch" → "/Users/rchaves/Projects/remote/langwatch"
    public static func decodeDirectoryName(_ name: String) -> String {
        // Replace leading dash with /, then remaining dashes that are path separators
        // The pattern is: dashes are used as path separators
        var result = name
        if result.hasPrefix("-") {
            result = "/" + String(result.dropFirst())
        }
        // Replace dashes that are path separators (between path components)
        // Heuristic: a dash followed by an uppercase letter is a path separator
        // Actually, Claude uses dashes for ALL path separators
        result = result.replacingOccurrences(of: "-", with: "/")
        return result
    }
}
