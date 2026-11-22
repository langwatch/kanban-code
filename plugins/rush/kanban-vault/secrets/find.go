package secrets

import (
	"fmt"
	"regexp"
	"slices"
	"strings"
)

// Detected is one secret Find found in a message.
type Detected struct {
	// Value is the secret itself, Start and End its byte span in the text.
	Value      string
	Start, End int
	// Kind is the rule that found it (provider_api_key, github_token, ...).
	Kind string
	// SuggestedName is the vault name to offer: the name it is assigned to
	// in the text, else a default for its kind.
	SuggestedName string
}

// Find returns the secrets in a message someone is about to send, skipping
// examples and placeholders (sk-proj-xxxx..., AKIA...EXAMPLE, your-key-here).
// Text past the scan budget is scanned in slices.
func Find(text string) []Detected {
	var out []Detected
	offset := 0
	for _, s := range sliceForScan(text) {
		for _, m := range detectSlice(s, Options{}) {
			end := m.SecretEnd
			if sentenceRuleIDs[m.RuleID] {
				end = withoutSentenceEnd(s, m.SecretStart, end)
			}
			v := s[m.SecretStart:end]
			if v == "" || isPlaceholderSecret(v, m.RuleID) || IsHandOffToken(v) {
				continue
			}
			d := Detected{Value: v, Start: offset + m.SecretStart, End: offset + end, Kind: m.RuleID}
			d.SuggestedName = suggestName(text, d)
			out = append(out, d)
		}
		offset += len(s)
	}
	return out
}

// sentenceRuleIDs are the rules whose value can run into the full stop or
// comma that ends the sentence around it ("follow it with the token X.").
var sentenceRuleIDs = map[string]bool{"sensitive_assignment": true, "bearer_token": true, "authorization_scheme_token": true}

// withoutSentenceEnd is end moved back over a run of . or , that closes
// the sentence: one followed by the end of the text, a space or a quote.
func withoutSentenceEnd(s string, start, end int) int {
	cut := end
	for cut > start && (s[cut-1] == '.' || s[cut-1] == ',') {
		cut--
	}
	if cut == end || cut == start {
		return end
	}
	if end == len(s) || strings.ContainsRune(" \t\r\n\"'`)]", rune(s[end])) {
		return cut
	}
	return end
}

// handOffToken is a one-time code a product hands a person to paste into
// an agent, such as a Laze connect link token (lzl_alk_<id>.<secret>):
// it works once, for minutes, so it goes to the agent as it is.
var handOffToken = regexp.MustCompile(`^lzl_[A-Za-z0-9_]+\.[0-9a-f]{32,}[.,]*$`)

// IsHandOffToken is whether v is a one-time code meant for the agent.
func IsHandOffToken(v string) bool { return handOffToken.MatchString(v) }

// vendorKinds are the rules that match on a vendor's prefix, whose body a
// placeholder can fill with too little randomness to be minted.
var vendorKinds = map[string]bool{"aws_access_key_id": true, "github_token": true, "provider_api_key": true,
	"stripe_secret_key": true, "slack_token": true, "google_api_key": true, "vendor_api_key": true, "jwt": true}

// placeholderWords mark a value as an example rather than a credential.
var placeholderWords = []string{"example", "your", "placeholder", "redacted", "dummy", "changeme", "sample", "fake",
	"insert", "replace", "xxxx", "****", "....", "1234567", "abcdefg", "qwerty", "<", ">"}

// isPlaceholderSecret is a value shaped like a key that is really an
// example: an example word, a masked run, one character six times in a
// row, a counting run, or a vendor prefix on a body too plain to be minted.
func isPlaceholderSecret(v, kind string) bool {
	l := strings.ToLower(v)
	for _, w := range placeholderWords {
		if strings.Contains(l, w) {
			return true
		}
	}
	if longestRepeatRun(v) >= 6 {
		return true
	}
	return vendorKinds[kind] && shannonEntropy(v) < 3.0
}

func longestRepeatRun(v string) int {
	longest, run := 0, 0
	var prev rune = -1
	for _, r := range v {
		if r == prev {
			run++
		} else {
			run = 1
		}
		prev = r
		longest = max(longest, run)
	}
	return longest
}

// nameLookback is how far back from a value its name is looked for.
const nameLookback = 200

var (
	envName = regexp.MustCompile(`^[A-Za-z_][A-Za-z0-9_]*$`)
	// assignedTo reads the name a value is assigned to on its line: NAME=,
	// export NAME=, NAME: and "NAME": ", the name starting the line or
	// following {, a comma or (.
	assignedTo  = regexp.MustCompile(`^(?:.*[{,(]\s*|\s*)(?:export\s+)?["'` + "`" + `]?([A-Za-z_][A-Za-z0-9_.-]*)["'` + "`" + `]?\s*(?::=|=|:)\s*["'` + "`" + `]?$`)
	telegramBot = regexp.MustCompile(`^[0-9]{8,10}:AA`)
	// saidAs reads what the words before a value call it: a word and then
	// key, token, secret or password ("the stripe api key is", "acme token:").
	saidAs = regexp.MustCompile(`(?i)\b([a-z][a-z0-9]{1,20})[ \t]+(api[ _-]?key|access[ _-]?token|auth[ _-]?token|secret[ _-]?key|key|token|secret|password)` +
		`(?:[ \t]+(?:is|here|now))?[ \t]*[:=]?[ \t]*["'` + "`" + `]?$`)
	// vendorPrefix is the letters a key starts with, before its first _ or -.
	vendorPrefix = regexp.MustCompile(`^([A-Za-z][A-Za-z0-9]{1,11})[_-]`)
)

