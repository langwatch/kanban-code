package main

import (
	"context"
	"encoding/json"
	"errors"
	"net"
	"slices"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/langwatch/kanban-code/plugins/rush/kanban-vault/secrets"
)

type fakeVault struct {
	mu     sync.Mutex
	names  []string
	added  map[string]string
	lsErr  error
	addErr error
	// What the vault holds under names the plugin didn't add, the
	// errors the next replaces answer with, and the replaces done.
	held       map[string]string
	replaceErr []error
	replaced   []string
}

func (v *fakeVault) Same(_ context.Context, name, value string) (bool, error) {
	v.mu.Lock()
	defer v.mu.Unlock()
	if got, ok := v.added[name]; ok {
		return got == value, nil
	}
	return v.held[name] == value, nil
}

func (v *fakeVault) Replace(_ context.Context, name, value string) error {
	v.mu.Lock()
	defer v.mu.Unlock()
	if len(v.replaceErr) > 0 {
		err := v.replaceErr[0]
		v.replaceErr = v.replaceErr[1:]
		if err != nil {
			return err
		}
	}
	if v.held == nil {
		v.held = map[string]string{}
	}
	v.held[name] = value
	v.replaced = append(v.replaced, name)
	return nil
}

func (v *fakeVault) Names(context.Context) ([]string, error) {
	v.mu.Lock()
	defer v.mu.Unlock()
	return slices.Clone(v.names), v.lsErr
}

func (v *fakeVault) setNames(names ...string) {
	v.mu.Lock()
	defer v.mu.Unlock()
	v.names = names
}

func (v *fakeVault) Add(_ context.Context, name, value string) error {
	v.mu.Lock()
	defer v.mu.Unlock()
	if v.addErr != nil {
		return v.addErr
	}
	if v.added == nil {
		v.added = map[string]string{}
	}
	v.added[name] = value
	v.names = append(v.names, name)
	return nil
}

var key = "sk-proj-" + strings.Repeat("Ab3dEf7gHi2jKlMn", 3)

func TestNothingToAskAbout(t *testing.T) {
	a := newApp(&fakeVault{})
	if r := a.intercept(intercept{Text: "set OPENAI_API_KEY=sk-1234 and <your-key>"}); r.Action != "allow" {
		t.Fatalf("got %+v", r)
	}
}

// The name offered can be taken by the time you say y: the save offers
// the next free one instead.
func TestTakenNameIsOfferedAgain(t *testing.T) {
	v := &fakeVault{}
	a := newApp(v)
	ask := a.intercept(intercept{Box: "s1", Text: "OPENAI_API_KEY=" + key})
	if ask.Question != "Save as vault secret OPENAI_API_KEY?" {
		t.Fatalf("ask %+v", ask)
	}
	v.setNames("OPENAI_API_KEY")
	again := a.answer(context.Background(), intercept{Box: "s1", Text: "OPENAI_API_KEY=" + key}, ask.ID, "y", "")
	if again.Action != "ask" || again.Question != "Save as vault secret OPENAI_API_KEY_2?" || len(v.added) != 0 {
		t.Fatalf("again %+v", again)
	}
	done := a.answer(context.Background(), intercept{Box: "s1", Text: "OPENAI_API_KEY=" + key}, again.ID, "y", "")
	if done.Action != "rewrite" || v.added["OPENAI_API_KEY_2"] != key {
		t.Fatalf("done %+v, added %v", done, v.added)
	}
	if got := done.apply("OPENAI_API_KEY=" + key); got != secrets.Replace("OPENAI_API_KEY="+key, key, "OPENAI_API_KEY_2") {
		t.Fatalf("sent %q", got)
	}
	// The next secret's question knows the name just saved.
	if next := a.intercept(intercept{Box: "s1", Text: "OPENAI_API_KEY=" + key + "x"}); next.Question != "Save as vault secret OPENAI_API_KEY_3?" {
		t.Fatalf("next %+v", next)
	}
}

// input is a message from a rush that shows a line to type.
func input(box, text string) intercept {
	return intercept{Box: box, Text: text, Asks: []string{askInput}}
}

