/**
 * The machine side of the boxd bridge, driven in-process with a fake stdin and
 * a collected stdout so the tests never need a real machine.
 */

import { strict as assert } from "node:assert";
import { appendFileSync, mkdirSync, mkdtempSync, readFileSync, rmSync, statSync, writeFileSync } from "node:fs";
import { homedir, tmpdir } from "node:os";
import { join } from "node:path";
import { PassThrough } from "node:stream";
import { afterEach, beforeEach, describe, test } from "node:test";
import { RemoteAgent, deriveCwdFromProjectDirName, readCwdFromTranscript, waitForDrain } from "./remote-agent.js";

interface Harness {
  agent: RemoteAgent;
  messages: Record<string, unknown>[];
  send: (message: Record<string, unknown>) => void;
  finished: Promise<void>;
  end: () => Promise<void>;
  waitFor: (
    predicate: (message: Record<string, unknown>) => boolean,
    label?: string
  ) => Promise<Record<string, unknown>>;
}

let home: string;
let previousEnv: Record<string, string | undefined>;

function startAgent(): Harness {
  const input = new PassThrough();
  const messages: Record<string, unknown>[] = [];
  const agent = new RemoteAgent({
    input,
    send: (message) => {
      messages.push(message);
    },
    log: () => undefined,
  });
  const finished = agent.run();
  const waitFor = async (
    predicate: (message: Record<string, unknown>) => boolean,
    label = "message"
  ): Promise<Record<string, unknown>> => {
    const deadline = Date.now() + 5_000;
    while (Date.now() < deadline) {
      const found = messages.find(predicate);
      if (found) return found;
      await new Promise((resolve) => setTimeout(resolve, 20));
    }
    throw new Error(`timed out waiting for ${label}; saw ${JSON.stringify(messages)}`);
  };
  return {
    agent,
    messages,
    send: (message) => input.write(`${JSON.stringify(message)}\n`),
    finished,
    end: async () => {
      input.end();
      await finished;
    },
    waitFor,
  };
}

beforeEach(() => {
  home = mkdtempSync(join(tmpdir(), "kanban-remote-agent-"));
  previousEnv = {
    KANBAN_CODE_HOME: process.env.KANBAN_CODE_HOME,
    CLAUDE_CONFIG_DIR: process.env.CLAUDE_CONFIG_DIR,
    CODEX_HOME: process.env.CODEX_HOME,
  };
  process.env.KANBAN_CODE_HOME = join(home, ".kanban-code");
  process.env.CLAUDE_CONFIG_DIR = join(home, ".claude");
  process.env.CODEX_HOME = join(home, ".codex");
  mkdirSync(process.env.KANBAN_CODE_HOME, { recursive: true });
});

afterEach(() => {
  for (const [key, value] of Object.entries(previousEnv)) {
    if (value === undefined) delete process.env[key];
    else process.env[key] = value;
  }
  rmSync(home, { recursive: true, force: true });
});

