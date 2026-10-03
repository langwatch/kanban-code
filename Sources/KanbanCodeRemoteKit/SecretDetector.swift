import Foundation

/// A credential found in free text: the value itself (for a URL password or a
/// `Bearer` header, only the secret part), where it sits, the rule that found
/// it and the vault name it would be saved under.
public struct DetectedSecret: Sendable, Equatable {
    public let value: String
    public let range: Range<String.Index>
    public let kind: String
    public let suggestedName: String

    public init(value: String, range: Range<String.Index>, kind: String, suggestedName: String) {
        self.value = value
        self.range = range
        self.kind = kind
        self.suggestedName = suggestedName
    }
}

/// A secret a composer offers to save under `name` (editable by the user).
public struct SecretProposal: Sendable, Equatable, Identifiable {
    public var value: String
    public var kind: String
    public var name: String
    public var id: String { value }

    public init(value: String, kind: String, name: String) {
        self.value = value
        self.kind = kind
        self.name = name
    }
}

/// Secret detection for prompts typed or pasted into a composer. The rules are
/// a port of LangWatch's redaction rules (packages/redaction/src/secrets.ts);
/// `find` adds a placeholder filter on top so documentation values
/// (`sk-1234...`, `xxxx`, `<your-key>`, AWS's `...EXAMPLE` key) never ask.
public enum SecretDetector {
    /// Tier a secret pasted into a prompt is saved with.
    public static let pastedTier = "judged"
    /// Rules a secret pasted into a prompt is saved with.
    public static let pastedRules = "Pasted into a chat prompt by Rogerio; use it only for the task that prompt asks for, never print or copy it."

    /// Secrets in `text` worth offering to save, in text order.
    public static func find(in text: String) -> [DetectedSecret] {
        matches(in: text).filter { !isPlaceholder($0.value, kind: $0.kind) }
    }

    /// The rules for keys a vendor mints in a fixed format (`sk-...`,
    /// `ghp_...`, `xoxb-...`): the ones safe to act on with no human looking.
    public static let vendorFormatRuleIds: Set<String> = [
        "github_token", "provider_api_key", "stripe_secret_key", "slack_token", "google_api_key", "vendor_api_key",
    ]

    /// The name a credential gets from its format alone (`OPENAI_API_KEY`,
    /// `GITHUB_TOKEN`), whatever text it was found in.
    public static func vendorName(of secret: DetectedSecret) -> String {
        defaultName(kind: secret.kind, value: secret.value, text: "", valueStart: 0)
    }

    /// Secrets in `text` found by the given rules only, placeholders left out.
    public static func find(in text: String, ruleIds: Set<String>) -> [DetectedSecret] {
        matches(in: text, ruleIds: ruleIds).filter { !isPlaceholder($0.value, kind: $0.kind) }
    }

    /// Every credential the rules recognise, placeholders included.
    public static func matches(in text: String, ruleIds: Set<String>? = nil) -> [DetectedSecret] {
        let ns = text as NSString
        guard ns.length > 0, ns.length <= maxScanLength else { return [] }
        var found: [RawMatch] = []
        for rule in rules {
            if let ruleIds, !ruleIds.contains(rule.id) { continue }
            if let pre = rule.precondition, !pre(text) { continue }
            found.append(contentsOf: rawMatches(of: rule, in: ns))
        }
        // Matches come sorted, so offsets are walked forward once rather than
        // converted from the start of the text for each one.
        let utf16 = text.utf16
        var cursor = utf16.startIndex
        var cursorOffset = 0
        func index(_ offset: Int) -> String.Index {
            cursor = utf16.index(cursor, offsetBy: offset - cursorOffset)
            cursorOffset = offset
            return cursor
        }
        return withoutOverlaps(found).map { m in
            let lower = index(m.value.location)
            let upper = index(NSMaxRange(m.value))
            let value = ns.substring(with: m.value)
            return DetectedSecret(value: value, range: lower..<upper, kind: m.ruleId,
                                  suggestedName: suggestedName(kind: m.ruleId, value: value, text: ns, valueStart: m.value.location))
        }
    }

