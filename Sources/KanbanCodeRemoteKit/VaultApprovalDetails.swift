import Foundation

/// Everything the human may want to see before approving a vault request.
/// The notification carries only the headline and the agent's reason; the
/// detail sheet on the Mac and the phone shows the rest.
public struct VaultApprovalDetails: Codable, Sendable, Equatable, Hashable {
    public enum Action: String, Codable, Sendable {
        /// Secrets for a command (`kv run`, `kv env`, `kv get`, a hook).
        case use
        /// Short-lived AWS credentials (`kv aws`).
        case aws
        /// A lease for the card's whole task (`kv request`).
        case lease
        /// Replacing a stored value.
        case replace
        /// Changing a secret's tier, rules, tags, label, lease time or role.
        case edit
        case delete
        /// Changing which keys open the owner-only secrets.
        case ownerKeys
    }

    /// Who is asking.
    public enum Origin: String, Codable, Sendable {
        case card
        case openClaw
        /// A process the master did not find in any card session.
        case outside
    }

    public struct Secret: Codable, Sendable, Equatable, Hashable {
        public var name: String
        /// Human label, e.g. "Slack user token".
        public var label: String
        /// The tier as the human reads it, e.g. "Judged by Jev".
        public var tier: String
        public var everyUseAsks: Bool

        public init(name: String, label: String, tier: String, everyUseAsks: Bool = false) {
            self.name = name
            self.label = label
            self.tier = tier
            self.everyUseAsks = everyUseAsks
        }
    }

    public var action: Action
    public var origin: Origin
    /// Card title or OpenClaw agent name, when known.
    public var principal: String?
    public var secrets: [Secret]
    /// The `kv` mode: run, env, get, hook, aws.
    public var mode: String?
    /// What an edit changes, e.g. ["rules", "tier"].
    public var changes: [String]
    /// The proposed values of an edit, one line each, e.g. "Tier: Always ask".
    public var changeLines: [String]
    /// Why the vault asks a human instead of deciding alone.
    public var whys: [String]
    public var command: String?
    public var cwd: String?
    /// The agent's reason, as it wrote it.
    public var reason: String?
    /// How long an "Approve for this card" lease lasts, when offered.
    public var leaseSeconds: Double?
    /// The card the client claimed when the master could not verify it.
    public var claimedCardId: String?
    /// A device over the tailnet, for requests not on loopback.
    public var remoteDevice: String?
    /// Executable names from the caller up.
    public var ancestry: [String]
    /// For a card that runs on another machine: how its command got here,
    /// e.g. "via ssh from Studio".
    public var cardOrigin: String?

    public init(
        action: Action,
        origin: Origin,
        principal: String? = nil,
        secrets: [Secret],
        mode: String? = nil,
        changes: [String] = [],
        changeLines: [String] = [],
        whys: [String] = [],
        command: String? = nil,
        cwd: String? = nil,
        reason: String? = nil,
        leaseSeconds: Double? = nil,
        claimedCardId: String? = nil,
        remoteDevice: String? = nil,
        ancestry: [String] = [],
        cardOrigin: String? = nil
    ) {
        self.cardOrigin = cardOrigin
        self.action = action
        self.origin = origin
        self.principal = principal
        self.secrets = secrets
        self.mode = mode
        self.changes = changes
        self.changeLines = changeLines
        self.whys = whys
        self.command = command
        self.cwd = cwd
        self.reason = reason
        self.leaseSeconds = leaseSeconds
        self.claimedCardId = claimedCardId
        self.remoteDevice = remoteDevice
        self.ancestry = ancestry
    }

    /// One labelled line of the detail sheet.
    public struct Row: Equatable, Sendable, Hashable {
        public var label: String
        public var value: String
        /// Shown in a monospaced font (commands, paths).
        public var monospaced: Bool

        public init(_ label: String, _ value: String, monospaced: Bool = false) {
            self.label = label
            self.value = value
            self.monospaced = monospaced
        }
    }

