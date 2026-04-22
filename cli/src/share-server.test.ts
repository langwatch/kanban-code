import { test, describe, beforeEach, afterEach } from "node:test";
import { strict as assert } from "node:assert";
import { mkdtempSync, rmSync, readFileSync, existsSync, mkdirSync, writeFileSync } from "node:fs";
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

describe("share-server discovery endpoint (GET /api/channels)", () => {
  beforeEach(() => {
    base = tmp();
    createChannel("general", {}, base);
    joinChannel("general", { cardId: "card_A", handle: "alice" }, base);
    joinChannel("general", { cardId: "card_B", handle: "bob" }, base);
  });
  afterEach(() => { rmSync(base, { recursive: true, force: true }); });

  test("returns an array of the channels the token has access to", async () => {
    const app = buildShareApp(mkDeps());
    const r = await request(app).get("/api/channels?token=tk_good");
    assert.equal(r.status, 200);
    assert.ok(Array.isArray(r.body.channels), "payload must be an array");
    assert.equal(r.body.channels.length, 1, "one share link == one channel (today)");
    const ch = r.body.channels[0];
    assert.equal(ch.name, "general");
    assert.deepEqual(
      ch.members.map((m: { handle: string }) => m.handle).sort(),
      ["alice", "bob"],
    );
    assert.ok(ch.remainingMs > 0);
  });

  test("requires a token", async () => {
    const app = buildShareApp(mkDeps());
    const r = await request(app).get("/api/channels");
    assert.equal(r.status, 401);
  });

  test("rejects an expired share", async () => {
    const app = buildShareApp(mkDeps({ expiresAt: Date.now() - 1000 }));
    const r = await request(app).get("/api/channels?token=tk_good");
    assert.equal(r.status, 410);
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
      assert.ok(c.text.startsWith("The message below"), `missing warning prefix on ${c.session}`);
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

  test("uploaded image can be fetched back via /api/images/:msgId/:filename", async () => {
    const app = buildShareApp(mkDeps());
    const png = Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a, 0x11, 0x22]);
    const up = await request(app)
      .post("/api/channels/general/images?token=tk_good")
      .set("Content-Type", "image/png")
      .send(png);
    assert.equal(up.status, 200);
    // Round-trip: derive {msgId, filename} from the absolute path just like the
    // web client does, then GET it back.
    const parts = (up.body.path as string).split("/");
    const filename = parts.pop()!;
    const msgId = parts.pop()!;
    const get = await request(app).get(`/api/images/${msgId}/${filename}?token=tk_good`);
    assert.equal(get.status, 200);
    // Header check — Express sets content-type by extension.
    assert.match(get.headers["content-type"] ?? "", /^image\/png/);
    assert.deepEqual(Buffer.from(get.body).subarray(0, 8), png.subarray(0, 8));
  });

  test("image fetch rejects path traversal attempts", async () => {
    const app = buildShareApp(mkDeps());
    // Bad msgId (contains ../)
    const r1 = await request(app).get("/api/images/..%2F..%2Fetc/passwd?token=tk_good");
    assert.ok(r1.status === 400 || r1.status === 404,
      `expected 400/404 for traversal, got ${r1.status}`);
    // Well-formed but non-existent
    const r2 = await request(app).get("/api/images/img_nonexistent/0.png?token=tk_good");
    assert.equal(r2.status, 404);
  });

  test("image fetch requires a token", async () => {
    const app = buildShareApp(mkDeps());
    const r = await request(app).get("/api/images/img_abc/0.png");
    assert.equal(r.status, 401);
  });

  test("image fetch accepts hyphen-containing msg IDs from the native client", async () => {
    // Regression: web uploads use `img_<32-hex>` but the Swift app emits
    // `msg_<UUIDv4-slice>` like `msg_50F2861B-19A` which contains a hyphen.
    // Early regex rejected it as `bad image path` (400).
    const app = buildShareApp(mkDeps());
    const msgId = "msg_50F2861B-19A";
    const dir = join(base, "channels", "images", msgId);
    mkdirSync(dir, { recursive: true });
    const png = Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a, 0x99]);
    writeFileSync(join(dir, "0.png"), png);
    const r = await request(app).get(`/api/images/${msgId}/0.png?token=tk_good`);
    assert.equal(r.status, 200, `expected 200, got ${r.status} (${r.text})`);
    assert.deepEqual(Buffer.from(r.body).subarray(0, 8), png.subarray(0, 8));
  });

  test("image fetch works when baseDir lives under a dot-prefixed directory", async () => {
    // Regression: Express's res.sendFile defaults to dotfiles: "ignore", which
    // silently 404s any path with a dot-segment — e.g. ~/.kanban-code. This
    // test reproduces that layout and asserts the file comes through.
    const dotBase = mkdtempSync(join(tmpdir(), ".kanban-test-"));
    try {
      createChannel("general", {}, dotBase);
      const app = buildShareApp(mkDeps({ baseDir: dotBase }));
      const png = Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a, 0xaa, 0xbb]);
      const up = await request(app)
        .post("/api/channels/general/images?token=tk_good")
        .set("Content-Type", "image/png")
        .send(png);
      assert.equal(up.status, 200);
      const parts = (up.body.path as string).split("/");
      const filename = parts.pop()!;
      const msgId = parts.pop()!;
      const get = await request(app).get(`/api/images/${msgId}/${filename}?token=tk_good`);
      assert.equal(get.status, 200, `sendFile must serve under a dot dir, got ${get.status}`);
      assert.deepEqual(Buffer.from(get.body).subarray(0, 8), png.subarray(0, 8));
    } finally {
      rmSync(dotBase, { recursive: true, force: true });
    }
  });
});

