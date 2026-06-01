import { test, describe } from "node:test";
import { strict as assert } from "node:assert";
import { shortenPath, toolLabel, formatTranscriptLines, gfmToSlackMrkdwn } from "./slack/format.js";

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

  test("emits one post per content block with the right kind", () => {
    const posts = formatTranscriptLines([
      asst([{ type: "thinking", thinking: "let me check the deps" }]),
      asst([
        { type: "text", text: "Reviewing the bump." },
        { type: "tool_use", name: "Bash", input: { description: "run tests" } },
      ]),
    ]);
    // 3 blocks total, so 3 posts (text/tool/thinking each routed independently
    // by the bridge: text -> channel root, tool/thinking -> in-thread).
    assert.equal(posts.length, 3);
    assert.deepEqual(
      posts.map((p) => p.kind),
      ["thinking", "text", "tool"]
    );
    assert.match(posts[0].text, /💭 _let me check the deps_/);
    assert.equal(posts[1].text, "Reviewing the bump.");
    assert.match(posts[2].text, /```\nBash\(run tests\)\n```/);
    assert.ok(posts.every((p) => p.role === "assistant"));
  });

  test("coalesces consecutive tool posts into one (debounce against Slack rate limits)", () => {
    const posts = formatTranscriptLines([
      asst([{ type: "text", text: "Checking the PR." }]),
      asst([{ type: "tool_use", name: "Bash", input: { description: "view PR" } }]),
      asst([{ type: "tool_use", name: "Bash", input: { description: "view diff" } }]),
      asst([{ type: "tool_use", name: "Bash", input: { description: "view checks" } }]),
    ]);
    // The 3 Bash calls fold into 1 tool post (single Slack API call instead
    // of 3); the text post stays separate so it can anchor the new thread.
    assert.equal(posts.length, 2);
    assert.equal(posts[0].kind, "text");
    assert.equal(posts[0].text, "Checking the PR.");
    assert.equal(posts[1].kind, "tool");
    assert.match(posts[1].text, /Bash\(view PR\)/);
    assert.match(posts[1].text, /Bash\(view diff\)/);
    assert.match(posts[1].text, /Bash\(view checks\)/);
  });

  test("a text post in the middle breaks the tool coalescing run", () => {
    // Real-world shape: tools, then the agent says something, then more tools.
    // The new text must anchor a new thread, so the second tool run can't fold
    // into the first.
    const posts = formatTranscriptLines([
      asst([{ type: "tool_use", name: "Bash", input: { description: "a" } }]),
      asst([{ type: "tool_use", name: "Bash", input: { description: "b" } }]),
      asst([{ type: "text", text: "Found two." }]),
      asst([{ type: "tool_use", name: "Bash", input: { description: "c" } }]),
    ]);
    assert.equal(posts.length, 3);
    assert.deepEqual(
      posts.map((p) => p.kind),
      ["tool", "text", "tool"]
    );
    assert.match(posts[0].text, /Bash\(a\)/);
    assert.match(posts[0].text, /Bash\(b\)/);
    assert.equal(posts[1].text, "Found two.");
    assert.match(posts[2].text, /Bash\(c\)/);
  });

  test("emoji/prose tool labels are not fenced and still coalesce as tool", () => {
    const posts = formatTranscriptLines([
      asst([{ type: "tool_use", name: "AskUserQuestion", input: { questions: [{ question: "Ship it?" }] } }]),
    ]);
    assert.equal(posts.length, 1);
    assert.equal(posts[0].kind, "tool");
    assert.doesNotMatch(posts[0].text, /```/);
    assert.match(posts[0].text, /❓ asking:/);
  });

  test("user turns (incl. tool_result lines) are not emitted", () => {
    const posts = formatTranscriptLines([
      asst([{ type: "text", text: "first" }]),
      usr([{ type: "tool_result", tool_use_id: "t1", content: "huge output..." }]),
      usr("a human steering message"),
      asst([{ type: "text", text: "second" }]),
    ]);
    // 2 text posts, both as root-bound; the human message + tool_result are
    // dropped (the human already sees their own Slack message; tool results
    // are the noise we're trying to hide).
    assert.equal(posts.length, 2);
    assert.deepEqual(
      posts.map((p) => ({ kind: p.kind, text: p.text })),
      [
        { kind: "text", text: "first" },
        { kind: "text", text: "second" },
      ]
    );
  });

  test("empty assistant content produces no post", () => {
    const posts = formatTranscriptLines([asst([{ type: "text", text: "   " }])]);
    assert.equal(posts.length, 0);
  });

  test("translates GFM markdown in assistant text to Slack mrkdwn", () => {
    const posts = formatTranscriptLines([
      asst([{ type: "text", text: "**hono 4.12.23**: serves, responds 200" }]),
    ]);
    assert.equal(posts[0].text, "*hono 4.12.23*: serves, responds 200");
  });
});

describe("gfmToSlackMrkdwn", () => {
  test("**bold** -> *bold*", () => {
    assert.equal(gfmToSlackMrkdwn("hello **world** ok"), "hello *world* ok");
  });

  test("__bold__ -> *bold*", () => {
    assert.equal(gfmToSlackMrkdwn("hello __world__ ok"), "hello *world* ok");
  });

  test("markdown italic *x* -> Slack italic _x_", () => {
    assert.equal(gfmToSlackMrkdwn("hello *world* ok"), "hello _world_ ok");
  });

  test("Slack-native italic _x_ is left alone", () => {
    assert.equal(gfmToSlackMrkdwn("hello _world_ ok"), "hello _world_ ok");
  });

  test("bold inside italic stays bold (not mistakenly italicised)", () => {
    // The reverse order would be a bug — `**x**` shouldn't end up as `_x_`.
    assert.equal(gfmToSlackMrkdwn("**bold**"), "*bold*");
    assert.equal(gfmToSlackMrkdwn("foo **bold** *italic* bar"), "foo *bold* _italic_ bar");
  });

  test("links: [label](url) -> <url|label>", () => {
    assert.equal(
      gfmToSlackMrkdwn("see [the docs](https://example.com/x) for more"),
      "see <https://example.com/x|the docs> for more",
    );
  });

  test("ATX headings -> bold lines", () => {
    assert.equal(gfmToSlackMrkdwn("# Heading 1\nbody"), "*Heading 1*\nbody");
    assert.equal(gfmToSlackMrkdwn("### Heading 3"), "*Heading 3*");
  });

  test("strikethrough: ~~x~~ -> ~x~", () => {
    assert.equal(gfmToSlackMrkdwn("~~old~~ new"), "~old~ new");
  });

  test("fenced code blocks pass through unchanged", () => {
    const input = "before\n```\n**not bold inside**\n```\nafter **bold**";
    assert.equal(gfmToSlackMrkdwn(input), "before\n```\n**not bold inside**\n```\nafter *bold*");
  });

  test("inline code passes through unchanged", () => {
    assert.equal(gfmToSlackMrkdwn("call `foo(**x**)` then **bold**"), "call `foo(**x**)` then *bold*");
  });

  test("realistic agent paragraph with bullets, bold and link", () => {
    const input = [
      "Strong evidence:",
      "- **hono 4.12.23 server smoke**: serves, responds 200",
      "- **Real bullboard server**: gets past module loading",
      "",
      "See [the docs](https://example.com).",
    ].join("\n");
    const out = gfmToSlackMrkdwn(input);
    assert.ok(out.includes("*hono 4.12.23 server smoke*"));
    assert.ok(out.includes("*Real bullboard server*"));
    assert.ok(out.includes("<https://example.com|the docs>"));
    // Slack uses `-` for bullets natively (since 2024); we don't touch them.
    assert.ok(out.includes("- *hono"));
  });
});