// The first question is only whether to save the secret, named by its
// first characters and length; a yes asks for its name in a line that
// starts as the one suggested, and enter saves under what was typed.
func TestSaveThenName(t *testing.T) {
	v := &fakeVault{}
	a := newApp(v)
	in := input("s1", "deploy with "+key+" please")
	ask := a.intercept(in)
	if ask.Action != "ask" || ask.Question != "Save this secret to the vault?" || ask.Input != nil ||
		!strings.Contains(ask.Detail, "sk-p… 56 chars") || strings.Contains(ask.Question+ask.Detail, "OPENAI") || strings.Contains(ask.Detail, key) {
		t.Fatalf("ask %+v", ask)
	}
	name := a.answer(context.Background(), in, ask.ID, "y", "")
	if name.Action != "ask" || name.Input == nil || name.Input.Value != "OPENAI_API_KEY" || name.Input.Error != "" || name.Input.Enter != "save" ||
		!strings.Contains(name.Question, "sk-p… 56 chars") || len(name.Choices) != 1 || !name.Choices[0].Esc || len(v.added) != 0 {
		t.Fatalf("name %+v, input %+v", name, name.Input)
	}
	done := a.answer(context.Background(), in, name.ID, keyEnter, " DEPLOY_KEY ")
	if done.Action != "rewrite" || v.added["DEPLOY_KEY"] != key || len(v.added) != 1 {
		t.Fatalf("done %+v, added %v", done, v.added)
	}
	if got := done.apply(in.Text); got != secrets.Replace(in.Text, key, "DEPLOY_KEY") {
		t.Fatalf("sent %q", got)
	}
}

// A name that can't be one, or that the vault has already, keeps the
// question up with why and what was typed; nothing is saved meanwhile.
func TestBadNameAsksAgain(t *testing.T) {
	v := &fakeVault{names: []string{"TAKEN"}}
	a := newApp(v)
	in := input("s1", "use "+key)
	q := a.answer(context.Background(), in, a.intercept(in).ID, "y", "")
	for _, c := range []struct{ typed, why string }{
		{"", "give it a name"},
		{"my key", "letters, digits and _"},
		{"1KEY", "doesn't start with a digit"},
		{"a/b", "letters, digits and _"},
		{strings.Repeat("A", 129), "at most 128"},
	} {
		q = a.answer(context.Background(), in, q.ID, keyEnter, c.typed)
		if q.Action != "ask" || q.Input == nil || q.Input.Value != c.typed || !strings.Contains(q.Input.Error, c.why) || len(v.added) != 0 {
			t.Fatalf("%q: %+v, input %+v, added %v", c.typed, q, q.Input, v.added)
		}
	}
	if done := a.answer(context.Background(), in, q.ID, keyEnter, "my_key"); done.Action != "rewrite" || v.added["my_key"] != key {
		t.Fatalf("done %+v, added %v", done, v.added)
	}
}

// The line starts as a name that's free: the one suggested, or the next
// after it when the vault has that one.
func TestSuggestedNameIsFree(t *testing.T) {
	v := &fakeVault{names: []string{"OPENAI_API_KEY"}}
	a := newApp(v)
	a.names = []string{"OPENAI_API_KEY"}
	in := input("s1", "use "+key)
	if q := a.answer(context.Background(), in, a.intercept(in).ID, "y", ""); q.Input == nil || q.Input.Value != "OPENAI_API_KEY_2" {
		t.Fatalf("got %+v", q.Input)
	}
}

// esc in the name goes back to whether to save it; n there sends it as it
// is.
func TestBackFromTheName(t *testing.T) {
	v := &fakeVault{}
	a := newApp(v)
	in := input("s1", "use "+key)
	name := a.answer(context.Background(), in, a.intercept(in).ID, "y", "")
	back := a.answer(context.Background(), in, name.ID, "b", "")
	if back.Action != "ask" || back.Input != nil || back.Question != "Save this secret to the vault?" {
		t.Fatalf("back %+v", back)
	}
	if r := a.answer(context.Background(), in, back.ID, "n", ""); r.Action != "allow" || len(v.added) != 0 {
		t.Fatalf("n = %+v, added %v", r, v.added)
	}
}

