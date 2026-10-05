import Testing
import Foundation
@testable import KanbanCodeRemoteKit

/// Port of LangWatch's packages/redaction/src/__tests__/secrets.unit.test.ts.
/// Fixture bodies are assembled at run time so no complete credential-shaped
/// literal exists in this file.
private let BODY = "aB3dEf7gHi2jKlMnOpQrStUvWx0123456789xYzAbCdEfGh"
private let HEX = "a1b2c3d4e5f6a7b8c9d0e1f2a3b4c5d6"

private func body(_ n: Int) -> String { String(BODY.prefix(n)) }
private func rep(_ s: String, _ n: Int) -> String { String(repeating: s, count: n) }
private func pemArmour(_ edge: String, _ label: String) -> String { "\(rep("-", 5))\(edge) \(label)\(rep("-", 5))" }
private func pemBlock(_ label: String, _ body: String) -> String {
    "\(pemArmour("BEGIN", label))\n\(body)\n\(pemArmour("END", label))"
}

private func redact(_ text: String) -> String { SecretDetector.redact(text) }
private func count(_ text: String) -> Int { SecretDetector.matches(in: text).count }

@Suite("secret rules, built-in provider and cloud keys")
struct SecretRuleProviderTests {
    static let cases: [(String, String)] = [
        ("an AWS access key id", "creds AKIAIOSFODNN7EXAMPLE here"),
        ("a GitHub token", "token ghp_\(rep("a", 36)) here"),
        ("an OpenAI project key", "key sk-proj-aB3dEf_gHi-jKlMnOpQrStUvWx0123456789xY here"),
        ("an Anthropic key", "key sk-ant-api03-aB3dEf_gHi-jKlMnOpQrStUvWx0123456789 here"),
        ("a LangWatch key", "key sk-lw-aB3dEf_gHi-jKlMnOpQrStUvWx0123456789 here"),
        ("a Slack token", "xoxb-\(rep("1", 20)) here"),
        ("a Google API key", "AIza\(rep("A", 35)) here"),
        ("a Stripe secret key", "sk_live_\(rep("a", 24)) here"),
        ("a JWT", "eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxMjM0NTY3ODkwIn0.abcDEF123456"),
    ]

    @Test("Each one is found", arguments: cases)
    func found(_ c: (String, String)) {
        #expect(redact(c.1).contains("[SECRET]"), "\(c.0)")
        #expect(count(c.1) >= 1, "\(c.0)")
    }

    @Test("A PEM block is found whole")
    func pem() {
        let text = redact("key:\n\(pemBlock("RSA PRIVATE KEY", "MIIabc\nDEFghi"))\ntail")
        #expect(!text.contains("MIIabc"))
        #expect(text.contains("[SECRET]"))
        #expect(text.contains("tail"))
    }

    @Test("A database URL gives only its password")
    func url() {
        #expect(redact("postgres://app:hunter2@db.internal:5432/app") == "postgres://app:[SECRET]@db.internal:5432/app")
    }

