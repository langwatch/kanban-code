import { test, describe } from "node:test";
import { strict as assert } from "node:assert";

import { postToSlack } from "./slack/post.js";

function fakeClient(opts: { resolves?: string; postError?: any } = {}) {
  const posted: [string, string][] = [];
  const uploaded: [string, string, string[]][] = [];
  const client = {
    async resolveChannelId(_name: string) {
      return opts.resolves;
    },
    async post(channel: string, text: string) {
      if (opts.postError) throw opts.postError;
      posted.push([channel, text]);
    },
    async postFiles(channel: string, text: string, paths: string[]) {
      if (opts.postError) throw opts.postError;
      uploaded.push([channel, text, paths]);
    },
  } as any;
  return { client, posted, uploaded };
}

describe("postToSlack", () => {
  test("resolves the channel name and posts to its id", async () => {
    const { client, posted } = fakeClient({ resolves: "C123" });
    const r = await postToSlack(client, "#dev", "PR ready: ...");
    assert.deepEqual(r, { ok: true, channelId: "C123" });
    assert.deepEqual(posted, [["C123", "PR ready: ..."]]);
  });

  test("attaches files to the same message instead of posting plain text", async () => {
    const { client, posted, uploaded } = fakeClient({ resolves: "C123" });
    const r = await postToSlack(client, "#content", "Draft ready", ["/tmp/a.png"]);
    assert.deepEqual(r, { ok: true, channelId: "C123" });
    assert.deepEqual(uploaded, [["C123", "Draft ready", ["/tmp/a.png"]]]);
    assert.equal(posted.length, 0);
  });

  test("surfaces missing_scope when the app cannot upload files", async () => {
    const { client } = fakeClient({ resolves: "C1", postError: { data: { error: "missing_scope" } } });
    const r = await postToSlack(client, "#content", "x", ["/tmp/a.png"]);
    assert.equal(r.error, "missing_scope");
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
