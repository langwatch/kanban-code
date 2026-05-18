import { test, describe, beforeEach, afterEach } from "node:test";
import { strict as assert } from "node:assert";
import { mkdtempSync, rmSync, existsSync, readFileSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import {
  channelDirs,
  channelLogPath,
  dmLogPath,
  validateChannelName,
  normalizeChannelName,
  createChannel,
  listChannels,
  getChannel,
  deleteChannel,
  renameChannel,
  persistMessageImages,
  joinChannel,
  leaveChannel,
  isMember,
  sendMessage,
  readMessages,
  readTail,
  appendDirectMessage,
  readDirectMessages,
  statChannel,
} from "./channels.js";

let base: string;

function newTmpBase(): string {
  return mkdtempSync(join(tmpdir(), "kanban-channels-test-"));
}

describe("path helpers", () => {
  test("channelDirs layout", () => {
    const d = channelDirs("/tmp/foo");
    assert.equal(d.base, "/tmp/foo/channels");
    assert.equal(d.channelsFile, "/tmp/foo/channels/channels.json");
    assert.equal(d.dm, "/tmp/foo/channels/dm");
  });

  test("channelLogPath rejects invalid names", () => {
    assert.throws(() => channelLogPath("Bad Name", "/tmp/foo"));
    assert.throws(() => channelLogPath("../etc", "/tmp/foo"));
  });

  test("dmLogPath sorts the pair", () => {
    const a = dmLogPath("card_B", "card_A", "/tmp/foo");
    const b = dmLogPath("card_A", "card_B", "/tmp/foo");
    assert.equal(a, b);
    assert.ok(a.includes("card_A__card_B"));
  });
});

describe("validation", () => {
  test("valid names accepted", () => {
    for (const n of ["general", "dev-ops", "team_1", "a"]) {
      validateChannelName(n);
    }
  });
  test("invalid names rejected", () => {
    for (const n of ["", "Has Space", "BadCase", "-leading-dash", "#leading", "a".repeat(65)]) {
      assert.throws(() => validateChannelName(n), new RegExp("Invalid"), `should reject ${n}`);
    }
  });
  test("normalizeChannelName strips # and lowercases", () => {
    assert.equal(normalizeChannelName("#General"), "general");
    assert.equal(normalizeChannelName("general"), "general");
  });
});

describe("channel CRUD", () => {
  beforeEach(() => { base = newTmpBase(); });
  afterEach(() => { rmSync(base, { recursive: true, force: true }); });

  test("createChannel creates metadata + empty jsonl", () => {
    const ch = createChannel("general", {}, base);
    assert.equal(ch.name, "general");
    assert.ok(ch.id.startsWith("ch_"));
    assert.ok(existsSync(channelLogPath("general", base)));
    const file = readFileSync(channelDirs(base).channelsFile, "utf-8");
    assert.ok(file.includes("\"general\""));
  });

  test("createChannel strips leading #", () => {
    const ch = createChannel("#general", {}, base);
    assert.equal(ch.name, "general");
  });

  test("createChannel rejects duplicates", () => {
    createChannel("general", {}, base);
    assert.throws(() => createChannel("general", {}, base), /already exists/);
  });

  test("listChannels returns all in order of creation", () => {
    createChannel("alpha", {}, base);
    createChannel("beta", {}, base);
    const list = listChannels(base);
    assert.equal(list.length, 2);
    assert.deepEqual(list.map((c) => c.name), ["alpha", "beta"]);
  });

  test("getChannel finds by normalized name", () => {
    createChannel("general", {}, base);
    assert.ok(getChannel("#General", base));
    assert.equal(getChannel("nonexistent", base), undefined);
  });

  test("deleteChannel removes metadata", () => {
    createChannel("general", {}, base);
    assert.equal(deleteChannel("general", base), true);
    assert.equal(listChannels(base).length, 0);
    assert.equal(deleteChannel("general", base), false);
  });

  test("renameChannel updates metadata and moves jsonl log", () => {
    createChannel("general", {}, base);
    sendMessage("general", { cardId: null, handle: "me" }, "hi", base);
    const oldLog = channelLogPath("general", base);
    assert.ok(existsSync(oldLog));

    const ok = renameChannel("general", "coord", base);
    assert.equal(ok, true);

    const channels = listChannels(base);
    assert.equal(channels.length, 1);
    assert.equal(channels[0].name, "coord");

    const newLog = channelLogPath("coord", base);
    assert.ok(existsSync(newLog));
    assert.ok(!existsSync(oldLog));

    // Message history survives the rename.
    const msgs = readMessages("coord", base);
    assert.equal(msgs.length, 1);
    assert.equal(msgs[0].body, "hi");
  });

  test("renameChannel rejects collision with existing name", () => {
    createChannel("general", {}, base);
    createChannel("coord", {}, base);
    assert.throws(() => renameChannel("general", "coord", base), /already exists/);
  });

  test("renameChannel is a no-op when old name doesn't exist", () => {
    assert.equal(renameChannel("nonexistent", "coord", base), false);
  });
});

describe("membership", () => {
  beforeEach(() => { base = newTmpBase(); });
  afterEach(() => { rmSync(base, { recursive: true, force: true }); });

  test("joinChannel adds member and emits join event", () => {
    createChannel("general", {}, base);
    const { alreadyMember, channel } = joinChannel(
      "general",
      { cardId: "card_abc", handle: "alice" },
      base
    );
    assert.equal(alreadyMember, false);
    assert.equal(channel.members.length, 1);
    const msgs = readMessages("general", base);
    assert.equal(msgs.length, 1);
    assert.equal(msgs[0].type, "join");
    assert.ok(msgs[0].body.includes("@alice joined"));
  });

  test("joinChannel is idempotent per cardId", () => {
    createChannel("general", {}, base);
    joinChannel("general", { cardId: "card_abc", handle: "alice" }, base);
    const { alreadyMember } = joinChannel(
      "general",
      { cardId: "card_abc", handle: "alice" },
      base
    );
    assert.equal(alreadyMember, true);
    assert.equal(listChannels(base)[0].members.length, 1);
  });

  test("joinChannel refreshes stale card id for same handle", () => {
    createChannel("general", {}, base);
    joinChannel("general", { cardId: "card_old", handle: "alice" }, base);
    const { alreadyMember } = joinChannel(
      "general",
      { cardId: "card_current", handle: "alice" },
      base
    );

    const members = listChannels(base)[0].members;
    assert.equal(alreadyMember, true);
    assert.equal(members.length, 1);
    assert.equal(members[0].cardId, "card_current");
  });

  test("joinChannel errors on unknown channel", () => {
    assert.throws(
      () => joinChannel("unknown", { cardId: "c", handle: "h" }, base),
      /does not exist/
    );
  });

  test("leaveChannel removes member and emits leave event", () => {
    createChannel("general", {}, base);
    joinChannel("general", { cardId: "card_abc", handle: "alice" }, base);
    const ch = leaveChannel("general", { cardId: "card_abc", handle: "alice" }, base);
    assert.ok(ch);
    assert.equal(ch!.members.length, 0);
    const msgs = readMessages("general", base);
    assert.ok(msgs.some((m) => m.type === "leave"));
  });

  test("two --as handles don't collide when both have null cardId", () => {
    createChannel("general", {}, base);
    joinChannel("general", { cardId: null, handle: "alice" }, base);
    joinChannel("general", { cardId: null, handle: "bob" }, base);
    joinChannel("general", { cardId: null, handle: "user" }, base);
    const all = listChannels(base);
    assert.equal(all[0].members.length, 3);
  });

  test("isMember true/false", () => {
    createChannel("general", {}, base);
    const { channel } = joinChannel(
      "general",
      { cardId: "card_abc", handle: "alice" },
      base
    );
    assert.equal(isMember(channel, "card_abc"), true);
    assert.equal(isMember(channel, "card_xyz"), false);
  });
});

describe("messages", () => {
  beforeEach(() => { base = newTmpBase(); });
  afterEach(() => { rmSync(base, { recursive: true, force: true }); });

  test("sendMessage appends to jsonl", () => {
    createChannel("general", {}, base);
    const m = sendMessage(
      "general",
      { cardId: "card_abc", handle: "alice" },
      "hello",
      base
    );
    assert.equal(m.body, "hello");
    const all = readMessages("general", base);
    assert.equal(all.length, 1);
    assert.equal(all[0].body, "hello");
    assert.equal(all[0].from.handle, "alice");
  });

  test("sendMessage errors on unknown channel", () => {
    assert.throws(
      () => sendMessage("unknown", { cardId: "c", handle: "h" }, "x", base),
      /does not exist/
    );
  });

  test("readTail returns last N", () => {
    createChannel("general", {}, base);
    for (let i = 0; i < 5; i++) {
      sendMessage("general", { cardId: "c", handle: "a" }, `m${i}`, base);
    }
    const tail = readTail("general", 3, base);
    assert.deepEqual(tail.map((m) => m.body), ["m2", "m3", "m4"]);
  });

  test("sendMessage with imagePaths persists images + stores paths in jsonl", () => {
    createChannel("pics", {}, base);
    // Create a source image in tmp
    const src = join(base, "src.png");
    writeFileSync(src, Buffer.from([0x89, 0x50, 0x4E, 0x47]));
    const m = sendMessage(
      "pics",
      { cardId: null, handle: "alice" },
      "check this",
      base,
      [src]
    );
    assert.equal(m.imagePaths?.length, 1);
    const persisted = m.imagePaths![0];
    assert.ok(existsSync(persisted), "persisted image should exist");
    assert.ok(persisted.includes(`/images/${m.id}/`), "persisted path under images/<id>/");

    // Round-trip: reloaded message carries imagePaths.
    const msgs = readMessages("pics", base);
    assert.deepEqual(msgs[0].imagePaths, m.imagePaths);
  });

  test("persistMessageImages skips missing source files", () => {
    const paths = persistMessageImages("msg_x", ["/does/not/exist.png"], base);
    assert.equal(paths.length, 0);
  });

  test("statChannel returns counts and last", () => {
    createChannel("general", {}, base);
    joinChannel("general", { cardId: "card_a", handle: "alice" }, base);
    sendMessage("general", { cardId: "card_a", handle: "alice" }, "hi", base);
    const s = statChannel("general", base);
    assert.ok(s);
    assert.equal(s!.messageCount, 2); // join + message
    assert.equal(s!.lastMessage?.body, "hi");
  });
});

describe("direct messages", () => {
  beforeEach(() => { base = newTmpBase(); });
  afterEach(() => { rmSync(base, { recursive: true, force: true }); });

  test("DM file path is stable regardless of party order", () => {
    appendDirectMessage(
      {
        id: "msg_1",
        ts: "2026-01-01T00:00:00Z",
        from: { cardId: "card_A", handle: "alice" },
        to: { cardId: "card_B", handle: "bob" },
        body: "hi bob",
      },
      base
    );
    const fwd = readDirectMessages("card_A", "card_B", base);
    const rev = readDirectMessages("card_B", "card_A", base);
    assert.equal(fwd.length, 1);
    assert.equal(rev.length, 1);
    assert.equal(fwd[0].body, "hi bob");
  });
});
