import { test, describe } from "node:test";
import { strict as assert } from "node:assert";

import { postToSlack } from "./slack/post.js";

function fakeClient(opts: { resolves?: string; postError?: any } = {}) {
  const posted: [string, string][] = [];
  const client = {
    async resolveChannelId(_name: string) {
      return opts.resolves;
    },
    async post(channel: string, text: string) {
      if (opts.postError) throw opts.postError;
      posted.push([channel, text]);
    },
  } as any;
  return { client, posted };
}

describe("postToSlack", () => {
  test("resolves the channel name and posts to its id", async () => {
    const { client, posted } = fakeClient({ resolves: "C123" });
    const r = await postToSlack(client, "#dev", "PR ready: ...");
    assert.deepEqual(r, { ok: true, channelId: "C123" });
    assert.deepEqual(posted, [["C123", "PR ready: ..."]]);
  });

  test("reports an unresolvable channel and does not post", async () => {
    const { client, posted } = fakeClient({ resolves: undefined });
    const r = await postToSlack(client, "#nope", "x");
    assert.equal(r.ok, false);
    assert.match(String(r.error), /not found/);
    assert.equal(posted.length, 0);
  });

  test("surfaces the Slack API error (e.g. not_in_channel) so the caller can act", async () => {
    const { client } = fakeClient({ resolves: "C1", postError: { data: { error: "not_in_channel" } } });
    const r = await postToSlack(client, "#dev", "x");
    assert.equal(r.ok, false);
    assert.equal(r.error, "not_in_channel");
    assert.equal(r.channelId, "C1");
  });
});