describe("remote agent protocol", () => {
  test("greets the Mac and answers a ping", async () => {
    const harness = startAgent();
    const hello = await harness.waitFor((m) => m.type === "hello", "hello");
    assert.equal(hello.kanbanHome, process.env.KANBAN_CODE_HOME);
    assert.equal(hello.home, homedir());
    assert.ok(typeof hello.agentVersion === "string");
    harness.send({ type: "ping" });
    await harness.waitFor((m) => m.type === "pong", "pong");
    await harness.end();
  });

  test("exits cleanly when stdin ends", async () => {
    const harness = startAgent();
    await harness.waitFor((m) => m.type === "hello", "hello");
    await harness.end();
    assert.equal(harness.messages[0].type, "hello");
  });

  test("streams only the bytes after the offset the Mac already has", async () => {
    const events = join(process.env.KANBAN_CODE_HOME!, "hook-events.jsonl");
    writeFileSync(events, '{"event":"one"}\n{"event":"two"}\n');
    const seen = Buffer.byteLength('{"event":"one"}\n');
    const harness = startAgent();
    harness.send({ type: "watch", roots: [{ path: events }], offsets: { [events]: seen } });
    const chunk = await harness.waitFor((m) => m.type === "file", "file chunk");
    assert.equal(chunk.offset, seen);
    assert.equal(Buffer.from(String(chunk.data), "base64").toString("utf-8"), '{"event":"two"}\n');
    assert.equal(chunk.eof, true);
    await harness.waitFor((m) => m.type === "activity" && m.kind === "hook", "hook activity");
    await harness.end();
  });

  test("a held file is not sent back, and release sends only what came after it", async () => {
    const events = join(process.env.KANBAN_CODE_HOME!, "hook-events.jsonl");
    const harness = startAgent();
    harness.send({ type: "watch", roots: [{ path: events }] });
    harness.send({ type: "hold", path: events });
    await harness.waitFor((m) => m.type === "hello", "hello");
    const pushed = '{"event":"pushed by the mac"}\n';
    writeFileSync(events, pushed);
    await new Promise((resolve) => setTimeout(resolve, 200));
    assert.equal(harness.messages.some((m) => m.type === "file"), false, "the pushed bytes came back");

    harness.send({ type: "release", path: events, offset: Buffer.byteLength(pushed) });
    await new Promise((resolve) => setTimeout(resolve, 100));
    assert.equal(harness.messages.some((m) => m.type === "file"), false, "release sent the held bytes");

    appendFileSync(events, '{"event":"from the machine"}\n');
    const chunk = await harness.waitFor((m) => m.type === "file", "appended chunk");
    assert.equal(chunk.offset, Buffer.byteLength(pushed));
    assert.equal(Buffer.from(String(chunk.data), "base64").toString("utf-8"), '{"event":"from the machine"}\n');
    await harness.end();
  });

  test("upload staging files never cross the bridge", async () => {
    const home = process.env.KANBAN_CODE_HOME!;
    const staged = [
      join(home, "transcript.jsonl.boxd-upload.tmp"),
      join(home, "transcript.jsonl.incoming-ab12cd34"),
      join(home, "transcript.jsonl.delta-ab12cd34"),
    ];
    const real = join(home, "hook-events.jsonl");
    const harness = startAgent();
    harness.send({ type: "watch", roots: [{ path: home }] });
    await harness.waitFor((m) => m.type === "hello", "hello");
    for (const path of staged) writeFileSync(path, '{"event":"half-written upload"}\n');
    writeFileSync(real, '{"event":"real"}\n');
    const chunk = await harness.waitFor((m) => m.type === "file", "the real file");
    assert.equal(chunk.path, real);
    assert.equal(harness.messages.filter((m) => m.type === "file").length, 1, "a staging file crossed");
    await harness.end();
  });

  test("a large file crosses the bridge in chunks cut at a newline", async () => {
    const events = join(process.env.KANBAN_CODE_HOME!, "hook-events.jsonl");
    const lines = Array.from({ length: 50 }, (_, i) => `{"event":"${String(i).padStart(3, "0")}"}\n`);
    writeFileSync(events, lines.join(""));
    const harness = startAgent();
    harness.agent.chunkBytes = 100;
    harness.send({ type: "watch", roots: [{ path: events }] });
    await harness.waitFor((m) => m.type === "file" && m.eof === true, "last chunk");
    const chunks = harness.messages.filter((m) => m.type === "file");
    assert.ok(chunks.length > 1, "expected more than one chunk");
    for (const chunk of chunks) {
      const text = Buffer.from(String(chunk.data), "base64").toString("utf-8");
      assert.ok(text.endsWith("\n"), `chunk cut inside a line: ${text}`);
      assert.ok(Buffer.byteLength(text) <= 100);
    }
    assert.equal(chunks.filter((m) => m.eof === true).length, 1);
    const joined = chunks.map((m) => Buffer.from(String(m.data), "base64").toString("utf-8")).join("");
    assert.equal(joined, lines.join(""));
    await harness.end();
  });

  test("a line longer than a chunk is sent whole", async () => {
    const events = join(process.env.KANBAN_CODE_HOME!, "hook-events.jsonl");
    const long = `{"event":"${"x".repeat(300)}"}\n`;
    writeFileSync(events, `{"event":"short"}\n${long}{"event":"tail"}\n`);
    const harness = startAgent();
    harness.agent.chunkBytes = 100;
    harness.send({ type: "watch", roots: [{ path: events }] });
    await harness.waitFor((m) => m.type === "file" && m.eof === true, "last chunk");
    const joined = harness.messages
      .filter((m) => m.type === "file")
      .map((m) => Buffer.from(String(m.data), "base64").toString("utf-8"))
      .join("");
    assert.equal(joined, `{"event":"short"}\n${long}{"event":"tail"}\n`);
    await harness.end();
  });

  test("reads no further than the wire drains, so a slow Mac never piles transcripts up in memory", async () => {
    const projects = join(process.env.CLAUDE_CONFIG_DIR!, "projects", "-work-app");
    mkdirSync(projects, { recursive: true });
    const line = `{"cwd":"/work/app","text":"${"x".repeat(1000)}"}\n`;
    const fileBytes = line.length * 1024;
    const files = Array.from({ length: 16 }, (_, i) => join(projects, `s${i}.jsonl`));
    for (const file of files) writeFileSync(file, line.repeat(1024));

    // Nobody reads the wire until the end, like an ssh pipe to a busy Mac.
    const wire = new PassThrough({ highWaterMark: 1024 });
    const input = new PassThrough();
    const messages: Record<string, unknown>[] = [];
    let sentFileBytes = 0;
    const agent = new RemoteAgent({
      input,
      send: (message) => {
        messages.push(message);
        if (message.type === "file") sentFileBytes += String(message.data).length;
        return wire.write(`${JSON.stringify(message)}\n`);
      },
      ready: () => waitForDrain(wire),
    });
    agent.chunkBytes = 64 * 1024;
    const finished = agent.run();
    input.write(`${JSON.stringify({ type: "watch", roots: [{ path: join(process.env.CLAUDE_CONFIG_DIR!, "projects"), globs: ["**/*.jsonl"] }], offsets: {} })}\n`);
    await new Promise((resolve) => setTimeout(resolve, 600));
    assert.ok(messages.some((m) => m.type === "file"), "expected the first chunk");
    assert.ok(
      sentFileBytes <= 2 * agent.chunkBytes * 1.4,
      `sent ${sentFileBytes} bytes of files while the wire was blocked`
    );

    // A ping still gets its pong while the files wait.
    input.write(`${JSON.stringify({ type: "ping" })}\n`);
    const deadline = Date.now() + 2_000;
    while (!messages.some((m) => m.type === "pong") && Date.now() < deadline) {
      await new Promise((resolve) => setTimeout(resolve, 20));
    }
    assert.ok(messages.some((m) => m.type === "pong"), "no pong while files were queued");

    // Once the Mac reads, every file arrives whole.
    wire.resume();
    const doneBy = Date.now() + 10_000;
    const complete = (): boolean =>
      files.every((file) => messages.some((m) => m.type === "file" && m.path === file && m.eof === true));
    while (!complete() && Date.now() < doneBy) {
      await new Promise((resolve) => setTimeout(resolve, 20));
    }
    assert.ok(complete(), "not every file reached its end");
    for (const file of files) {
      const bytes = messages
        .filter((m) => m.type === "file" && m.path === file)
        .reduce((sum, m) => sum + Buffer.from(String(m.data), "base64").length, 0);
      assert.equal(bytes, fileBytes);
    }
    input.end();
    await finished;
  });

  test("a non-jsonl file the Mac already holds at its size is not sent again on start", async () => {
    const toolResults = join(process.env.CLAUDE_CONFIG_DIR!, "projects", "-work-app", "s1", "tool-results");
    mkdirSync(toolResults, { recursive: true });
    const held = join(toolResults, "held.txt");
    const fresh = join(toolResults, "fresh.txt");
    writeFileSync(held, "already on the Mac");
    writeFileSync(fresh, "new");
    const harness = startAgent();
    harness.send({
      type: "watch",
      roots: [{ path: toolResults }],
      offsets: { [held]: statSync(held).size },
    });
    await harness.waitFor((m) => m.type === "file" && m.path === fresh, "fresh file");
    await new Promise((resolve) => setTimeout(resolve, 200));
    assert.equal(harness.messages.filter((m) => m.type === "file" && m.path === held).length, 0);

    writeFileSync(held, "changed on the machine");
    await harness.waitFor((m) => m.type === "file" && m.path === held, "changed file");
    await harness.end();
  });

  test("holds a partial jsonl line until its newline arrives", async () => {
    const events = join(process.env.KANBAN_CODE_HOME!, "hook-events.jsonl");
    writeFileSync(events, "");
    const harness = startAgent();
    harness.send({ type: "watch", roots: [{ path: events }], offsets: {} });
    await harness.waitFor((m) => m.type === "hello", "hello");

    appendFileSync(events, '{"event":"one"}\n{"event":"par');
    const first = await harness.waitFor((m) => m.type === "file", "first chunk");
    assert.equal(Buffer.from(String(first.data), "base64").toString("utf-8"), '{"event":"one"}\n');
    assert.equal(first.eof, false);

    appendFileSync(events, 'tial"}\n');
    const second = await harness.waitFor(
      (m) => m.type === "file" && m.offset === 16,
      "second chunk"
    );
    assert.equal(
      Buffer.from(String(second.data), "base64").toString("utf-8"),
      '{"event":"partial"}\n'
    );
    assert.equal(second.eof, true);
    await harness.end();
  });

  test("sends a rewritten file whole, and only when its content changes", async () => {
    const context = join(process.env.KANBAN_CODE_HOME!, "context");
    mkdirSync(context, { recursive: true });
    const file = join(context, "s1.json");
    writeFileSync(file, '{"usedPercentage":6,"model":"Opus 5 (1M context)"}');
    const harness = startAgent();
    harness.send({ type: "watch", roots: [{ path: context }], offsets: {} });
    const first = await harness.waitFor((m) => m.type === "file", "first file");
    assert.equal(first.offset, 0);

    // Shorter than the first write: the Mac needs all of it, not a tail.
    writeFileSync(file, '{"usedPercentage":18,"model":"Opus 5"}');
    const second = await harness.waitFor(
      (m) => m.type === "file" && String(m.data) !== String(first.data),
      "rewritten file"
    );
    assert.equal(second.offset, 0);
    assert.equal(
      Buffer.from(String(second.data), "base64").toString("utf-8"),
      '{"usedPercentage":18,"model":"Opus 5"}'
    );

    // The same bytes again are not sent a second time.
    const seen = harness.messages.filter((m) => m.type === "file").length;
    writeFileSync(file, '{"usedPercentage":18,"model":"Opus 5"}');
    await new Promise((resolve) => setTimeout(resolve, 300));
    assert.equal(harness.messages.filter((m) => m.type === "file").length, seen);
    await harness.end();
  });

  test("reports a transcript's own working directory", async () => {
    const projects = join(process.env.CLAUDE_CONFIG_DIR!, "projects", "-home-boxd-app");
    mkdirSync(projects, { recursive: true });
    const transcript = join(projects, "session.jsonl");
    writeFileSync(
      transcript,
      `${JSON.stringify({ type: "user", cwd: "/home/boxd/app", message: { content: "hi" } })}\n`
    );
    const harness = startAgent();
    harness.send({
      type: "watch",
      roots: [{ path: join(process.env.CLAUDE_CONFIG_DIR!, "projects"), globs: ["**/*.jsonl"] }],
      offsets: {},
    });
    const chunk = await harness.waitFor((m) => m.type === "file", "transcript chunk");
    assert.equal(chunk.cwd, "/home/boxd/app");
    await harness.waitFor((m) => m.type === "activity" && m.kind === "transcript", "activity");
    await harness.end();
  });

  test("derives the working directory from the project directory name", async () => {
    const projects = join(process.env.CLAUDE_CONFIG_DIR!, "projects", "-home-boxd-app");
    mkdirSync(projects, { recursive: true });
    writeFileSync(join(projects, "session.jsonl"), `${JSON.stringify({ type: "summary" })}\n`);
    const harness = startAgent();
    harness.send({
      type: "watch",
      roots: [{ path: join(process.env.CLAUDE_CONFIG_DIR!, "projects"), globs: ["**/*.jsonl"] }],
      offsets: {},
    });
    const chunk = await harness.waitFor((m) => m.type === "file", "transcript chunk");
    assert.equal(chunk.cwd, "/home/boxd/app");
    await harness.end();
  });

  test("reads a codex rollout's working directory from session_meta", async () => {
    const sessions = join(process.env.CODEX_HOME!, "sessions", "2026", "08");
    mkdirSync(sessions, { recursive: true });
    const rollout = join(sessions, "rollout-2026-08-29.jsonl");
    writeFileSync(
      rollout,
      `${JSON.stringify({ type: "session_meta", payload: { cwd: "/home/boxd/app", id: "x" } })}\n`
    );
    const harness = startAgent();
    harness.send({
      type: "watch",
      roots: [{ path: join(process.env.CODEX_HOME!, "sessions"), globs: ["**/*.jsonl"] }],
      offsets: {},
    });
    const chunk = await harness.waitFor((m) => m.type === "file", "rollout chunk");
    assert.equal(chunk.cwd, "/home/boxd/app");
    await harness.end();
  });

  test("reports a deleted file", async () => {
    const contextDir = join(process.env.KANBAN_CODE_HOME!, "context");
    mkdirSync(contextDir, { recursive: true });
    const file = join(contextDir, "abc.json");
    writeFileSync(file, "{}");
    const harness = startAgent();
    harness.send({
      type: "watch",
      roots: [{ path: contextDir, globs: ["*.json"] }],
      offsets: {},
    });
    await harness.waitFor((m) => m.type === "file", "context chunk");
    rmSync(file, { force: true });
    const removed = await harness.waitFor((m) => m.type === "removed", "removed");
    assert.equal(removed.path, file);
    await harness.end();
  });

  test("writes a put, creating parent directories", async () => {
    const harness = startAgent();
    const target = join(home, "deep", "nested", "prompt.txt");
    harness.send({
      type: "put",
      path: target,
      data: Buffer.from("hello prompt").toString("base64"),
      mode: 0o755,
    });
    const deadline = Date.now() + 5_000;
    while (Date.now() < deadline && !safeExists(target)) {
      await new Promise((resolve) => setTimeout(resolve, 20));
    }
    assert.equal(readFileSync(target, "utf-8"), "hello prompt");
    assert.equal(statSync(target).mode & 0o777, 0o755);
    await harness.end();
  });

  test("runs an exec and reports a non-zero exit instead of throwing", async () => {
    const harness = startAgent();
    harness.send({
      type: "exec",
      id: "e1",
      argv: ["/bin/sh", "-c", "printf out; printf err 1>&2; exit 3"],
    });
    const result = await harness.waitFor((m) => m.type === "exec-result", "exec-result");
    assert.equal(result.id, "e1");
    assert.equal(result.stdout, "out");
    assert.equal(result.stderr, "err");
    assert.equal(result.code, 3);
    await harness.end();
  });

  test("passes stdin to an exec", async () => {
    const harness = startAgent();
    harness.send({ type: "exec", id: "e2", argv: ["/bin/cat"], stdin: "piped body" });
    const result = await harness.waitFor((m) => m.type === "exec-result", "exec-result");
    assert.equal(result.stdout, "piped body");
    assert.equal(result.code, 0);
    await harness.end();
  });

  test("forwards a proxy request and writes back its result", async () => {
    const proxyDir = join(process.env.KANBAN_CODE_HOME!, "commands", "proxy");
    mkdirSync(proxyDir, { recursive: true });
    const harness = startAgent();
    await harness.waitFor((m) => m.type === "hello", "hello");

    const request = {
      id: "req-1",
      argv: ["channel", "send", "team", "hello"],
      cwd: "/home/boxd/app",
      env: { KANBAN_CARD_ID: "card-1" },
      images: [],
    };
    writeFileSync(join(proxyDir, "req-1.json"), JSON.stringify(request));
    const forwarded = await harness.waitFor((m) => m.type === "proxy", "proxy");
    assert.deepEqual(forwarded.argv, request.argv);
    assert.equal(forwarded.id, "req-1");

    harness.send({ type: "proxy-result", id: "req-1", stdout: "sent\n", stderr: "", code: 0 });
    const responsePath = join(
      process.env.KANBAN_CODE_HOME!,
      "commands",
      "proxy-responses",
      "req-1.json"
    );
    const deadline = Date.now() + 5_000;
    while (Date.now() < deadline && !safeExists(responsePath)) {
      await new Promise((resolve) => setTimeout(resolve, 20));
    }
    assert.deepEqual(JSON.parse(readFileSync(responsePath, "utf-8")), {
      id: "req-1",
      stdout: "sent\n",
      stderr: "",
      code: 0,
    });
    assert.equal(safeExists(join(proxyDir, "req-1.json")), false);
    await harness.end();
  });
});