    /// `text` with each detected secret replaced by `[SECRET]`.
    public static func redact(_ text: String) -> String {
        var out = text
        for secret in matches(in: text).reversed() {
            out.replaceSubrange(secret.range, with: redactionMarker)
        }
        return out
    }

    // MARK: - Composer offer

    /// The secrets a composer offers to save before sending `text`: one per
    /// distinct value, each with a name free against `existingNames` and the
    /// other offers.
    public static func proposals(in text: String, existingNames: Set<String>) -> [SecretProposal] {
        var taken = existingNames
        var seen = Set<String>()
        var out: [SecretProposal] = []
        for secret in find(in: text) where seen.insert(secret.value).inserted {
            let name = uniqueName(secret.suggestedName, existing: taken)
            taken.insert(name)
            out.append(SecretProposal(value: secret.value, kind: secret.kind, name: name))
        }
        return out
    }

    /// What saving a composer's offers came to: the text to send (references
    /// for what was saved), what is still unsaved, and why it stopped.
    public struct SaveResult: Sendable, Equatable {
        public var text: String
        public var remaining: [SecretProposal]
        public var error: String?
    }

    /// Saves each offer through `add` (which returns an error message or nil)
    /// under the typed name, or a free one when that is taken or invalid, so a
    /// stored secret is never replaced. Stops at the first failure.
    public static func save(_ proposals: [SecretProposal], in text: String, existingNames: Set<String>,
                            isolation: isolated (any Actor)? = #isolation,
                            add: (SecretProposal) async -> String?) async -> SaveResult {
        var taken = existingNames
        var saved: [SecretProposal] = []
        for (i, offered) in proposals.enumerated() {
            var proposal = offered
            let typed = proposal.name.trimmingCharacters(in: .whitespaces)
            proposal.name = uniqueName(isValidName(typed) ? typed : "SECRET", existing: taken)
            if let error = await add(proposal) {
                return SaveResult(text: apply(text, saved: saved), remaining: Array(proposals[i...]),
                                  error: "Could not save \(proposal.name): \(error)")
            }
            taken.insert(proposal.name)
            saved.append(proposal)
        }
        return SaveResult(text: apply(text, saved: saved), remaining: [], error: nil)
    }

    /// `text` with each saved proposal swapped for its vault reference.
    public static func apply(_ text: String, saved: [SecretProposal]) -> String {
        saved.reduce(text) { replace($0, value: $1.value, name: $1.name) }
    }

    // MARK: - Names and replacement

    /// `base`, or `base_2`, `base_3`... when taken.
    public static func uniqueName(_ base: String, existing: Set<String>) -> String {
        if !existing.contains(base) { return base }
        var n = 2
        while existing.contains("\(base)_\(n)") { n += 1 }
        return "\(base)_\(n)"
    }

