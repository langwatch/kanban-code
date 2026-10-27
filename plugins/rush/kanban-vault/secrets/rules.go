// Package secrets finds credentials in free text: API keys, tokens, private
// keys, passwords in connection URLs and values assigned to credential-named
// fields. It is a port of LangWatch's redaction rules
// (packages/redaction/src/secrets.ts); Go's regexp has no lookarounds, so
// the token boundaries those rules read in lookbehinds and lookaheads are
// checked in code around each match instead.
package secrets

import (
	"math"
	"regexp"
	"strings"
)

// Marker is what a redacted secret is replaced with.
const Marker = "[SECRET]"

// maxScanLength is the slice size a long input is cut into before scanning.
const maxScanLength = 250_000

type rule struct {
	id          string
	description string
	re          *regexp.Regexp
	// render keeps the matched text up to the secret group and puts the
	// marker in place of that group (a URL's scheme and user, a Bearer
	// prefix); without it the whole match is the secret.
	render bool
	// secretGroup is the capture group holding the secret itself, for the
	// rules that keep context around it. 0 means the whole match.
	secretGroup int
	// accept is a second-stage test on a regex match; groups[0] is the match.
	accept func(groups []string) bool
	// precondition skips the scan when the text cannot match.
	precondition func(text string) bool
	// tokenBounded rules may not start or end inside a longer identifier:
	// the character on each side must not be [A-Za-z0-9_-].
	tokenBounded bool
	// schemeBefore rules need a URL scheme right in front of the match,
	// which then counts as part of the reported span.
	schemeBefore bool
	// notFollowedBy, when set, is a set of bytes that may not follow the match.
	notFollowedBy string
}

const entropySampleLength = 256

// shannonEntropy is the entropy of value in bits per character, over the
// first 256 characters.
func shannonEntropy(value string) float64 {
	sample := []rune(value)
	if len(sample) > entropySampleLength {
		sample = sample[:entropySampleLength]
	}
	if len(sample) == 0 {
		return 0
	}
	counts := map[rune]int{}
	for _, r := range sample {
		counts[r]++
	}
	entropy := 0.0
	n := float64(len(sample))
	for _, c := range counts {
		p := float64(c) / n
		entropy -= p * math.Log2(p)
	}
	return entropy
}

func countCharClasses(value string) (lower, upper, digit int) {
	for i := 0; i < len(value); i++ {
		switch c := value[i]; {
		case c >= 'a' && c <= 'z':
			lower++
		case c >= 'A' && c <= 'Z':
			upper++
		case c >= '0' && c <= '9':
			digit++
		}
	}
	return
}

func isTokenByte(c byte) bool {
	return c >= 'a' && c <= 'z' || c >= 'A' && c <= 'Z' || c >= '0' && c <= '9' || c == '_' || c == '-'
}

