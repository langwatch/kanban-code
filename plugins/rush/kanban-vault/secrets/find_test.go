package secrets

import (
	"strings"
	"testing"
)

// findBody is a random-looking body with no counting run: body's
// 0123456789 reads as a placeholder to Find.
const findBody = "Zq7Wx3Rt9Lp2Mn8Kv4Bc6Hd1Fg5Js0TyQe3Ua9Ox2Ni7Gk4"

func fb(n int) string { return findBody[:n] }

func TestFindNamesTheSecret(t *testing.T) {
	proj := "sk-proj-" + fb(40)
	ant := "sk-ant-api03-" + fb(40)
	gh := "ghp_" + fb(36)
	cases := []struct{ label, text, value, kind, name string }{
		{"an OpenAI key alone", "use " + proj + " for this", proj, "provider_api_key", "OPENAI_API_KEY"},
		{"an Anthropic key", ant, ant, "provider_api_key", "ANTHROPIC_API_KEY"},
		{"a GitHub token", "token " + gh, gh, "github_token", "GITHUB_TOKEN"},
		{"an AWS key id", "AKIA2E0A8F3B244C9986", "AKIA2E0A8F3B244C9986", "aws_access_key_id", "AWS_ACCESS_KEY_ID"},
		{"a Slack token", "xoxb-" + fb(30), "xoxb-" + fb(30), "slack_token", "SLACK_TOKEN"},
		{"a Stripe key", "sk_live_" + fb(24), "sk_live_" + fb(24), "stripe_secret_key", "STRIPE_SECRET_KEY"},
		{"an unknown vendor", "zyq_8fK2mQ7pXvL4nR9sT1wZ3yB6cD0eG5hJ2kM4pQ7rS9t", "zyq_8fK2mQ7pXvL4nR9sT1wZ3yB6cD0eG5hJ2kM4pQ7rS9t", "shaped_api_key", "ZYQ_API_KEY"},
		{"named by the words before it", "here is the acme api key: zyq_8fK2mQ7pXvL4nR9sT1wZ3yB6cD0eG5hJ2kM4pQ7rS9t ok", "zyq_8fK2mQ7pXvL4nR9sT1wZ3yB6cD0eG5hJ2kM4pQ7rS9t", "shaped_api_key", "ACME_API_KEY"},
		{"a word and token", "long text, then our billing token is h9Kd2Lm4Nq7Pr1Ts5Vw8Xz3", "h9Kd2Lm4Nq7Pr1Ts5Vw8Xz3", "sensitive_assignment", "BILLING_TOKEN"},
		{"a known vendor keeps its name", "the acme key: " + gh, gh, "github_token", "GITHUB_TOKEN"},
		{"NAME=value", "MY_KEY=" + proj, proj, "provider_api_key", "MY_KEY"},
		{"export NAME=value", "export openrouter_key=" + proj, proj, "provider_api_key", "OPENROUTER_KEY"},
		{"NAME: value", "deploy_token: " + gh, gh, "github_token", "DEPLOY_TOKEN"},
		{`"NAME": "value"`, `{"client_secret": "h9Kd2Lm4Nq7Pr1Ts5Vw8Xz3"}`, "h9Kd2Lm4Nq7Pr1Ts5Vw8Xz3", "sensitive_assignment", "CLIENT_SECRET"},
		{"a value named by its keyword", "TWILIO_AUTH_TOKEN=a1b2c3d4e5f6a7b8c9d0e1f2a3b4c5d6", "a1b2c3d4e5f6a7b8c9d0e1f2a3b4c5d6", "sensitive_assignment", "TWILIO_AUTH_TOKEN"},
		{"a URL's password", "DATABASE_URL=postgres://app:Hk29xQm4Lp@db:5432/app", "Hk29xQm4Lp", "url_credentials", "POSTGRES_PASSWORD"},
		{"a URL's password, unnamed", "connect to mongodb+srv://app:Hk29xQm4Lp@db/app", "Hk29xQm4Lp", "url_credentials", "MONGODB_PASSWORD"},
		{"a LangWatch key", "sk-lw-" + fb(30), "sk-lw-" + fb(30), "provider_api_key", "LANGWATCH_API_KEY"},
		{"a Hugging Face token", "hf_" + fb(34), "hf_" + fb(34), "vendor_api_key", "HF_TOKEN"},
		{"a Telegram bot token", "839201746:AA" + fb(33), "839201746:AA" + fb(33), "vendor_api_key", "TELEGRAM_BOT_TOKEN"},
		{"a name mid-sentence is not taken", "my api key: h9Kd2Lm4Nq7Pr1Ts5Vw8Xz3", "h9Kd2Lm4Nq7Pr1Ts5Vw8Xz3", "sensitive_assignment", "SECRET"},
		{"a name after a comma", `{"a": 1, "openai": "` + proj + `"}`, proj, "provider_api_key", "OPENAI"},
		{"a Bearer token", "Authorization: Bearer " + fb(32), fb(32), "bearer_token", "BEARER_TOKEN"},
		{"a Basic header", "Authorization: Basic dXNlcjpzdXBlcnNlY3JldDEyMw==", "dXNlcjpzdXBlcnNlY3JldDEyMw==", "basic_auth_credentials", "BASIC_AUTH"},
	}
	for _, c := range cases {
		found := Find(c.text)
		if len(found) != 1 {
			t.Errorf("%s: found %d", c.label, len(found))
			continue
		}
		d := found[0]
		if d.Value != c.value || c.text[d.Start:d.End] != c.value || d.Kind != c.kind || d.SuggestedName != c.name {
			t.Errorf("%s: got %s %s at %d-%d (value matches: %v)", c.label, d.Kind, d.SuggestedName, d.Start, d.End, d.Value == c.value)
		}
	}
}