    /// Whether `name` can be a vault secret and environment variable name.
    public static func isValidName(_ name: String) -> Bool {
        name.range(of: #"^[A-Za-z_][A-Za-z0-9_]*$"#, options: .regularExpression) != nil
    }

    /// `text` with every occurrence of the secret replaced by `{{vault:NAME}}`
    /// and a line at the end telling the agent how to use it.
    public static func replace(_ text: String, secret: DetectedSecret, name: String) -> String {
        replace(text, value: secret.value, name: name)
    }

    public static func replace(_ text: String, value: String, name: String) -> String {
        guard !value.isEmpty else { return text }
        let replaced = text.replacingOccurrences(of: value, with: "{{vault:\(name)}}")
        let line = usageLine(name)
        if replaced.contains(line) { return replaced }
        let lastLine = replaced.split(separator: "\n", omittingEmptySubsequences: false).last.map(String.init) ?? ""
        let separator = isUsageLine(lastLine) ? "\n" : "\n\n"
        return replaced + separator + line
    }

    public static func usageLine(_ name: String) -> String {
        "({{vault:\(name)}} is a Kanban vault secret. Use it with `kv run \(name) -- <cmd>`, never print it.)"
    }

    private static func isUsageLine(_ line: String) -> Bool {
        line.hasPrefix("({{vault:") && line.hasSuffix("never print it.)")
    }

    // MARK: - Placeholders

    private static let vendorKinds: Set<String> = [
        "aws_access_key_id", "github_token", "provider_api_key", "stripe_secret_key",
        "slack_token", "google_api_key", "vendor_api_key", "jwt",
    ]

    private static let placeholderWords = [
        "example", "your", "placeholder", "redacted", "dummy", "changeme", "sample", "fake",
        "insert", "replace", "xxxx", "****", "....", "1234567", "abcdefg", "qwerty", "<", ">",
    ]

    /// Documentation and template values: example words, masked runs, one
    /// character repeated, counting sequences, or a vendor prefix on a body
    /// with too little randomness to be minted.
    static func isPlaceholder(_ value: String, kind: String) -> Bool {
        let lower = value.lowercased()
        if placeholderWords.contains(where: { lower.contains($0) }) { return true }
        if longestRepeatRun(value) >= 6 { return true }
        if vendorKinds.contains(kind), shannonEntropyBits(value) < 3.0 { return true }
        return false
    }

    private static func longestRepeatRun(_ value: String) -> Int {
        var longest = 0, run = 0
        var previous: Character?
        for c in value {
            run = (c == previous) ? run + 1 : 1
            previous = c
            longest = max(longest, run)
        }
        return longest
    }

    // MARK: - Suggested names

    /// How far back from a value its name or URL scheme is looked for.
    private static let nameLookback = 200

    private static let assignmentRegex = regex(
        #"^(?:.*[{,(]\s*|\s*)(?:export\s+)?["'`]?([A-Za-z_][A-Za-z0-9_.-]*)["'`]?\s*(?::=|=|:)\s*["'`]?$"#)

    static func suggestedName(kind: String, value: String, text: NSString, valueStart: Int) -> String {
        let window = max(0, valueStart - nameLookback)
        let lineStart = text.rangeOfCharacter(from: .newlines, options: .backwards,
                                              range: NSRange(location: window, length: valueStart - window)).location
        let from = lineStart == NSNotFound ? window : lineStart + 1
        let prefix = text.substring(with: NSRange(location: from, length: valueStart - from))
        let pns = prefix as NSString
        if let m = assignmentRegex.firstMatch(in: prefix, range: NSRange(location: 0, length: pns.length)) {
            let name = pns.substring(with: m.range(at: 1)).uppercased()
            if isValidName(name) { return name }
        }
        return defaultName(kind: kind, value: value, text: text, valueStart: valueStart)
    }

    private static let vendorNames: [(String, String)] = [
        ("sk-lw-", "LANGWATCH_API_KEY"), ("ik-lw-", "LANGWATCH_API_KEY"), ("pat-lw-", "LANGWATCH_API_KEY"),
        ("vk-lw-", "LANGWATCH_API_KEY"), ("gl", "GITLAB_TOKEN"), ("npm_", "NPM_TOKEN"),
        ("GOCSPX-", "GOOGLE_CLIENT_SECRET"), ("mb_", "METABASE_API_KEY"), ("dckr_pat_", "DOCKER_TOKEN"),
        ("shp", "SHOPIFY_ACCESS_TOKEN"), ("SG.", "SENDGRID_API_KEY"), ("hf_", "HF_TOKEN"),
        ("gsk_", "GROQ_API_KEY"), ("pplx-", "PERPLEXITY_API_KEY"), ("nvapi-", "NVIDIA_API_KEY"),
        ("r8_", "REPLICATE_API_TOKEN"), ("xai-", "XAI_API_KEY"), ("ntn_", "NOTION_TOKEN"),
        ("secret_", "NOTION_TOKEN"), ("dop_v1_", "DIGITALOCEAN_TOKEN"), ("figd_", "FIGMA_TOKEN"),
        ("ATATT", "ATLASSIAN_API_TOKEN"), ("sq0", "SQUARE_ACCESS_TOKEN"), ("EAAG", "FACEBOOK_ACCESS_TOKEN"),
        ("key-", "MAILGUN_API_KEY"), ("re_", "RESEND_API_KEY"), ("phx_", "POSTHOG_API_KEY"),
        ("lin_api_", "LINEAR_API_KEY"), ("sl.", "DROPBOX_TOKEN"), ("ya29.", "GOOGLE_OAUTH_TOKEN"),
        ("sbp_", "SUPABASE_ACCESS_TOKEN"), ("sntry", "SENTRY_AUTH_TOKEN"), ("fw_", "FIREWORKS_API_KEY"),
        ("NRAK-", "NEW_RELIC_API_KEY"), ("PMAK-", "POSTMAN_API_KEY"), ("dp.", "DOPPLER_TOKEN"),
        ("pat", "AIRTABLE_TOKEN"),
    ]

    static func defaultName(kind: String, value: String, text: NSString, valueStart: Int) -> String {
        switch kind {
        case "provider_api_key":
            if value.hasPrefix("sk-ant-") { return "ANTHROPIC_API_KEY" }
            if value.hasPrefix("sk-lw-") { return "LANGWATCH_API_KEY" }
            return "OPENAI_API_KEY"
        case "github_token": return "GITHUB_TOKEN"
        case "aws_access_key_id": return "AWS_ACCESS_KEY_ID"
        case "slack_token": return "SLACK_TOKEN"
        case "stripe_secret_key": return "STRIPE_SECRET_KEY"
        case "google_api_key": return "GOOGLE_API_KEY"
        case "jwt": return "JWT"
        case "pem_private_key", "putty_private_key": return "PRIVATE_KEY"
        case "kubeconfig_client_credentials": return "KUBECONFIG_CLIENT_KEY"
        case "bearer_token": return "BEARER_TOKEN"
        case "authorization_scheme_token": return "AUTH_TOKEN"
        case "basic_auth_credentials": return "BASIC_AUTH"
        case "url_credentials":
            let window = max(0, valueStart - nameLookback)
            let before = text.substring(with: NSRange(location: window, length: valueStart - window))
            if let sep = before.range(of: "://", options: .backwards) {
                let scheme = before[..<sep.lowerBound].reversed().prefix { $0.isASCII && ($0.isLetter || $0.isNumber || "+.-".contains($0)) }
                let word = String(scheme.reversed()).prefix { $0.isLetter || $0.isNumber }.uppercased()
                if word.first?.isLetter == true, isValidName(word) { return "\(word)_PASSWORD" }
            }
            return "PASSWORD"
        case "vendor_api_key":
            if value.range(of: #"^[0-9]{8,10}:AA"#, options: .regularExpression) != nil { return "TELEGRAM_BOT_TOKEN" }
            if value.hasPrefix("glc_") || value.hasPrefix("glsa_") { return "GRAFANA_TOKEN" }
            return vendorNames.first { value.hasPrefix($0.0) }?.1 ?? "SECRET"
        default: return "SECRET"
        }
    }

    // MARK: - Rule engine

    static let redactionMarker = "[SECRET]"
    private static let maxScanLength = 250_000

    private struct RawMatch {
        let ruleId: String
        let span: NSRange
        let value: NSRange
    }

    /// Which part of a match is the credential: the whole match (clamped at a
    /// quote or backtick), everything after a context group, or one group.
    private enum ValuePart {
        case clamped
        case after(Int)
        case group(Int)
    }

    private struct Rule {
        let id: String
        let regex: NSRegularExpression
        var value: ValuePart = .clamped
        var accept: ((NSTextCheckingResult, NSString) -> Bool)?
        var precondition: ((String) -> Bool)?
        var precededBy: NSRegularExpression?
    }

    private static func regex(_ pattern: String, _ options: NSRegularExpression.Options = []) -> NSRegularExpression {
        // swiftlint:disable:next force_try
        try! NSRegularExpression(pattern: pattern, options: options)
    }

    private static func group(_ m: NSTextCheckingResult, _ i: Int, _ text: NSString) -> String {
        let r = m.range(at: i)
        return r.location == NSNotFound ? "" : text.substring(with: r)
    }

    private static func rawMatches(of rule: Rule, in text: NSString) -> [RawMatch] {
        var out: [RawMatch] = []
        for m in rule.regex.matches(in: text as String, range: NSRange(location: 0, length: text.length)) {
            if let accept = rule.accept, !accept(m, text) { continue }
            let full = m.range
            let value: NSRange
            let spanEnd: Int
            switch rule.value {
            case .clamped:
                let kept = keptLengthAtBoundary(text.substring(with: full) as NSString)
                if kept == 0 { continue }
                value = NSRange(location: full.location, length: kept)
                spanEnd = full.location + kept
            case .after(let g):
                let r = m.range(at: g)
                let start = r.location + r.length
                value = NSRange(location: start, length: full.location + full.length - start)
                spanEnd = full.location + full.length
            case .group(let g):
                value = m.range(at: g)
                spanEnd = full.location + full.length
            }
            if value.length == 0 { continue }
            var spanStart = full.location
            if let pre = rule.precededBy {
                // The scheme is at most 31 characters, so only that window is read.
                let from = max(0, full.location - 31)
                let before = NSRange(location: from, length: full.location - from)
                if let p = pre.firstMatch(in: text as String, range: before) { spanStart -= p.range.length }
            }
            out.append(RawMatch(ruleId: rule.id, span: NSRange(location: spanStart, length: spanEnd - spanStart), value: value))
        }
        return out
    }

    /// A secret never contains a quote or backtick, so a match stops at the first one.
    private static func keptLengthAtBoundary(_ match: NSString) -> Int {
        let r = match.rangeOfCharacter(from: CharacterSet(charactersIn: "\"'`"))
        return r.location == NSNotFound ? match.length : r.location
    }

    /// Rules overlap by design; the first (most specific) rule keeps the credential.
    private static func withoutOverlaps(_ matches: [RawMatch]) -> [RawMatch] {
        // `kept` stays sorted by start and never overlaps itself, so only the
        // neighbours of the insertion point can overlap a new match.
        var kept: [RawMatch] = []
        for m in matches {
            var lo = 0, hi = kept.count
            while lo < hi {
                let mid = (lo + hi) / 2
                if kept[mid].span.location < m.span.location { lo = mid + 1 } else { hi = mid }
            }
            if lo > 0, NSMaxRange(kept[lo - 1].span) > m.span.location { continue }
            if lo < kept.count, kept[lo].span.location < NSMaxRange(m.span) { continue }
            kept.insert(m, at: lo)
        }
        return kept
    }

    // MARK: - Value tests

    private static let entropySampleLength = 256

    static func shannonEntropyBits(_ value: String) -> Double {
        let units = Array(value.utf16.prefix(entropySampleLength))
        guard !units.isEmpty else { return 0 }
        let sample = String(decoding: units, as: UTF16.self)
        var counts: [Unicode.Scalar: Int] = [:]
        var total = 0
        for scalar in sample.unicodeScalars { counts[scalar, default: 0] += 1; total += 1 }
        var entropy = 0.0
        for count in counts.values {
            let p = Double(count) / Double(total)
            entropy -= p * log2(p)
        }
        return entropy
    }

    private static func charClasses(_ value: String) -> (lower: Int, upper: Int, digit: Int) {
        var lower = 0, upper = 0, digit = 0
        for u in value.utf16 {
            if u >= 97 && u <= 122 { lower += 1 } else if u >= 65 && u <= 90 { upper += 1 } else if u >= 48 && u <= 57 { digit += 1 }
        }
        return (lower, upper, digit)
    }

    private static func test(_ regex: NSRegularExpression, _ value: String) -> Bool {
        regex.firstMatch(in: value, range: NSRange(location: 0, length: (value as NSString).length)) != nil
    }

    private static let shapedMinBody = 26
    private static let shapedMaxBody = 120

    private static func isKeyShapedBody(_ body: String) -> Bool {
        let n = body.utf16.count
        guard n >= shapedMinBody, n <= shapedMaxBody else { return false }
        let c = charClasses(body)
        guard c.lower >= 2, c.upper >= 2, c.digit >= 2 else { return false }
        return shannonEntropyBits(body) >= 3.9
    }

    private static let digestPrefixes: Set<String> = [
        "sha1", "sha224", "sha256", "sha384", "sha512", "sha3", "md4", "md5", "blake2b", "blake2s", "blake3",
        "crc32", "xxh3", "xxh64", "base32", "base58", "base64", "hex", "uuid", "urn", "cid", "etag", "hash",
        "digest", "checksum", "integrity",
    ]
    private static let hexBodyCredentialSegments = ["live", "test", "prod", "sk", "pk", "key", "secret", "token"]
    private static let identifierPrefixes: Set<String> = [
        "commit", "sha", "sha1", "sha256", "md5", "hash", "digest", "trace", "span", "id", "uuid", "rev", "blob",
        "tree", "etag", "checksum",
    ]
    private static let recordIdPrefixes: Set<String> = [
        "project", "provider", "card", "eval", "monitor", "scenario", "ses", "sess", "session", "thread", "conv",
        "langyconv", "span", "trace", "run", "msg", "task", "job", "step", "node", "team", "org", "user", "call",
        "req", "resp", "chatcmpl", "toolu", "asst", "file", "batch", "evt", "acct", "cus", "sub",
    ]
    private static let publicKeyPrefixes: Set<String> = ["phc"]

    private static func isNonCredentialPrefix(_ prefix: String) -> Bool {
        let lower = prefix.lowercased()
        return digestPrefixes.contains(lower) || identifierPrefixes.contains(lower)
            || recordIdPrefixes.contains(lower) || publicKeyPrefixes.contains(lower)
    }

    private static let placeholderValueRegex = regex(
        #"^(?:x+|\*+|\.+|-+|_+|0+|(?:your|my|our|insert|replace|example|sample|dummy|fake|placeholder|changeme|redacted|removed|hidden|none|null|nil|undefined|todo|tbd|fixme)[a-z0-9_\- ]*)$"#,
        .caseInsensitive)
    private static let envReferenceRegex = regex(#"^(?:\$[A-Za-z_][A-Za-z0-9_]*|[A-Z][A-Z0-9]*(?:_[A-Z0-9]+)+)$"#)
    private static let codeExpressionRegex = regex(#"^[A-Za-z_$][\w$]*(?:\.[A-Za-z_$][\w$]*)+$"#)
    private static let pathLikeRegex = regex(#"^[~.]{0,2}/|/[^/\s]*\.[a-z]{1,5}$"#)
    private static let urlRegex = regex(#"^[a-z][a-z0-9+.-]*://"#, .caseInsensitive)
    private static let versionRegex = regex(#"^v?\d+(?:[._-]\d+)+"#)
    private static let hexRegex = regex(#"^[0-9a-f]{32,}$"#, .caseInsensitive)
    private static let base32Regex = regex(#"^[A-Z2-7]{32,}={0,6}$"#)
    private static let strictIntroduction = regex(#"[:=]\s*["'`]?$"#)

    private static func isCredentialValue(_ value: String) -> Bool {
        guard value.utf16.count >= 16 else { return false }
        if test(placeholderValueRegex, value) || test(envReferenceRegex, value) || test(codeExpressionRegex, value)
            || test(pathLikeRegex, value) || test(urlRegex, value) || value.contains(redactionMarker) {
            return false
        }
        return shannonEntropyBits(value) >= 2.9
    }

    private static func isKeyMaterial(_ value: String) -> Bool {
        guard value.utf16.count >= 20, isCredentialValue(value), !test(versionRegex, value),
              shannonEntropyBits(value) >= 3.4 else { return false }
        if test(hexRegex, value) || test(base32Regex, value) { return true }
        let c = charClasses(value)
        return c.digit >= 2 && (c.lower >= 2 || c.upper >= 2)
    }

    private static func isBasicAuthPayload(_ value: String) -> Bool {
        if value.hasSuffix("=") { return true }
        let c = charClasses(value)
        return c.digit > 0 || (c.lower > 0 && c.upper > 0)
    }

    private static let credentialQualifiers = [
        "master", "encryption", "signing", "private", "access", "api", "auth", "secret", "refresh", "session",
        "bearer", "verification", "webhook", "client", "service", "personal", "root", "admin",
    ]

    private static let tokenStart = #"(?<![A-Za-z0-9_-])"#
    private static let tokenEnd = #"(?![A-Za-z0-9_-])"#

    private static let vendorKeyPatterns = [
        #"(?:sk|ik|pat|vk)-lw-[A-Za-z0-9_-]{3,}"#,
        #"gl(?:pat|rt|dt|soat|ptt|cbt|imt|agent|ffct)-[A-Za-z0-9_-]{20,}"#,
        #"npm_[A-Za-z0-9]{36}"#,
        #"GOCSPX-[A-Za-z0-9_-]{20,}"#,
        #"mb_[A-Za-z0-9+/=]{40,}"#,
        #"dckr_pat_[A-Za-z0-9_-]{20,}"#,
        #"shp(?:at|ss|ca|pa)_[0-9a-fA-F]{32}"#,
        #"SG\.[A-Za-z0-9_-]{16,}\.[A-Za-z0-9_-]{16,}"#,
        #"hf_[A-Za-z0-9]{30,}"#,
        #"gsk_[A-Za-z0-9]{40,}"#,
        #"pplx-[A-Za-z0-9]{30,}"#,
        #"nvapi-[A-Za-z0-9_-]{40,}"#,
        #"r8_[A-Za-z0-9]{30,}"#,
        #"xai-[A-Za-z0-9]{40,}"#,
        #"ntn_[A-Za-z0-9]{30,}"#,
        #"secret_[A-Za-z0-9]{40,}"#,
        #"dop_v1_[0-9a-f]{64}"#,
        #"figd_[A-Za-z0-9_-]{30,}"#,
        #"ATATT[A-Za-z0-9_=-]{100,}"#,
        #"sq0(?:atp|csp)-[A-Za-z0-9_-]{20,}"#,
        #"EAAG[A-Za-z0-9]{60,}"#,
        #"key-[0-9a-f]{32}"#,
        #"re_[A-Za-z0-9_-]{20,}"#,
        #"phx_[A-Za-z0-9]{30,}"#,
        #"lin_api_[A-Za-z0-9]{30,}"#,
        #"sl\.[A-Za-z0-9_-]{60,}"#,
        #"ya29\.[A-Za-z0-9_-]{20,}"#,
        #"sbp_[0-9a-f]{40,}"#,
        #"sntry(?:s|u)_[A-Za-z0-9_.-]{30,}"#,
        #"fw_[A-Za-z0-9]{20,}"#,
        #"gl(?:c|sa)_[A-Za-z0-9]{30,}"#,
        #"NRAK-[A-Za-z0-9]{20,}"#,
        #"PMAK-[A-Za-z0-9]{20,}-[A-Za-z0-9]{20,}"#,
        #"dp\.(?:pt|st|ct|sa)\.[A-Za-z0-9_-]{20,}"#,
        #"pat[A-Za-z0-9]{14}\.[0-9a-f]{64}"#,
        #"[0-9]{8,10}:AA[A-Za-z0-9_-]{33}"#,
    ]

    private static var credentialKeyword: String {
        let q = credentialQualifiers.joined(separator: "|")
        return #"(?:x[_.\- ]?)?(?:"#
            + #"(?:\#(q))[_.\- ]?(?:api[_.\- ]?)?key"#
            + #"|(?:\#(q))?[_.\- ]?(?:api[_.\- ]?)?"#
            + #"(?:token|secret|password|passwd|pwd|credentials?|authorization|cookie)"#
            + ")"
    }

    nonisolated(unsafe) private static let rules: [Rule] = [
        Rule(id: "pem_private_key", regex: regex(
            #"-----BEGIN (?:RSA |EC |DSA |OPENSSH |PGP |ENCRYPTED )?PRIVATE KEY(?: BLOCK)?-----[\s\S]*?-----END (?:RSA |EC |DSA |OPENSSH |PGP |ENCRYPTED )?PRIVATE KEY(?: BLOCK)?-----"#)),
        Rule(id: "putty_private_key", regex: regex(#"PuTTY-User-Key-File-\d+:[\s\S]*?(?:\n\s*\n|$)"#)),
        Rule(id: "kubeconfig_client_credentials",
             regex: regex(#"\b(client-(?:key|certificate)-data:\s*)[A-Za-z0-9+/=]{40,}"#), value: .after(1)),
        Rule(id: "aws_access_key_id", regex: regex(#"\b(?:AKIA|ASIA|AGPA|AIDA|AROA|ANPA|ANVA)[0-9A-Z]{16}\b"#)),
        Rule(id: "github_token", regex: regex(#"\b(?:gh[posru]_[A-Za-z0-9]{36,}|github_pat_[A-Za-z0-9_]{60,})\b"#)),
        Rule(id: "provider_api_key", regex: regex(#"\bsk-[A-Za-z0-9_-]{20,}(?![A-Za-z0-9_-])"#)),
        Rule(id: "stripe_secret_key", regex: regex(#"\b[rs]k_(?:live|test)_[A-Za-z0-9]{16,}\b"#)),
        Rule(id: "slack_token", regex: regex(#"\bxox[abposr]-[A-Za-z0-9-]{10,}\b"#)),
        Rule(id: "google_api_key", regex: regex(#"\bAIza[0-9A-Za-z_-]{35}\b"#)),
        Rule(id: "vendor_api_key", regex: regex("\(tokenStart)(?:\(vendorKeyPatterns.joined(separator: "|")))\(tokenEnd)")),
        Rule(id: "jwt", regex: regex(#"\beyJ[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\b"#)),
        Rule(id: "url_credentials",
             regex: regex(#"(?<=[a-z][a-z0-9+.-]{0,30})(://[^\s:@/]+:)([^\s:@/]+)(@)"#, .caseInsensitive),
             value: .group(2),
             precededBy: regex(#"[a-z][a-z0-9+.-]{0,30}$"#, .caseInsensitive)),
        Rule(id: "bearer_token", regex: regex(#"\b(Bearer\s+)[A-Za-z0-9._~+/-]{10,}=*"#, .caseInsensitive), value: .after(1)),
        Rule(id: "authorization_scheme_token",
             regex: regex(#"\b(Authorization:\s*(?:Token|SSWS|GenieKey|Splunk|OAuth)\s+)[A-Za-z0-9._~+/-]{10,}=*"#, .caseInsensitive),
             value: .after(1)),
        Rule(id: "basic_auth_credentials",
             regex: regex(#"\b(Basic\s+)([A-Za-z0-9+/]{16,}={0,2})(?![A-Za-z0-9+/=])"#), value: .after(1),
             accept: { m, t in isBasicAuthPayload(group(m, 2, t)) }),
        Rule(id: "prefixed_hex_api_key",
             regex: regex("\(tokenStart)([A-Za-z][A-Za-z0-9]{1,11})_(?:\(hexBodyCredentialSegments.joined(separator: "|")))_([0-9a-f]{24,128})\(tokenEnd)",
                          .caseInsensitive),
             accept: { m, t in !identifierPrefixes.contains(group(m, 1, t).lowercased()) },
             precondition: { $0.contains("_") }),
        Rule(id: "shaped_api_key",
             regex: regex("\(tokenStart)([A-Za-z][A-Za-z0-9]{1,11})[_-]([A-Za-z0-9_+/-]{\(shapedMinBody),})\(tokenEnd)"),
             accept: { m, t in !isNonCredentialPrefix(group(m, 1, t)) && isKeyShapedBody(group(m, 2, t)) },
             precondition: { $0.contains("_") || $0.contains("-") }),
        Rule(id: "sensitive_assignment",
             regex: regex(#"((?:^|[\W_])(?:\#(credentialKeyword))(?:\s+[A-Za-z]{1,8}){0,2}["'`]?(?:\s*[:=]{1,2}\s*|[ \t?-]+)["'`]?)([^\s"'`,;<>(){}\[\]\\]{16,})"#,
                          .caseInsensitive),
             value: .group(2),
             accept: { m, t in
                 let introduction = group(m, 1, t)
                 let value = group(m, 2, t)
                 return test(strictIntroduction, introduction) ? isCredentialValue(value) : isKeyMaterial(value)
             }),
    ]

    /// Rule ids, in the order they run (most specific first).
    public static var ruleIds: [String] { rules.map(\.id) }
}
