import { test, describe, beforeEach, afterEach } from "node:test";
import { strict as assert } from "node:assert";
import { mkdtempSync, rmSync, readFileSync, writeFileSync, mkdirSync, statSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

import { installHooks, areHooksInstalled, HOOK_EVENTS } from "./hooks.js";

describe("hook installer (sandboxed)", () => {
  let home: string;
  let claudeDir: string;
  let settings: string;

  beforeEach(() => {
    home = mkdtempSync(join(tmpdir(), "kanban-hooks-home-"));
    claudeDir = mkdtempSync(join(tmpdir(), "kanban-hooks-claude-"));
    settings = join(claudeDir, "settings.json");
    process.env.KANBAN_CODE_HOME = home;
    process.env.CLAUDE_CONFIG_DIR = claudeDir;
  });
  afterEach(() => {
    delete process.env.KANBAN_CODE_HOME;
    delete process.env.CLAUDE_CONFIG_DIR;
    rmSync(home, { recursive: true, force: true });
    rmSync(claudeDir, { recursive: true, force: true });
  });

  test("registers all events + statusline and deploys executable scripts", () => {
    const r = installHooks();
    const root = JSON.parse(readFileSync(settings, "utf-8"));
    for (const event of HOOK_EVENTS) {
      const cmds = root.hooks[event].flatMap((g: any) => g.hooks.map((h: any) => h.command));
      assert.ok(cmds.includes(r.hookScriptPath), `${event} missing hook`);
    }
    assert.equal(root.statusLine.command, r.statuslinePath);
    assert.ok(areHooksInstalled(undefined, r.hookScriptPath));
    // scripts exist and are executable
    assert.ok(statSync(r.hookScriptPath).mode & 0o111);
    assert.ok(statSync(r.statuslinePath).mode & 0o111);
  });

  test("is idempotent: no duplicate hook entries on repeat install", () => {
    installHooks();
    const r = installHooks();
    const root = JSON.parse(readFileSync(settings, "utf-8"));
    const stopHooks = root.hooks.Stop.flatMap((g: any) => g.hooks).filter(
      (h: any) => h.command === r.hookScriptPath
    );
    assert.equal(stopHooks.length, 1);
  });

  test("preserves unrelated settings and pre-existing hooks", () => {
    mkdirSync(claudeDir, { recursive: true });
    writeFileSync(
      settings,
      JSON.stringify({
        model: "opus",
        hooks: { Stop: [{ matcher: "", hooks: [{ type: "command", command: "/other/tool.sh" }] }] },
      })
    );
    const r = installHooks();
    const root = JSON.parse(readFileSync(settings, "utf-8"));
    assert.equal(root.model, "opus");
    const stopCmds = root.hooks.Stop.flatMap((g: any) => g.hooks.map((h: any) => h.command));
    assert.ok(stopCmds.includes("/other/tool.sh"), "pre-existing hook preserved");
    assert.ok(stopCmds.includes(r.hookScriptPath), "ours added");
  });
});