    /// The rows of the detail sheet, in the order they are shown.
    public func rows(cardName: String? = nil) -> [Row] {
        var rows: [Row] = []
        switch origin {
        case .card:
            let name = cardName ?? principal ?? "unknown card"
            rows.append(Row("Card", cardOrigin.map { "\(name), \($0)" } ?? name))
        case .openClaw:
            rows.append(Row("OpenClaw agent", principal ?? "unknown agent"))
        case .outside:
            var from = "Not a Kanban card session"
            if let claimedCardId { from += " (claims card \(claimedCardId))" }
            rows.append(Row("From", from))
        }
        rows.append(Row("Reason", AttentionCopy.usableReason(reason) ?? "None given"))
        let secretLines = secrets.map { s in
            let name = s.label == s.name ? s.name : "\(s.label) (\(s.name))"
            return "\(name), \(s.tier)\(s.everyUseAsks ? ", every use asks" : "")"
        }
        rows.append(Row(secrets.count == 1 ? "Secret" : "Secrets", secretLines.joined(separator: "\n")))
        rows.append(Row("Wants to", AttentionCopy.actionPhrase(self)))
        for line in changeLines { rows.append(Row("Change", line)) }
        if !whys.isEmpty { rows.append(Row("Why it asks", whys.joined(separator: "\n"))) }
        if let command, !command.isEmpty { rows.append(Row("Command", command, monospaced: true)) }
        if let cwd, !cwd.isEmpty { rows.append(Row("Directory", cwd, monospaced: true)) }
        if let leaseSeconds { rows.append(Row("Lease", "\(AttentionCopy.duration(leaseSeconds)) if approved for the card")) }
        if let remoteDevice { rows.append(Row("Device", remoteDevice)) }
        if !ancestry.isEmpty { rows.append(Row("Process", ancestry.prefix(8).joined(separator: " < "), monospaced: true)) }
        return rows
    }
}

/// The words of attention notifications: a short headline naming who asks
/// for what, and a body that is only the agent's own reason.
public enum AttentionCopy {
    /// An answer that refuses: "Deny", "No".
    public static func isDenial(_ resolution: String) -> Bool {
        let lower = resolution.lowercased()
        return lower.hasPrefix("deny") || lower.hasPrefix("no")
    }

    // MARK: Notifications

    /// Title and body of a notification for `request`.
    public static func notification(for request: AttentionRequest, cardName rawCardName: String?) -> (title: String, body: String) {
        let cardName = rawCardName.map { shortName($0) }
        switch request.kind {
        case .vaultApproval:
            return (request.title, request.body)
        case .question:
            guard let cardName else { return (request.title, request.body) }
            let header = request.title == "Question" ? "" : request.title
            let body = [header, request.body].filter { !$0.isEmpty }.joined(separator: ": ")
            return ("\(cardName) is asking you a question", body)
        case .planApproval:
            guard let cardName else { return (request.title, request.body) }
            return ("\(cardName) wants you to approve a plan", request.body)
        case .permission:
            // The body opens with one plain line; the command after it is
            // for the detail sheet.
            let summary = firstParagraph(request.body)
            guard let cardName else { return (request.title, summary) }
            return ("\(cardName) needs your permission", summary)
        }
    }

    /// Longest card name a notification title carries.
    public static let cardNameLimit = 40

    /// `name` cut to `limit` characters at a word boundary, with "...": a
    /// card named after its whole first prompt still makes a short title.
    public static func shortName(_ name: String, limit: Int = cardNameLimit) -> String {
        let flat = name.split(whereSeparator: \.isNewline).joined(separator: " ")
            .trimmingCharacters(in: .whitespaces)
        guard flat.count > limit else { return flat }
        let head = flat.prefix(limit)
        let cut = head.lastIndex(of: " ").map { head[..<$0] } ?? head
        return cut.trimmingCharacters(in: .whitespaces.union(.punctuationCharacters)) + "..."
    }

    /// Text up to the first blank line.
    public static func firstParagraph(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let range = trimmed.range(of: "\n\n") else { return trimmed }
        return String(trimmed[..<range.lowerBound])
    }

    /// "Kanban Chat Claude wants AWS lw-dev access".
    public static func vaultHeadline(_ details: VaultApprovalDetails) -> String {
        "\(subject(details)) \(actionPhrase(details))"
    }

