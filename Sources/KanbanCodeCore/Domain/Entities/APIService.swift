import Foundation

/// A named API service configuration that wraps a coding assistant CLI with a launcher prefix,
/// model override, and optional base URL for third-party backends like Ollama.
///
/// Commands produced with a service:
///   `[launcherPrefix] [cliCommand] [--model modelFlag] -- [assistant-flags]`
///
/// Example (Ollama):
///   `ollama launch claude --model qwen3-coder-next:cloud -- --dangerously-skip-permissions`
public struct APIService: Identifiable, Codable, Sendable, Equatable {
    public var id: String
    public var name: String
    public var assistant: CodingAssistant
    /// Shell command prepended before the assistant CLI, e.g. `"ollama launch"`.
    /// `nil` means call the assistant CLI directly.
    public var launcherPrefix: String?
    /// Value passed to `--model`, e.g. `"qwen3-coder-next:cloud"`. `nil` omits the flag.
    public var modelFlag: String?
    /// Optional base URL injected as an environment variable (e.g. `ANTHROPIC_BASE_URL`).
    public var baseURL: String?

    public init(
        id: String = UUID().uuidString,
        name: String,
        assistant: CodingAssistant,
        launcherPrefix: String? = nil,
        modelFlag: String? = nil,
        baseURL: String? = nil
    ) {
        self.id = id
        self.name = name
        self.assistant = assistant
        self.launcherPrefix = launcherPrefix
        self.modelFlag = modelFlag
        self.baseURL = baseURL
    }

    /// Whether a `--` separator is required before assistant-specific flags.
    public var needsSeparator: Bool { launcherPrefix != nil || modelFlag != nil }
}
