import { test, describe } from "node:test";
import { strict as assert } from "node:assert";
import { parse as parseYaml } from "yaml";
import { routeSlackMessage, slackToPlain } from "./slack/inbound.js";
import { slackAppManifest } from "./slack/manifest.js";
import { formatSystemAnnouncement, SYSTEM_MESSAGE_PREFIX } from "./slack/announce.js";

const MAPPING = { C123: "dependabot-scout", C999: "security-scout" };
const reasonOf = (d: ReturnType<typeof routeSlackMessage>) => (d.action === "ignore" ? d.reason : undefined);

describe("routeSlackMessage", () => {
  test("delivers a human message in a mapped channel to the right agent", () => {
    const d = routeSlackMessage({ type: "message", channel: "C123", user: "U1", text: "focus on the lodash PR" }, MAPPING, "UBOT");
    assert.deepEqual(d, { action: "deliver", slug: "dependabot-scout", text: "focus on the lodash PR" });
  });

  test("ignores the bot's own messages (no loops)", () => {
    assert.equal(routeSlackMessage({ type: "message", channel: "C123", bot_id: "B1", text: "hi" }, MAPPING).action, "ignore");
    assert.equal(reasonOf(routeSlackMessage({ type: "message", channel: "C123", user: "UBOT", text: "hi" }, MAPPING, "UBOT")), "self");
  });

  test("ignores edits/joins (subtypes), non-messages, unmapped channels, empties", () => {
    assert.equal(reasonOf(routeSlackMessage({ type: "message", subtype: "message_changed", channel: "C123" }, MAPPING)), "subtype:message_changed");
    assert.equal(reasonOf(routeSlackMessage({ type: "reaction_added", channel: "C123" }, MAPPING)), "not-a-message");
    assert.equal(reasonOf(routeSlackMessage({ type: "message", channel: "CXXX", user: "U1", text: "hi" }, MAPPING)), "unmapped-channel");
    assert.equal(reasonOf(routeSlackMessage({ type: "message", channel: "C123", user: "U1", text: "   " }, MAPPING)), "empty");
  });

  test("slackToPlain unwraps links/mentions and unescapes entities", () => {
    assert.equal(slackToPlain("see <https://x.com|the docs> &amp; retry"), "see the docs (https://x.com) & retry");
    assert.match(slackToPlain("ping <@U123> now"), /ping\s+now/);
    assert.equal(slackToPlain("<https://ci.example/run>"), "https://ci.example/run");
  });
});

describe("formatSystemAnnouncement", () => {
  test("prepends the [SYSTEM MESSAGE] marker so automated traffic is distinguishable from agent replies", () => {
    const out = formatSystemAnnouncement("Good morning, review the open Dependabot PRs.");
    assert.equal(out, "[SYSTEM MESSAGE]\nGood morning, review the open Dependabot PRs.");
    assert.ok(out.startsWith(SYSTEM_MESSAGE_PREFIX));
  });

  test("preserves multi-line bodies verbatim under the marker", () => {
    const body = "line one\nline two";
    assert.equal(formatSystemAnnouncement(body), `${SYSTEM_MESSAGE_PREFIX}\n${body}`);
  });
});

describe("slackAppManifest", () => {
  test("is Socket Mode with the scopes/events the bridge needs", () => {
    const m = parseYaml(slackAppManifest());
    assert.equal(m.settings.socket_mode_enabled, true);
    assert.equal(m.settings.event_subscriptions.bot_events.includes("message.groups"), true, "private channels");
    assert.equal(m.settings.event_subscriptions.bot_events.includes("message.channels"), true);
    assert.ok(m.oauth_config.scopes.bot.includes("chat:write"));
    assert.ok(m.oauth_config.scopes.bot.includes("groups:history"));
  });
});