// Several secrets in a message are each asked about and named, in order;
// a secret already saved leaves the message before the next is asked
// about.
func TestSecretsAreNamedInOrder(t *testing.T) {
	v := &fakeVault{}
	a := newApp(v)
	gh := "ghp_" + strings.Repeat("Zq7Wx3Rt9", 4)
	in := input("s1", key+" and "+gh)
	save := a.intercept(in)
	name := a.answer(context.Background(), in, save.ID, "y", "")
	next := a.answer(context.Background(), in, name.ID, keyEnter, "FIRST")
	if next.Action != "ask" || next.Input != nil || !strings.Contains(next.Detail, "ghp_… 40 chars") || len(next.Replace) != 1 {
		t.Fatalf("next %+v", next)
	}
	in.Text = next.apply(in.Text)
	if strings.Contains(in.Text, key) || !strings.Contains(in.Text, gh) {
		t.Fatalf("the first is out of the message: %q", in.Text)
	}
	name = a.answer(context.Background(), in, next.ID, "y", "")
	if name.Input == nil || name.Input.Value != "GITHUB_TOKEN" {
		t.Fatalf("name %+v", name.Input)
	}
	done := a.answer(context.Background(), in, name.ID, keyEnter, "SECOND")
	sent := done.apply(in.Text)
	if done.Action != "rewrite" || v.added["FIRST"] != key || v.added["SECOND"] != gh ||
		!strings.HasPrefix(sent, "{{vault:FIRST}} and {{vault:SECOND}}") {
		t.Fatalf("done %+v, sent %q, added %v", done, sent, v.added)
	}
}

// stored is a vault that holds name with value, and the plugin on it with
// the vault's names listed, as they are once a secret was typed.
func stored(name, value string, replaceErr ...error) (*fakeVault, *app) {
	v := &fakeVault{names: []string{name}, held: map[string]string{name: value}, replaceErr: replaceErr}
	a := newApp(v)
	a.names, a.namesAt = []string{name}, time.Now()
	return v, a
}

// A name typed that the vault already holds asks whether to replace its
// value: r replaces it, keeping the name, and the message goes with its
// reference. Nothing is added under another name.
func TestTypedStoredNameAsksToReplace(t *testing.T) {
	v, a := stored("METABASE_API_KEY", "the-old-value")
	in := input("s1", "METABASE_API_KEY="+key)
	name := a.answer(context.Background(), in, a.intercept(in).ID, "y", "")
	if name.Input == nil || name.Input.Value != "METABASE_API_KEY_2" {
		t.Fatalf("name %+v, input %+v", name, name.Input)
	}
	ask := a.answer(context.Background(), in, name.ID, keyEnter, "METABASE_API_KEY")
	if ask.Action != "ask" || ask.Input != nil || ask.Question != "METABASE_API_KEY is already in the vault. Replace its value?" ||
		!strings.Contains(ask.Detail, "keeps its tier") || len(v.replaced) != 0 || len(v.added) != 0 {
		t.Fatalf("ask %+v, replaced %v, added %v", ask, v.replaced, v.added)
	}
	if len(ask.Choices) != 2 || ask.Choices[0].Key != "r" || ask.Choices[0].Enter || !ask.Choices[1].Esc {
		t.Fatalf("choices %+v", ask.Choices)
	}
	done := a.answer(context.Background(), in, ask.ID, "r", "")
	if done.Action != "rewrite" || !slices.Equal(v.replaced, []string{"METABASE_API_KEY"}) || v.held["METABASE_API_KEY"] != key || len(v.added) != 0 {
		t.Fatalf("done %+v, replaced %v, held %v, added %v", done, v.replaced, v.held, v.added)
	}
	if got := done.apply(in.Text); got != secrets.Replace(in.Text, key, "METABASE_API_KEY") {
		t.Fatalf("sent %q", got)
	}
}

// Saying no to the replace goes back to the name, which starts as the
// free one again; the stored secret is left alone.
func TestAnotherNameInsteadOfReplacing(t *testing.T) {
	v, a := stored("METABASE_API_KEY", "the-old-value")
	in := input("s1", "METABASE_API_KEY="+key)
	name := a.answer(context.Background(), in, a.intercept(in).ID, "y", "")
	ask := a.answer(context.Background(), in, name.ID, keyEnter, "METABASE_API_KEY")
	back := a.answer(context.Background(), in, ask.ID, "n", "")
	if back.Action != "ask" || back.Input == nil || back.Input.Value != "METABASE_API_KEY_2" || back.Input.Error != "" {
		t.Fatalf("back %+v, input %+v", back, back.Input)
	}
	done := a.answer(context.Background(), in, back.ID, keyEnter, "METABASE_API_KEY_2")
	if done.Action != "rewrite" || v.added["METABASE_API_KEY_2"] != key || len(v.replaced) != 0 || v.held["METABASE_API_KEY"] != "the-old-value" {
		t.Fatalf("done %+v, added %v, replaced %v", done, v.added, v.replaced)
	}
}

