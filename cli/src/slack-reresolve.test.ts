import { test, describe } from "node:test";
import { strict as assert } from "node:assert";
import { matchPendingChannels, PendingAgent } from "./slack/reresolve.js";
import type { SlackChannelInfo } from "./slack/client.js";

const chan = (name: string, id: string, isMember: boolean, isPrivate = false): SlackChannelInfo => ({
  id,
  name,
  isMember,
  isPrivate,
});
const p = (slug: string, channel: string): PendingAgent => ({ slug, channel });

describe("matchPendingChannels (the #677 self-heal core)", () => {
  test("public channel that exists but the bot is NOT a member stays pending", () => {
    // The #677 trap: conversations.list returns a public channel the moment it
    // exists, before the invite. Mirroring it then would post to a channel the
    // bot can't write to. Must NOT resolve until is_member flips true.
    const { resolved, stillPending } = matchPendingChannels(
      [p("kanban-keeper", "#agent-kanban-keeper")],
      [chan("agent-kanban-keeper", "C1", false)],
    );
    assert.equal(resolved.length, 0);
    assert.deepEqual(
      stillPending.map((a) => a.slug),
      ["kanban-keeper"],
    );
  });

  test("resolves — with the channel id — once the bot becomes a member", () => {
    const { resolved, stillPending } = matchPendingChannels(
      [p("kanban-keeper", "#agent-kanban-keeper")],
      [chan("agent-kanban-keeper", "C1", true)],
    );
    assert.deepEqual(resolved, [{ slug: "kanban-keeper", channelId: "C1" }]);
    assert.equal(stillPending.length, 0);
  });

  test("a channel absent from the snapshot stays pending", () => {
    const { resolved, stillPending } = matchPendingChannels([p("x", "not-created-yet")], [chan("other", "C9", true)]);
    assert.equal(resolved.length, 0);
    assert.equal(stillPending.length, 1);
  });

  test("private channel (only listed once a member) resolves", () => {
    // Slack only returns a private channel in conversations.list when the bot is
    // a member, so its presence with isMember=true is the normal resolve path.
    const { resolved } = matchPendingChannels([p("sec", "#private-sec")], [chan("private-sec", "CP", true, true)]);
    assert.deepEqual(resolved, [{ slug: "sec", channelId: "CP" }]);
  });

  test("a raw channel id in config is taken as-is (operator-wired; membership is theirs)", () => {
    const { resolved, stillPending } = matchPendingChannels([p("x", "C0123ABC")], []);
    assert.deepEqual(resolved, [{ slug: "x", channelId: "C0123ABC" }]);
    assert.equal(stillPending.length, 0);
  });

  test("'#name' and bare 'name' resolve identically", () => {
    const withHash = matchPendingChannels([p("a", "#foo")], [chan("foo", "C1", true)]);
    const bare = matchPendingChannels([p("a", "foo")], [chan("foo", "C1", true)]);
    assert.deepEqual(withHash.resolved, bare.resolved);
  });

  test("mixed roster in ONE snapshot: members resolve, non-members and absent ones pend", () => {
    const { resolved, stillPending } = matchPendingChannels(
      [p("a", "aa"), p("b", "bb"), p("c", "cc")],
      [chan("aa", "CA", true), chan("bb", "CB", false)], // cc absent entirely
    );
    assert.deepEqual(resolved, [{ slug: "a", channelId: "CA" }]);
    assert.deepEqual(
      stillPending.map((a) => a.slug).sort(),
      ["b", "c"],
    );
  });

  test("promote-once: resolved agents are removed from stillPending, so the next pass can't re-resolve (no double-tail)", () => {
    let pending: PendingAgent[] = [p("a", "aa"), p("b", "bb")];
    // pass 1: only aa's channel is ready
    let r = matchPendingChannels(pending, [chan("aa", "CA", true)]);
    pending = r.stillPending;
    assert.deepEqual(r.resolved, [{ slug: "a", channelId: "CA" }]);
    assert.deepEqual(pending.map((x) => x.slug), ["b"]);
    // pass 2: aa is STILL in the (now larger) snapshot, but it left `pending`,
    // so it is not resolved a second time — only the newly-ready bb is.
    r = matchPendingChannels(pending, [chan("aa", "CA", true), chan("bb", "CB", true)]);
    assert.deepEqual(r.resolved, [{ slug: "b", channelId: "CB" }]);
    assert.equal(r.stillPending.length, 0);
  });

  test("empty pending set resolves to nothing (loop can stop)", () => {
    const { resolved, stillPending } = matchPendingChannels([], [chan("aa", "CA", true)]);
    assert.equal(resolved.length, 0);
    assert.equal(stillPending.length, 0);
  });
});