// Prefixes minted by developer services, alternated into one pass.
var vendorKeyPatterns = []string{
	// LangWatch's own token prefixes; the 3-char floor keeps a bare prefix
	// printed alone in docs from matching as a key.
	`(?:sk|ik|pat|vk)-lw-[A-Za-z0-9_-]{3,}`,
	// GitLab personal, project, deploy, runner and agent tokens.
	`gl(?:pat|rt|dt|soat|ptt|cbt|imt|agent|ffct)-[A-Za-z0-9_-]{20,}`,
	`npm_[A-Za-z0-9]{36}`,
	// Google OAuth client secret.
	`GOCSPX-[A-Za-z0-9_-]{20,}`,
	`mb_[A-Za-z0-9+/=]{40,}`,
	`dckr_pat_[A-Za-z0-9_-]{20,}`,
	// Shopify admin, storefront, custom and private app tokens.
	`shp(?:at|ss|ca|pa)_[0-9a-fA-F]{32}`,
	`SG\.[A-Za-z0-9_-]{16,}\.[A-Za-z0-9_-]{16,}`,
	`hf_[A-Za-z0-9]{30,}`,
	`gsk_[A-Za-z0-9]{40,}`,
	`pplx-[A-Za-z0-9]{30,}`,
	`nvapi-[A-Za-z0-9_-]{40,}`,
	`r8_[A-Za-z0-9]{30,}`,
	`xai-[A-Za-z0-9]{40,}`,
	// Notion integration tokens, current and legacy.
	`ntn_[A-Za-z0-9]{30,}`,
	`secret_[A-Za-z0-9]{40,}`,
	`dop_v1_[0-9a-f]{64}`,
	`figd_[A-Za-z0-9_-]{30,}`,
	`ATATT[A-Za-z0-9_=-]{100,}`,
	`sq0(?:atp|csp)-[A-Za-z0-9_-]{20,}`,
	`EAAG[A-Za-z0-9]{60,}`,
	`key-[0-9a-f]{32}`,
	`re_[A-Za-z0-9_-]{20,}`,
	`phx_[A-Za-z0-9]{30,}`,
	`lin_api_[A-Za-z0-9]{30,}`,
	`sl\.[A-Za-z0-9_-]{60,}`,
	`ya29\.[A-Za-z0-9_-]{20,}`,
	`sbp_[0-9a-f]{40,}`,
	`sntry(?:s|u)_[A-Za-z0-9_.-]{30,}`,
	`fw_[A-Za-z0-9]{20,}`,
	`gl(?:c|sa)_[A-Za-z0-9]{30,}`,
	`NRAK-[A-Za-z0-9]{20,}`,
	`PMAK-[A-Za-z0-9]{20,}-[A-Za-z0-9]{20,}`,
	`dp\.(?:pt|st|ct|sa)\.[A-Za-z0-9_-]{20,}`,
	// Airtable personal access token: patXXXXXXXXXXXXXX.<64 hex>.
	`pat[A-Za-z0-9]{14}\.[0-9a-f]{64}`,
	// Telegram bot token: <numeric bot id>:AA<35-char body>.
	`[0-9]{8,10}:AA[A-Za-z0-9_-]{33}`,
}

// Bounds for the shape-only rule: the floor keeps short identifiers out, the
// ceiling keeps an encoded payload from being taken whole.
const (
	shapedTokenMinBody    = 26
	shapedTokenMaxBody    = 120
	shapedTokenMinEntropy = 3.9
)

// isKeyShapedBody wants two of each class (upper, lower, digit), which tells
// random bytes from SHAs and camelCase identifiers.
func isKeyShapedBody(body string) bool {
	if len(body) < shapedTokenMinBody || len(body) > shapedTokenMaxBody {
		return false
	}
	lower, upper, digit := countCharClasses(body)
	if lower < 2 || upper < 2 || digit < 2 {
		return false
	}
	return shannonEntropy(body) >= shapedTokenMinEntropy
}

func setOf(words ...string) map[string]bool {
	s := make(map[string]bool, len(words))
	for _, w := range words {
		s[w] = true
	}
	return s
}

// Digest and encoding prefixes: a content hash has a key's entropy and none
// of its sensitivity.
var digestPrefixes = setOf("sha1", "sha224", "sha256", "sha384", "sha512", "sha3", "md4", "md5",
	"blake2b", "blake2s", "blake3", "crc32", "xxh3", "xxh64", "base32", "base58", "base64", "hex",
	"uuid", "urn", "cid", "etag", "hash", "digest", "checksum", "integrity")

// The middle word that makes a prefixed hex string a credential.
var hexBodyCredentialSegments = []string{"live", "test", "prod", "sk", "pk", "key", "secret", "token"}

// Prefixes that name an identifier even with a credential segment after them.
var identifierPrefixes = setOf("commit", "sha", "sha1", "sha256", "md5", "hash", "digest", "trace",
	"span", "id", "uuid", "rev", "blob", "tree", "etag", "checksum")

// Prefixes that name a record, minted in the same shape as a key.
var recordIDPrefixes = setOf("project", "provider", "card", "eval", "monitor", "scenario", "ses",
	"sess", "session", "thread", "conv", "langyconv", "span", "trace", "run", "msg", "task", "job",
	"step", "node", "team", "org", "user", "call", "req", "resp", "chatcmpl", "toolu", "asst", "file",
	"batch", "evt", "acct", "cus", "sub")

