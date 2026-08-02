import { describe, test } from "node:test";
import { strict as assert } from "node:assert";
import { existsSync, mkdtempSync, mkdirSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import {
  appliesModelSwitchDirectly,
  assertOwnedSubagent,
  buildSubagentPrompt,
  modelSwitchCommand,
  needsModelSwitchConfirmation,
  depthLimitError,
  descendantIds,
  kanbanCodeIsRunning,
  makeSubagentRequest,
  missingForkSessionError,
  normalizeMaximumDepth,
  normalizeSubagentHandle,
  resolveSubagentPrompt,
  subagentDepth,
  subagentRelationship,
  submitSubagentRequest,
} from "./subagents.js";
import { deriveHandle } from "./handles.js";
import { formatCardSummary } from "./format.js";
import type { CardSummary, Link } from "./types.js";

function card(id: string, parentCardId?: string): Link {
  return {
    id,
    parentCardId,
    column: "in_progress",
    createdAt: new Date().toISOString(),
    updatedAt: new Date().toISOString(),
    manualOverrides: {
      worktreePath: false,
      tmuxSession: false,
      name: false,
      column: false,
      prLink: false,
      issueLink: false,
    },
    manuallyArchived: false,
    source: "manual",
    isRemote: false,
  };
}

describe("subagent hierarchy", () => {
  test("computes depth, descendants, and ownership recursively", () => {
    const root = card("root");
    const child = card("child", root.id);
    const grandchild = card("grandchild", child.id);
    const links = [root, child, grandchild];
    assert.equal(subagentDepth(root.id, links), 0);
    assert.equal(subagentDepth(grandchild.id, links), 2);
    assert.deepEqual(descendantIds(root.id, links), new Set([child.id, grandchild.id]));
    assert.doesNotThrow(() => assertOwnedSubagent(root, grandchild, links));
    assert.throws(() => assertOwnedSubagent(child, root, links), /not a subagent owned/);
  });

  test("bootstrap prompt teaches reporting and self-archive", () => {
    const prompt = buildSubagentPrompt({ ...card("root"), name: "Parent" }, "Investigate the bug");
    assert.match(prompt, /kanban parent dm <message>/);
    assert.match(prompt, /kanban parent dm-and-self-archive <message>/);
    assert.match(prompt, /Investigate the bug/);
  });

  test("bootstrap prompt explains the per-card compaction threshold", () => {
    const prompt = buildSubagentPrompt(
      { ...card("root"), name: "Parent" },
      "Investigate the bug",
      250_000
    );
    assert.match(prompt, /250k context threshold/);
    assert.match(prompt, /kanban self-compact/);
    assert.match(prompt, /post-compact continuation message/);
    assert.match(prompt, /steered reminder mid-turn at 350k/);
    assert.match(prompt, /interrupt with a forced \/compact at 450k/);
  });

  test("depth error is explicit", () => {
    assert.equal(
      depthLimitError(1),
      "You already reached the user-defined maximum subagent depth of 1. You cannot spawn another subagent. Do the work yourself."
    );
  });

  test("does not deep-link a running app, which would steal focus", () => {
    const opened: string[] = [];
    const notifyIfNotRunning = (running: boolean) => {
      if (running) return;
      opened.push("open");
    };
    notifyIfNotRunning(true);
    assert.deepEqual(opened, []);
    notifyIfNotRunning(false);
    assert.deepEqual(opened, ["open"]);
    assert.equal(typeof kanbanCodeIsRunning(), "boolean");
  });

  test("labels a sender as parent or subagent relative to the receiver", () => {
    const root = card("root");
    const child = card("child", root.id);
    const grandchild = card("grandchild", child.id);
    const stranger = card("stranger");
    const links = [root, child, grandchild, stranger];
    assert.equal(subagentRelationship(root.id, child.id, links), "parent");
    assert.equal(subagentRelationship(root.id, grandchild.id, links), "parent");
    assert.equal(subagentRelationship(child.id, root.id, links), "subagent");
    assert.equal(subagentRelationship(grandchild.id, root.id, links), "subagent");
    assert.equal(subagentRelationship(stranger.id, child.id, links), undefined);
    assert.equal(subagentRelationship(child.id, child.id, links), undefined);
    assert.equal(subagentRelationship(null, child.id, links), undefined);
  });

  test("model switching matches how each assistant reads /model", () => {
    assert.equal(modelSwitchCommand("opus"), "/model opus");
    assert.equal(modelSwitchCommand("/model opus"), "/model opus");
    assert.equal(modelSwitchCommand("sonnet", "claude"), "/model sonnet");
    // Codex takes no argument and opens a picker, so a name there would be
    // submitted as an ordinary prompt.
    assert.equal(modelSwitchCommand("gpt-5", "codex"), "/model");
    assert.equal(appliesModelSwitchDirectly("codex"), false);
    assert.equal(appliesModelSwitchDirectly("claude"), true);
    assert.throws(() => modelSwitchCommand("  "), /model name is required/);
  });

  test("the mid-conversation switch dialog is recognised", () => {
    const dialog = [
      "Switch model?",
      "This conversation is cached for the current model.",
      "❯ 1. Yes, switch to Sonnet 5",
      "  2. No, go back",
    ].join("\n");

    assert.ok(needsModelSwitchConfirmation(dialog));
    assert.ok(!needsModelSwitchConfirmation("⎿  Set model to Opus 5 and saved as your default"));
    assert.ok(!needsModelSwitchConfirmation("❯ "));
  });

  test("missing fork transcript recommends a new spawn", () => {
    assert.equal(
      missingForkSessionError("root"),
      "Card root has no session to fork. Use `kanban subagent spawn` to start a new child instead."
    );
  });

  test("handles are normalized into readable slugs", () => {
    assert.equal(normalizeSubagentHandle("parser-bug"), "parser-bug");
    assert.equal(normalizeSubagentHandle("@Cache Path"), "cache_path");
    assert.equal(
      normalizeSubagentHandle("a-very-long-handle-that-exceeds-the-maximum-length"),
      "a-very-long-handle-that"
    );
    assert.throws(() => normalizeSubagentHandle("!!!"), /no letters or digits/);
  });

  test("a dashed handle stays dashed as a card name and a chat handle", () => {
    const handle = normalizeSubagentHandle("hi-tester");

    assert.equal(handle, "hi-tester");
    // The card is named after the handle and the chat handle is derived back
    // from that name, so slugifying has to be a no-op or the two drift apart.
    assert.equal(deriveHandle(handle, new Set()), handle);
  });

  test("bootstrap prompt states the child handle", () => {
    const prompt = buildSubagentPrompt(
      { ...card("root"), name: "Parent" },
      "Investigate the bug",
      undefined,
      "parser_bug"
    );
    assert.match(prompt, /Your chat handle is @parser_bug\./);
  });

  test("configured depth is bounded", () => {
    assert.equal(normalizeMaximumDepth(undefined), 1);
    assert.equal(normalizeMaximumDepth(-2), 0);
    assert.equal(normalizeMaximumDepth(99), 5);
  });

  test("multiline stdin preserves shell metacharacters and trailing whitespace", () => {
    const prompt = "line with `backticks` and $HOME\n'quotes' \n\n";
    assert.equal(resolveSubagentPrompt(["-"], prompt), prompt);
    assert.equal(resolveSubagentPrompt([], prompt), prompt);
    assert.equal(resolveSubagentPrompt(["positional", "$value"], "ignored"), "positional $value");
  });
});

describe("subagent command transport", () => {
  test("round-trips a response through the app inbox protocol", async () => {
    const home = mkdtempSync(join(tmpdir(), "kanban-subagent-command-"));
    const old = process.env.KANBAN_CODE_HOME;
    process.env.KANBAN_CODE_HOME = home;
    try {
      const request = makeSubagentRequest("spawn", "root", {
        prompt: "hello",
        contextThresholdTokens: 250_000,
      });
      const response = await submitSubagentRequest(request, {
        timeoutMs: 2_000,
        notify: (id) => {
          const persisted = JSON.parse(
            readFileSync(join(home, "commands", "inbox", `${id}.json`), "utf8")
          );
          assert.equal(persisted.contextThresholdTokens, 250_000);
          const responses = join(home, "commands", "responses");
          mkdirSync(responses, { recursive: true });
          writeFileSync(join(responses, `${id}.json`), JSON.stringify({ id, ok: true, cardId: "child" }));
        },
      });
      assert.equal(response.cardId, "child");
      assert.equal(request.contextThresholdTokens, 250_000);
    } finally {
      if (old === undefined) delete process.env.KANBAN_CODE_HOME;
      else process.env.KANBAN_CODE_HOME = old;
      rmSync(home, { recursive: true, force: true });
    }
  });

  test("removes an unclaimed request after timeout", async () => {
    const home = mkdtempSync(join(tmpdir(), "kanban-subagent-timeout-"));
    const old = process.env.KANBAN_CODE_HOME;
    process.env.KANBAN_CODE_HOME = home;
    try {
      const request = makeSubagentRequest("spawn", "root", { prompt: "hello" });
      await assert.rejects(
        submitSubagentRequest(request, { timeoutMs: 20, notify: () => {} }),
        /within 1 seconds/
      );
      assert.equal(
        existsSync(join(home, "commands", "inbox", `${request.id}.json`)),
        false
      );
    } finally {
      if (old === undefined) delete process.env.KANBAN_CODE_HOME;
      else process.env.KANBAN_CODE_HOME = old;
      rmSync(home, { recursive: true, force: true });
    }
  });
});

describe("subagent list presentation", () => {
  test("shows hierarchy, assistant, model, token usage, and context", () => {
    const summary: CardSummary = {
      id: "child",
      name: "Investigate parser",
      column: "in_progress",
      assistant: "claude",
      modelOverride: "sonnet",
      selfCompactContextThresholdTokens: 250_000,
      subagentDepth: 1,
      tmuxAlive: true,
      prs: [],
      queuedPrompts: 0,
      isRemote: false,
      tokens: {
        input: 420_000,
        output: 10_000,
        cost: 1.25,
        context: { used: 430_000, max: 1_000_000, percentage: "43%" },
      },
    };

    const rendered = formatCardSummary(summary);
    assert.match(rendered, /depth:1/);
    assert.match(rendered, /claude/);
    assert.match(rendered, /model:sonnet/);
    assert.match(rendered, /compact:250k/);
    assert.match(rendered, /430k tok \$1\.25/);
    assert.match(rendered, /430k\/1\.0M ctx \(43%\)/);
  });
});