    /// The notification body of a vault request: the agent's reason; without
    /// one, the command that asked, so the human still knows what it is for.
    public static func vaultBody(_ details: VaultApprovalDetails) -> String {
        if let reason = usableReason(details.reason) { return reason }
        if let command = details.command.map(shortCommand), !command.isEmpty { return "No reason given. Asked by: \(command)" }
        return "No reason given."
    }

    /// Longest command a notification body carries.
    public static let commandLimit = 140

    /// A command on one line, cut to `commandLimit` characters.
    public static func shortCommand(_ command: String) -> String {
        let flat = command.split(whereSeparator: \.isNewline).joined(separator: " ").trimmingCharacters(in: .whitespaces)
        return flat.count > commandLimit ? String(flat.prefix(commandLimit)) + "..." : flat
    }

    static func subject(_ details: VaultApprovalDetails) -> String {
        switch details.origin {
        case .card: details.principal.map { shortName($0) } ?? "A card"
        case .openClaw: details.principal.map { "OpenClaw agent \(shortName($0))" } ?? "An OpenClaw agent"
        case .outside: "A process outside any card"
        }
    }

    /// "wants to use the Slack user token", "wants AWS lw-dev access for 2 days".
    public static func actionPhrase(_ details: VaultApprovalDetails) -> String {
        let labels = details.secrets.map(\.label)
        let allAws = !details.secrets.isEmpty && details.secrets.allSatisfy { $0.name.hasPrefix("aws:") }
        let things = list(labels.map { "the \($0)" })
        let bare = list(labels)
        switch details.action {
        case .use, .aws:
            return allAws ? "wants \(bare) access" : "wants to use \(things)"
        case .lease:
            let span = details.leaseSeconds.map { " for \(duration($0))" } ?? ""
            return allAws ? "wants \(bare) access\(span)" : "wants to use \(things)\(span)"
        case .replace:
            return "wants to replace \(things)"
        case .delete:
            return "wants to delete \(things)"
        case .ownerKeys:
            return "wants to change the keys that unlock the owner-only secrets"
        case .edit:
            let what = details.changes.isEmpty ? "settings" : list(details.changes)
            if labels.count > 1 { return "wants to change the \(what) of \(things)" }
            return "wants to change \(things) \(what)"
        }
    }

    /// "A", "A and B", "A, B and C", "A, B and 3 more".
    public static func list(_ items: [String]) -> String {
        switch items.count {
        case 0: return ""
        case 1: return items[0]
        case 2, 3: return items.dropLast().joined(separator: ", ") + " and " + items.last!
        default: return items.prefix(2).joined(separator: ", ") + " and \(items.count - 2) more"
        }
    }

    /// "2 days", "1 day", "12 hours", "90 minutes", "30 minutes".
    public static func duration(_ seconds: Double) -> String {
        let minutes = Int((seconds / 60).rounded())
        if minutes < 60 || minutes % 60 != 0 { return minutes == 1 ? "1 minute" : "\(minutes) minutes" }
        let hours = minutes / 60
        if hours < 48 && hours % 24 != 0 { return hours == 1 ? "1 hour" : "\(hours) hours" }
        let days = Int((seconds / 86400).rounded())
        return days == 1 ? "1 day" : "\(days) days"
    }

    // MARK: Secret labels

    private static let words: [String: String] = [
        "AWS": "AWS", "GCP": "GCP", "API": "API", "URL": "URL", "URI": "URI", "ID": "ID", "DB": "DB",
        "SSH": "SSH", "JWT": "JWT", "OAUTH": "OAuth", "HF": "HF", "PAT": "PAT", "SMTP": "SMTP", "S3": "S3",
        "CLI": "CLI", "SDK": "SDK", "NPM": "npm", "PYPI": "PyPI", "OPENAI": "OpenAI", "GITHUB": "GitHub",
        "GITLAB": "GitLab", "LANGWATCH": "LangWatch", "POSTHOG": "PostHog", "OPENROUTER": "OpenRouter",
        "ELEVENLABS": "ElevenLabs", "HUBSPOT": "HubSpot", "SENDGRID": "SendGrid", "LINKEDIN": "LinkedIn",
        "YOUTUBE": "YouTube", "DEEPSEEK": "DeepSeek", "OPENCLAW": "OpenClaw", "MCP": "MCP", "LLM": "LLM",
        "TLS": "TLS", "SSL": "SSL", "DNS": "DNS", "IP": "IP", "SSO": "SSO", "OIDC": "OIDC", "SAML": "SAML",
    ]

