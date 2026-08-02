import Foundation

/// Token/context usage data captured from Claude Code's statusline.
public struct ContextUsage: Sendable, Equatable {
    public let usedPercentage: Double       // 0-100
    public let contextWindowSize: Int       // 200_000 or 1_000_000
    public let totalInputTokens: Int
    public let totalOutputTokens: Int
    public let totalCostUsd: Double?
    public let model: String?

    /// Claude's current context-window usage in tokens.
    ///
    /// `totalInputTokens + totalOutputTokens` is a lifetime-ish statusline
    /// total and can stay high after compaction. The percentage/window pair is
    /// what backs Claude Code's visible context meter, so automation that acts
    /// on "current context" should use this value.
    /// `--model` takes an alias such as `opus`, while the statusline reports a
    /// display name such as "Opus 5 (1M context)". The leading family word is
    /// the alias, which is what launching a card on the same model needs.
    public var modelAlias: String? {
        guard let model else { return nil }
        let words = model.split(whereSeparator: { !$0.isLetter })
        guard let family = words.first(where: { $0.lowercased() != "claude" }) else { return nil }
        return family.lowercased()
    }

    public var currentContextTokens: Int {
        guard contextWindowSize > 0, usedPercentage > 0 else {
            return totalInputTokens + totalOutputTokens
        }
        return Int((Double(contextWindowSize) * usedPercentage / 100.0).rounded())
    }

    public init(
        usedPercentage: Double,
        contextWindowSize: Int,
        totalInputTokens: Int,
        totalOutputTokens: Int,
        totalCostUsd: Double? = nil,
        model: String? = nil
    ) {
        self.usedPercentage = usedPercentage
        self.contextWindowSize = contextWindowSize
        self.totalInputTokens = totalInputTokens
        self.totalOutputTokens = totalOutputTokens
        self.totalCostUsd = totalCostUsd
        self.model = model
    }
}

/// Reads context usage files written by the statusline script.
/// Files are at ~/.kanban-code/context/<sessionId>.json.
public enum ContextUsageReader {

    private static let basePath: String = {
        (NSHomeDirectory() as NSString).appendingPathComponent(".kanban-code/context")
    }()

    /// Read context usage for a session. Returns nil if no data available.
    public static func read(sessionId: String, basePath: String? = nil) -> ContextUsage? {
        let dir = basePath ?? self.basePath
        let path = (dir as NSString).appendingPathComponent("\(sessionId).json")

        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }

        guard let usedPct = obj["usedPercentage"] as? Double,
              let ctxSize = obj["contextWindowSize"] as? Int,
              let inputTokens = obj["totalInputTokens"] as? Int,
              let outputTokens = obj["totalOutputTokens"] as? Int else {
            return nil
        }

        return ContextUsage(
            usedPercentage: usedPct,
            contextWindowSize: ctxSize,
            totalInputTokens: inputTokens,
            totalOutputTokens: outputTokens,
            totalCostUsd: obj["totalCostUsd"] as? Double,
            model: obj["model"] as? String
        )
    }
}
