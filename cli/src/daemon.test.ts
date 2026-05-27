import { test, describe, beforeEach, afterEach } from "node:test";
import { strict as assert } from "node:assert";
import { mkdtempSync, rmSync, mkdirSync, writeFileSync, appendFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

import { Daemon, DEFAULT_SELF_COMPACT_RULES } from "./agents/daemon.js";
import { writeLinks, isoNow } from "./cards.js";
import { readLinks } from "./data.js";
import { hookEventsPath, contextDir } from "./paths.js";
import { recordAnnounceSuppress, ANNOUNCE_SUPPRESS_TTL_MS } from "./slack/announce-suppress.js";
import type { Link, QueuedPrompt } from "./types.js";

const SID = "11111111-1111-5111-8111-111111111111";

function card(queued: QueuedPrompt[] = []): Link {
  const now = isoNow();
  return {
    id: "card_d",
    name: "daemon-agent",
    column: "in_progress",
    createdAt: now,
    updatedAt: now,
    manualOverrides: { worktreePath: false, tmuxSession: false, name: true, column: false, prLink: false, issueLink: false },
    manuallyArchived: false,
    source: "manual",
    isRemote: false,
    sessionLink: { sessionId: SID },
    tmuxLink: { sessionName: "daemon-agent" },
    queuedPrompts: queued,
  };
}

function writeContextPct(pct: number, windowSize = 1_000_000): void {
  mkdirSync(contextDir(), { recursive: true });
  writeFileSync(
    join(contextDir(), `${SID}.json`),
    JSON.stringify({ usedPercentage: pct, contextWindowSize: windowSize, totalInputTokens: 0, totalOutputTokens: 0, totalCostUsd: 0, model: "x" })
  );
}

describe("daemon (sandboxed, injected paste)", () => {
  let home: string;
  let pastes: [string, string][];
  function newDaemon() {
    return new Daemon({ selfCompact: { enabled: true }, paste: (s, t) => pastes.push([s, t]) });
  }

  beforeEach(() => {
    home = mkdtempSync(join(tmpdir(), "kanban-daemon-"));
    process.env.KANBAN_CODE_HOME = home;
    process.env.CLAUDE_CONFIG_DIR = join(home, "claude");
    pastes = [];
  });
  afterEach(() => {
    delete process.env.KANBAN_CODE_HOME;
    delete process.env.CLAUDE_CONFIG_DIR;
    rmSync(home, { recursive: true, force: true });
  });

  test("auto-sends an eligible queued prompt on Stop and dequeues it", () => {
    writeLinks([card([{ id: "p1", body: "continue the work", sendAutomatically: true }])]);
    const r = newDaemon().maybeAutoSend(SID, Date.now());
    assert.equal(r.sent, true);
    assert.deepEqual(pastes, [["daemon-agent", "continue the work"]]);
    assert.equal(readLinks()[0].queuedPrompts?.length, 0);
  });

  test("does not auto-send a non-auto prompt", () => {
    writeLinks([card([{ id: "p1", body: "manual only", sendAutomatically: false }])]);
    const r = newDaemon().maybeAutoSend(SID, Date.now());
    assert.equal(r.sent, false);
    assert.equal(r.reason, "no-eligible");
    assert.equal(pastes.length, 0);
  });

  test("a user prompt after the Stop pauses auto-send", () => {
    writeLinks([card([{ id: "p1", body: "go", sendAutomatically: true }])]);
    const d = newDaemon();
    const stopMs = Date.now();
    // A UserPromptSubmit recorded after the stop should block the send.
    appendFileSync(
      hookEventsPath(),
      JSON.stringify({ sessionId: SID, event: "UserPromptSubmit", timestamp: new Date(stopMs + 200).toISOString() }) + "\n"
    );
    d.processEvents();
    const r = d.maybeAutoSend(SID, stopMs);
    assert.equal(r.sent, false);
    assert.equal(r.reason, "user-prompted");
    assert.equal(pastes.length, 0);
  });

  test("drops a stale self-compact warning instead of sending it", () => {
    const warning = DEFAULT_SELF_COMPACT_RULES[0].message; // the 500k warning
    writeLinks([card([{ id: "p1", body: warning, sendAutomatically: true }])]);
    writeContextPct(10); // 100k tokens -> below 500k -> stale
    const r = newDaemon().maybeAutoSend(SID, Date.now());
    assert.equal(r.sent, false);
    assert.equal(r.reason, "dropped-stale");
    assert.equal(pastes.length, 0);
    assert.equal(readLinks()[0].queuedPrompts?.length, 0, "stale warning dropped from queue");
  });

  test("auto-compact queues the crossed warning once (no re-queue)", () => {
    writeLinks([card()]);
    writeContextPct(55); // 550k -> crosses 500k queuePrompt rule
    const d = newDaemon();
    const acted = d.evaluateAutoCompact();
    assert.deepEqual(acted, [{ sessionId: SID, action: "queuePrompt", thresholdTokens: 500_000 }]);
    assert.equal(readLinks()[0].queuedPrompts?.[0].body, DEFAULT_SELF_COMPACT_RULES[0].message);

    const again = d.evaluateAutoCompact();
    assert.equal(again.length, 0, "must not re-trigger the same threshold");
    assert.equal(readLinks()[0].queuedPrompts?.length, 1, "no duplicate queued warning");
  });

  test("auto-compact sends /compact at the hard threshold", () => {
    writeLinks([card()]);
    writeContextPct(80); // 800k -> crosses 750k compactNow rule
    const acted = newDaemon().evaluateAutoCompact();
    assert.deepEqual(acted, [{ sessionId: SID, action: "compactNow", thresholdTokens: 750_000 }]);
    assert.deepEqual(pastes, [["daemon-agent", "/compact"]]);
  });

  test("reads appended hook events incrementally", () => {
    const d = newDaemon();
    appendFileSync(hookEventsPath(), JSON.stringify({ sessionId: SID, event: "SessionStart", timestamp: isoNow() }) + "\n");
    appendFileSync(hookEventsPath(), JSON.stringify({ sessionId: SID, event: "Stop", timestamp: isoNow() }) + "\n");
    assert.equal(d.readNewHookEvents().length, 2);
    assert.equal(d.readNewHookEvents().length, 0, "offset advanced; nothing new");
    appendFileSync(hookEventsPath(), JSON.stringify({ sessionId: SID, event: "Stop", timestamp: isoNow() }) + "\n");
    assert.equal(d.readNewHookEvents().length, 1);
  });
});

describe("daemon: mirror prompts to Slack only on confirmed receipt", () => {
  let home: string;
  let pastes: [string, string][];
  let announces: [string, string][];
  function newDaemon() {
    return new Daemon({
      selfCompact: { enabled: false },
      paste: (s, t) => pastes.push([s, t]),
      announce: (slug, text) => announces.push([slug, text]),
    });
  }
  /// Append a UserPromptSubmit hook line carrying the prompt the way the real
  /// hook does (base64 of the full payload), so the daemon decodes it.
  function writeUserPrompt(sessionId: string, prompt: string, ts = Date.now()): void {
    const payloadB64 = Buffer.from(JSON.stringify({ prompt }), "utf-8").toString("base64");
    appendFileSync(
      hookEventsPath(),
      JSON.stringify({ sessionId, event: "UserPromptSubmit", timestamp: new Date(ts).toISOString(), payloadB64 }) + "\n"
    );
  }

  beforeEach(() => {
    home = mkdtempSync(join(tmpdir(), "kanban-daemon-ann-"));
    process.env.KANBAN_CODE_HOME = home;
    process.env.CLAUDE_CONFIG_DIR = join(home, "claude");
    pastes = [];
    announces = [];
  });
  afterEach(() => {
    delete process.env.KANBAN_CODE_HOME;
    delete process.env.CLAUDE_CONFIG_DIR;
    rmSync(home, { recursive: true, force: true });
  });

  test("announces a prompt with the exact received text on UserPromptSubmit", () => {
    writeLinks([card()]);
    const d = newDaemon();
    writeUserPrompt(SID, "Good morning, list open Dependabot PRs");
    d.processEvents();
    assert.deepEqual(announces, [["daemon-agent", "Good morning, list open Dependabot PRs"]]);
  });

  test("auto-send does not announce at paste time (announce waits for receipt)", () => {
    writeLinks([card([{ id: "p1", body: "continue", sendAutomatically: true }])]);
    const d = newDaemon();
    const r = d.maybeAutoSend(SID, Date.now());
    assert.equal(r.sent, true);
    assert.deepEqual(pastes, [["daemon-agent", "continue"]]);
    assert.deepEqual(announces, [], "no announce until this prompt's own UserPromptSubmit");
  });

  test("a bridge-relayed prompt is not echoed, and its marker is consumed", () => {
    writeLinks([card()]);
    const d = newDaemon();
    recordAnnounceSuppress(SID); // the bridge marks the relay before pasting
    writeUserPrompt(SID, "hey agent, please do X"); // the relayed human text
    d.processEvents();
    assert.deepEqual(announces, [], "relay must not be echoed");
    // The marker was consumed: a subsequent (non-relay) prompt is announced.
    writeUserPrompt(SID, "scheduled nudge");
    d.processEvents();
    assert.deepEqual(announces, [["daemon-agent", "scheduled nudge"]]);
  });

  test("each marker suppresses exactly one received prompt", () => {
    writeLinks([card()]);
    const d = newDaemon();
    recordAnnounceSuppress(SID);
    recordAnnounceSuppress(SID);
    writeUserPrompt(SID, "relay 1");
    writeUserPrompt(SID, "relay 2");
    writeUserPrompt(SID, "automated 3");
    d.processEvents();
    assert.deepEqual(announces, [["daemon-agent", "automated 3"]]);
  });

  test("an expired marker does not suppress a later prompt", () => {
    writeLinks([card()]);
    const d = newDaemon();
    recordAnnounceSuppress(SID, Date.now() - (ANNOUNCE_SUPPRESS_TTL_MS + 1000));
    writeUserPrompt(SID, "automated after a stale marker");
    d.processEvents();
    assert.deepEqual(announces, [["daemon-agent", "automated after a stale marker"]]);
  });

  test("a UserPromptSubmit without a captured prompt is not announced", () => {
    writeLinks([card()]);
    const d = newDaemon();
    appendFileSync(hookEventsPath(), JSON.stringify({ sessionId: SID, event: "UserPromptSubmit", timestamp: isoNow() }) + "\n");
    d.processEvents();
    assert.deepEqual(announces, []);
  });
});
