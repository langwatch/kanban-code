import { test, describe, beforeEach, afterEach } from "node:test";
import { strict as assert } from "node:assert";
import { mkdtempSync, rmSync, readFileSync, existsSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import request from "supertest";

import { createChannel, joinChannel, readMessages } from "./channels.js";
import type { Link } from "./types.js";
import { buildShareApp, type ShareServerDeps } from "./share-server.js";

let base: string;
function tmp(): string { return mkdtempSync(join(tmpdir(), "kanban-share-test-")); }

function mkLink(id: string, tmuxName: string): Link {
  return {
    id,
    name: id,
    column: "in_progress",
    createdAt: new Date().toISOString(),
    updatedAt: new Date().toISOString(),
    tmuxLink: { sessionName: tmuxName },
    isRemote: false,
    prLinks: [],
    manualOverrides: {
      worktreePath: false, tmuxSession: false, name: false,
      column: false, prLink: false, issueLink: false,
    },
    source: "manual",
    manuallyArchived: false,
  } as unknown as Link;
}

function mkDeps(overrides: Partial<ShareServerDeps> = {}): ShareServerDeps & { calls: { session: string; text: string }[] } {
  const calls: { session: string; text: string }[] = [];
  return {
    channelName: "general",
    token: "tk_good",
    baseDir: base,
    loadLinks: () => [mkLink("card_A", "session-a"), mkLink("card_B", "session-b")],
    sender: (s, t) => { calls.push({ session: s, text: t }); return { ok: true }; },
    liveSessionProbe: () => true,
    expiresAt: Date.now() + 60_000,
    calls,
    ...overrides,
  };
}

describe("share-server auth", () => {
  beforeEach(() => {
    base = tmp();
    createChannel("general", {}, base);
    joinChannel("general", { cardId: "card_A", handle: "alice" }, base);
    joinChannel("general", { cardId: "card_B", handle: "bob" }, base);
  });
  afterEach(() => { rmSync(base, { recursive: true, force: true }); });

  test("requests without token return 401", async () => {
    const app = buildShareApp(mkDeps());
    const r = await request(app).get("/api/channels/general/info");
    assert.equal(r.status, 401);
  });

  test("requests with wrong token return 401", async () => {
    const app = buildShareApp(mkDeps());
    const r = await request(app).get("/api/channels/general/info?token=tk_wrong");
    assert.equal(r.status, 401);
  });

  test("expired share returns 410 Gone", async () => {
    const app = buildShareApp(mkDeps({ expiresAt: Date.now() - 5_000 }));
    const r = await request(app).get("/api/channels/general/info?token=tk_good");
    assert.equal(r.status, 410);
    assert.match(r.text, /expired/i);
  });

  test("channel name in URL must match configured channel", async () => {
    // Prevents lateral access to other channels via the same share link.
    const app = buildShareApp(mkDeps());
    const r = await request(app).get("/api/channels/other-channel/info?token=tk_good");
    assert.equal(r.status, 404);
  });
});

describe("share-server info endpoint", () => {
  beforeEach(() => {
    base = tmp();
    createChannel("general", {}, base);
    joinChannel("general", { cardId: "card_A", handle: "alice" }, base);
    joinChannel("general", { cardId: "card_B", handle: "bob" }, base);
  });
  afterEach(() => { rmSync(base, { recursive: true, force: true }); });

  test("returns channel name, members, and remaining-ms", async () => {
    const exp = Date.now() + 15 * 60_000;
    const app = buildShareApp(mkDeps({ expiresAt: exp }));
    const r = await request(app).get("/api/channels/general/info?token=tk_good");
    assert.equal(r.status, 200);
    assert.equal(r.body.name, "general");
    assert.deepEqual(
      r.body.members.map((m: { handle: string }) => m.handle).sort(),
      ["alice", "bob"]
    );
    assert.ok(r.body.remainingMs > 14 * 60_000);
    assert.ok(r.body.remainingMs <= 15 * 60_000);
  });
});

describe("share-server history endpoint", () => {
  beforeEach(() => {
    base = tmp();
    createChannel("general", {}, base);
    joinChannel("general", { cardId: "card_A", handle: "alice" }, base);
  });
  afterEach(() => { rmSync(base, { recursive: true, force: true }); });

  test("returns recent messages in insertion order", async () => {
    const app = buildShareApp(mkDeps());
    // Seed three messages via /send
    for (const body of ["one", "two", "three"]) {
      const r = await request(app)
        .post("/api/channels/general/send?token=tk_good")
        .send({ handle: "dana", body });
      assert.equal(r.status, 200);
    }
    const r = await request(app).get("/api/channels/general/history?token=tk_good");
    assert.equal(r.status, 200);
    const bodies = r.body.messages
      .filter((m: { type?: string }) => m.type === "message")
      .map((m: { body: string }) => m.body);
    assert.deepEqual(bodies, ["one", "two", "three"]);
  });
});

describe("share-server send endpoint", () => {
  beforeEach(() => {
    base = tmp();
    createChannel("general", {}, base);
    joinChannel("general", { cardId: "card_A", handle: "alice" }, base);
    joinChannel("general", { cardId: "card_B", handle: "bob" }, base);
  });
  afterEach(() => { rmSync(base, { recursive: true, force: true }); });

  test("posts a message, persists with source=external, fans out to every agent with warning prefix", async () => {
    const deps = mkDeps();
    const app = buildShareApp(deps);
    const r = await request(app)
      .post("/api/channels/general/send?token=tk_good")
      .send({ handle: "dana", body: "hello everyone" });
    assert.equal(r.status, 200);
    assert.equal(r.body.msg.source, "external");
    // Server namespaces external handles with `ext_` so agents can see at a
    // glance that this came in from a share link.
    assert.equal(r.body.msg.from.handle, "ext_dana");
    // Persisted with the external flag.
    const log = readMessages("general", base);
    const last = log.filter((m) => m.type === "message").pop()!;
    assert.equal(last.source, "external");
    assert.equal(last.from.handle, "ext_dana");
    // Every agent was fanned out to, with the warning prefix.
    assert.equal(deps.calls.length, 2);
    for (const c of deps.calls) {
      assert.ok(c.text.startsWith("⚠️"), `missing warning prefix on ${c.session}`);
      assert.ok(c.text.includes("[Message from #general @ext_dana]: hello everyone"));
    }
  });

  test("rejects empty bodies", async () => {
    const app = buildShareApp(mkDeps());
    const r = await request(app)
      .post("/api/channels/general/send?token=tk_good")
      .send({ handle: "dana", body: "   " });
    assert.equal(r.status, 400);
  });

  test("rejects missing handle", async () => {
    const app = buildShareApp(mkDeps());
    const r = await request(app)
      .post("/api/channels/general/send?token=tk_good")
      .send({ body: "hi" });
    assert.equal(r.status, 400);
  });

  test("rejects handle with invalid characters", async () => {
    const app = buildShareApp(mkDeps());
    const r = await request(app)
      .post("/api/channels/general/send?token=tk_good")
      .send({ handle: "evil/handle", body: "hi" });
    assert.equal(r.status, 400);
  });

  test("external handle is namespaced with ext_ even when guest didn't type it", async () => {
    // Prevents a guest from impersonating an internal member by picking
    // the same display name. "alice" from the web → "ext_alice" in fanout.
    const app = buildShareApp(mkDeps());
    const r = await request(app)
      .post("/api/channels/general/send?token=tk_good")
      .send({ handle: "alice", body: "not the real alice" });
    assert.equal(r.status, 200);
    assert.equal(r.body.msg.from.handle, "ext_alice");
  });

  test("external handle that already starts with ext_ is not double-prefixed", async () => {
    const app = buildShareApp(mkDeps());
    const r = await request(app)
      .post("/api/channels/general/send?token=tk_good")
      .send({ handle: "ext_dana", body: "hi" });
    assert.equal(r.status, 200);
    assert.equal(r.body.msg.from.handle, "ext_dana");
  });
});

describe("share-server images endpoint", () => {
  beforeEach(() => {
    base = tmp();
    createChannel("general", {}, base);
  });
  afterEach(() => { rmSync(base, { recursive: true, force: true }); });

  test("uploads a PNG and returns an absolute path under the channels/images dir", async () => {
    const app = buildShareApp(mkDeps());
    // Minimal valid PNG (8-byte signature is enough for our handler's content-type check).
    const png = Buffer.from([
      0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a,
      0x00, 0x00, 0x00, 0x0d, // IHDR length
    ]);
    const r = await request(app)
      .post("/api/channels/general/images?token=tk_good")
      .set("Content-Type", "image/png")
      .send(png);
    assert.equal(r.status, 200);
    assert.ok(r.body.path, "response must include path");
    assert.ok(r.body.path.endsWith(".png"), `expected .png extension, got ${r.body.path}`);
    assert.ok(existsSync(r.body.path), "file must exist on disk");
    const bytes = readFileSync(r.body.path);
    assert.deepEqual(bytes.subarray(0, 8), png.subarray(0, 8), "uploaded bytes must round-trip");
  });

  test("rejects non-image content types", async () => {
    const app = buildShareApp(mkDeps());
    const r = await request(app)
      .post("/api/channels/general/images?token=tk_good")
      .set("Content-Type", "application/octet-stream")
      .send(Buffer.from("lolz"));
    assert.equal(r.status, 415);
  });
});

describe("share-server SSE stream", () => {
  beforeEach(() => {
    base = tmp();
    createChannel("general", {}, base);
    joinChannel("general", { cardId: "card_A", handle: "alice" }, base);
  });
  afterEach(() => { rmSync(base, { recursive: true, force: true }); });

  test("streams new messages appended to the channel jsonl", async () => {
    const app = buildShareApp(mkDeps());
    const { createServer } = await import("node:http");
    const server = createServer(app);
    await new Promise<void>((res) => server.listen(0, () => res()));
    const port = (server.address() as { port: number }).port;

    // Open an SSE connection and collect events.
    const received: string[] = [];
    const url = `http://localhost:${port}/api/channels/general/stream?token=tk_good&handle=dana`;
    const resp = await fetch(url);
    assert.equal(resp.status, 200);
    assert.match(resp.headers.get("content-type") ?? "", /text\/event-stream/);

    const reader = resp.body!.getReader();
    const decoder = new TextDecoder();
    let buffer = "";
    const readTask = (async () => {
      while (true) {
        const { done, value } = await reader.read();
        if (done) break;
        buffer += decoder.decode(value, { stream: true });
        // parse event blocks separated by \n\n
        let idx: number;
        while ((idx = buffer.indexOf("\n\n")) !== -1) {
          const block = buffer.slice(0, idx);
          buffer = buffer.slice(idx + 2);
          const dataLine = block.split("\n").find((l) => l.startsWith("data: "));
          if (dataLine) received.push(dataLine.slice(6));
        }
      }
    })();

    // Give the server a beat to subscribe the watcher, then post a message.
    await new Promise((r) => setTimeout(r, 50));
    await request(app)
      .post("/api/channels/general/send?token=tk_good")
      .send({ handle: "dana", body: "hi from stream test" });

    // Wait up to 2s for the message to arrive on the stream.
    const deadline = Date.now() + 2000;
    while (Date.now() < deadline && !received.some((s) => s.includes("hi from stream test"))) {
      await new Promise((r) => setTimeout(r, 25));
    }
    reader.cancel();
    await readTask.catch(() => {});
    server.close();

    assert.ok(
      received.some((s) => s.includes("hi from stream test")),
      `expected a message SSE event, got: ${JSON.stringify(received)}`
    );
  });
});
