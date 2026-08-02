import Foundation

/// How a threshold message reaches the agent. The three modes are the same
/// delivery semantics the CLI exposes through `kanban send --mode`.
public enum SelfCompactAction: String, Codable, Sendable, CaseIterable {
    case queuePrompt
    case steer
    case interrupt

    public var displayName: String {
        switch self {
        case .queuePrompt: "Queue prompt"
        case .steer: "Steer"
        case .interrupt: "Interrupt"
        }
    }

    public var detail: String {
        switch self {
        case .queuePrompt: "Waits in the card's queue and is sent once the agent goes idle."
        case .steer: "Pasted into the session right away. The agent reads it between turns."
        case .interrupt: "Stops the agent with Escape first, then sends the message."
        }
    }

    /// Settings saved before steering and interrupting were separate modes spell
    /// the steering action `compactNow`.
    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        if raw == "compactNow" {
            self = .steer
            return
        }
        guard let action = SelfCompactAction(rawValue: raw) else {
            throw DecodingError.dataCorruptedError(
                in: try decoder.singleValueContainer(),
                debugDescription: "Unknown self-compact action \"\(raw)\""
            )
        }
        self = action
    }
}

public struct SelfCompactRule: Identifiable, Codable, Sendable, Equatable {
    public var id: String
    public var thresholdTokens: Int
    public var action: SelfCompactAction
    public var message: String

    public init(
        id: String,
        thresholdTokens: Int,
        action: SelfCompactAction,
        message: String
    ) {
        self.id = id
        self.thresholdTokens = thresholdTokens
        self.action = action
        self.message = message
    }

    public static let defaults: [SelfCompactRule] = [
        SelfCompactRule(
            id: "ctx-500k",
            thresholdTokens: 500_000,
            action: .queuePrompt,
            message: "You are above the 500k context limit. Whenever it is convenient, use the kanban CLI to send yourself a self-compact."
        ),
        SelfCompactRule(
            id: "ctx-600k",
            thresholdTokens: 600_000,
            action: .queuePrompt,
            message: "You are above the 600k context limit. Please compact yourself soon using the kanban CLI self-compact command."
        ),
        SelfCompactRule(
            id: "ctx-700k",
            thresholdTokens: 700_000,
            action: .steer,
            message: "You are above the 700k context limit. Compact yourself IMMEDIATELY using the kanban CLI self-compact command."
        ),
        SelfCompactRule(
            id: "ctx-750k",
            thresholdTokens: 750_000,
            action: .interrupt,
            message: "/compact"
        ),
    ]
}

public struct SelfCompactSettings: Codable, Sendable, Equatable {
    public var enabled: Bool
    public var pollIntervalSeconds: Int
    public var rules: [SelfCompactRule]

    public init(
        enabled: Bool = false,
        pollIntervalSeconds: Int = 30,
        rules: [SelfCompactRule] = SelfCompactRule.defaults
    ) {
        self.enabled = enabled
        self.pollIntervalSeconds = pollIntervalSeconds
        self.rules = rules
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? false
        pollIntervalSeconds = try c.decodeIfPresent(Int.self, forKey: .pollIntervalSeconds) ?? 30
        let decodedRules = (try? c.decodeIfPresent([SelfCompactRule].self, forKey: .rules)) ?? SelfCompactRule.defaults
        rules = decodedRules.isEmpty ? SelfCompactRule.defaults : decodedRules
    }

    private enum CodingKeys: String, CodingKey {
        case enabled, pollIntervalSeconds, rules
    }
}

public enum SelfCompactPolicy {
    public static let steerOffsetTokens = 100_000
    public static let forcedCompactOffsetTokens = 200_000
    public static let cardThresholdOptions = Array(stride(from: 200_000, through: 750_000, by: 50_000))

    public static func rules(
        cardThresholdTokens: Int?,
        globalSettings: SelfCompactSettings
    ) -> [SelfCompactRule] {
        if let threshold = cardThresholdTokens, threshold > 0 {
            return cardRules(thresholdTokens: threshold)
        }
        guard globalSettings.enabled else { return [] }
        return globalSettings.rules
            .filter { $0.thresholdTokens > 0 }
            .sorted { $0.thresholdTokens < $1.thresholdTokens }
    }

    public static func cardRules(thresholdTokens: Int) -> [SelfCompactRule] {
        guard thresholdTokens > 0,
              thresholdTokens <= Int.max - forcedCompactOffsetTokens
        else { return [] }

        // Same escalation as the global defaults: ask while the agent can choose
        // its own moment, steer once it is overdue, interrupt when it is not
        // stopping on its own.
        let label = tokenLabel(thresholdTokens)
        let steerThreshold = thresholdTokens + steerOffsetTokens
        return [
            SelfCompactRule(
                id: "card-ctx-\(thresholdTokens)-nudge",
                thresholdTokens: thresholdTokens,
                action: .queuePrompt,
                message: "You are above the \(label) context limit. Whenever it is convenient, use the kanban CLI to send yourself a self-compact, passing an argument for the post-compact message on how to continue."
            ),
            SelfCompactRule(
                id: "card-ctx-\(steerThreshold)-steer",
                thresholdTokens: steerThreshold,
                action: .steer,
                message: "You are above the \(tokenLabel(steerThreshold)) context limit. Compact yourself now with the kanban CLI self-compact command, passing an argument for the post-compact message on how to continue."
            ),
            SelfCompactRule(
                id: "card-ctx-\(thresholdTokens + forcedCompactOffsetTokens)-force",
                thresholdTokens: thresholdTokens + forcedCompactOffsetTokens,
                action: .interrupt,
                message: "/compact"
            ),
        ]
    }

    /// An empty message on a steer or interrupt rule still has to say something,
    /// and the only useful thing to say at a context threshold is `/compact`.
    public static func command(for rule: SelfCompactRule) -> String {
        let trimmed = rule.message.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "/compact" : rule.message
    }

    public static func tokenLabel(_ tokens: Int) -> String {
        if tokens.isMultiple(of: 1_000) {
            return "\(tokens / 1_000)k"
        }
        return "\(tokens)"
    }

    public static func signature(for rules: [SelfCompactRule]) -> String {
        rules.map { "\($0.thresholdTokens):\($0.action.rawValue):\($0.message)" }.joined(separator: "|")
    }
}