// Keys published on purpose, like PostHog's phc_ project key.
var publicKeyPrefixes = setOf("phc")

func isNonCredentialPrefix(prefix string) bool {
	l := strings.ToLower(prefix)
	return digestPrefixes[l] || identifierPrefixes[l] || recordIDPrefixes[l] || publicKeyPrefixes[l]
}

const (
	hexBodyMin = 24
	hexBodyMax = 128
)

var (
	placeholderValue = regexp.MustCompile(`(?i)^(?:x+|\*+|\.+|-+|_+|0+|(?:your|my|our|insert|replace|example|sample|dummy|fake|placeholder|changeme|redacted|removed|hidden|none|null|nil|undefined|todo|tbd|fixme)[a-z0-9_\- ]*)$`)
	// A reference to a credential: $VAR, or a SCREAMING_SNAKE name.
	envReference = regexp.MustCompile(`^(?:\$[A-Za-z_][A-Za-z0-9_]*|[A-Z][A-Z0-9]*(?:_[A-Z0-9]+)+)$`)
	// process.env.OPENAI_API_KEY, config.auth.token: code, not key material.
	codeExpression = regexp.MustCompile(`^[A-Za-z_$][\w$]*(?:\.[A-Za-z_$][\w$]*)+$`)
	pathLike       = regexp.MustCompile(`^[~.]{0,2}/|/[^/\s]*\.[a-z]{1,5}$`)
	urlLike        = regexp.MustCompile(`(?i)^[a-z][a-z0-9+.-]*://`)
	versionString  = regexp.MustCompile(`^v?\d+(?:[._-]\d+)+`)
	allHex32       = regexp.MustCompile(`(?i)^[0-9a-f]{32,}$`)
	base32Seed     = regexp.MustCompile(`^[A-Z2-7]{32,}={0,6}$`)
	strictIntro    = regexp.MustCompile(`[:=]\s*["'` + "`" + `]?$`)
)

const (
	contextValueMinLength  = 16
	contextValueMinEntropy = 2.9
	looseValueMinLength    = 20
	looseValueMinEntropy   = 3.4
)

// isCredentialValue: does a value already introduced by a keyword carry a
// credential, and not a placeholder, a variable, code, a path or a URL?
func isCredentialValue(value string) bool {
	if len(value) < contextValueMinLength {
		return false
	}
	if placeholderValue.MatchString(value) || envReference.MatchString(value) ||
		codeExpression.MatchString(value) || pathLike.MatchString(value) || urlLike.MatchString(value) ||
		strings.Contains(value, Marker) {
		return false
	}
	return shannonEntropy(value) >= contextValueMinEntropy
}

// isKeyMaterial is the bar when only whitespace separates the keyword from
// the value: it must look like key material on its own.
func isKeyMaterial(value string) bool {
	if len(value) < looseValueMinLength || !isCredentialValue(value) || versionString.MatchString(value) {
		return false
	}
	if shannonEntropy(value) < looseValueMinEntropy {
		return false
	}
	if allHex32.MatchString(value) || base32Seed.MatchString(value) {
		return true
	}
	lower, upper, digit := countCharClasses(value)
	return digit >= 2 && (lower >= 2 || upper >= 2)
}

// Words that turn a bare `key` into a credential.
var credentialQualifiers = []string{"master", "encryption", "signing", "private", "access", "api",
	"auth", "secret", "refresh", "session", "bearer", "verification", "webhook", "client", "service",
	"personal", "root", "admin"}

var credentialQualifierSet = setOf(credentialQualifiers...)

var qualifierAlternation = strings.Join(credentialQualifiers, "|")

// Words that introduce a credential, compound spellings included; `key`
// needs a qualifier.
var credentialKeyword = `(?:x[_.\- ]?)?(?:` +
	`(?:` + qualifierAlternation + `)[_.\- ]?(?:api[_.\- ]?)?key` +
	`|(?:` + qualifierAlternation + `)?[_.\- ]?(?:api[_.\- ]?)?` +
	`(?:token|secret|password|passwd|pwd|credentials?|authorization|cookie)` +
	`)`

