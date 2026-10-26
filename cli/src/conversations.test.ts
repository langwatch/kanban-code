import { test, describe, beforeEach, afterEach } from "node:test";
import { strict as assert } from "node:assert";
import { appendFileSync, existsSync, mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { CONVERSATION_ADJECTIVES, CONVERSATION_ANIMALS } from "./conversation-words.js";
import {
  ConversationError,
  conversationLogPath,
  createConversation,
  foldConversations,
  formatConversationList,
  generateConversationId,
  isValidConversationId,
  listCardConversations,
  listSummaries,
  peerConversationLogPath,
  previewText,
  replyToConversation,
  setConversationTitle,
  showConversation,
  summarizeConversation,
  type ConversationContext,
} from "./conversations.js";
import type { Link } from "./types.js";

function link(id: string, extra: Partial<Link> = {}): Link {
  return {
    id,
    column: "in_progress",
    createdAt: "2026-10-26T00:00:00Z",
    updatedAt: "2026-10-26T00:00:00Z",
    manualOverrides: { worktreePath: false, tmuxSession: false, name: false, column: false, prLink: false, issueLink: false },
    manuallyArchived: false,
    source: "manual",
    isRemote: false,
    ...extra,
  } as Link;
}

const lines = (...events: object[]) => events.map((event) => JSON.stringify(event)).join("\n") + "\n";

describe("foldConversations", () => {
  test("builds titles, messages and the summary fields", () => {
    const log = lines(
      { type: "created", conv: "swift-otter", at: "2026-10-26T10:00:00.000Z", by: "human" },
      { type: "message", conv: "swift-otter", id: "m1", role: "human", text: "can we harden the vault?", at: "2026-10-26T10:00:01.000Z" },
      { type: "message", conv: "swift-otter", id: "m2", role: "agent", text: "Yes,\n  starting with   leases.", at: "2026-10-26T10:00:05.000Z" },
      { type: "title", conv: "swift-otter", title: "Vault hardening", at: "2026-10-26T10:00:05.000Z", by: "agent" }
    );
    const [conversation] = foldConversations(log);
    const summary = summarizeConversation(conversation);
    assert.equal(summary.id, "swift-otter");
    assert.equal(summary.title, "Vault hardening");
    assert.equal(summary.createdAt, "2026-10-26T10:00:00.000Z");
    assert.equal(summary.updatedAt, "2026-10-26T10:00:05.000Z");
    assert.equal(summary.messageCount, 2);
    assert.equal(summary.lastRole, "agent");
    assert.equal(summary.preview, "Yes, starting with   leases.");
    assert.equal(summary.waiting, true);
    assert.equal(summary.unread, true);
    assert.equal(summary.replied, true);
    assert.equal(summary.archived, false);
  });

  test("a message with a known id replaces its text in place", () => {
    const log = lines(
      { type: "created", conv: "calm-heron", at: "2026-10-26T10:00:00.000Z", by: "human" },
      { type: "message", conv: "calm-heron", id: "m1", role: "human", text: "first", at: "2026-10-26T10:00:01.000Z" },
      { type: "message", conv: "calm-heron", id: "m2", role: "human", text: "second", at: "2026-10-26T10:00:02.000Z" },
      { type: "message", conv: "calm-heron", id: "m1", role: "human", text: "first, edited", at: "2026-10-26T10:00:03.000Z" }
    );
    const [conversation] = foldConversations(log);
    assert.deepEqual(conversation.messages.map((m) => [m.id, m.text, m.at]), [
      ["m1", "first, edited", "2026-10-26T10:00:01.000Z"],
      ["m2", "second", "2026-10-26T10:00:02.000Z"],
    ]);
  });

  test("retracted removes the message", () => {
    const log = lines(
      { type: "created", conv: "calm-heron", at: "2026-10-26T10:00:00.000Z", by: "human" },
      { type: "message", conv: "calm-heron", id: "m1", role: "human", text: "one", at: "2026-10-26T10:00:01.000Z" },
      { type: "message", conv: "calm-heron", id: "m2", role: "human", text: "two", at: "2026-10-26T10:00:02.000Z" },
      { type: "retracted", conv: "calm-heron", id: "m2", at: "2026-10-26T10:00:03.000Z" }
    );
    const summary = summarizeConversation(foldConversations(log)[0]);
    assert.equal(summary.messageCount, 1);
    assert.equal(summary.preview, "one");
    assert.equal(summary.updatedAt, "2026-10-26T10:00:01.000Z");
  });

  test("read clears unread until the agent writes again; waiting stays until the human answers", () => {
    const base = [
      { type: "created", conv: "keen-owl", at: "2026-10-26T10:00:00.000Z", by: "human" },
      { type: "message", conv: "keen-owl", id: "a1", role: "agent", text: "done", at: "2026-10-26T10:00:01.000Z" },
      { type: "read", conv: "keen-owl", at: "2026-10-26T10:00:02.000Z" },
    ];
    let summary = summarizeConversation(foldConversations(lines(...base))[0]);
    assert.equal(summary.unread, false);
    assert.equal(summary.waiting, true);

    summary = summarizeConversation(
      foldConversations(
        lines(...base, { type: "message", conv: "keen-owl", id: "a2", role: "agent", text: "more", at: "2026-10-26T10:00:03.000Z" })
      )[0]
    );
    assert.equal(summary.unread, true);

    summary = summarizeConversation(
      foldConversations(
        lines(...base, { type: "message", conv: "keen-owl", id: "h1", role: "human", text: "thanks", at: "2026-10-26T10:00:03.000Z" })
      )[0]
    );
    assert.equal(summary.waiting, false);
    assert.equal(summary.unread, false);
  });

  test("an older read event does not move the read mark back", () => {
    const log = lines(
      { type: "created", conv: "keen-owl", at: "2026-10-26T10:00:00.000Z", by: "human" },
      { type: "message", conv: "keen-owl", id: "a1", role: "agent", text: "done", at: "2026-10-26T10:00:01.000Z" },
      { type: "read", conv: "keen-owl", at: "2026-10-26T10:00:05.000Z" },
      { type: "read", conv: "keen-owl", at: "2026-10-26T10:00:00.500Z" }
    );
    assert.equal(summarizeConversation(foldConversations(log)[0]).unread, false);
  });

  test("archived hides a conversation from the list unless all are asked for", () => {
    const log = lines(
      { type: "created", conv: "keen-owl", at: "2026-10-26T10:00:00.000Z", by: "human" },
      { type: "created", conv: "calm-heron", at: "2026-10-26T10:00:01.000Z", by: "human" },
      { type: "archived", conv: "keen-owl", at: "2026-10-26T10:00:02.000Z", archived: true }
    );
    const conversations = foldConversations(log);
    assert.deepEqual(listSummaries(conversations).map((s) => s.id), ["calm-heron"]);
    assert.deepEqual(listSummaries(conversations, true).map((s) => s.id), ["calm-heron", "keen-owl"]);
    const unarchived = foldConversations(log + lines({ type: "archived", conv: "keen-owl", at: "2026-10-26T10:00:03.000Z", archived: false }));
    assert.equal(listSummaries(unarchived).length, 2);
  });

  test("a title event with an empty title clears it; created carries title and quote", () => {
    const log = lines(
      { type: "created", conv: "keen-owl", at: "2026-10-26T10:00:00.000Z", by: "agent", title: " Plan ", quote: "The lease tiers are..." },
      { type: "title", conv: "keen-owl", title: "  ", at: "2026-10-26T10:00:01.000Z", by: "human" }
    );
    const [conversation] = foldConversations(log);
    assert.equal(conversation.title, undefined);
    assert.equal(conversation.quote, "The lease tiers are...");
    const titled = foldConversations(log.split("\n")[0] + "\n")[0];
    assert.equal(titled.title, "Plan");
  });

  test("a title the human gives wins over the agent's later titles until the human clears it", () => {
    const at = (s: number) => `2026-10-26T10:00:0${s}.000Z`;
    const events: object[] = [
      { type: "created", conv: "keen-owl", at: at(0), by: "agent", title: "Agent plan" },
      { type: "title", conv: "keen-owl", title: "My plan", at: at(1), by: "human" },
      { type: "title", conv: "keen-owl", title: "Agent again", at: at(2), by: "agent" },
    ];
    assert.equal(foldConversations(lines(...events))[0].title, "My plan");
    events.push({ type: "title", conv: "keen-owl", title: "", at: at(3), by: "human" });
    events.push({ type: "title", conv: "keen-owl", title: "Agent after clear", at: at(4), by: "agent" });
    assert.equal(foldConversations(lines(...events))[0].title, "Agent after clear");
    const named = lines({ type: "created", conv: "keen-owl", at: at(0), by: "human", title: "Named at start" },
                        { type: "title", conv: "keen-owl", title: "Agent", at: at(1), by: "agent" });
    assert.equal(foldConversations(named)[0].title, "Named at start");
  });

  test("lines that do not parse or lack fields are skipped", () => {
    const log =
      "not json\n" +
      lines({ type: "created", conv: "keen-owl", at: "2026-10-26T10:00:00.000Z", by: "human" }) +
      '{"type":"message","conv":"keen-owl","id":"m1","role":"robot","text":"x","at":"2026-10-26T10:00:01.000Z"}\n' +
      '{"type":"message","conv":"keen-owl"\n' +
      '{"type":"unknown","conv":"keen-owl","at":"2026-10-26T10:00:01.000Z"}\n';
    const conversations = foldConversations(log);
    assert.equal(conversations.length, 1);
    assert.equal(conversations[0].messages.length, 0);
  });

  test("the list is most recent first", () => {
    const log = lines(
      { type: "created", conv: "keen-owl", at: "2026-10-26T10:00:00.000Z", by: "human" },
      { type: "created", conv: "calm-heron", at: "2026-10-26T10:00:01.000Z", by: "human" },
      { type: "message", conv: "keen-owl", id: "m1", role: "human", text: "bump", at: "2026-10-26T10:00:02.000Z" }
    );
    assert.deepEqual(listSummaries(foldConversations(log)).map((s) => s.id), ["keen-owl", "calm-heron"]);
  });

  test("a conversation started from the human's message keeps who wrote it and the agent's reply", () => {
    const log = lines({
      type: "created",
      conv: "keen-owl",
      at: "2026-10-26T10:00:00.000Z",
      by: "human",
      quote: "move the reports",
      quoteRole: "human",
      quoteReply: "Done, all 40 moved.",
    });
    const summary = summarizeConversation(foldConversations(log)[0]);
    assert.equal(summary.quote, "move the reports");
    assert.equal(summary.quoteRole, "human");
    assert.equal(summary.quoteReply, "Done, all 40 moved.");
  });
});

describe("previewText", () => {
  test("joins lines and cuts long text with an ellipsis", () => {
    assert.equal(previewText("a\n\n  b  \nc"), "a b c");
    const long = "x".repeat(200);
    const preview = previewText(long);
    assert.equal(Array.from(preview).length, 120);
    assert.ok(preview.endsWith("…"));
  });
});

describe("generateConversationId", () => {
  test("two words from the lists, unique among the existing ids", () => {
    const id = generateConversationId([]);
    const [adjective, animal] = id.split("-");
    assert.ok(CONVERSATION_ADJECTIVES.includes(adjective));
    assert.ok(CONVERSATION_ANIMALS.includes(animal));
    assert.ok(isValidConversationId(id));
  });

  test("skips an id already taken", () => {
    // The first draw is always amber-badger, the second swift-otter.
    const draws = [0, 0, 50.5 / 60, 35.5 / 60];
    let i = 0;
    const random = () => draws[i++ % draws.length];
    assert.equal(generateConversationId(["amber-badger"], random), "swift-otter");
  });

  test("still finds a free id when random keeps colliding", () => {
    const id = generateConversationId(["amber-badger"], () => 0);
    assert.notEqual(id, "amber-badger");
    assert.ok(isValidConversationId(id));
  });

  test("the word lists are lowercase, unique, and the same size", () => {
    for (const list of [CONVERSATION_ADJECTIVES, CONVERSATION_ANIMALS]) {
      assert.equal(list.length, 60);
      assert.equal(new Set(list).size, list.length);
      for (const word of list) assert.match(word, /^[a-z]+$/);
    }
  });
});

describe("isValidConversationId", () => {
  test("lowercase ascii, digits and a dash, at most 64 characters", () => {
    assert.equal(isValidConversationId("swift-otter"), true);
    assert.equal(isValidConversationId("amber-badger-2"), true);
    assert.equal(isValidConversationId("swiftotter"), false);
    assert.equal(isValidConversationId("Swift-Otter"), false);
    assert.equal(isValidConversationId("swift otter"), false);
    assert.equal(isValidConversationId("a-" + "b".repeat(63)), false);
  });
});

describe("conversation commands", () => {
  let home: string;
  let previousHome: string | undefined;
  const local = "mac-1";
  const card = link("card_main", { ownerMachine: local });
  let tick = 0;
  let ids = 0;
  const ctx = (target: Link = card, machine: string | undefined = local): ConversationContext => ({
    card: target,
    localMachineId: machine,
    now: () => new Date(Date.UTC(2026, 9, 26, 10, 0, tick++)),
    newMessageId: () => `msg_${++ids}`,
  });

  beforeEach(() => {
    home = mkdtempSync(join(tmpdir(), "kanban-conversations-"));
    previousHome = process.env.KANBAN_CODE_HOME;
    process.env.KANBAN_CODE_HOME = home;
    tick = 0;
    ids = 0;
  });

  afterEach(() => {
    if (previousHome === undefined) delete process.env.KANBAN_CODE_HOME;
    else process.env.KANBAN_CODE_HOME = previousHome;
    rmSync(home, { recursive: true, force: true });
  });

  function seed(path: string, text: string) {
    mkdirSync(dirname(path), { recursive: true });
    writeFileSync(path, text);
  }

  test("new, reply with a title, list and show", () => {
    const created = createConversation(ctx(), { random: () => 0 });
    assert.equal(created.conversation.id, "amber-badger");
    assert.equal(created.message, undefined);

    const reply = replyToConversation(ctx(), "amber-badger", "Yes, starting with the lease tiers.", "Vault hardening");
    assert.equal(reply.title, "Vault hardening");
    assert.equal(reply.conversation.title, "Vault hardening");
    assert.equal(reply.conversation.waiting, true);
    assert.equal(reply.message?.role, "agent");

    const raw = readFileSync(conversationLogPath(card.id), "utf-8").trimEnd().split("\n").map((line) => JSON.parse(line));
    assert.deepEqual(raw.map((event) => event.type), ["created", "title", "message"]);
    assert.equal(raw[0].by, "agent");
    assert.equal(raw[1].by, "agent");
    assert.equal(raw[2].at, "2026-10-26T10:00:01.000Z");
    assert.match(raw[2].at, /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{3}Z$/);

    const listed = listCardConversations(ctx());
    assert.deepEqual(listed.map((s) => [s.id, s.title, s.messageCount]), [["amber-badger", "Vault hardening", 1]]);
    assert.match(formatConversationList(listed), /^amber-badger {2}Vault hardening {2}1 msg +waiting on human {2}unread$/);

    const detail = showConversation(ctx(), "amber-badger");
    assert.deepEqual(detail.messages.map((m) => m.text), ["Yes, starting with the lease tiers."]);
  });

  test("a title alone renames without a message", () => {
    createConversation(ctx(), { random: () => 0 });
    const result = replyToConversation(ctx(), "amber-badger", "", "Only a title");
    assert.equal(result.message, undefined);
    assert.equal(result.conversation.title, "Only a title");
    assert.equal(result.conversation.messageCount, 0);
    assert.throws(() => replyToConversation(ctx(), "amber-badger", "  "), /Nothing to send/);
  });

  test("new with a message speaks first and waits on the human", () => {
    const created = createConversation(ctx(), { title: "Plan", message: "Shall I start?" });
    assert.equal(created.conversation.title, "Plan");
    assert.equal(created.conversation.waiting, true);
    assert.equal(created.conversation.messageCount, 1);
    const second = createConversation(ctx());
    assert.notEqual(second.conversation.id, created.conversation.id);
  });

  test("title renames as the agent", () => {
    createConversation(ctx(), { random: () => 0 });
    assert.equal(setConversationTitle(ctx(), "amber-badger", "  New name ").title, "New name");
    assert.throws(() => setConversationTitle(ctx(), "amber-badger", " "), /empty/);
  });

  test("after the user renames, the agent's title is not applied and the CLI says so", () => {
    createConversation(ctx(), { random: () => 0, title: "Agent plan" });
    appendFileSync(conversationLogPath(card.id),
      JSON.stringify({ type: "title", conv: "amber-badger", title: "My plan", at: "2026-10-26T10:00:30.000Z", by: "human" }) + "\n");
    const reply = replyToConversation(ctx(), "amber-badger", "Done.", "Other plan");
    assert.equal(reply.title, undefined);
    assert.equal(reply.keptHumanTitle, "My plan");
    assert.equal(reply.conversation.title, "My plan");
    assert.equal(reply.conversation.messageCount, 1);
    assert.throws(() => setConversationTitle(ctx(), "amber-badger", "Other plan"), /user named this conversation "My plan"/);
  });

  test("an unknown conversation fails and lists the card's conversations", () => {
    createConversation(ctx(), { random: () => 0, title: "Vault hardening" });
    assert.throws(
      () => replyToConversation(ctx(), "no-such-thing", "hi"),
      (error: unknown) =>
        error instanceof ConversationError &&
        /No conversation "no-such-thing"/.test(error.message) &&
        /amber-badger {2}Vault hardening/.test(error.message)
    );
    assert.throws(() => showConversation(ctx(), "nope"), /This card has no conversations|No conversation "nope"/);
  });

  test("show --limit keeps the newest messages, oldest first", () => {
    createConversation(ctx(), { random: () => 0 });
    for (const text of ["one", "two", "three"]) replyToConversation(ctx(), "amber-badger", text);
    assert.deepEqual(showConversation(ctx(), "amber-badger", 2).messages.map((m) => m.text), ["two", "three"]);
  });

  test("a card another master owns refuses writes and reads that master's copy", () => {
    const foreign = link("card_box", { ownerMachine: "box-1" });
    assert.throws(() => createConversation(ctx(foreign)), /card runs on box-1; run this there/);
    assert.throws(() => replyToConversation(ctx(foreign), "swift-otter", "hi"), /card runs on box-1/);
    assert.throws(() => setConversationTitle(ctx(foreign), "swift-otter", "x"), /card runs on box-1/);
    assert.equal(existsSync(conversationLogPath(foreign.id)), false);

    seed(
      peerConversationLogPath("box-1", foreign.id),
      lines(
        { type: "created", conv: "swift-otter", at: "2026-10-26T09:00:00.000Z", by: "human" },
        { type: "message", conv: "swift-otter", id: "m1", role: "agent", text: "from the box", at: "2026-10-26T09:00:01.000Z" }
      )
    );
    assert.deepEqual(listCardConversations(ctx(foreign)).map((s) => s.id), ["swift-otter"]);
    assert.equal(showConversation(ctx(foreign), "swift-otter").messages[0].text, "from the box");
  });

  test("an adopted card reads the mirror, then continues from a copy of it on first append", () => {
    const adopted = link("card_adopted", { ownerMachine: local });
    const mirror = peerConversationLogPath("box-1", adopted.id);
    // A copy cut mid-line must not glue the next event onto the broken line.
    seed(
      mirror,
      lines(
        { type: "created", conv: "swift-otter", at: "2026-10-26T09:00:00.000Z", by: "human" },
        { type: "message", conv: "swift-otter", id: "m1", role: "human", text: "before the move", at: "2026-10-26T09:00:01.000Z" }
      ) + '{"type":"message","conv":"swift'
    );
    assert.deepEqual(listCardConversations(ctx(adopted)).map((s) => s.messageCount), [1]);

    replyToConversation(ctx(adopted), "swift-otter", "after the move");
    const local_ = conversationLogPath(adopted.id);
    assert.equal(existsSync(local_), true);
    assert.deepEqual(showConversation(ctx(adopted), "swift-otter").messages.map((m) => m.text), ["before the move", "after the move"]);
    assert.equal(readFileSync(mirror, "utf-8").includes("after the move"), false);
  });

  test("a card without an owner machine is local", () => {
    const plain = link("card_plain");
    const created = createConversation(ctx(plain, undefined));
    assert.equal(listCardConversations(ctx(plain, undefined))[0].id, created.conversation.id);
  });
});
