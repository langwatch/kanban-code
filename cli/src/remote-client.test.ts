import { test, describe, before, after, beforeEach, afterEach } from "node:test";
import { strict as assert } from "node:assert";
import { createServer, type IncomingMessage, type Server, type ServerResponse } from "node:http";
import { existsSync, mkdtempSync, readFileSync, rmSync, statSync, writeFileSync, mkdirSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { Command } from "commander";

import {
  registerRemoteCommands,
  resolveCardRef,
  parseColumn,
  normalizeUrl,
  remoteClientConfigPath,
  type RemoteCard,
  type RemoteIO,
  type RemoteMessage,
} from "./remote-client.js";
import {
  addDevice,
  generateRemoteToken,
  hashRemoteToken,
  pairingLink,
  readDevicesFile,
  remoteDevicesPath,
  revokeDevice,
  tailscaleHost,
} from "./remote-devices.js";
import { shouldProxy } from "./remote-proxy.js";

// ── Mock of the Mac's remote API (docs/remote-control.md) ────────────

const FULL_TOKEN = "kc_" + "a".repeat(40);
const AGENT_TOKEN = "kc_" + "b".repeat(40);

interface MockState {
  cards: RemoteCard[];
  transcripts: Map<string, RemoteMessage[]>;
  prompts: { cardId: string; text: string; mode?: string }[];
  tasks: unknown[];
  interrupts: string[];
  /** Card polls left before a busy card turns idle. */
  busyPolls: Map<string, number>;
}

function card(partial: Partial<RemoteCard> & { id: string; title: string }): RemoteCard {
  return {
    column: "in_progress",
    projectPath: "/Users/me/Projects/langwatch",
    projectName: "langwatch",
    assistant: "claude",
    runtime: "tmux",
    isLive: true,
    isBusy: false,
    terminals: [],
    prs: [],
    queuedPromptCount: 0,
    archived: false,
    updatedAt: "2026-09-26T09:00:00.000Z",
    ...partial,
  };
}

function freshState(): MockState {
  return {
    cards: [
      card({ id: "card_2abcFIRST", title: "Fix the flaky test", isBusy: true }),
      card({ id: "card_2abcSECOND", title: "Docs pass", column: "requires_attention" }),
      card({ id: "card_3zzzSTOPPED", title: "Old idea", column: "backlog", isLive: false, runtime: "none", projectName: "kanban", projectPath: "/Users/me/Projects/kanban" }),
      card({ id: "card_4arch", title: "Archived one", column: "done", archived: true }),
    ],
    transcripts: new Map([
      [
        "card_2abcFIRST",
        [
          { id: "m1", role: "user", text: "fix the flaky test", at: "2026-09-26T10:00:00.000Z" },
          { id: "m2", role: "assistant", text: "Looking at it.", at: "2026-09-26T10:00:01.000Z" },
        ],
      ],
    ]),
    prompts: [],
    tasks: [],
    interrupts: [],
    busyPolls: new Map(),
  };
}

let state: MockState;
let server: Server;
let baseUrl: string;

function send(res: ServerResponse, status: number, body?: unknown): void {
  res.writeHead(status, body === undefined ? {} : { "content-type": "application/json" });
  res.end(body === undefined ? undefined : JSON.stringify(body));
}

async function readBody(req: IncomingMessage): Promise<any> {
  const chunks: Buffer[] = [];
  for await (const chunk of req) chunks.push(chunk as Buffer);
  const text = Buffer.concat(chunks).toString("utf8");
  return text ? JSON.parse(text) : undefined;
}

async function handle(req: IncomingMessage, res: ServerResponse): Promise<void> {
  const url = new URL(req.url ?? "/", "http://mock");
  const path = url.pathname;
  if (req.method === "GET" && path === "/v1/health") {
    return send(res, 200, { app: "kanban-code", version: "9.9.9", apiVersion: 1, hostName: "mock-mac" });
  }
  const auth = req.headers.authorization ?? "";
  const token = auth.startsWith("Bearer ") ? auth.slice(7) : "";
  if (token !== FULL_TOKEN && token !== AGENT_TOKEN) return send(res, 401, { error: "unknown token" });
  const scope = token === FULL_TOKEN ? "full" : "agent";

  if (req.method === "GET" && path === "/v1/me") {
    return send(res, 200, { id: `dev_${scope}`, name: scope === "full" ? "iPhone" : "openclaw", scope, createdAt: "2026-09-26T09:00:00.000Z", lastSeenAt: null });
  }
  if (req.method === "GET" && path === "/v1/board") {
    // Like the server: the working set unless ?all=1.
    const all = url.searchParams.get("all") === "1";
    return send(res, 200, {
      cards: all ? state.cards : state.cards.filter((c: any) => !c.archived && c.column !== "all_sessions"),
      projects: [
        { path: "/Users/me/Projects/langwatch", name: "langwatch" },
        { path: "/Users/me/Projects/kanban", name: "kanban" },
      ],
      generatedAt: "2026-09-26T10:00:00.000Z",
    });
  }
  if (req.method === "POST" && path === "/v1/tasks") {
    const body = await readBody(req);
    if (!["langwatch", "/users/me/projects/langwatch"].includes(String(body.project).toLowerCase())) {
      return send(res, 400, { error: `unknown project ${body.project}; known: langwatch, kanban` });
    }
    state.tasks.push(body);
    const created = card({ id: "card_9NEW", title: body.name ?? body.prompt.slice(0, 30), isBusy: body.launch !== false, isLive: body.launch !== false, column: body.launch === false ? "backlog" : "in_progress", worktreePath: body.worktree !== undefined ? "/wt/x" : null });
    state.cards.push(created);
    return send(res, 201, created);
  }
  const m = /^\/v1\/cards\/([^/]+)(\/[a-z]+)?$/.exec(path);
  if (m) {
    const id = decodeURIComponent(m[1]);
    const c = state.cards.find((x) => x.id === id);
    if (!c) return send(res, 404, { error: `no card ${id}` });
    const action = m[2];
    if (!action && req.method === "GET") {
      const left = state.busyPolls.get(id);
      if (left !== undefined) {
        if (left <= 0) {
          c.isBusy = false;
          state.busyPolls.delete(id);
        } else {
          state.busyPolls.set(id, left - 1);
          const msgs = state.transcripts.get(id) ?? [];
          msgs.push({ id: `poll${left}`, role: "assistant", text: `step ${left}` });
          state.transcripts.set(id, msgs);
        }
      }
      return send(res, 200, c);
    }
    if (action === "/transcript" && req.method === "GET") {
      const limit = Number(url.searchParams.get("limit") ?? 50);
      const all = state.transcripts.get(id) ?? [];
      return send(res, 200, { cardId: id, messages: all.slice(-limit), olderCursor: null });
    }
    if (action === "/prompt" && req.method === "POST") {
      if (!c.isLive) return send(res, 409, { error: "no live session" });
      const body = await readBody(req);
      state.prompts.push({ cardId: id, ...body });
      return send(res, 204);
    }
    if (action === "/interrupt" && req.method === "POST") {
      if (!c.isLive) return send(res, 409, { error: "no live session" });
      state.interrupts.push(id);
      return send(res, 204);
    }
    if (action === "/resume" && req.method === "POST") {
      c.isLive = true;
      c.runtime = "tmux";
      return send(res, 200, c);
    }
    if (action === "/terminal") return send(res, scope === "full" ? 426 : 403, { error: "terminal needs scope full" });
  }
  return send(res, 404, { error: "not found" });
}

// ── Harness ──────────────────────────────────────────────────────────

class ExitSignal extends Error {
  constructor(readonly code: number) {
    super(`exit ${code}`);
  }
}

let home: string;
const savedEnv = { ...process.env };

async function run(
  args: string[],
  opts: { env?: NodeJS.ProcessEnv; stdin?: string } = {}
): Promise<{ code: number; out: string; err: string }> {
  let out = "";
  let err = "";
  let clock = 0;
  const io: RemoteIO = {
    out: (t) => void (out += t),
    err: (t) => void (err += t),
    readStdin: async () => opts.stdin ?? "",
    env: { KANBAN_CODE_HOME: home, ...opts.env },
    sleep: async (ms) => void (clock += ms),
    now: () => Date.parse("2026-09-26T10:00:05.000Z") + clock,
    exit: (code) => {
      throw new ExitSignal(code);
    },
  };
  const program = new Command().exitOverride().configureOutput({ writeOut: (t) => (out += t), writeErr: (t) => (err += t) });
  registerRemoteCommands(program, io);
  program.commands.forEach((c) => c.exitOverride());
  program.commands[0]?.commands.forEach((c) => c.exitOverride());
  try {
    await program.parseAsync(["node", "kanban", "remote", ...args]);
    return { code: 0, out, err };
  } catch (error) {
    if (error instanceof ExitSignal) return { code: error.code, out, err };
    const code = (error as { exitCode?: number }).exitCode;
    if (typeof code === "number") return { code, out, err };
    throw error;
  }
}

async function loggedIn(token = FULL_TOKEN): Promise<void> {
  const r = await run(["login", baseUrl, "--token", token]);
  assert.equal(r.code, 0, r.err);
}

before(async () => {
  server = createServer((req, res) => {
    handle(req, res).catch((e) => send(res, 500, { error: String(e) }));
  });
  await new Promise<void>((resolve) => server.listen(0, "127.0.0.1", resolve));
  const addr = server.address() as { port: number };
  baseUrl = `http://127.0.0.1:${addr.port}`;
});

after(() => {
  server.close();
});

beforeEach(() => {
  state = freshState();
  home = mkdtempSync(join(tmpdir(), "kanban-remote-client-test-"));
  process.env.KANBAN_CODE_HOME = home;
});

afterEach(() => {
  rmSync(home, { recursive: true, force: true });
  process.env = { ...savedEnv };
});

// ── Client ───────────────────────────────────────────────────────────

describe("kanban remote login / whoami / logout", () => {
  test("login checks health and me, then saves the config with mode 600", async () => {
    const r = await run(["login", baseUrl + "/", "--token", FULL_TOKEN]);
    assert.equal(r.code, 0, r.err);
    assert.match(r.out, /Logged in to mock-mac .* as 'iPhone', scope full/);
    const path = join(home, "remote-client.json");
    assert.equal(remoteClientConfigPath(), path);
    const saved = JSON.parse(readFileSync(path, "utf8"));
    assert.equal(saved.url, baseUrl);
    assert.equal(saved.token, FULL_TOKEN);
    assert.equal(saved.scope, "full");
    assert.equal(statSync(path).mode & 0o777, 0o600);
  });

  test("login with a bad token fails with a 401 hint and saves nothing", async () => {
    const r = await run(["login", baseUrl, "--token", "kc_nope"]);
    assert.equal(r.code, 1);
    assert.match(r.err, /refused the token \(401: unknown token\)/);
    assert.match(r.err, /kanban remote pair/);
    assert.equal(existsSync(join(home, "remote-client.json")), false);
  });

  test("an unreachable Mac names Tailscale", async () => {
    const r = await run(["login", "http://127.0.0.1:9", "--token", FULL_TOKEN]);
    assert.equal(r.code, 1);
    assert.match(r.err, /Cannot reach the Kanban Code Mac at http:\/\/127\.0\.0\.1:9/);
    assert.match(r.err, /Tailscale/);
  });

  test("whoami reports the device, env vars override the file", async () => {
    await loggedIn();
    let r = await run(["whoami"]);
    assert.equal(r.code, 0, r.err);
    assert.match(r.out, /iPhone \(dev_full\), scope full/);
    r = await run(["whoami", "--json"], { env: { KANBAN_REMOTE_TOKEN: AGENT_TOKEN } });
    const parsed = JSON.parse(r.out);
    assert.equal(parsed.device.scope, "agent");
    assert.match(parsed.source, /KANBAN_REMOTE_TOKEN over/);
  });

  test("env vars alone work without a login", async () => {
    const r = await run(["cards", "--json"], { env: { KANBAN_REMOTE_URL: baseUrl, KANBAN_REMOTE_TOKEN: AGENT_TOKEN } });
    assert.equal(r.code, 0, r.err);
    assert.equal(JSON.parse(r.out).length, 3);
  });

  test("without a login the error says how to log in", async () => {
    const r = await run(["cards"]);
    assert.equal(r.code, 1);
    assert.match(r.err, /kanban remote login <url> --token <token>/);
  });

  test("logout removes the file", async () => {
    await loggedIn();
    const r = await run(["logout"]);
    assert.equal(r.code, 0);
    assert.equal(existsSync(join(home, "remote-client.json")), false);
  });

  test("a revoked token turns into a 401 on the next command", async () => {
    await loggedIn();
    const r = await run(["cards"], { env: { KANBAN_REMOTE_TOKEN: "kc_revoked" } });
    assert.equal(r.code, 1);
    assert.match(r.err, /401/);
  });
});

describe("kanban remote cards / show / projects", () => {
  beforeEach(() => loggedIn());

  test("cards hides archived ones and filters by column and project", async () => {
    let r = await run(["cards"]);
    assert.equal(r.code, 0, r.err);
    assert.match(r.out, /card_2abcFIRST\s+In Progress\s+busy/);
    assert.match(r.out, /card_3zzzSTOPPED\s+Backlog\s+stopped/);
    assert.doesNotMatch(r.out, /Archived one/);

    r = await run(["cards", "--column", "waiting", "--json"]);
    assert.deepEqual(JSON.parse(r.out).map((c: RemoteCard) => c.id), ["card_2abcSECOND"]);

    r = await run(["cards", "--project", "kanban", "--json"]);
    assert.deepEqual(JSON.parse(r.out).map((c: RemoteCard) => c.id), ["card_3zzzSTOPPED"]);

    r = await run(["cards", "--all", "--json"]);
    assert.equal(JSON.parse(r.out).length, 4);
  });

  test("an unknown column lists the known ones", async () => {
    const r = await run(["cards", "--column", "later"]);
    assert.equal(r.code, 1);
    assert.match(r.err, /Unknown column 'later'.*requires_attention \(Waiting\)/);
  });

  test("show takes a unique id prefix or an exact title", async () => {
    let r = await run(["show", "card_3"]);
    assert.equal(r.code, 0, r.err);
    assert.match(r.out, /Old idea\n  id:\s+card_3zzzSTOPPED/);
    r = await run(["show", "docs pass", "--json"]);
    assert.equal(JSON.parse(r.out).id, "card_2abcSECOND");
  });

  test("an ambiguous prefix lists the candidates", async () => {
    const r = await run(["show", "card_2abc"]);
    assert.equal(r.code, 1);
    assert.match(r.err, /matches 2 cards/);
    assert.match(r.err, /card_2abcFIRST\s+Fix the flaky test/);
  });

  test("projects lists names and paths", async () => {
    const r = await run(["projects"]);
    assert.match(r.out, /langwatch\s+\/Users\/me\/Projects\/langwatch/);
  });
});

describe("kanban remote task / send / interrupt / resume", () => {
  beforeEach(() => loggedIn(AGENT_TOKEN));

  test("task sends the contract body with a random worktree", async () => {
    const r = await run(["task", "--project", "langwatch", "--worktree", "--name", "Flaky", "fix", "the", "flaky", "test"]);
    assert.equal(r.code, 0, r.err);
    assert.deepEqual(state.tasks[0], { project: "langwatch", prompt: "fix the flaky test", name: "Flaky", worktree: "" });
    assert.match(r.out, /Created card_9NEW "Flaky" in langwatch/);
    assert.match(r.out, /transcript card_9NEW --follow/);
  });

  test("task reads the prompt from stdin and passes a named worktree, model and no-launch", async () => {
    const r = await run(
      ["task", "--project", "/Users/me/Projects/langwatch", "--worktree=fix-flaky", "--assistant", "codex", "--model", "gpt-5", "--no-launch", "--json", "-"],
      { stdin: "line one\nline two\n" }
    );
    assert.equal(r.code, 0, r.err);
    assert.deepEqual(state.tasks[0], {
      project: "/Users/me/Projects/langwatch",
      prompt: "line one\nline two",
      worktree: "fix-flaky",
      assistant: "codex",
      model: "gpt-5",
      launch: false,
    });
    assert.equal(JSON.parse(r.out).column, "backlog");
  });

  test("an unknown project shows the server's 400 message", async () => {
    const r = await run(["task", "--project", "nope", "do it"]);
    assert.equal(r.code, 1);
    assert.match(r.err, /unknown project nope; known: langwatch, kanban/);
  });

  test("send queues by default and interrupts with --now", async () => {
    let r = await run(["send", "card_2abcF", "also", "run", "the", "tests"]);
    assert.equal(r.code, 0, r.err);
    assert.match(r.out, /delivered when the turn ends/);
    r = await run(["send", "Fix the flaky test", "--now", "-"], { stdin: "stop, wrong file\n" });
    assert.equal(r.code, 0, r.err);
    assert.deepEqual(state.prompts, [
      { cardId: "card_2abcFIRST", text: "also run the tests", mode: "queue" },
      { cardId: "card_2abcFIRST", text: "stop, wrong file", mode: "now" },
    ]);
  });

  test("send to a card with no live session explains the 409 and how to resume", async () => {
    const r = await run(["send", "card_3", "hello"]);
    assert.equal(r.code, 1);
    assert.match(r.err, /no live session \(409\)\. Run: kanban remote resume card_3zzzSTOPPED/);
  });

  test("interrupt and resume", async () => {
    let r = await run(["interrupt", "card_2abcF"]);
    assert.equal(r.code, 0, r.err);
    assert.deepEqual(state.interrupts, ["card_2abcFIRST"]);
    r = await run(["resume", "Old idea"]);
    assert.equal(r.code, 0, r.err);
    assert.match(r.out, /Resumed card_3zzzSTOPPED "Old idea" \(idle\)/);
  });
});

describe("kanban remote transcript / wait", () => {
  beforeEach(() => loggedIn(AGENT_TOKEN));

  test("transcript prints the latest messages", async () => {
    const r = await run(["transcript", "card_2abcF", "--limit", "1"]);
    assert.equal(r.code, 0, r.err);
    assert.doesNotMatch(r.out, /fix the flaky test/);
    assert.match(r.out, /assistant:\n  Looking at it\./);
  });

  test("--follow prints each new message once until the card is idle", async () => {
    state.busyPolls.set("card_2abcFIRST", 2);
    const r = await run(["transcript", "card_2abcF", "--follow", "--json"]);
    assert.equal(r.code, 0, r.err);
    const ids = r.out.trim().split("\n").map((l) => JSON.parse(l).id);
    assert.deepEqual(ids, ["m1", "m2", "poll2", "poll1"]);
  });

  test("wait returns once the card settles", async () => {
    state.busyPolls.set("card_2abcFIRST", 3);
    const r = await run(["wait", "card_2abcF"]);
    assert.equal(r.code, 0, r.err);
    assert.match(r.out, /is idle/);
  });

  test("wait exits 124 on timeout", async () => {
    state.busyPolls.set("card_2abcFIRST", 1000);
    const r = await run(["wait", "card_2abcF", "--timeout", "10s"]);
    assert.equal(r.code, 124);
    assert.match(r.err, /still busy/);
  });

  test("wait on a quiet idle card returns at once", async () => {
    const r = await run(["wait", "card_2abcSECOND", "--timeout", "1s"]);
    assert.equal(r.code, 0, r.err);
  });

  test("a bad --timeout is a usage error", async () => {
    const r = await run(["wait", "card_2abcF", "--timeout", "soon"]);
    assert.notEqual(r.code, 0);
    assert.match(r.err, /duration like 90/);
  });
});

describe("helpers", () => {
  test("inside a remote card, kanban remote runs locally instead of going to the proxy", () => {
    const env = { KANBAN_REMOTE_PROXY: "1" };
    assert.equal(shouldProxy(["remote", "cards"], env), false);
    assert.equal(shouldProxy(["cards"], env), true);
  });

  test("resolveCardRef prefers the exact id over a prefix", () => {
    const cards = [card({ id: "abc", title: "x" }), card({ id: "abcd", title: "y" })];
    assert.equal(resolveCardRef(cards, "abc").id, "abc");
    assert.throws(() => resolveCardRef(cards, "zzz"), /No card matches/);
  });

  test("parseColumn takes wire values and display names", () => {
    assert.equal(parseColumn("In Progress"), "in_progress");
    assert.equal(parseColumn("waiting"), "requires_attention");
    assert.equal(parseColumn("requires_attention"), "requires_attention");
  });

  test("normalizeUrl adds a scheme and trims slashes", () => {
    assert.equal(normalizeUrl("mac.tail1234.ts.net:7780/"), "http://mac.tail1234.ts.net:7780");
    assert.equal(normalizeUrl("https://mac.ts.net:7780"), "https://mac.ts.net:7780");
  });
});

// ── Pairing on the Mac ───────────────────────────────────────────────

describe("devices.json", () => {
  test("tokens are kc_ plus 40 base62 characters", () => {
    for (let i = 0; i < 50; i++) assert.match(generateRemoteToken(), /^kc_[0-9A-Za-z]{40}$/);
  });

  test("the path follows KANBAN_CODE_HOME", () => {
    assert.equal(remoteDevicesPath(), join(home, "remote", "devices.json"));
  });

  test("addDevice writes the shared format with only the token hash", () => {
    const { device, token } = addDevice("openclaw", "agent", remoteDevicesPath(), new Date("2026-09-26T10:00:00Z"));
    const raw = readFileSync(remoteDevicesPath(), "utf8");
    assert.doesNotMatch(raw, new RegExp(token));
    const file = JSON.parse(raw);
    assert.deepEqual(Object.keys(file), ["devices"]);
    assert.deepEqual(file.devices[0], {
      id: device.id,
      name: "openclaw",
      scope: "agent",
      tokenHash: hashRemoteToken(token),
      createdAt: "2026-09-26T10:00:00.000Z",
      lastSeenAt: null,
    });
    assert.match(file.devices[0].tokenHash, /^[0-9a-f]{64}$/);
    assert.equal(statSync(remoteDevicesPath()).mode & 0o777, 0o600);
  });

  test("known SHA-256 of a token", () => {
    assert.equal(hashRemoteToken("abc"), "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad");
  });

  test("other devices and unknown keys survive add and revoke", () => {
    mkdirSync(join(home, "remote"), { recursive: true });
    const existing = {
      devices: [
        { id: "dev_phone", name: "iPhone", scope: "full", tokenHash: "f".repeat(64), createdAt: "2026-09-01T00:00:00.000Z", lastSeenAt: "2026-09-25T00:00:00.000Z", extra: 1 },
      ],
      version: 7,
    };
    writeFileSync(remoteDevicesPath(), JSON.stringify(existing));
    const { device } = addDevice("openclaw", "agent");
    let file = readDevicesFile();
    assert.equal(file.version, 7);
    assert.deepEqual(file.devices[0], existing.devices[0]);
    revokeDevice(device.id);
    file = readDevicesFile();
    assert.deepEqual(file, existing);
  });

  test("revoke by name, and refuses an ambiguous name", () => {
    addDevice("twin", "agent");
    addDevice("twin", "full");
    addDevice("solo", "full");
    assert.throws(() => revokeDevice("twin"), /2 devices are named 'twin'/);
    assert.equal(revokeDevice("SOLO").name, "solo");
    assert.throws(() => revokeDevice("solo"), /No paired device/);
  });

  test("pair, devices and revoke commands", async () => {
    const r = await run(["pair", "--name", "openclaw", "--scope", "agent", "--url", "http://mac.tail.ts.net:7780", "--json"]);
    assert.equal(r.code, 0, r.err);
    const out = JSON.parse(r.out);
    assert.match(out.token, /^kc_[0-9A-Za-z]{40}$/);
    assert.equal(out.link, pairingLink("http://mac.tail.ts.net:7780", out.token));
    assert.ok(out.link.startsWith(`kanbancode://pair?url=http%3A%2F%2Fmac.tail.ts.net%3A7780&token=${out.token}&name=`));
    assert.equal(readDevicesFile().devices[0].tokenHash, hashRemoteToken(out.token));

    let list = await run(["devices"]);
    assert.match(list.out, /openclaw\s+agent/);
    assert.doesNotMatch(list.out, /tokenHash/);

    const rv = await run(["revoke", "openclaw"]);
    assert.equal(rv.code, 0, rv.err);
    list = await run(["devices"]);
    assert.match(list.out, /No paired devices/);
    const missing = await run(["revoke", "openclaw"]);
    assert.equal(missing.code, 1);
  });

  test("an invalid scope is refused", async () => {
    const r = await run(["pair", "--name", "x", "--scope", "root"]);
    assert.notEqual(r.code, 0);
    assert.equal(existsSync(remoteDevicesPath()), false);
  });

  test("tailscaleHost prefers MagicDNS, then the IPv4, then nothing", () => {
    const status = (self: object) => () => JSON.stringify({ Self: self });
    assert.equal(tailscaleHost(status({ DNSName: "mac.tail1234.ts.net.", TailscaleIPs: ["100.1.2.3"] })), "mac.tail1234.ts.net");
    assert.equal(tailscaleHost(status({ DNSName: "", TailscaleIPs: ["fd7a::1", "100.1.2.3"] })), "100.1.2.3");
    assert.equal(tailscaleHost(() => { throw new Error("not installed"); }), undefined);
  });
});