describe("transcript working directory", () => {
  test("reads the first line that carries a cwd", () => {
    const path = join(home, "transcript.jsonl");
    writeFileSync(
      path,
      [
        JSON.stringify({ type: "summary" }),
        JSON.stringify({ type: "user", cwd: "/work/app" }),
        JSON.stringify({ type: "assistant", cwd: "/other" }),
      ].join("\n") + "\n"
    );
    assert.equal(readCwdFromTranscript(path), "/work/app");
  });

  test("scans an oversized first line that no JSON parse can reach", () => {
    const path = join(home, "huge.jsonl");
    const padding = "x".repeat(70_000);
    writeFileSync(
      path,
      `${JSON.stringify({ type: "session_meta", payload: { cwd: "/work/app", instructions: padding } })}\n`
    );
    assert.equal(readCwdFromTranscript(path), "/work/app");
  });

  test("gives up when no cwd appears in the first 64 KB", () => {
    const path = join(home, "late.jsonl");
    const padding = "x".repeat(70_000);
    writeFileSync(
      path,
      `${JSON.stringify({ type: "session_meta", payload: { instructions: padding, cwd: "/work/app" } })}\n`
    );
    assert.equal(readCwdFromTranscript(path), undefined);
  });

  test("prefers the directory reading that exists, dash as a separator", () => {
    const present = new Set(["/home", "/home/boxd", "/home/boxd/my", "/home/boxd/my/app"]);
    assert.equal(
      deriveCwdFromProjectDirName("-home-boxd-my-app", (p) => present.has(p)),
      "/home/boxd/my/app"
    );
  });

  test("prefers the directory reading that exists, dash inside a name", () => {
    const present = new Set(["/home", "/home/boxd", "/home/boxd/my-app"]);
    assert.equal(
      deriveCwdFromProjectDirName("-home-boxd-my-app", (p) => present.has(p)),
      "/home/boxd/my-app"
    );
  });

  test("falls back to the plain reading when nothing matches", () => {
    assert.equal(
      deriveCwdFromProjectDirName("-home-boxd-x", () => false),
      "/home/boxd/x"
    );
  });
});

function safeExists(path: string): boolean {
  try {
    statSync(path);
    return true;
  } catch {
    return false;
  }
}
