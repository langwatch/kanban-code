import { test, describe, beforeEach, afterEach } from "node:test";
import { strict as assert } from "node:assert";
import { mkdtempSync, rmSync, existsSync, readFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

import { recordAnnounceSuppress, announceSuppressPath } from "./slack/announce-suppress.js";

describe("announce-suppress store", () => {
  let home: string;
  beforeEach(() => {
    home = mkdtempSync(join(tmpdir(), "kanban-suppress-"));
    process.env.KANBAN_CODE_HOME = home;
  });
  afterEach(() => {
    delete process.env.KANBAN_CODE_HOME;
    rmSync(home, { recursive: true, force: true });
  });

  test("records a marker line keyed by session with a timestamp", () => {
    recordAnnounceSuppress("sess-1", 1234);
    const lines = readFileSync(announceSuppressPath(), "utf-8").trim().split("\n");
    assert.equal(lines.length, 1);
    const o = JSON.parse(lines[0]);
    assert.equal(o.sessionId, "sess-1");
    assert.equal(o.ts, 1234);
  });

  test("ignores an empty session id (nothing to suppress)", () => {
    recordAnnounceSuppress("", 1);
    assert.equal(existsSync(announceSuppressPath()), false);
  });

  test("appends rather than overwrites, so the daemon can tail it", () => {
    recordAnnounceSuppress("a", 1);
    recordAnnounceSuppress("b", 2);
    const lines = readFileSync(announceSuppressPath(), "utf-8").trim().split("\n");
    assert.equal(lines.length, 2);
  });
});
