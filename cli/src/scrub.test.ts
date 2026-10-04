import assert from "node:assert/strict";
import { describe, test } from "node:test";
import { formatScrubReport, runScrub, type ScrubReport, type ScrubStatus } from "./scrub.js";

function report(dryRun: boolean): ScrubReport {
  return {
    machine: "box",
    startedAt: "2026-10-03T04:30:00.000Z",
    finishedAt: "2026-10-03T04:31:10.000Z",
    dryRun,
    filesSeen: 120,
    filesScanned: 100,
    filesUnchanged: 20,
    filesLive: 2,
    bytesScanned: 3 * 2 ** 30,
    filesWithSecrets: 7,
    replacements: 41,
    newSecrets: 3,
    skipped: 1,
    bySecret: { OPENAI_API_KEY: 30, "scrubbed/found/SLACK_TOKEN_ab12cd34": 11 },
    byFolder: { "~/.claude/projects": 40, "~/.kanban-code/logs": 1 },
    files: [],
    errors: [],
  };
}

function client(statuses: ScrubStatus[]) {
  const calls: Array<{ method: string; path: string; body?: unknown }> = [];
  return {
    calls,
    async call<T>(method: string, path: string, body?: unknown) {
      calls.push({ method, path, body });
      if (method === "GET") return { status: 200, body: (statuses.length > 1 ? statuses.shift() : statuses[0]) as T };
      return { status: 202, body: statuses[0] as T };
    },
  };
}

const schedule = { enabled: true, hour: 4, minute: 30 };

describe("kv scrub", () => {
  test("a dry run report says what a run would do, with counts by folder and secret", () => {
    const text = formatScrubReport(report(true));
    assert.match(text, /box: dry run of 2026-10-03T04:30Z, 70s/);
    assert.match(text, /would replace 41 values in 7 files; 3 not in the vault \(a run saves them under scrubbed\/found\/\); 1 left in place/);
    assert.match(text, /100 scanned \(3\.00 GiB\), 20 unchanged since the last run, 2 live/);
    assert.match(text, /\s+40 {2}~\/\.claude\/projects/);
    assert.match(text, /\s+30 {2}OPENAI_API_KEY/);
  });

  test("a run report names the backup", () => {
    const text = formatScrubReport({ ...report(false), backupPath: "/home/.kanban-code/scrub-backups/2026-10-03", backupFiles: 7 });
    assert.match(text, /replaced 41 values/);
    assert.match(text, /backup: what was replaced in 7 files, in .*scrub-backups\/2026-10-03 \(deleted after 7 days\)/);
  });

  test("--dry-run starts a dry run, waits for it and prints its report", async () => {
    const c = client([
      { machine: "box", schedule, running: true, progress: "scanned 200 of 900 files" },
      { machine: "box", schedule, running: false, lastDryRun: report(true) },
    ]);
    let printed = "";
    const code = await runScrub(["--dry-run"], c, (t) => (printed += t), async () => {});
    assert.equal(code, 0);
    assert.deepEqual(c.calls[0], { method: "POST", path: "../scrub/run", body: { dryRun: true } });
    assert.match(printed, /would replace 41 values/);
  });

  test("--once runs one time in another patterns mode, with vendors left out, and changes no schedule", async () => {
    const c = client([{ machine: "mac", schedule, running: false, lastDryRun: report(true) }]);
    const code = await runScrub(["--dry-run", "--once", "on", "--except", "LANGWATCH_API_KEY,NPM_TOKEN"], c, () => {}, async () => {});
    assert.equal(code, 0);
    assert.deepEqual(c.calls[0], {
      method: "POST",
      path: "../scrub/run",
      body: { dryRun: true, patterns: "on", except: ["LANGWATCH_API_KEY", "NPM_TOKEN"] },
    });
    assert.equal(c.calls.some((x) => x.method === "PUT"), false);
    await assert.rejects(runScrub(["--except", "LANGWATCH_API_KEY"], c, () => {}, async () => {}), /--once on --except/);
    await assert.rejects(runScrub(["--once", "sometimes"], c, () => {}, async () => {}), /--once on\|typed\|off/);
  });

  test("--at sets the daily time and keeps the switch", async () => {
    const c = client([{ machine: "box", schedule, running: false }]);
    await runScrub(["--at", "03:15"], c, () => {}, async () => {});
    const put = c.calls.find((x) => x.method === "PUT");
    assert.deepEqual(put, { method: "PUT", path: "../scrub/schedule", body: { enabled: true, hour: 3, minute: 15, paths: [] } });
  });

  test("--restore sends absolute paths and fails when a file could not be restored", async () => {
    const calls: Array<{ method: string; path: string; body?: unknown }> = [];
    const c = {
      async call<T>(method: string, path: string, body?: unknown) {
        calls.push({ method, path, body });
        return { status: 200, body: { files: 1, errors: ["/x/b.jsonl: no backup holds it"] } as T };
      },
    };
    let printed = "";
    const code = await runScrub(["--restore", "/x/a.jsonl", "/x/b.jsonl"], c, (t) => (printed += t), async () => {});
    assert.equal(code, 1);
    assert.deepEqual(calls, [{ method: "POST", path: "../scrub/restore", body: { paths: ["/x/a.jsonl", "/x/b.jsonl"] } }]);
    assert.match(printed, /restored 1 file\n/);
    assert.match(printed, /no backup holds it/);
    await assert.rejects(runScrub(["--restore"], c, () => {}, async () => {}), /--restore/);
  });

  test("--patterns off keeps the rest of the settings", async () => {
    const c = client([{ machine: "box", schedule: { ...schedule, paths: ["~/notes"] }, running: false }]);
    await runScrub(["--patterns", "off"], c, () => {}, async () => {});
    const put = c.calls.find((x) => x.method === "PUT");
    assert.deepEqual(put?.body, { enabled: true, hour: 4, minute: 30, paths: ["~/notes"], patterns: "off" });
    await runScrub(["--patterns", "typed"], c, () => {}, async () => {});
    assert.equal((c.calls.filter((x) => x.method === "PUT")[1]?.body as { patterns: string }).patterns, "typed");
    await assert.rejects(runScrub(["--patterns", "maybe"], c, () => {}, async () => {}), /typed\|on\|off/);
  });

  test("--add and --remove edit the extra paths and keep the rest", async () => {
    const c = client([{ machine: "box", schedule: { ...schedule, paths: ["~/notes", "~/old"] }, running: false }]);
    await runScrub(["--add", "~/work/log.txt", "--remove", "~/old"], c, () => {}, async () => {});
    const put = c.calls.find((x) => x.method === "PUT");
    assert.deepEqual(put?.body, { enabled: true, hour: 4, minute: 30, paths: ["~/notes", "~/work/log.txt"] });
  });
});
