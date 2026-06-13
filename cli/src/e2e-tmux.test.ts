/**
 * Real tmux integration test for channel fan-out.
 * Spins up 2 real tmux sessions, routes a broadcast through the CLI, and
 * captures each pane to verify the prefixed message arrived and the sender
 * did NOT echo back.
 *
 * Skipped when tmux is unavailable (CI environments without tmux).
 */

import { test, describe, before, after } from "node:test";
import { strict as assert } from "node:assert";
import { execFile, execFileSync, execSync } from "node:child_process";
import { mkdtempSync, rmSync, writeFileSync, mkdirSync, existsSync } from "node:fs";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";

const CLI = resolve(import.meta.dirname, "kanban.ts");

function hasTmux(): boolean {
  try {
    execSync("tmux -V", { stdio: "ignore" });
    return true;
  } catch {
    return false;
  }
}

function runCli(args: string[], env: NodeJS.ProcessEnv = {}): { stdout: string; stderr: string; code: number } {
  try {
    const stdout = execFileSync("npx", ["tsx", CLI, ...args], {
      encoding: "utf-8",
      env: { ...process.env, ...env },
    });
    return { stdout, stderr: "", code: 0 };
  } catch (e: any) {
    return {
      stdout: String(e.stdout ?? ""),
      stderr: String(e.stderr ?? ""),
      code: e.status ?? 1,
    };
  }
}

function tmuxCapture(session: string): string {
  return execSync(`tmux capture-pane -p -t ${session}`, { encoding: "utf-8" });
}

function tmuxKill(session: string): void {
  try { execSync(`tmux kill-session -t ${session}`, { stdio: "ignore" }); } catch {}
}

function tmuxNew(session: string, cwd: string): void {
  execSync(`tmux new-session -d -s ${session} -c ${cwd}`);
}

// This suite drives a real bare shell and asserts on pasted text rendered in
// the pane, so it needs an interactive tmux + shell. Reliable locally; skipped
// in CI where the non-interactive runner does not render pasted keystrokes the
// same way (the deterministic real-tmux coverage lives in launch/reconcile).
const skipReason = !hasTmux()
  ? "tmux unavailable"
  : process.env.CI
    ? "needs an interactive shell; not reliable in CI"
    : false;
const skipIfNoTmux = { skip: skipReason };

