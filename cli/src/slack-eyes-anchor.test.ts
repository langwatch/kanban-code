import { test, describe, beforeEach, afterEach } from "node:test";
import { strict as assert } from "node:assert";
import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

import { writeEyesAnchor, readEyesAnchor, clearEyesAnchor } from "./slack/eyes-anchor.js";

let home: string;
const origHome = process.env.HOME;
beforeEach(() => {
  home = mkdtempSync(join(tmpdir(), "kanban-eyes-anchor-"));
  process.env.HOME = home;
});
afterEach(() => {
  rmSync(home, { recursive: true, force: true });
  if (origHome === undefined) delete process.env.HOME;
  else process.env.HOME = origHome;
});

describe("eyes-anchor persistence", () => {
  test("write -> read round-trips channelId and ts", () => {
    writeEyesAnchor("agent-x", { channelId: "C1234", ts: "1780000000.123" });
    const back = readEyesAnchor("agent-x");
    assert.deepEqual(back, { channelId: "C1234", ts: "1780000000.123" });
  });

  test("read returns undefined for an unknown slug", () => {
    assert.equal(readEyesAnchor("never-written"), undefined);
  });

  test("clear removes the persisted file so subsequent read is undefined", () => {
    writeEyesAnchor("agent-y", { channelId: "C1", ts: "1.2" });
    clearEyesAnchor("agent-y");
    assert.equal(readEyesAnchor("agent-y"), undefined);
  });

  test("clear is idempotent on an absent slug", () => {
    clearEyesAnchor("never-written");
    assert.equal(readEyesAnchor("never-written"), undefined);
  });

  test("read rejects records missing channelId or ts so a bad file doesn't crash the bridge", () => {
    // Write a malformed payload (no ts) directly using writeEyesAnchor's path
    // by casting: the helper itself enforces fields. Simulate corruption by
    // writing a record with only channelId.
    writeEyesAnchor("agent-z", { channelId: "C1", ts: "" });
    assert.equal(readEyesAnchor("agent-z"), undefined);
  });
});
