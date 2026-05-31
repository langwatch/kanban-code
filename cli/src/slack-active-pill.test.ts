import { test, describe, before, after } from "node:test";
import { strict as assert } from "node:assert";
import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

// Point kanbanHome() at a tmp dir BEFORE importing the module under test so the
// persistence files land somewhere disposable per run.
let tmpHome: string;

before(() => {
  tmpHome = mkdtempSync(join(tmpdir(), "kanban-active-pill-"));
  process.env.KANBAN_CODE_HOME = tmpHome;
});
after(() => {
  rmSync(tmpHome, { recursive: true, force: true });
  delete process.env.KANBAN_CODE_HOME;
});

describe("active-pill persistence", () => {
  test("write -> read round-trips the pill state", async () => {
    const { writeActivePill, readActivePill } = await import("./slack/active-pill.js");
    writeActivePill("agent-a", {
      channelId: "C123",
      threadTs: "1730000000.000100",
      label: "is working…",
      lastSetMs: 1730000000000,
    });
    const got = readActivePill("agent-a");
    assert.deepEqual(got, {
      channelId: "C123",
      threadTs: "1730000000.000100",
      label: "is working…",
      lastSetMs: 1730000000000,
    });
  });

  test("read returns undefined for an agent that has never had a pill", async () => {
    const { readActivePill } = await import("./slack/active-pill.js");
    assert.equal(readActivePill("never-existed"), undefined);
  });

  test("clear removes the file so a later read sees nothing", async () => {
    const { writeActivePill, readActivePill, clearActivePill } = await import("./slack/active-pill.js");
    writeActivePill("agent-b", {
      channelId: "C2",
      threadTs: "1.2",
      label: "is working…",
      lastSetMs: 1,
    });
    assert.notEqual(readActivePill("agent-b"), undefined);
    clearActivePill("agent-b");
    assert.equal(readActivePill("agent-b"), undefined);
  });

  test("clear on a missing file is a no-op (does not throw)", async () => {
    const { clearActivePill } = await import("./slack/active-pill.js");
    assert.doesNotThrow(() => clearActivePill("never-existed-also"));
  });

  test("read tolerates a corrupted file (returns undefined)", async () => {
    const { writeFileSync, mkdirSync } = await import("node:fs");
    const { join } = await import("node:path");
    const dir = join(tmpHome, "active-pills");
    mkdirSync(dir, { recursive: true });
    writeFileSync(join(dir, "agent-corrupt"), "not json");
    const { readActivePill } = await import("./slack/active-pill.js");
    assert.equal(readActivePill("agent-corrupt"), undefined);
  });

  test("read rejects partial records (missing required fields)", async () => {
    const { writeFileSync, mkdirSync } = await import("node:fs");
    const { join } = await import("node:path");
    const dir = join(tmpHome, "active-pills");
    mkdirSync(dir, { recursive: true });
    writeFileSync(
      join(dir, "agent-partial"),
      JSON.stringify({ channelId: "C", threadTs: "1.0" }), // missing label + lastSetMs
    );
    const { readActivePill } = await import("./slack/active-pill.js");
    assert.equal(readActivePill("agent-partial"), undefined);
  });
});