func TestFindSkipsExamplesAndPlaceholders(t *testing.T) {
	for _, text := range []string{
		"set OPENAI_API_KEY=sk-1234 first",
		"sk-proj-xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx",
		"sk-proj-XXXXXXXXXXXXXXXXXXXXXXXXXXXX",
		"OPENAI_API_KEY=<your-key>",
		"api_key: <your-key-here>",
		"token ghp_" + strings.Repeat("a", 36),
		"AWS key AKIAIOSFODNN7EXAMPLE from the docs",
		"sk-ant-your-key-goes-here-and-nowhere-else",
		"OPENAI_API_KEY=sk-...",
		"sk-proj-aaaaaaB3dEf7gHi2jKlMnOpQrStUvWx0123456789",
		"sk-proj-1234567890abcdefghijklmnopqrstuvwxyz",
		"export OPENAI_API_KEY={{vault:OPENAI_API_KEY}}",
		"Use it with `kv run OPENAI_API_KEY -- <cmd>`, never print it.",
	} {
		if found := Find(text); len(found) > 0 {
			t.Errorf("%q: found %s", text, found[0].Kind)
		}
	}
}

func TestFindSeveralSecrets(t *testing.T) {
	proj, gh := "sk-proj-"+fb(40), "ghp_"+fb(36)
	found := Find("a " + proj + " and b " + gh)
	if len(found) != 2 || found[0].Value != proj || found[1].Value != gh {
		t.Fatalf("found %d", len(found))
	}
}

func TestFindPastTheScanBudget(t *testing.T) {
	proj := "sk-proj-" + fb(40)
	text := strings.Repeat("x ", maxScanLength) + "\nKEY=" + proj
	found := Find(text)
	if len(found) != 1 || text[found[0].Start:found[0].End] != proj || found[0].SuggestedName != "KEY" {
		t.Fatalf("found %d", len(found))
	}
}

func TestUniqueName(t *testing.T) {
	cases := []struct {
		base     string
		existing []string
		want     string
	}{
		{"OPENAI_API_KEY", nil, "OPENAI_API_KEY"},
		{"OPENAI_API_KEY", []string{"OPENAI_API_KEY"}, "OPENAI_API_KEY_2"},
		{"OPENAI_API_KEY", []string{"OPENAI_API_KEY", "OPENAI_API_KEY_2"}, "OPENAI_API_KEY_3"},
		{"SECRET", []string{"OTHER"}, "SECRET"},
	}
	for _, c := range cases {
		if got := UniqueName(c.base, c.existing); got != c.want {
			t.Errorf("UniqueName(%s, %v) = %s, want %s", c.base, c.existing, got, c.want)
		}
	}
}

func TestReplace(t *testing.T) {
	proj := "sk-proj-" + fb(40)
	got := Replace("try "+proj+" then again "+proj, proj, "OPENAI_API_KEY")
	want := "try {{vault:OPENAI_API_KEY}} then again {{vault:OPENAI_API_KEY}}" +
		"\n\n({{vault:OPENAI_API_KEY}} is a Kanban vault secret. Use it with `kv run OPENAI_API_KEY -- <cmd>`, never print it.)"
	if Replace("x", "", "N") != "x" {
		t.Error("an empty value changes nothing")
	}
	if got != want {
		t.Errorf("got %q", got)
	}
	if again := Replace(got, proj, "OPENAI_API_KEY"); again != want {
		t.Errorf("a second Replace appended again: %q", again)
	}
	if found := Find(got); len(found) != 0 {
		t.Errorf("the replaced text still has a secret: %s", found[0].Kind)
	}
}

// A second secret's usage line goes right under the first, not after
// another blank line.
func TestReplaceStacksUsageLines(t *testing.T) {
	proj, gh := "sk-proj-"+fb(40), "ghp_"+fb(36)
	got := Replace(Replace(proj+" "+gh, proj, "A"), gh, "B")
	want := Ref("A") + " " + Ref("B") + "\n\n" + UsageLine("A") + "\n" + UsageLine("B")
	if got != want {
		t.Errorf("got %q", got)
	}
}

func TestFindTypedPasswords(t *testing.T) {
	pw := "Qm7" + "xW2#" + "pL9v"
	found := []string{
		"password: " + pw,
		"pwd=" + pw,
		`{"password": "` + pw + `"}`,
		"a senha do facebook é " + pw,
		"my facebook password is " + pw + ".",
		"Facebook password\n" + pw,
		"log in\n\nsomeone.test@example.com\n\n" + pw + "\n\n2fa: 123456",
		"someone.test@example.com:" + pw,
	}
	for _, text := range found {
		ds := Find(text)
		if len(ds) != 1 || ds[0].Value != pw || ds[0].SuggestedName != "PASSWORD" && ds[0].SuggestedName != "PWD" {
			t.Errorf("Find(%q) = %+v, want the password", text, ds)
		}
	}
	notPasswords := []string{
		"your password should be long and memorable",
		"password: required",
		"password = req.body.password",
		"password: ${DB_PASSWORD}",
		"password = getpass()",
		"password: ********",
		"password: <your-password>",
		"password: Obrigado!",
		"password: 12345678",
		"someone@example.com\n+55 11 99999-9999",
		"someone@example.com\nThanks, talk tomorrow",
		"password manager is 1Password",
		"bypass: Ab12cd34Ef56",
	}
	for _, text := range notPasswords {
		if ds := Find(text); len(ds) != 0 {
			t.Errorf("Find(%q) = %+v, want nothing", text, ds)
		}
	}
}