// isBasicAuthPayload tells a base64 payload after `Basic ` from the English
// word after "Basic" in a sentence.
func isBasicAuthPayload(value string) bool {
	if strings.HasSuffix(value, "=") {
		return true
	}
	lower, upper, digit := countCharClasses(value)
	return digit > 0 || lower > 0 && upper > 0
}

const endBlock = `(?: BLOCK)?-----`

// valueRules run in order: precise vendor rules before the broad shape and
// context ones, so a match reports under its vendor.
var valueRules = []rule{
	{
		id:          "pem_private_key",
		description: "PEM private key block",
		re:          regexp.MustCompile(`-----BEGIN (?:RSA |EC |DSA |OPENSSH |PGP |ENCRYPTED )?PRIVATE KEY` + endBlock + `[\s\S]*?-----END (?:RSA |EC |DSA |OPENSSH |PGP |ENCRYPTED )?PRIVATE KEY` + endBlock),
	},
	{
		// PuTTY's own format has no armour; the body is clamped at the next
		// blank line.
		id:          "putty_private_key",
		description: "PuTTY private key file",
		re:          regexp.MustCompile(`PuTTY-User-Key-File-\d+:[\s\S]*?(?:\n\s*\n|$)`),
	},
	{
		// The certificate goes with the key: together they are a working login.
		id:          "kubeconfig_client_credentials",
		description: "Embedded kubeconfig client key or certificate",
		re:          regexp.MustCompile(`\b(client-(?:key|certificate)-data:\s*)([A-Za-z0-9+/=]{40,})`),
		render:      true,
		secretGroup: 2,
	},
	{
		id:          "aws_access_key_id",
		description: "AWS access key id",
		re:          regexp.MustCompile(`\b(?:AKIA|ASIA|AGPA|AIDA|AROA|ANPA|ANVA)[0-9A-Z]{16}\b`),
	},
	{
		id:          "github_token",
		description: "GitHub token",
		re:          regexp.MustCompile(`\b(?:gh[posru]_[A-Za-z0-9]{36,}|github_pat_[A-Za-z0-9_]{60,})\b`),
	},
	{
		// OpenAI, Anthropic, LangWatch and others share the sk- namespace; the
		// body is base64url, so the whole token is taken.
		id:          "provider_api_key",
		description: "Provider API key (sk-...)",
		re:          regexp.MustCompile(`\bsk-[A-Za-z0-9_-]{20,}`),
	},
	{
		id:          "stripe_secret_key",
		description: "Stripe secret key",
		re:          regexp.MustCompile(`\b[rs]k_(?:live|test)_[A-Za-z0-9]{16,}\b`),
	},
	{
		id:          "slack_token",
		description: "Slack token",
		re:          regexp.MustCompile(`\bxox[abposr]-[A-Za-z0-9-]{10,}\b`),
	},
	{
		id:          "google_api_key",
		description: "Google API key",
		re:          regexp.MustCompile(`\bAIza[0-9A-Za-z_-]{35}\b`),
	},
	{
		id:           "vendor_api_key",
		description:  "Developer-service API key (GitLab, npm, Docker Hub, Shopify, SendGrid, Hugging Face, Groq, Notion, Atlassian and others)",
		re:           regexp.MustCompile(`(?:` + strings.Join(vendorKeyPatterns, "|") + `)`),
		tokenBounded: true,
	},
	{
		id:          "jwt",
		description: "JSON Web Token",
		re:          regexp.MustCompile(`\beyJ[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\b`),
	},
	{
		// scheme://user:password@host keeps all but the password. The match
		// anchors on "://"; the scheme in front is checked in code and counts
		// as part of the reported span.
		id:           "url_credentials",
		description:  "Password embedded in a connection URL",
		re:           regexp.MustCompile(`(://[^\s:@/]+:)([^\s:@/]+)(@)`),
		render:       true,
		secretGroup:  2,
		schemeBefore: true,
	},
	{
		id:          "bearer_token",
		description: "Bearer authorization token",
		re:          regexp.MustCompile(`(?i)\b(Bearer\s+)([A-Za-z0-9._~+/-]{10,}=*)`),
		render:      true,
		secretGroup: 2,
	},
	{
		// Token, OAuth or Splunk are ordinary words, so they count only inside
		// an Authorization header.
		id:          "authorization_scheme_token",
		description: "Non-Bearer authorization scheme token",
		re:          regexp.MustCompile(`(?i)\b(Authorization:\s*(?:Token|SSWS|GenieKey|Splunk|OAuth)\s+)([A-Za-z0-9._~+/-]{10,}=*)`),
		render:      true,
		secretGroup: 2,
	},
	{
		id:            "basic_auth_credentials",
		description:   "Basic authorization credentials",
		re:            regexp.MustCompile(`\b(Basic\s+)([A-Za-z0-9+/]{16,}={0,2})`),
		notFollowedBy: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/=",
		accept:        func(g []string) bool { return isBasicAuthPayload(g[2]) },
		render:        true,
		secretGroup:   2,
	},
	{
		// The all-hex sibling of the shape rule: a credential segment in the
		// middle is what tells a key from a digest or a trace id.
		id:          "prefixed_hex_api_key",
		description: "API key with a vendor prefix and an all-hex body",
		re: regexp.MustCompile(`(?i)([A-Za-z][A-Za-z0-9]{1,11})_(?:` + strings.Join(hexBodyCredentialSegments, "|") + `)_` +
			`([0-9a-f]{24,128})`),
		tokenBounded: true,
		accept:       func(g []string) bool { return !identifierPrefixes[strings.ToLower(g[1])] },
		precondition: func(t string) bool { return strings.Contains(t, "_") },
	},
	{
		// A vendor nobody has heard of: a short prefix, a separator and a
		// high-entropy body.
		id:           "shaped_api_key",
		description:  "High-entropy API key with a vendor-style prefix",
		re:           regexp.MustCompile(`([A-Za-z][A-Za-z0-9]{1,11})[_-]([A-Za-z0-9_+/-]{26,})`),
		tokenBounded: true,
		accept: func(g []string) bool {
			return !isNonCredentialPrefix(g[1]) && isKeyShapedBody(g[2])
		},
		precondition: func(t string) bool { return strings.ContainsAny(t, "_-") },
	},
	{
		// The text says what the value is. Up to two filler words may sit
		// between the keyword and the separator ("key now:", "token here =").
		// Whitespace alone separates only when the value looks like key
		// material. Backslash ends a value: JSON-encoded text carries a
		// literal \n that must not run a value across lines.
		id:          "sensitive_assignment",
		description: "Value assigned to a credential-named field",
		re: regexp.MustCompile(`(?i)((?:^|[\W_])(?:` + credentialKeyword + `)(?:\s+[A-Za-z]{1,8}){0,2}["'` + "`" + `]?` +
			`(?:\s*[:=]{1,2}\s*|[ \t?-]+)["'` + "`" + `]?)` +
			`([^\s"'` + "`" + `,;<>(){}\[\]\\]{16,})`),
		render:      true,
		secretGroup: 2,
		accept: func(g []string) bool {
			if strictIntro.MatchString(g[1]) {
				return isCredentialValue(g[2])
			}
			return isKeyMaterial(g[2])
		},
	},
	{
		// "password: X", "senha do gmail é X", "DB_PASS=X", `"password": "X"`.
		id:          "labelled_password",
		description: "Password written after its label",
		re: regexp.MustCompile(`(?im)(?:^|[^\p{L}\p{N}])` + passwordLabel + passwordOf +
			`["'` + "`" + `]?(?:[ \t]*(?:[:=]{1,2}|=>|->)[ \t]*|[ \t]+(?:is|é|eh|es|est|ist)[ \t]+)["'` + "`" + `]?` +
			passwordValue + `(?:["'` + "`" + `\s]|$)`),
		render:      true,
		secretGroup: 1,
		accept:      func(g []string) bool { return isTypedPassword(g[1]) },
	},
	{
		// A label alone on its line and the password on the next one.
		id:          "password_line",
		description: "Password on the line after its label",
		re: regexp.MustCompile(`(?im)^[ \t]*(?:[\p{L}\p{N}.@_-]{1,40}[ \t]+)?` + passwordLabel + passwordOf +
			`[ \t]*:?[ \t]*\r?\n(?:[ \t]*\r?\n)?[ \t]*` + passwordValue + `[ \t]*\r?$`),
		render:      true,
		secretGroup: 1,
		accept:      func(g []string) bool { return isTypedPassword(g[1]) },
	},
	{
		// A login pasted as it is: the email address, then the password on
		// the next line or after a colon, a slash or a bar.
		id:          "credential_block",
		description: "Password pasted under or after an email address",
		re: regexp.MustCompile(`(?im)^[ \t]*(?:(?:e-?mail|user(?:name)?|login|usu[aá]rio)[ \t]*[:=]?[ \t]*)?` + emailAddress +
			`[ \t]*(?:\r?\n(?:[ \t]*\r?\n)?[ \t]*|[ \t]*[|/:][ \t]*)` + passwordValue + `[ \t]*\r?$`),
		render:      true,
		secretGroup: 1,
		accept:      func(g []string) bool { return isTypedPassword(g[1]) },
	},
}