    /// A human label for a secret: its own label when set, else one
    /// derived from the name (`aws:lw-dev` is "AWS lw-dev",
    /// `SLACK_USER_TOKEN` is "Slack user token"). A project's secret adds
    /// its project and environment: `shop/dev/OPENAI_API_KEY` is
    /// "OpenAI API key · shop · dev".
    public static func secretLabel(name: String, label: String? = nil) -> String {
        let parsed = VaultSecretName(name)
        if parsed.project != nil {
            return ([secretLabel(name: parsed.key, label: label)] + parsed.scopeParts).joined(separator: " · ")
        }
        if let label = label?.trimmingCharacters(in: .whitespacesAndNewlines), !label.isEmpty { return label }
        if name.hasPrefix("aws:") {
            var parts = name.dropFirst(4).split(separator: ":").map(String.init)
            if parts.count > 1, parts.last == "read" {
                parts.removeLast()
                return "AWS \(parts.joined(separator: ":")) read-only"
            }
            return "AWS \(parts.joined(separator: ":"))"
        }
        let pieces = name.split(whereSeparator: { "_-./:".contains($0) }).map(String.init)
        guard !pieces.isEmpty else { return name }
        let out = pieces.enumerated().map { index, piece -> String in
            if let known = words[piece.uppercased()] { return known }
            // A word already written in mixed case (GitHub) stays as is.
            if piece != piece.uppercased() && piece != piece.lowercased() { return piece }
            let lower = piece.lowercased()
            return index == 0 ? lower.prefix(1).uppercased() + lower.dropFirst() : lower
        }
        return out.joined(separator: " ")
    }

    // MARK: Reasons

    public enum ReasonProblem: String, Sendable, Equatable {
        case missing
        case tooShort
        case looksLikeCommand
        case tooLong
    }

    private static let commandStarts: Set<String> = [
        "sudo", "kv", "aws", "curl", "wget", "npm", "pnpm", "yarn", "npx", "git", "gh", "kubectl", "helm",
        "docker", "terraform", "python", "python3", "node", "bash", "sh", "zsh", "export", "cd", "make",
        "swift", "cargo", "go", "ssh", "scp", "psql", "wrangler", "uv", "pip", "echo", "cat", "env",
    ]

    /// What is wrong with an agent's reason, nil when a human can read it
    /// as one plain sentence.
    public static func reasonProblem(_ reason: String?) -> ReasonProblem? {
        let text = (reason ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty { return .missing }
        if text.contains("\n") || text.count > 200 { return .tooLong }
        let words = text.split(whereSeparator: \.isWhitespace)
        // A command is typed lowercase; a sentence opening with the same word has a capital.
        if let first = words.first, commandStarts.contains(String(first)) { return .looksLikeCommand }
        if text.range(of: #"(^|\s)--?[A-Za-z]"#, options: .regularExpression) != nil { return .looksLikeCommand }
        if text.range(of: #"[|;&`$<>{}]"#, options: .regularExpression) != nil { return .looksLikeCommand }
        if words.count < 4 { return .tooShort }
        return nil
    }

    /// The reason to show the human: itself when readable, nil otherwise.
    public static func usableReason(_ reason: String?) -> String? {
        reasonProblem(reason) == nil ? reason!.trimmingCharacters(in: .whitespacesAndNewlines) : nil
    }

    /// How agents are told to write a reason.
    public static let reasonGuidance =
        "Give --reason as one short plain sentence that Rogerio reads on his phone: what you want to do and why. " +
        "Example: --reason \"Deploy the langwatch staging app to check the fix for the login bug\""
}