// A name typed that already holds this very value is used as it is: no
// question, nothing saved or replaced.
func TestTypedStoredNameWithTheSameValue(t *testing.T) {
	v, a := stored("METABASE_API_KEY", key)
	in := input("s1", "METABASE_API_KEY="+key)
	name := a.answer(context.Background(), in, a.intercept(in).ID, "y", "")
	done := a.answer(context.Background(), in, name.ID, keyEnter, "METABASE_API_KEY")
	if done.Action != "rewrite" || len(v.added) != 0 || len(v.replaced) != 0 {
		t.Fatalf("done %+v, added %v, replaced %v", done, v.added, v.replaced)
	}
	if got := done.apply(in.Text); got != secrets.Replace(in.Text, key, "METABASE_API_KEY") {
		t.Fatalf("sent %q", got)
	}
}

// A replace the vault hasn't had approved yet leaves a question to look
// again, with nothing sent; looking again takes the approval, and backing
// out keeps the message in the box.
func TestReplaceWaitsForTheApproval(t *testing.T) {
	v, a := stored("METABASE_API_KEY", "the-old-value", errWaiting, errWaiting, nil)
	in := input("s1", "METABASE_API_KEY="+key)
	name := a.answer(context.Background(), in, a.intercept(in).ID, "y", "")
	ask := a.answer(context.Background(), in, name.ID, keyEnter, "METABASE_API_KEY")
	wait := a.answer(context.Background(), in, ask.ID, "r", "")
	if wait.Action != "ask" || wait.Question != "Waiting for your approval to replace METABASE_API_KEY" || len(v.replaced) != 0 ||
		len(wait.Choices) != 2 || !wait.Choices[0].Enter || !wait.Choices[1].Esc {
		t.Fatalf("wait %+v", wait)
	}
	wait = a.answer(context.Background(), in, wait.ID, "y", "")
	if wait.Action != "ask" || wait.Question != "Waiting for your approval to replace METABASE_API_KEY" {
		t.Fatalf("still waiting %+v", wait)
	}
	done := a.answer(context.Background(), in, wait.ID, "y", "")
	if done.Action != "rewrite" || v.held["METABASE_API_KEY"] != key || !strings.Contains(done.apply(in.Text), "{{vault:METABASE_API_KEY}}") {
		t.Fatalf("done %+v, held %v", done, v.held)
	}

	_, a = stored("METABASE_API_KEY", "the-old-value", errWaiting)
	name = a.answer(context.Background(), in, a.intercept(in).ID, "y", "")
	ask = a.answer(context.Background(), in, name.ID, keyEnter, "METABASE_API_KEY")
	wait = a.answer(context.Background(), in, ask.ID, "r", "")
	if back := a.answer(context.Background(), in, wait.ID, "n", ""); back.Action != "block" || !strings.Contains(back.Reason, "still in the box") {
		t.Fatalf("back %+v", back)
	}
}

// A replace the vault denies says why, and never sends the secret on its own.
func TestDeniedReplace(t *testing.T) {
	_, a := stored("METABASE_API_KEY", "the-old-value", errors.New("denied by Rogerio"))
	in := input("s1", "METABASE_API_KEY="+key)
	name := a.answer(context.Background(), in, a.intercept(in).ID, "y", "")
	ask := a.answer(context.Background(), in, name.ID, keyEnter, "METABASE_API_KEY")
	r := a.answer(context.Background(), in, ask.ID, "r", "")
	if r.Action != "ask" || r.Question != "Couldn't save the secret to the vault" || !strings.Contains(r.Detail, "denied by Rogerio") {
		t.Fatalf("got %+v", r)
	}
}

// The same secret sent again starts as the name it was saved under, and
// that name is taken without saving it twice.
func TestSameSecretAgain(t *testing.T) {
	v := &fakeVault{}
	a := newApp(v)
	in := input("s1", "use "+key)
	q := a.answer(context.Background(), in, a.intercept(in).ID, "y", "")
	a.answer(context.Background(), in, q.ID, keyEnter, "MINE")
	v.mu.Lock()
	v.added = nil
	v.mu.Unlock()
	q = a.answer(context.Background(), in, a.intercept(in).ID, "y", "")
	if q.Input == nil || q.Input.Value != "MINE" {
		t.Fatalf("got %+v", q.Input)
	}
	if done := a.answer(context.Background(), in, q.ID, keyEnter, "MINE"); done.Action != "rewrite" || len(v.added) != 0 ||
		!strings.Contains(done.apply(in.Text), "{{vault:MINE}}") {
		t.Fatalf("done %+v, added %v", done, v.added)
	}
}

