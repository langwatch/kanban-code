import Foundation

/// Parses Gemini CLI session JSON files.
///
/// Gemini stores sessions at `~/.gemini/tmp/<project-slug>/chats/session-<timestamp>.json`.
/// Each file is a single JSON object with a `messages` array containing the conversation.
public enum GeminiSessionParser {

    // MARK: - Codable Structs

    /// Top-level session file structure.
    public struct SessionFile: Codable, Sendable {
        public let sessionId: String
        public let projectHash: String?
        public let startTime: String?
        public let lastUpdated: String?
        public let messages: [Message]
        public let summary: String?

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            sessionId = try container.decode(String.self, forKey: .sessionId)
            projectHash = try container.decodeIfPresent(String.self, forKey: .projectHash)
            startTime = try container.decodeIfPresent(String.self, forKey: .startTime)
            lastUpdated = try container.decodeIfPresent(String.self, forKey: .lastUpdated)
            summary = try container.decodeIfPresent(String.self, forKey: .summary)
            // Decode messages individually — if one fails, render it as raw JSON text
            var messagesContainer = try container.nestedUnkeyedContainer(forKey: .messages)
            var parsed: [Message] = []
            while !messagesContainer.isAtEnd {
                if let msg = try? messagesContainer.decode(Message.self) {
                    parsed.append(msg)
                } else {
                    // Re-decode the failing element as raw JSON for display
                    let raw = try messagesContainer.decode(AnyCodable.self)
                    let type = raw.stringValue(forKey: "type") ?? "unknown"
                    let rawText: String
                    if let data = try? JSONEncoder().encode(raw),
                       let str = String(data: data, encoding: .utf8) {
                        rawText = str
                    } else {
                        rawText = "(unparseable message)"
                    }
                    parsed.append(Message(type: type, rawContent: rawText))
                }
            }
            messages = parsed
        }
    }

    /// A single message in the conversation.
    public struct Message: Codable, Sendable {
        public let id: String?
        public let type: String // "user", "gemini", "info", "error"
        public let content: MessageContent
        public let thoughts: [Thought]?
        public let tokens: TokenInfo?
        public let model: String?
        public let toolCalls: [ToolCall]?
        public let timestamp: String?

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            id = try container.decodeIfPresent(String.self, forKey: .id)
            type = try container.decode(String.self, forKey: .type)
            content = try container.decode(MessageContent.self, forKey: .content)
            thoughts = try container.decodeIfPresent([Thought].self, forKey: .thoughts)
            tokens = try container.decodeIfPresent(TokenInfo.self, forKey: .tokens)
            model = try container.decodeIfPresent(String.self, forKey: .model)
            toolCalls = try container.decodeIfPresent([ToolCall].self, forKey: .toolCalls)
            timestamp = try container.decodeIfPresent(String.self, forKey: .timestamp)
        }

        /// Fallback initializer for messages that failed to decode.
        init(type: String, rawContent: String) {
            self.id = nil
            self.type = type
            self.content = .text(rawContent)
            self.thoughts = nil
            self.tokens = nil
            self.model = nil
            self.toolCalls = nil
            self.timestamp = nil
        }
    }

    /// User content is `[{"text": "..."}]`, gemini/info/error content is a plain string.
    /// This enum handles both representations.
    public enum MessageContent: Codable, Sendable {
        case text(String)
        case parts([ContentPart])

        public init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            if let text = try? container.decode(String.self) {
                self = .text(text)
            } else if let parts = try? container.decode([ContentPart].self) {
                self = .parts(parts)
            } else {
                self = .text("")
            }
        }

        public func encode(to encoder: Encoder) throws {
            var container = encoder.singleValueContainer()
            switch self {
            case .text(let str):
                try container.encode(str)
            case .parts(let parts):
                try container.encode(parts)
            }
        }

        /// Extract the combined text from this content, regardless of format.
        public var textValue: String {
            switch self {
            case .text(let str):
                return str
            case .parts(let parts):
                return parts.compactMap(\.text).joined(separator: "\n")
            }
        }
    }

    /// A content part in a user message.
    public struct ContentPart: Codable, Sendable {
        public let text: String?
    }

    /// A thought/reasoning block from the model.
    public struct Thought: Codable, Sendable {
        public let text: String?
    }

    /// Token usage information.
    public struct TokenInfo: Codable, Sendable {
        public let inputTokens: Int?
        public let outputTokens: Int?
        public let totalTokens: Int?
    }

    /// A tool call made by the model.
    public struct ToolCall: Codable, Sendable {
        public let id: String?
        public let name: String?
        public let args: [String: String]?
        public let result: String?
        public let status: String?
        public let timestamp: String?
        public let displayName: String?
        public let description: String?

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            id = try container.decodeIfPresent(String.self, forKey: .id)
            name = try container.decodeIfPresent(String.self, forKey: .name)
            status = try container.decodeIfPresent(String.self, forKey: .status)
            timestamp = try container.decodeIfPresent(String.self, forKey: .timestamp)
            displayName = try container.decodeIfPresent(String.self, forKey: .displayName)
            description = try container.decodeIfPresent(String.self, forKey: .description)
            // args can be [String: String] or other types; decode flexibly
            if let raw = try? container.decodeIfPresent([String: String].self, forKey: .args) {
                args = raw
            } else {
                args = nil
            }
            // result can be a string, an array of functionResponse objects, or absent
            if let str = try? container.decodeIfPresent(String.self, forKey: .result) {
                result = str
            } else if let arr = try? container.decodeIfPresent([[String: AnyCodable]].self, forKey: .result) {
                // Extract output text from functionResponse array
                var outputs: [String] = []
                for item in arr {
                    if let fr = item["functionResponse"],
                       case .dictionary(let frDict) = fr,
                       let response = frDict["response"],
                       case .dictionary(let respDict) = response,
                       let output = respDict["output"],
                       case .string(let text) = output {
                        outputs.append(text)
                    }
                }
                result = outputs.isEmpty ? nil : outputs.joined(separator: "\n")
            } else {
                result = nil
            }
        }
    }

    /// Minimal type-erased Codable for flexible JSON decoding.
    public enum AnyCodable: Codable, Sendable {
        case string(String)
        case int(Int)
        case double(Double)
        case bool(Bool)
        case dictionary([String: AnyCodable])
        case array([AnyCodable])
        case null

        public init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            if let v = try? container.decode(String.self) { self = .string(v) }
            else if let v = try? container.decode(Int.self) { self = .int(v) }
            else if let v = try? container.decode(Double.self) { self = .double(v) }
            else if let v = try? container.decode(Bool.self) { self = .bool(v) }
            else if let v = try? container.decode([String: AnyCodable].self) { self = .dictionary(v) }
            else if let v = try? container.decode([AnyCodable].self) { self = .array(v) }
            else { self = .null }
        }

        public func encode(to encoder: Encoder) throws {
            var container = encoder.singleValueContainer()
            switch self {
            case .string(let v): try container.encode(v)
            case .int(let v): try container.encode(v)
            case .double(let v): try container.encode(v)
            case .bool(let v): try container.encode(v)
            case .dictionary(let v): try container.encode(v)
            case .array(let v): try container.encode(v)
            case .null: try container.encodeNil()
            }
        }

        /// Extract a string value from a dictionary-typed AnyCodable.
        func stringValue(forKey key: String) -> String? {
            guard case .dictionary(let dict) = self,
                  let val = dict[key],
                  case .string(let str) = val else { return nil }
            return str
        }
    }

    // MARK: - Metadata Extraction

    /// Metadata extracted from a Gemini session file.
    public struct SessionMetadata: Sendable {
        public let sessionId: String
        public var messageCount: Int
        public var firstPrompt: String?
        public var summary: String?
        public var projectPath: String?
    }

    /// Parse a session JSON file and extract metadata.
    /// - Parameter filePath: Absolute path to the session JSON file.
    /// - Returns: Extracted metadata, or nil if the file cannot be parsed.
    public static func extractMetadata(from filePath: String) throws -> SessionMetadata? {
        let data = try Data(contentsOf: URL(fileURLWithPath: filePath))
        let decoder = JSONDecoder()
        let session = try decoder.decode(SessionFile.self, from: data)

        let userAndGeminiMessages = session.messages.filter {
            $0.type == "user" || $0.type == "gemini"
        }
        guard !userAndGeminiMessages.isEmpty else { return nil }

        let firstUserMessage = session.messages.first { $0.type == "user" }
        let firstPrompt = firstUserMessage?.content.textValue

        return SessionMetadata(
            sessionId: session.sessionId,
            messageCount: userAndGeminiMessages.count,
            firstPrompt: firstPrompt.flatMap { $0.isEmpty ? nil : String($0.prefix(500)) },
            summary: session.summary,
            projectPath: nil // Resolved externally from projects.json slug mapping
        )
    }

    /// Parse the full session file.
    /// - Parameter filePath: Absolute path to the session JSON file.
    /// - Returns: The parsed session, or nil if the file cannot be parsed.
    public static func parseSession(from filePath: String) throws -> SessionFile? {
        let data = try Data(contentsOf: URL(fileURLWithPath: filePath))
        let decoder = JSONDecoder()
        return try decoder.decode(SessionFile.self, from: data)
    }
}