    @Test("Every shape of scheme keeps everything but the password")
    func schemes() {
        let cases: [(String, String)] = [
            ("redis://default:Ab3xY9zQ@cache-01:6379", "redis://default:[SECRET]@cache-01:6379"),
            ("mongodb+srv://admin:p%40ss@cluster0.mongodb.net", "mongodb+srv://admin:[SECRET]@cluster0.mongodb.net"),
            ("git+ssh://git:token123@github.com/langwatch/langwatch.git", "git+ssh://git:[SECRET]@github.com/langwatch/langwatch.git"),
            ("jdbc:postgresql://svc:9f8e7d6c@10.0.0.4:5432/app", "jdbc:postgresql://svc:[SECRET]@10.0.0.4:5432/app"),
            ("HTTPS://USER:PASS@EXAMPLE.COM", "HTTPS://USER:[SECRET]@EXAMPLE.COM"),
        ]
        for (input, expected) in cases { #expect(redact(input) == expected) }
    }

    @Test("Text that only looks like a connection URL is left alone")
    func notURL() {
        for input in [
            "://user:password@host",
            "no scheme here: user:password@host",
            "See https://app.langwatch.ai/api/trace/abc123?include=spans",
            "mail someone@example.com and read @langwatch/redaction",
        ] { #expect(redact(input) == input) }
    }

    @Test("A bearer header gives only the token")
    func bearer() {
        #expect(redact("Authorization: Bearer abc123token456xyz") == "Authorization: Bearer [SECRET]")
    }

    @Test("Ordinary text is left alone")
    func ordinary() {
        let input = "The model answered in 42 ms and the user said thanks."
        #expect(redact(input) == input)
        #expect(count(input) == 0)
        #expect(redact("please ask the desk about the task") == "please ask the desk about the task")
    }

    @Test("A modern base64url provider key is found whole")
    func base64url() {
        let key = "sk-proj-aB3dEf_gHi-jKlMnOpQrStUvWx0123456789xYaB-cD_eF"
        #expect(redact("here is my key \(key) thanks") == "here is my key [SECRET] thanks")
    }
}

@Suite("secret rules, beyond the known-vendor list")
struct SecretRuleVendorTests {
    @Test("A key from a vendor with no built-in rule is found on shape alone")
    func unknownVendor() {
        let prompt = "I had to kill the other exploring agent, key now: zyq_8fK2mQ7pXvL4nR9sT1wZ3yB6cD0eG5hJ2kM4pQ7rS9t"
        #expect(redact(prompt) == "I had to kill the other exploring agent, key now: [SECRET]")
        #expect(count(prompt) == 1)
        #expect(redact("zyq_8fK2mQ7pXvL4nR9sT1wZ3yB6cD0eG5hJ2kM4pQ7rS9t") == "[SECRET]")
    }

    static let vendorKeys: [(String, String)] = [
        ("GitLab", "GITLAB_TOKEN=glpat-\(body(21))"),
        ("npm", "npm_\(body(36))"),
        ("Docker Hub", "dckr_pat_\(body(28))"),
        ("Shopify", "shpat_\(HEX)"),
        ("SendGrid", "SG.\(body(22)).\(body(43))"),
        ("Hugging Face", "hf_\(body(34))"),
        ("Groq", "gsk_\(body(47))"),
        ("Perplexity", "pplx-\(body(40))"),
        ("Replicate", "r8_\(body(37))"),
        ("xAI", "xai-\(body(47))"),
        ("Notion", "ntn_\(body(40))"),
        ("DigitalOcean", "dop_v1_\(HEX)\(HEX)"),
        ("Figma", "figd_\(body(36))"),
        ("Square", "sq0atp-\(body(22))"),
        ("Mailgun", "key-\(HEX)"),
        ("Resend", "re_\(body(24))"),
        ("PostHog", "phx_\(body(36))"),
        ("Linear", "lin_api_\(body(40))"),
        ("Google OAuth", "ya29.\(body(28))"),
        ("Supabase", "sbp_\(HEX)\(HEX.prefix(8))"),
        ("Telegram", "123456789:AA\(body(33))"),
        ("Airtable", "pat\(body(14)).\(HEX)\(HEX)"),
    ]

    @Test("Widely used vendor credentials are found", arguments: vendorKeys)
    func vendors(_ c: (String, String)) {
        #expect(count(c.1) > 0, "\(c.0)")
    }

    static let ownKeys: [(String, String)] = [
        ("API key", "sk-lw-\(body(12))_\(body(32))"),
        ("ingest key", "ik-lw-\(body(12))_\(body(32))"),
        ("legacy personal access token", "pat-lw-\(body(12))_\(BODY)"),
        ("a short API key", "sk-lw-123af"),
        ("a short ingest key", "ik-lw-123af"),
        ("a short legacy token", "pat-lw-123af"),
    ]

    @Test("A key minted by LangWatch is found on its prefix", arguments: ownKeys)
    func langwatch(_ c: (String, String)) {
        #expect(count(c.1) > 0, "\(c.0)")
    }

    @Test("A vendor-prefixed key with an all-hex body is found, an identifier is not")
    func prefixedHex() {
        #expect(redact("acme_live_\(HEX)") == "[SECRET]")
        #expect(redact("widget_test_\(HEX)") == "[SECRET]")
        #expect(redact("store_secret_\(HEX)") == "[SECRET]")
        let commit = "commit_key_51d07b547d0a8f3e2c1b9d4a6e7f8091a2b3c4d5"
        #expect(redact(commit) == commit)
        #expect(count("trace_token_\(HEX)aabbccdd") == 0)
    }

    static let missed: [(String, String)] = [
        ("Google OAuth client secret", "GOCSPX-\(body(24))"),
        ("LangWatch virtual key", "vk-lw-\(body(12))_\(body(32))"),
        ("a short LangWatch virtual key", "vk-lw-123af"),
        ("Metabase key", "mb_\(body(44))"),
        ("an Authorization Token header", "Authorization: Token \(body(32))"),
        ("an Okta SSWS Authorization header", "Authorization: SSWS \(body(32))"),
        ("an Opsgenie GenieKey header", "Authorization: GenieKey \(body(32))"),
        ("a Splunk header", "Authorization: Splunk \(body(32))"),
        ("an OAuth header", "Authorization: OAuth \(body(32))"),
        ("an encrypted PEM block", pemBlock("ENCRYPTED PRIVATE KEY", "MIIabc")),
        ("a PGP private key block", pemBlock("PGP PRIVATE KEY BLOCK", "lQOYBF")),
        ("a PuTTY private key", "PuTTY-User-Key-File-3: ssh-rsa\nPrivate-Lines: 8\nAAAABBBB\n\ntail"),
        ("an embedded kubeconfig key", "client-key-data: \(body(44))"),
        ("an embedded kubeconfig certificate", "client-certificate-data: \(body(44))"),
    ]

    @Test("Credentials the vendor list had missed are found", arguments: missed)
    func missedOnes(_ c: (String, String)) {
        #expect(count(c.1) > 0, "\(c.0)")
    }

    @Test("Credentials that already worked still do")
    func stillWorks() {
        #expect(count("phx_\(body(36))") == 1)
        #expect(count("Bearer \(body(32))") == 1)
        #expect(count(pemBlock("PRIVATE KEY", "MIIabc")) == 1)
    }

    @Test("A key with a standard base64 body is found")
    func base64() {
        #expect(redact("acme_aB3dEf+gHi/jKlMnOpQrStUvWx0123456789xY") == "[SECRET]")
        #expect(redact("acme_aB+dEf/gHi+jKlMnOpQrStUvWx0123456789xY") == "[SECRET]")
    }

    @Test("A key with an upper or mixed case prefix is found, an env var name is not")
    func casedPrefix() {
        #expect(redact("LW_\(body(43))") == "[SECRET]")
        #expect(redact("Xy_\(body(38))") == "[SECRET]")
        for name in ["AWS_SECRET_ACCESS_KEY", "DATABASE_URL_PRODUCTION", "LANGWATCH_TELEMETRY_ENDPOINT_OVERRIDE_URL"] {
            #expect(redact(name) == name)
        }
        let integrity = "SHA512-\(body(43))"
        #expect(redact(integrity) == integrity)
    }

    @Test("A credential introduced by name in free text is found")
    func named() {
        #expect(redact("my api key: h9Kd2Lm4Nq7Pr1Ts5Vw8Xz3") == "my api key: [SECRET]")
        #expect(redact("TWILIO_AUTH_TOKEN=a1b2c3d4e5f6a7b8c9d0e1f2a3b4c5d6") == "TWILIO_AUTH_TOKEN=[SECRET]")
        #expect(redact(#"{"client_secret":"h9Kd2Lm4Nq7Pr1Ts5Vw8Xz3"}"#) == #"{"client_secret":"[SECRET]"}"#)
        #expect(redact("Authorization: Basic dXNlcjpzdXBlcnNlY3JldDEyMw==") == "Authorization: Basic [SECRET]")
    }
}

@Suite("secret rules, text that only looks like secrets")
struct SecretRuleLeaveAloneTests {
    static let leaveAlone: [(String, String)] = [
        ("a commit hash", "fix in commit 51d07b547d0a8f3e2c1b9d4a6e7f8091a2b3c4d5"),
        ("short commit hashes", "reverted 5ebf89d6f4 and f05d495818"),
        ("a UUID", "id 550e8400-e29b-41d4-a716-446655440000 done"),
        ("an uppercase UUID", "ID 550E8400-E29B-41D4-A716-446655440000 done"),
        ("trace and span ids", "traceparent: 00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01"),
        ("ISO timestamps", "started 2026-08-10T14:32:11.482Z ended 14:32:19.005Z"),
        ("a source path", "see modules/metric/process/src/services/metric-request-collection.service.ts"),
        ("a path with a line number", "packages/redaction/src/secrets.ts:142"),
        ("a URL with query parameters", "https://app.langwatch.ai/project/my-project/traces?spanId=abc123"),
        ("a base64 data URI", "data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg=="),
        ("model names", "compared claude-opus-5 with gpt-5-mini and claude-3-5-sonnet-20241022"),
        ("a bedrock model id", "us.anthropic.claude-opus-4-20250514-v1:0"),
        ("semver bumps", "bumped langwatch from 1.2.1 to 2.6.0 and web to 3.9.0"),
        ("a subresource integrity hash", "integrity sha512-4Zj6ZL6qF9pQwEr7tYu2Io1pAsDfGh3JkL5mNb8Vc9X"),
        ("a docker image digest", "sha256:9f86d081884c7d659a2feaa0c55ad015a3bf4f1b2b0b822cd15d6c15b0f00a08"),
        ("a content-hashed asset", "dist/assets/index-DxK9mQ2p.js 1,234.56 kB"),
        ("a kubernetes pod name", "pod/langwatch-app-7d9f8c6b5d-x2mnq restarted"),
        ("an AWS ARN", "arn:aws:iam::123456789012:role/langwatch-app-runtime-role"),
        ("a snake_case identifier", "const user_id_1234567890abcdef = row.id;"),
        ("reading an environment variable", "const apiKey = process.env.OPENAI_API_KEY;"),
        ("a property access chain", "const token = config.auth.accessToken.value;"),
        ("a path following a credential keyword", "token: src/server/app-layer/traces/log-request-collection.service.ts"),
        ("an absolute path", "secret = /etc/langwatch/credentials.yaml"),
        ("an environment variable reference", "export ACME_API_KEY=$ACME_API_KEY"),
        ("a documented placeholder", "OPENAI_API_KEY=your-api-key-here"),
        ("a masked value", "api_key: xxxxxxxxxxxxxxxxxxxx"),
        ("a documented header", "Send the Authorization: Basic <base64-credentials> header."),
        ("a sentence about basic auth", "This uses Basic authentication over TLS."),
        ("a documented bearer header", "Send the Authorization: Bearer <your-token> header."),
        ("prose using the word key", "The key insight is that the token budget was the bottleneck."),
        ("advice about a key", "Set the api key in your .env file before running the tests"),
        ("an API version field", #"{"api_version": "2024-10-21", "model": "claude-opus-5"}"#),
        ("a request id header", "X-Request-Id: 7f3a9b2c-1d4e-5f6a-8b9c-0d1e2f3a4b5c"),
        ("usage attributes", "gen_ai.usage.input_tokens=15234 gen_ai.usage.output_tokens=892"),
        ("a branch name", "feat/coding-agent-session-events and issue6124/red-team-native"),
        ("already-redacted text", "key now: [SECRET] and token: [SECRET]"),
        ("an ordinary agent sentence", "I had to kill the other exploring agent because it was burning tokens on the same files."),
        ("a bare 32-hex token", HEX),
        ("a bare 64-hex token", HEX + HEX),
        ("a bare base62 token", BODY),
        ("a bare 21-character nanoid", "V1StGXR8Z5jdHi6BmyT"),
        ("a bare 32-character nanoid", "V1StGXR8Z5jdHi6BmyTV1StGXR8Z5jdH"),
        ("a bare git SHA", "51d07b547d0a8f3e2c1b9d4a6e7f8091a2b3c4d5"),
        ("a bare trace id", "4bf92f3577b34da6a3ce929d0e0e4736"),
        ("a bare span id", "00f067aa0ba902b7"),
        ("an AWS environment variable name", "AWS_SECRET_ACCESS_KEY"),
        ("a database environment variable name", "DATABASE_URL_PRODUCTION"),
        ("a long environment variable name", "LANGWATCH_TELEMETRY_ENDPOINT_OVERRIDE_URL"),
        ("a prefixed commit id", "commit_51d07b547d0a8f3e2c1b9d4a6e7f8091a2b3c4d5"),
        ("a prefixed trace id", "trace_4bf92f3577b34da6a3ce929d0e0e4736"),
        ("a prefixed digest", "digest_\(HEX)"),
        ("an identifier prefix carrying a credential segment", "commit_key_51d07b547d0a8f3e2c1b9d4a6e7f8091a2b3c4d5"),
        ("a trace prefix carrying a credential segment", "trace_token_\(HEX)aabbccdd"),
        ("words containing sk- and ask-", "risk-based scoring, disk-usage report, ask-me-anything, mask-sensitive-fields"),
        ("a transcript tag", "<task-notification> and <task-progress>"),
        ("package versions", "@langwatch/gateway-process@3.12.0 and pnpm@10.4.1"),
        ("a public PostHog project key", "phc_\(body(43))"),
        ("a project id", "project_\(body(29))"),
        ("a card id", "card_\(body(29))"),
        ("a scenario id", "scenario_\(body(29))"),
        ("a langy conversation id", "langyconv_\(body(29))"),
        ("a provider id", "provider_\(body(29))"),
        ("an OpenAI completion id", "chatcmpl-\(body(29))"),
        ("an Anthropic tool use id", "toolu_\(body(29))"),
        ("a thread id", "thread_\(body(29))"),
        ("a run id", "run_\(body(29))"),
        ("an assistant id", "asst_\(body(29))"),
        ("prose about a digest of a key", "a bare digest of an API key is offline-checkable against a list"),
        ("prose about an authorization header", "the Authorization header is attacker-controlled and can be killed"),
        ("a key field holding a content hash", #"{"key":"\#(rep("a1b2c3d4e5f6", 3))"}"#),
        ("a key field holding a UUID", #"{"key":"550e8400-e29b-41d4-a716-446655440000"}"#),
        ("a key field holding a record id", #"{"key":"project_\#(body(29))"}"#),
        ("a key entry in an OTLP attribute pair", #"{"key":"gen_ai.usage.input_tokens"}"#),
        ("a key field in YAML holding a commit", "key: \(rep("9f8e7d6c5b4a3928", 2))"),
        // Transcript text a hand-written `sk-.*` used to shred upstream.
        ("a task notification", "<task-notification>agent finished</task-notification> and then it stopped"),
        ("a system reminder", "<system-reminder>The user has not replied yet.</system-reminder>"),
        ("a tool name", "TaskCreate returned a new agent id"),
        ("risk-based", "we took a risk-based approach to the migration"),
        ("disk-usage", "disk-usage is at 84% on the clickhouse node"),
        ("ask-follow-up", "ask-follow-up was disabled for this run"),
        ("mask-sensitive-fields", "the mask-sensitive-fields flag is on"),
        ("flask-restful", "flask-restful is not a dependency here"),
        ("desk-check", "moved the desk-check to the review step"),
        // Prose following a credential word.
        ("the secret sauce", "the secret sauce here is careful measurement of everything"),
        ("password advice", "your password should be long and memorable and never reused"),
        // A JSON-escaped newline does not extend a value.
        ("an escaped newline after an env reference", "api_key = $OPENAI_API_KEY\\nnext line here"),
        ("a real newline after an env reference", "api_key = $OPENAI_API_KEY\nnext line here"),
        ("a terraform local", "github_token_secret = local.github_token_secret_name"),
        ("an empty marker header", "authorization: [SECRET]"),
        ("thanks", "the user said thanks"),
    ]

    @Test("Each is left exactly as written", arguments: leaveAlone)
    func leftAlone(_ c: (String, String)) {
        #expect(redact(c.1) == c.1, "\(c.0)")
        #expect(SecretDetector.find(in: c.1).isEmpty, "\(c.0)")
    }

    @Test("A bare key field holding an identifier is left alone")
    func keyField() {
        let hash = rep("a1b2c3d4e5f6", 3)
        #expect(redact(#"{"key":"\#(hash)"}"#) == #"{"key":"\#(hash)"}"#)
        #expect(redact("key: \(hash)") == "key: \(hash)")
    }

    @Test("A qualified key name is still a credential")
    func qualifiedKey() {
        let material = rep("a1b2c3d4e5f6", 3)
        for name in ["api_key", "secret_key", "apiKey", "x-api-key"] {
            #expect(redact("\(name): \(material)") == "\(name): [SECRET]", "\(name)")
        }
    }

    @Test("A credential after a whitespace separator is found")
    func whitespace() {
        #expect(count("Authorization \(body(30))") == 1)
        #expect(redact("api key \(HEX)") == "api key [SECRET]")
    }
}

@Suite("secret rules, scan budget")
struct SecretRuleBudgetTests {
    @Test("A 200 KB transcript scans quickly and finds nothing")
    func large() {
        let chunk = "The agent read modules/trace/process/src/services/trace-legacy-read.service.ts at "
            + "2026-08-10T14:32:11.482Z, commit 51d07b547d0a8f3e2c1b9d4a6e7f8091a2b3c4d5, "
            + #"model claude-opus-5, {"input_tokens":15234,"cost_usd":0.0412}"# + "\n"
        let payload = String(rep(chunk, 200_000 / chunk.count + 1).prefix(200_000))
        let started = Date()
        #expect(count(payload) == 0)
        #expect(Date().timeIntervalSince(started) < 4)
    }

    static let adversarial: [(String, String)] = [
        ("a long underscore run", rep("a_", 50_000)),
        ("a long hyphen run", rep("a-", 50_000)),
        ("a keyword followed by filler", "api_key: \(rep("a", 100_000))"),
        ("repeated keywords", rep("password=", 20_000)),
        ("repeated open quotes", rep(#"api_key:""#, 20_000) + "x"),
        ("lowercase prose with no URL in it", rep("the dashboard stopped loading ", 8_000)),
        ("one URL per line", rep("postgres://svc:pw@10.0.0.4:5432/app\n", 6_000)),
        ("a scheme-shaped run with no separator", rep("a", 100_000) + "://"),
    ]

    @Test("Stays linear on inputs shaped to stall a careless pattern", arguments: adversarial)
    func linear(_ c: (String, String)) {
        let started = Date()
        _ = count(String(c.1.prefix(250_000)))
        #expect(Date().timeIntervalSince(started) < 4, "\(c.0)")
    }
}

@Suite("secret detection report")
struct SecretDetectionReportTests {
    @Test("A provider key reports its rule and leaves the text alone")
    func provider() {
        let input = "key sk-proj-aB3dEf_gHi-jKlMnOpQrStUvWx0123456789xY here"
        let m = SecretDetector.matches(in: input)
        #expect(m.count == 1)
        #expect(m.first?.kind == "provider_api_key")
        #expect(m.first?.value == "sk-proj-aB3dEf_gHi-jKlMnOpQrStUvWx0123456789xY")
    }

    @Test("A connection URL reports the password as the value")
    func url() {
        let m = SecretDetector.matches(in: "db postgres://user:hunter2@db.internal:5432/app end")
        #expect(m.count == 1)
        #expect(m.first?.kind == "url_credentials")
        #expect(m.first?.value == "hunter2")
        let jdbc = SecretDetector.matches(in: "jdbc:postgresql://svc:9f8e7d6c@10.0.0.4:5432/app")
        #expect(jdbc.first?.value == "9f8e7d6c")
        #expect(jdbc.first?.suggestedName == "POSTGRESQL_PASSWORD")
    }

    @Test("Several distinct secrets are each reported")
    func several() {
        let kinds = SecretDetector.matches(in: "aws AKIAIOSFODNN7EXAMPLE and gh ghp_\(rep("a", 36))").map(\.kind).sorted()
        #expect(kinds == ["aws_access_key_id", "github_token"])
        let two = SecretDetector.matches(in: "aws AKIAIOSFODNN7EXAMPLE and gitlab glpat-\(body(21))").map(\.kind).sorted()
        #expect(two == ["aws_access_key_id", "vendor_api_key"])
    }

    @Test("One credential several rules recognise is reported once, under the most specific rule")
    func once() {
        let m = SecretDetector.matches(in: "api_key: sk-proj-aB3dEf_gHi-jKlMnOpQrStUvWx0123456789xY")
        #expect(m.map(\.kind) == ["provider_api_key"])
        let unknown = SecretDetector.matches(in: "key now: zyq_8fK2mQ7pXvL4nR9sT1wZ3yB6cD0eG5hJ2kM4pQ7rS9t")
        #expect(unknown.map(\.kind) == ["shaped_api_key"])
    }

    @Test("The rule list keeps the vendor, shape and named-value layers")
    func ruleIds() {
        #expect(SecretDetector.ruleIds.count >= 8)
        for id in ["vendor_api_key", "shaped_api_key", "sensitive_assignment"] { #expect(SecretDetector.ruleIds.contains(id)) }
    }
}

@Suite("pasted secrets in a prompt")
struct PastedSecretTests {
    // Realistic random bodies, built at run time.
    static let openai = "sk-proj-" + "Qm7vT2xLp9Rk4Wn8Zb3Hc6Yd1Fg5Js0Ae" + "_Uq-Vt8Nr2Mx"
    static let anthropic = "sk-ant-api03-" + "Zr8Kq2Vm5Tx9Lb3Nw7Hc1Yp4Fd6Gs0Je" + "AuQiWo"
    static let github = "ghp_" + "Xk9Lm2Pq7Rt4Vw8Zb3Nc6Hd1Fg5Js0AeQiWo"

    @Test("Placeholders and documentation values never ask")
    func placeholders() {
        for text in [
            "use sk-1234 for now",
            "OPENAI_API_KEY=sk-xxxxxxxxxxxxxxxxxxxxxxxx",
            "export OPENAI_API_KEY=<your-key>",
            "api_key: <your-api-key-here>",
            "token ghp_\(rep("a", 36))",
            "AKIAIOSFODNN7EXAMPLE",
            "sk-proj-12345678901234567890abcdef",
            "OPENAI_API_KEY=sk-your-openai-api-key-goes-here",
            "sk_live_\(rep("a", 24))",
            "OPENAI_API_KEY={{vault:OPENAI_API_KEY}}",
            "password: ********************",
        ] {
            #expect(SecretDetector.find(in: text).isEmpty, "\(text)")
        }
    }

    @Test("A key in a sentence gets its vendor's name")
    func vendorNames() {
        let found = SecretDetector.find(in: "here is my key \(Self.openai), and claude \(Self.anthropic) plus \(Self.github)")
        #expect(found.map(\.suggestedName) == ["OPENAI_API_KEY", "ANTHROPIC_API_KEY", "GITHUB_TOKEN"])
        #expect(found.map(\.value) == [Self.openai, Self.anthropic, Self.github])
    }

    @Test("An assigned name wins over the vendor's name")
    func assigned() {
        let cases: [(String, String)] = [
            ("MY_OPENAI=\(Self.openai)", "MY_OPENAI"),
            ("export prod_key=\(Self.openai)", "PROD_KEY"),
            ("  staging_token: \(Self.github)", "STAGING_TOKEN"),
            (#"{"model": "gpt", "LLM_KEY": "\#(Self.openai)"}"#, "LLM_KEY"),
            ("my api key: \(Self.openai)", "OPENAI_API_KEY"),
            ("x-api-key: \(Self.openai)", "OPENAI_API_KEY"),
            ("my secret is zyq_8fK2mQ7pXvL4nR9sT1wZ3yB6cD0eG5hJ2kM4pQ7rS9t", "SECRET"),
            ("Authorization: Bearer Qm7vT2xLp9Rk4Wn8Zb3Hc6Yd1", "BEARER_TOKEN"),
        ]
        for (text, name) in cases {
            #expect(SecretDetector.find(in: text).first?.suggestedName == name, "\(text)")
        }
    }

    @Test("A taken name gets the next free suffix")
    func unique() {
        #expect(SecretDetector.uniqueName("OPENAI_API_KEY", existing: []) == "OPENAI_API_KEY")
        #expect(SecretDetector.uniqueName("OPENAI_API_KEY", existing: ["OPENAI_API_KEY"]) == "OPENAI_API_KEY_2")
        #expect(SecretDetector.uniqueName("A", existing: ["A", "A_2", "A_3"]) == "A_4")
    }

    @Test("Replacing swaps every occurrence and adds one usage line per name")
    func replace() throws {
        let text = "use \(Self.openai) here, and again \(Self.openai)\nthen \(Self.github)"
        let found = SecretDetector.find(in: text)
        let openai = try #require(found.first)
        var out = SecretDetector.replace(text, secret: openai, name: "OPENAI_API_KEY")
        #expect(!out.contains(Self.openai))
        #expect(out.components(separatedBy: "{{vault:OPENAI_API_KEY}}").count == 4)
        #expect(out.hasSuffix("\n\n(" + "{{vault:OPENAI_API_KEY}} is a Kanban vault secret. Use it with `kv run OPENAI_API_KEY -- <cmd>`, never print it.)"))
        out = SecretDetector.replace(out, value: Self.github, name: "GITHUB_TOKEN")
        #expect(out.hasSuffix("never print it.)\n(" + "{{vault:GITHUB_TOKEN}} is a Kanban vault secret. Use it with `kv run GITHUB_TOKEN -- <cmd>`, never print it.)"))
        #expect(SecretDetector.replace(out, value: Self.github, name: "GITHUB_TOKEN") == out)
        #expect(SecretDetector.find(in: out).isEmpty)
    }

    @Test("The composer offers each distinct value once, with names free in the vault and among the offers")
    func proposals() {
        let other = "sk-proj-" + "Lb3Nw7Hc1Yp4Fd6Gs0JeZr8Kq2Vm5Tx9" + "_AuQiWo"
        let text = "first \(Self.openai) then \(other) and \(Self.openai) again"
        let offers = SecretDetector.proposals(in: text, existingNames: ["OPENAI_API_KEY"])
        #expect(offers.map(\.name) == ["OPENAI_API_KEY_2", "OPENAI_API_KEY_3"])
        #expect(offers.map(\.value) == [Self.openai, other])
        let sent = SecretDetector.apply(text, saved: offers)
        #expect(sent.hasPrefix("first {{vault:OPENAI_API_KEY_2}} then {{vault:OPENAI_API_KEY_3}} and {{vault:OPENAI_API_KEY_2}} again\n\n("))
        #expect(SecretDetector.proposals(in: "nothing to see", existingNames: []).isEmpty)
    }

    @Test("Saving keeps the offered names free, fixes an invalid typed name, and stops at the first failure")
    func save() async {
        let other = "sk-proj-" + "Lb3Nw7Hc1Yp4Fd6Gs0JeZr8Kq2Vm5Tx9" + "_AuQiWo"
        let text = "a \(Self.openai) b \(other) c \(Self.github)"
        var offers = SecretDetector.proposals(in: text, existingNames: [])
        offers[0].name = "MY KEY"
        var added: [String] = []
        var compared: [String] = []
        // OPENAI_API_KEY_2 was offered free and is taken by the time of the save.
        let ok = await SecretDetector.save(offers, in: text, existingNames: ["OPENAI_API_KEY_2"]) { p in
            compared.append(p.name); return .different
        } add: { p, replacing in
            added.append(p.name + (replacing ? " (replace)" : "")); return nil
        }
        #expect(added == ["SECRET", "OPENAI_API_KEY_2_2", "GITHUB_TOKEN"])
        #expect(compared.isEmpty)
        #expect(ok.error == nil && ok.remaining.isEmpty && ok.replace == nil)
        #expect(ok.text.hasPrefix("a {{vault:SECRET}} b {{vault:OPENAI_API_KEY_2_2}} c {{vault:GITHUB_TOKEN}}\n\n("))

        var calls = 0
        let failed = await SecretDetector.save(offers, in: text, existingNames: []) { _ in .absent } add: { _, _ in
            calls += 1; return calls == 2 ? "vault locked" : nil
        }
        #expect(failed.error == "Could not save OPENAI_API_KEY_2: vault locked")
        #expect(failed.remaining.map(\.value) == [other, Self.github])
        #expect(failed.text.contains("{{vault:SECRET}}") && failed.text.contains(other) && failed.text.contains(Self.github))
    }

    @Test("A typed name the vault holds asks before its value is replaced")
    func typedStoredNameAsksToReplace() async {
        let text = "rotate \(Self.openai) now, and use \(Self.github)"
        var offers = SecretDetector.proposals(in: text, existingNames: ["OPENAI_API_KEY"])
        #expect(offers.map(\.name) == ["OPENAI_API_KEY_2", "GITHUB_TOKEN"])
        offers[0].name = "OPENAI_API_KEY"
        var added: [String] = []
        let add: (SecretProposal, Bool) async -> String? = { p, replacing in
            added.append(p.name + (replacing ? " (replace)" : "")); return nil
        }

        let asked = await SecretDetector.save(offers, in: text, existingNames: ["OPENAI_API_KEY"], compare: { _ in .different }, add: add)
        #expect(asked.replace == "OPENAI_API_KEY" && asked.error == nil)
        #expect(asked.remaining.map(\.name) == ["OPENAI_API_KEY", "GITHUB_TOKEN"])
        #expect(asked.text == text)
        #expect(added.isEmpty)
        #expect(SecretDetector.replaceQuestion("OPENAI_API_KEY") == "OPENAI_API_KEY is already in the vault. Replace its value?")

        // Replace: the stored name gets the value, the prompt its reference.
        let yes = SecretDetector.answeringReplace(asked.remaining, replace: true)
        let replaced = await SecretDetector.save(yes, in: asked.text, existingNames: ["OPENAI_API_KEY"], compare: { _ in .different }, add: add)
        #expect(added == ["OPENAI_API_KEY (replace)", "GITHUB_TOKEN"])
        #expect(replaced.replace == nil && replaced.error == nil && replaced.remaining.isEmpty)
        #expect(replaced.text.hasPrefix("rotate {{vault:OPENAI_API_KEY}} now, and use {{vault:GITHUB_TOKEN}}\n\n("))

        // Pick another name: the free name is back, and saves with no question.
        added = []
        let no = SecretDetector.answeringReplace(asked.remaining, replace: false)
        #expect(no.map(\.name) == ["OPENAI_API_KEY_2", "GITHUB_TOKEN"])
        let kept = await SecretDetector.save(no, in: asked.text, existingNames: ["OPENAI_API_KEY"], compare: { _ in .different }, add: add)
        #expect(added == ["OPENAI_API_KEY_2", "GITHUB_TOKEN"] && kept.replace == nil)

        // A yes for one name does not cover another typed after it.
        added = []
        var renamed = yes
        renamed[0].name = "GITHUB_TOKEN_OLD"
        let other = await SecretDetector.save(renamed, in: asked.text, existingNames: ["OPENAI_API_KEY", "GITHUB_TOKEN_OLD"],
                                              compare: { _ in .different }, add: add)
        #expect(other.replace == "GITHUB_TOKEN_OLD" && added.isEmpty)
    }

    @Test("A typed name that already holds the pasted value is used with no question and no save")
    func typedStoredNameWithTheSameValue() async {
        let text = "use \(Self.openai)"
        var offers = SecretDetector.proposals(in: text, existingNames: ["OPENAI_API_KEY"])
        offers[0].name = "OPENAI_API_KEY"
        var added = 0
        let same = await SecretDetector.save(offers, in: text, existingNames: ["OPENAI_API_KEY"]) { _ in .same } add: { _, _ in
            added += 1; return nil
        }
        #expect(added == 0 && same.replace == nil && same.error == nil && same.remaining.isEmpty)
        #expect(same.text.hasPrefix("use {{vault:OPENAI_API_KEY}}\n\n("))
    }

    @Test("A typed name the vault does not hold is added, and the offered free name saves with no lookup")
    func newNamesSaveWithNoQuestion() async {
        let text = "use \(Self.openai) and \(Self.github)"
        var offers = SecretDetector.proposals(in: text, existingNames: ["OPENAI_API_KEY"])
        offers[1].name = "GH_DEPLOY_TOKEN"
        var compared: [String] = []
        var added: [String] = []
        let r = await SecretDetector.save(offers, in: text, existingNames: ["OPENAI_API_KEY"]) { p in
            compared.append(p.name); return .absent
        } add: { p, replacing in
            added.append(p.name + (replacing ? " (replace)" : "")); return nil
        }
        #expect(compared == ["GH_DEPLOY_TOKEN"])
        #expect(added == ["OPENAI_API_KEY_2", "GH_DEPLOY_TOKEN"])
        #expect(r.replace == nil && r.error == nil)
    }
}