// A save that fails after the name was typed says why, and never sends
// the secret on its own.
func TestFailedSaveAfterNaming(t *testing.T) {
	v := &fakeVault{addErr: errors.New("the master is not running")}
	a := newApp(v)
	in := input("s1", "use "+key)
	q := a.answer(context.Background(), in, a.intercept(in).ID, "y", "")
	r := a.answer(context.Background(), in, q.ID, keyEnter, "MINE")
	if r.Action != "ask" || r.Input != nil || r.Question != "Couldn't save the secret to the vault" || !strings.Contains(r.Detail, "the master is not running") {
		t.Fatalf("got %+v", r)
	}
	if back := a.answer(context.Background(), in, r.ID, "n", ""); back.Action != "block" {
		t.Fatalf("n after a failure = %+v", back)
	}
}

// A secret you let go isn't asked about again in that box until it's sent
// or cleared.
func TestLetGoUntilSent(t *testing.T) {
	a := newApp(&fakeVault{})
	in := intercept{Box: "s1", Text: "use " + key}
	ask := a.intercept(in)
	if r := a.answer(context.Background(), in, ask.ID, "n", ""); r.Action != "allow" {
		t.Fatalf("n = %+v", r)
	}
	if r := a.intercept(in); r.Action != "allow" {
		t.Fatalf("asked again: %+v", r)
	}
	if r := a.intercept(intercept{Box: "s2", Text: in.Text}); r.Action != "ask" {
		t.Fatal("another box is asked")
	}
	a.event(uiEvent{Kind: evInputSent, Session: &uiSession{ID: "s1"}})
	if r := a.intercept(in); r.Action != "ask" {
		t.Fatal("sent, the box is asked about again")
	}
}

func TestMissingVault(t *testing.T) {
	a := newApp(&fakeVault{lsErr: errors.New("kv isn't installed: Kanban Code installs it in ~/.local/bin")})
	in := intercept{Text: "use " + key}
	ask := a.intercept(in)
	r := a.answer(context.Background(), in, ask.ID, "y", "")
	if r.Action != "ask" || r.Question != "Couldn't save the secret to the vault" || !strings.Contains(r.Detail, "kv isn't installed") {
		t.Fatalf("got %+v", r)
	}
	if back := a.answer(context.Background(), in, r.ID, "n", ""); back.Action != "block" {
		t.Fatalf("n after a failure = %+v", back)
	}
}

func TestStaleQuestion(t *testing.T) {
	a := newApp(&fakeVault{})
	if r := a.answer(context.Background(), intercept{Text: key}, "nope", "y", ""); r.Action != "block" {
		t.Fatalf("got %+v", r)
	}
}

func TestHint(t *testing.T) {
	if h := hint(key); h != "sk-p… 56 chars" {
		t.Fatal(h)
	}
}

// swap says secrets.Replace as a replacement and what it appends, a usage
// line under one already there.
func TestSwap(t *testing.T) {
	text := "a " + key
	once := swap(text, key, "A").apply(text)
	if once != secrets.Replace(text, key, "A") {
		t.Fatalf("once %q", once)
	}
	other := "ghp_" + strings.Repeat("Zq7Wx3Rt9", 4)
	twice := swap(once+" "+other, other, "B")
	if !strings.HasPrefix(twice.Append, "\n") || twice.apply(once+" "+other) != secrets.Replace(once+" "+other, other, "B") {
		t.Fatalf("twice %+v", twice)
	}
}