// fillerWords come before key or token without naming whose it is.
var fillerWords = map[string]bool{"my": true, "the": true, "a": true, "an": true, "this": true, "that": true, "our": true,
	"your": true, "new": true, "old": true, "is": true, "use": true, "with": true, "of": true, "for": true, "and": true,
	"or": true, "api": true, "secret": true, "access": true, "auth": true, "private": true, "public": true, "same": true,
	"other": true, "another": true, "real": true, "test": true, "its": true, "their": true, "his": true, "her": true}

// genericName is the name of a secret nothing tells apart.
const genericName = "SECRET"

// suggestName is the name d's value is assigned to on its line, uppercased,
// else a default for its kind. A value only its shape gives away is named
// by the words before it ("the stripe key: ..." is STRIPE_KEY), else by its
// own prefix (stm_... is STM_API_KEY).
func suggestName(text string, d Detected) string {
	from := max(0, d.Start-nameLookback)
	if nl := strings.LastIndexAny(text[from:d.Start], "\r\n"); nl >= 0 {
		from += nl + 1
	}
	before := text[from:d.Start]
	if m := assignedTo.FindStringSubmatch(before); m != nil {
		if n := strings.ToUpper(m[1]); envName.MatchString(n) {
			return n
		}
	}
	name := defaultName(text, d)
	if name != genericName {
		return name
	}
	if m := saidAs.FindStringSubmatch(before); m != nil && !fillerWords[strings.ToLower(m[1])] {
		what := strings.NewReplacer(" ", "_", "-", "_").Replace(m[2])
		if n := strings.ToUpper(m[1] + "_" + what); envName.MatchString(n) {
			return n
		}
	}
	if slices.Contains(ShapeOnlyRuleIDs, d.Kind) {
		if m := vendorPrefix.FindStringSubmatch(d.Value); m != nil {
			return strings.ToUpper(m[1]) + "_API_KEY"
		}
	}
	if n := serviceName(text[max(0, d.Start-nameLookback):d.Start]); n != "" {
		return n
	}
	return name
}

var (
	// urlHost is the host of a link: https://laze.so/docs gives laze.so.
	urlHost = regexp.MustCompile(`(?i)https?://([a-z0-9.-]+)`)
	// credentialWord is what the words right before a value call it.
	credentialWord = regexp.MustCompile(`(?i)(api[ _-]?key|access[ _-]?token|auth[ _-]?token|token|password|passwd|key|secret)\W*$`)
)

// serviceName names a secret by the site the text links to before it and
// what the text calls it: "read https://laze.so/... with the token X" is
// LAZE_TOKEN. "" when no link comes before the value.
func serviceName(before string) string {
	hosts := urlHost.FindAllStringSubmatch(before, -1)
	if len(hosts) == 0 {
		return ""
	}
	labels := strings.Split(strings.Trim(hosts[len(hosts)-1][1], ".-"), ".")
	site := labels[0]
	if len(labels) >= 2 {
		site = labels[len(labels)-2]
	}
	site = strings.ToUpper(strings.ReplaceAll(site, "-", "_"))
	what := "SECRET"
	if m := credentialWord.FindStringSubmatch(before); m != nil {
		what = strings.ToUpper(strings.NewReplacer(" ", "_", "-", "_").Replace(m[1]))
	}
	if n := site + "_" + what; envName.MatchString(n) {
		return n
	}
	return ""
}

// vendorNames name a vendor_api_key by its prefix, first match wins.
var vendorNames = [][2]string{
	{"sk-lw-", "LANGWATCH_API_KEY"}, {"ik-lw-", "LANGWATCH_API_KEY"}, {"pat-lw-", "LANGWATCH_API_KEY"},
	{"vk-lw-", "LANGWATCH_API_KEY"}, {"gl", "GITLAB_TOKEN"}, {"npm_", "NPM_TOKEN"},
	{"GOCSPX-", "GOOGLE_CLIENT_SECRET"}, {"mb_", "METABASE_API_KEY"}, {"dckr_pat_", "DOCKER_TOKEN"},
	{"shp", "SHOPIFY_ACCESS_TOKEN"}, {"SG.", "SENDGRID_API_KEY"}, {"hf_", "HF_TOKEN"},
	{"gsk_", "GROQ_API_KEY"}, {"pplx-", "PERPLEXITY_API_KEY"}, {"nvapi-", "NVIDIA_API_KEY"},
	{"r8_", "REPLICATE_API_TOKEN"}, {"xai-", "XAI_API_KEY"}, {"ntn_", "NOTION_TOKEN"},
	{"secret_", "NOTION_TOKEN"}, {"dop_v1_", "DIGITALOCEAN_TOKEN"}, {"figd_", "FIGMA_TOKEN"},
	{"ATATT", "ATLASSIAN_API_TOKEN"}, {"sq0", "SQUARE_ACCESS_TOKEN"}, {"EAAG", "FACEBOOK_ACCESS_TOKEN"},
	{"key-", "MAILGUN_API_KEY"}, {"re_", "RESEND_API_KEY"}, {"phx_", "POSTHOG_API_KEY"},
	{"lin_api_", "LINEAR_API_KEY"}, {"sl.", "DROPBOX_TOKEN"}, {"ya29.", "GOOGLE_OAUTH_TOKEN"},
	{"sbp_", "SUPABASE_ACCESS_TOKEN"}, {"sntry", "SENTRY_AUTH_TOKEN"}, {"fw_", "FIREWORKS_API_KEY"},
	{"NRAK-", "NEW_RELIC_API_KEY"}, {"PMAK-", "POSTMAN_API_KEY"}, {"dp.", "DOPPLER_TOKEN"},
	{"pat", "AIRTABLE_TOKEN"},
}

