import { test, describe } from "node:test";
import { strict as assert } from "node:assert";
import { shortenPath, toolLabel, formatTranscriptLines } from "./slack/format.js";

describe("shortenPath", () => {
  test("keeps short paths, trims long ones to last 3", () => {
    assert.equal(shortenPath("src/a.ts"), "src/a.ts");
    assert.equal(shortenPath("/a/b/c/d/e.ts"), ".../c/d/e.ts");
  });
});

describe("toolLabel", () => {
  test("Bash prefers description, falls back to command", () => {
    assert.equal(toolLabel("Bash", { description: "run tests", command: "npm test" }), "Bash(run tests)");
    assert.equal(toolLabel("Bash", { command: "npm test" }), "Bash(npm test)");
  });
  test("file tools shorten the path", () => {
    assert.equal(toolLabel("Read", { file_path: "/x/y/z/w/file.ts" }), "Read(.../z/w/file.ts)");
    assert.equal(toolLabel("Edit", { file_path: "a/b.ts" }), "Edit(a/b.ts)");
  });
  test("Grep shows pattern and optional path", () => {
    assert.equal(toolLabel("Grep", { pattern: "foo", path: "/a/b/c/d" }), 'Grep("foo" in .../b/c/d)');
    assert.equal(toolLabel("Grep", { pattern: "foo" }), 'Grep("foo")');
  });
  test("Skill, TaskUpdate, plan + question tools", () => {
    assert.equal(toolLabel("Skill", { skill: "drive-pr" }), "Skill(drive-pr)");
    assert.equal(toolLabel("TaskUpdate", { taskId: "3", status: "completed" }), "TaskUpdate(3: completed)");
    assert.equal(toolLabel("EnterPlanMode", {}), "📋 entered plan mode");
    assert.match(toolLabel("AskUserQuestion", { questions: [{ question: "Ship it?" }] }), /❓ asking:\n• Ship it\?/);
  });
});

describe("formatTranscriptLines", () => {
  const asst = (content: any) => ({ type: "assistant", message: { role: "assistant", content } });
  const usr = (content: any) => ({ type: "user", message: { role: "user", content } });

  test("merges consecutive assistant lines (thinking + reply + tool) into one post", () => {
    const posts = formatTranscriptLines([
      asst([{ type: "thinking", thinking: "let me check the deps" }]),
      asst([
        { type: "text", text: "Reviewing the bump." },
        { type: "tool_use", name: "Bash", input: { description: "run tests" } },
      ]),
    ]);
    assert.equal(posts.length, 1);
    assert.equal(posts[0].role, "assistant");
    assert.match(posts[0].text, /💭 _let me check the deps_/);
    assert.match(posts[0].text, /Reviewing the bump\./);
    // Command-style tool labels render in a fenced code block, not inline.
    assert.match(posts[0].text, /```\nBash\(run tests\)\n```/);
  });

  test("emoji/prose tool labels are not fenced", () => {
    const posts = formatTranscriptLines([
      asst([{ type: "tool_use", name: "AskUserQuestion", input: { questions: [{ question: "Ship it?" }] } }]),
    ]);
    assert.doesNotMatch(posts[0].text, /```/);
    assert.match(posts[0].text, /❓ asking:/);
  });

  test("a user turn between assistant turns splits them, and user turns are not emitted", () => {
    const posts = formatTranscriptLines([
      asst([{ type: "text", text: "first" }]),
      usr("a human steering message"),
      asst([{ type: "text", text: "second" }]),
    ]);
    assert.equal(posts.length, 2);
    assert.deepEqual(posts.map((p) => p.text), ["first", "second"]);
    assert.ok(posts.every((p) => p.role === "assistant"));
  });

  test("empty assistant content produces no post", () => {
    const posts = formatTranscriptLines([asst([{ type: "text", text: "   " }])]);
    assert.equal(posts.length, 0);
  });

  test("tool_result lines (user role) are skipped", () => {
    const posts = formatTranscriptLines([
      usr([{ type: "tool_result", tool_use_id: "t1", content: "huge output..." }]),
    ]);
    assert.equal(posts.length, 0);
  });
});