// The plugin over its connection, with the test as rush: a pasted key is
// asked about, y saves it with kv (run by rush's exec, given the key on
// stdin) and the message goes with its reference and the line on using it.
func TestOverTheWire(t *testing.T) {
	mine, theirs := net.Pipe()
	plug := serve(theirs)
	t.Cleanup(func() { mine.Close(); plug.Close() })

	var mu sync.Mutex
	stored := map[string]string{"OPENAI_API_KEY": "taken"}
	var notes []string
	rush := newConn(mine, func(_ context.Context, method string, params json.RawMessage) (any, error) {
		mu.Lock()
		defer mu.Unlock()
		switch method {
		case "exec":
			var in struct {
				Name  string   `json:"name"`
				Args  []string `json:"args"`
				Stdin string   `json:"stdin"`
			}
			_ = json.Unmarshal(params, &in)
			if in.Name != "kv" {
				return nil, errors.New("not in the manifest: " + in.Name)
			}
			switch in.Args[0] {
			case "ls":
				var list []map[string]string
				for n := range stored {
					list = append(list, map[string]string{"name": n})
				}
				b, _ := json.Marshal(list)
				return execOut{Stdout: string(b)}, nil
			case "add":
				if !slices.Contains(in.Args, "judged") {
					return execOut{Code: 2, Stderr: "kv: no tier"}, nil
				}
				stored[in.Args[1]] = in.Stdin
				return execOut{}, nil
			}
			return execOut{Code: 2, Stderr: "kv: no such command"}, nil
		case "ui.notify":
			var in struct{ Text string }
			_ = json.Unmarshal(params, &in)
			notes = append(notes, in.Text)
			return map[string]any{}, nil
		}
		return nil, errors.New("unexpected " + method)
	})
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()

	text := "deploy with " + key + " please"
	var ask interceptResult
	if err := rush.Call(ctx, "ui.intercept", intercept{Hook: "before-send", UI: "main", Box: "s1", Text: text}, &ask); err != nil {
		t.Fatal(err)
	}
	if ask.Action != "ask" || !strings.HasPrefix(ask.Question, "Save as vault secret OPENAI_API_KEY") || strings.Contains(ask.Detail, key) {
		t.Fatalf("ask = %+v", ask)
	}
	// Asked before the vault's names were listed, it offers the name again
	// once a save finds it taken.
	res := ask
	for range 2 {
		q := res
		answer := map[string]any{"hook": "before-send", "ui": "main", "box": "s1", "text": q.apply(text), "id": q.ID, "key": "y"}
		if err := rush.Call(ctx, "ui.intercept.answer", answer, &res); err != nil {
			t.Fatal(err)
		}
		if res.Action != "ask" {
			break
		}
		if res.Question != "Save as vault secret OPENAI_API_KEY_2?" {
			t.Fatalf("offered again = %+v", res)
		}
	}
	sent := res.apply(text)
	if res.Action != "rewrite" || strings.Contains(sent, key) || !strings.Contains(sent, "deploy with {{vault:OPENAI_API_KEY_2}} please") ||
		!strings.Contains(sent, "kv run OPENAI_API_KEY_2") {
		t.Fatalf("after y = %+v", res)
	}
	mu.Lock()
	was := stored["OPENAI_API_KEY_2"]
	mu.Unlock()
	if was != key {
		t.Fatalf("kv was given %q", was)
	}

	// A rush that shows a line to type is asked whether to save, then for
	// the name, and kv gets the secret under the name typed.
	other := "ghp_" + strings.Repeat("Zq7Wx3Rt9", 4)
	text = "and " + other
	asks := []string{askInput}
	if err := rush.Call(ctx, "ui.intercept", intercept{Hook: "before-send", UI: "main", Box: "s2", Text: text, Asks: asks}, &ask); err != nil {
		t.Fatal(err)
	}
	if ask.Action != "ask" || ask.Input != nil || strings.Contains(ask.Question, "GITHUB") {
		t.Fatalf("ask = %+v", ask)
	}
	var name interceptResult
	if err := rush.Call(ctx, "ui.intercept.answer", map[string]any{"box": "s2", "text": text, "asks": asks, "id": ask.ID, "key": "y"}, &name); err != nil {
		t.Fatal(err)
	}
	if name.Action != "ask" || name.Input == nil || name.Input.Value != "GITHUB_TOKEN" {
		t.Fatalf("name = %+v", name)
	}
	res = interceptResult{}
	if err := rush.Call(ctx, "ui.intercept.answer", map[string]any{"box": "s2", "text": text, "asks": asks, "id": name.ID, "key": "enter", "value": "DEPLOY_TOKEN"}, &res); err != nil {
		t.Fatal(err)
	}
	mu.Lock()
	defer mu.Unlock()
	if res.Action != "rewrite" || res.apply(text) != secrets.Replace(text, other, "DEPLOY_TOKEN") || stored["DEPLOY_TOKEN"] != other {
		t.Fatalf("after the name = %+v", res)
	}
}