var kindNames = map[string]string{
	"github_token": "GITHUB_TOKEN", "aws_access_key_id": "AWS_ACCESS_KEY_ID", "slack_token": "SLACK_TOKEN",
	"stripe_secret_key": "STRIPE_SECRET_KEY", "google_api_key": "GOOGLE_API_KEY", "jwt": "JWT",
	"pem_private_key": "PRIVATE_KEY", "putty_private_key": "PRIVATE_KEY",
	"kubeconfig_client_credentials": "KUBECONFIG_CLIENT_KEY", "bearer_token": "BEARER_TOKEN",
	"authorization_scheme_token": "AUTH_TOKEN", "basic_auth_credentials": "BASIC_AUTH",
	"labelled_password": "PASSWORD", "password_line": "PASSWORD", "credential_block": "PASSWORD",
}

// defaultName names a secret by its kind and, for some, its prefix or the
// URL scheme in front of it (postgres://... is POSTGRES_PASSWORD).
func defaultName(text string, d Detected) string {
	switch d.Kind {
	case "provider_api_key":
		switch {
		case strings.HasPrefix(d.Value, "sk-ant-"):
			return "ANTHROPIC_API_KEY"
		case strings.HasPrefix(d.Value, "sk-lw-"):
			return "LANGWATCH_API_KEY"
		}
		return "OPENAI_API_KEY"
	case "url_credentials":
		before := text[max(0, d.Start-nameLookback):d.Start]
		if sep := strings.LastIndex(before, "://"); sep >= 0 {
			i := sep
			for i > 0 && isSchemeByte(before[i-1]) {
				i--
			}
			scheme := before[i:sep]
			j := 0
			for j < len(scheme) && (isLetter(scheme[j]) || scheme[j] >= '0' && scheme[j] <= '9') {
				j++
			}
			if word := strings.ToUpper(scheme[:j]); word != "" && isLetter(word[0]) {
				return word + "_PASSWORD"
			}
		}
		return "PASSWORD"
	case "vendor_api_key":
		switch {
		case telegramBot.MatchString(d.Value):
			return "TELEGRAM_BOT_TOKEN"
		case strings.HasPrefix(d.Value, "glc_"), strings.HasPrefix(d.Value, "glsa_"):
			return "GRAFANA_TOKEN"
		}
		for _, vn := range vendorNames {
			if strings.HasPrefix(d.Value, vn[0]) {
				return vn[1]
			}
		}
	}
	if n := kindNames[d.Kind]; n != "" {
		return n
	}
	return genericName
}

// UniqueName is base, or base_2, base_3... the first that is not taken.
func UniqueName(base string, existing []string) string {
	if !slices.Contains(existing, base) {
		return base
	}
	for i := 2; ; i++ {
		if n := fmt.Sprintf("%s_%d", base, i); !slices.Contains(existing, n) {
			return n
		}
	}
}

// Ref is how a message names a vault secret in place of its value.
func Ref(name string) string { return "{{vault:" + name + "}}" }

// UsageLine is the line Replace adds, once per name, telling the agent how
// to use the secret.
func UsageLine(name string) string {
	return "(" + Ref(name) + " is a Kanban vault secret. Use it with `kv run " + name + " -- <cmd>`, never print it.)"
}

func isUsageLine(line string) bool {
	return strings.HasPrefix(line, "({{vault:") && strings.HasSuffix(line, "never print it.)")
}

// Replace puts {{vault:NAME}} in place of every occurrence of value and
// adds the usage line for NAME at the end, once: after a blank line, or
// right under another usage line.
func Replace(text, value, name string) string {
	if value == "" {
		return text
	}
	text = strings.ReplaceAll(text, value, Ref(name))
	line := UsageLine(name)
	if strings.Contains(text, line) {
		return text
	}
	sep := "\n\n"
	if isUsageLine(text[strings.LastIndexByte(text, '\n')+1:]) {
		sep = "\n"
	}
	return text + sep + line
}