// Words that name a password, in the languages it gets typed in.
const passwordLabel = `(?:password|passwd|passwort|passphrase|pwd|pass|senha|contrase(?:ñ|n)a|mot de passe|wachtwoord)`

// "password for facebook", "senha do gmail".
const passwordOf = `(?:[ \t]+(?:for|of|on|to|at|do|da|de|del|du|no|na|para|von|für)[ \t]+[\p{L}\p{N}.@_-]{1,40})?`

// A password: one run with no space or quote, 8 to 128 characters, a
// sentence's full stop or comma after it left out.
const passwordValue = `([^\s"'` + "`" + `]{7,127}[^\s"'` + "`" + `.,;])[.,;]?`

const emailAddress = `[A-Za-z0-9._%+-]+@[A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+)+`

var (
	wordWithPunctuation = regexp.MustCompile(`^\p{L}+[!?.,:;]*$`)
	phoneLike           = regexp.MustCompile(`^\+?[0-9 ().-]{7,}$`)
	dateLike            = regexp.MustCompile(`^\d{4}-\d{2}-\d{2}`)
	emailLike           = regexp.MustCompile(`^` + emailAddress + `$`)
)

// isTypedPassword: does a value next to a password label read as a
// password? Not a placeholder, a reference, code, a path, an address, a
// number, a date or a plain word, and at least two of lowercase, uppercase,
// digits and symbols.
func isTypedPassword(value string) bool {
	if len(value) < 8 || len(value) > 128 {
		return false
	}
	if isPlaceholderSecret(value, "labelled_password") || placeholderValue.MatchString(value) {
		return false
	}
	if envReference.MatchString(value) || codeExpression.MatchString(value) || pathLike.MatchString(value) ||
		urlLike.MatchString(value) || emailLike.MatchString(value) || versionString.MatchString(value) ||
		dateLike.MatchString(value) || phoneLike.MatchString(value) || wordWithPunctuation.MatchString(value) {
		return false
	}
	if strings.Contains(value, Marker) || strings.Contains(value, "{{vault:") || strings.ContainsAny(value, "()[]{}<>") {
		return false
	}
	if strings.ContainsAny(value[:1], "-$%") {
		return false
	}
	lower, upper, digit := countCharClasses(value)
	other := len([]rune(value)) - lower - upper - digit
	classes := 0
	for _, n := range []int{lower, upper, digit, other} {
		if n > 0 {
			classes++
		}
	}
	return classes >= 2
}

// Rule is one built-in rule, for listing.
type Rule struct {
	ID, Description string
}

// BuiltinRules lists the built-in rules in the order they run.
func BuiltinRules() []Rule {
	out := make([]Rule, len(valueRules))
	for i, r := range valueRules {
		out[i] = Rule{r.id, r.description}
	}
	return out
}

// ShapeOnlyRuleIDs are the rules that judge a token by shape alone: the only
// ones that can take an identifier, and the only ones a caller has cause to
// turn off.
var ShapeOnlyRuleIDs = []string{"prefixed_hex_api_key", "shaped_api_key"}