describe("broadcast fan-out (real tmux)", skipIfNoTmux, () => {
  let home: string;
  const sess = {
    alice: `kanban-e2e-alice-${Date.now()}`,
    bob: `kanban-e2e-bob-${Date.now()}`,
  };

  before(() => {
    home = mkdtempSync(join(tmpdir(), "kanban-e2e-tmux-"));
    mkdirSync(join(home, ".kanban-code"), { recursive: true });
    tmuxNew(sess.alice, home);
    tmuxNew(sess.bob, home);
    writeFileSync(
      join(home, ".kanban-code", "links.json"),
      JSON.stringify(
        {
          links: [
            {
              id: "card_alice",
              name: "alice-card",
              column: "in_progress",
              createdAt: new Date().toISOString(),
              updatedAt: new Date().toISOString(),
              tmuxLink: { sessionName: sess.alice },
              isRemote: false,
              prLinks: [],
              manualOverrides: {},
              source: "manual",
              manuallyArchived: false,
            },
            {
              id: "card_bob",
              name: "bob-card",
              column: "in_progress",
              createdAt: new Date().toISOString(),
              updatedAt: new Date().toISOString(),
              tmuxLink: { sessionName: sess.bob },
              isRemote: false,
              prLinks: [],
              manualOverrides: {},
              source: "manual",
              manuallyArchived: false,
            },
          ],
        },
        null,
        2
      )
    );
  });

  after(() => {
    tmuxKill(sess.alice);
    tmuxKill(sess.bob);
    rmSync(home, { recursive: true, force: true });
  });

  test("user broadcast reaches both agents' panes with #channel @user prefix", () => {
    const env = { HOME: home };
    runCli(["channel", "create", "demo", "--as-user"], env);
    runCli(["channel", "join", "demo", "--as", "alice", "--as-card-id", "card_alice"], env);
    runCli(["channel", "join", "demo", "--as", "bob", "--as-card-id", "card_bob"], env);

    const r = runCli(["channel", "send", "demo", "standup at 10", "--as-user"], env);
    assert.equal(r.code, 0, r.stderr);

    // Give tmux a beat to process the paste+Enter.
    execSync("sleep 0.5");

    const a = tmuxCapture(sess.alice);
    const b = tmuxCapture(sess.bob);

    // Human handle is derived from the system user (NSUserName / os.userInfo)
    // so the prefix can be any slug. Just match any handle.
    assert.match(a, /Message from #demo @\w+.*standup at 10/);
    assert.match(b, /Message from #demo @\w+.*standup at 10/);
  });

  test("agent broadcast does not echo back to sender", () => {
    const env = { HOME: home };
    // Alice sends as herself via --as. Fan-out should reach bob only.
    runCli(
      ["channel", "send", "demo", "hey bob", "--as", "alice", "--as-card-id", "card_alice"],
      env
    );
    execSync("sleep 0.5");

    const a = tmuxCapture(sess.alice);
    const b = tmuxCapture(sess.bob);

    // Bob receives
    assert.match(b, /Message from #demo @alice.*hey bob/);
    // Alice does NOT see her own broadcast in her pane
    const aLines = a.split("\n");
    const echoed = aLines.some((l) => /Message from #demo @alice.*hey bob/.test(l));
    assert.equal(echoed, false, "sender received their own broadcast back (should be skipped)");
  });

  test("concurrent `kanban send` to two cards never crosses the prompts", async () => {
    // Regression for the cross-process tmux-paste-buffer race that swapped the
    // dependabot-scout and changelog-scribe nudges on Mondays. Two `kanban send`
    // processes pasting at the same wall-clock instant both wrote to tmux's
    // shared anonymous paste buffer; whichever `set-buffer` won the race
    // overwrote the other before either pasted. The fix routes each paste
    // through a uniquely-named buffer so concurrent calls can't collide.
    //
    // Repeat enough times that even a borderline race would surface, then
    // require ALL iterations to land their own text in their own pane.
    const env = { HOME: home };
    const iterations = 5;
    for (let i = 0; i < iterations; i++) {
      const aliceText = `alice-only-${i}-${process.hrtime.bigint()}`;
      const bobText = `bob-only-${i}-${process.hrtime.bigint()}`;
      await Promise.all([
        new Promise<void>((resolve, reject) => {
          const child = execFile("npx", ["tsx", CLI, "send", "card_alice", aliceText], { env: { ...process.env, ...env } });
          child.on("exit", (code) => (code === 0 ? resolve() : reject(new Error(`alice send exited ${code}`))));
        }),
        new Promise<void>((resolve, reject) => {
          const child = execFile("npx", ["tsx", CLI, "send", "card_bob", bobText], { env: { ...process.env, ...env } });
          child.on("exit", (code) => (code === 0 ? resolve() : reject(new Error(`bob send exited ${code}`))));
        }),
      ]);
      execSync("sleep 0.3");
      const a = tmuxCapture(sess.alice);
      const b = tmuxCapture(sess.bob);
      assert.match(a, new RegExp(aliceText), `iteration ${i}: alice pane did not contain its own text`);
      assert.match(b, new RegExp(bobText), `iteration ${i}: bob pane did not contain its own text`);
      assert.equal(a.includes(bobText), false, `iteration ${i}: alice pane received bob's text (paste-buffer race)`);
      assert.equal(b.includes(aliceText), false, `iteration ${i}: bob pane received alice's text (paste-buffer race)`);
    }
  });

  test("DM reaches only the recipient", () => {
    const env = { HOME: home };
    runCli(
      ["dm", "send", "alice", "private hi", "--as", "bob", "--as-card-id", "card_bob"],
      env
    );
    execSync("sleep 0.5");
    const a = tmuxCapture(sess.alice);
    const b = tmuxCapture(sess.bob);
    assert.match(a, /DM from @bob.*private hi/);
    const bot = b.split("\n");
    const echoedOnBob = bot.some((l) => /DM from @bob.*private hi/.test(l));
    assert.equal(echoedOnBob, false);
  });
});