describe("share-server long-poll", () => {
  beforeEach(() => {
    base = tmp();
    createChannel("general", {}, base);
    joinChannel("general", { cardId: "card_A", handle: "alice" }, base);
  });
  afterEach(() => { rmSync(base, { recursive: true, force: true }); });

  test("requires a token", async () => {
    const app = buildShareApp(mkDeps());
    const r = await request(app).get("/api/channels/general/poll");
    assert.equal(r.status, 401);
  });

  test("returns immediately with messages newer than `since`", async () => {
    // Seed the jsonl with a message the client has "already seen" and two it
    // hasn't. Polling with `since=<first id>` should return the other two.
    const app = buildShareApp(mkDeps());
    await request(app).post("/api/channels/general/send?token=tk_good")
      .send({ handle: "alice", body: "first" });
    await request(app).post("/api/channels/general/send?token=tk_good")
      .send({ handle: "alice", body: "second" });
    await request(app).post("/api/channels/general/send?token=tk_good")
      .send({ handle: "alice", body: "third" });
    // The jsonl has a leading `join` entry from beforeEach, so filter to real
    // messages before picking the `since` id.
    const sent = readMessages("general", base).filter((m) => m.type === "message");
    const start = Date.now();
    const r = await request(app).get(
      `/api/channels/general/poll?token=tk_good&since=${sent[0].id}`,
    );
    const elapsed = Date.now() - start;
    assert.equal(r.status, 200);
    assert.ok(elapsed < 500, `poll with backlog must return fast, took ${elapsed}ms`);
    assert.deepEqual(r.body.messages.map((m: { body: string }) => m.body), ["second", "third"]);
    assert.equal(r.body.lastId, sent[2].id);
  });

  test("hangs waiting for the next append when there's nothing newer", async () => {
    // With an empty tail, the poll should block ~until the next message
    // shows up on the jsonl. Simulate that by sending a message after a
    // short delay and asserting the poll resolves with it.
    const app = buildShareApp(mkDeps());
    await request(app).post("/api/channels/general/send?token=tk_good")
      .send({ handle: "alice", body: "seed" });
    const seed = readMessages("general", base).filter((m) => m.type === "message")[0];

    const pollPromise = request(app).get(
      `/api/channels/general/poll?token=tk_good&since=${seed.id}`,
    );
    setTimeout(() => {
      request(app).post("/api/channels/general/send?token=tk_good")
        .send({ handle: "alice", body: "async" })
        .end(() => { /* fire and forget */ });
    }, 80);

    const r = await pollPromise;
    assert.equal(r.status, 200);
    assert.ok(r.body.messages.length >= 1,
      `expected >=1 msg after async append, got ${JSON.stringify(r.body)}`);
    assert.ok(r.body.messages.some((m: { body: string }) => m.body === "async"));
  });

  test("cold-start poll (no `since`) returns empty so the client doesn't re-receive history", async () => {
    // History is served by the separate /history endpoint. The poll loop's
    // first iteration passes since=<last id from history>, but the guard
    // below covers a client that passes no `since`: it must not dump the
    // entire jsonl in bulk (which would look like every message arriving
    // twice in the UI).
    const app = buildShareApp(mkDeps());
    await request(app).post("/api/channels/general/send?token=tk_good")
      .send({ handle: "alice", body: "one" });
    const r = await new Promise<{ status: number; body: { messages: unknown[] } }>((resolve) => {
      // Add a short timeout so the hanging long-poll doesn't freeze the
      // test; 150ms is enough to see "nothing came back immediately".
      const req2 = request(app).get("/api/channels/general/poll?token=tk_good");
      const timer = setTimeout(() => { req2.abort(); resolve({ status: 0, body: { messages: [] } }); }, 150);
      req2.end((_err, response) => {
        clearTimeout(timer);
        if (response) resolve({ status: response.status, body: response.body });
        else resolve({ status: 0, body: { messages: [] } });
      });
    });
    // Either we got nothing back in 150ms (the long-poll is hanging — good)
    // OR we got back an empty array. Anything non-empty is a regression.
    assert.equal(r.body.messages.length, 0,
      `cold-start poll must not return history, got ${JSON.stringify(r.body)}`);
  });
});
