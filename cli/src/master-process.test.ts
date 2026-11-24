import { test } from "node:test";
import assert from "node:assert/strict";
import { MASTER_PROCESS_NAMES } from "./subagents.js";

test("a running master is found on the Mac app and on the Linux server", () => {
  assert.ok(MASTER_PROCESS_NAMES.includes("KanbanCode"));
  // pgrep -x matches the kernel's 15 character process name on Linux.
  assert.ok(MASTER_PROCESS_NAMES.includes("kanban-code-ser"));
  for (const name of MASTER_PROCESS_NAMES) assert.ok(name.length <= 15);
});
