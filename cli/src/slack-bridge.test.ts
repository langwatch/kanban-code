import { test, describe } from "node:test";
import { strict as assert } from "node:assert";
import { parse as parseYaml } from "yaml";
import { routeSlackMessage, slackToPlain } from "./slack/inbound.js";
import { slackAppManifest } from "./slack/manifest.js";
import { formatReceivedMessage, RECEIVED_MESSAGE_HEADER } from "./slack/announce.js";

const MAPPING = { C123: "dependabot-scout", C999: "security-scout" };
const reasonOf = (d: ReturnType<typeof routeSlackMessage>) => (d.action === "ignore" ? d.reason : undefined);

describe("routeSlackMessage", () => {
  test("delivers a human message in a mapped channel to the right agent", () => {
    const d = routeSlackMessage({ type: "message", channel: "C123", user: "U1", text: "focus on the lodash PR" }, MAPPING, "UBOT");
    assert.deepEqual(d, { action: "deliver", slug: "dependabot-scout", text: "focus on the lodash PR", files: [] });
  });

  test("delivers a file_share with attachments even when the text is empty", () => {
    const files = [{ id: "F1", name: "screenshot.png", mimetype: "image/png", url_private: "https://files.slack.com/F1" }];
    const d = routeSlackMessage({ type: "message", subtype: "file_share", channel: "C123", user: "U1", text: "", files }, MAPPING);
    assert.deepEqual(d, { action: "deliver", slug: "dependabot-scout", text: "", files });
  });

  test("delivers a file_share with text and attachments together", () => {
    const files = [{ id: "F2", name: "ticket.pdf", mimetype: "application/pdf", url_private: "https://files.slack.com/F2" }];
    const d = routeSlackMessage({ type: "message", subtype: "file_share", channel: "C123", user: "U1", text: "read this", files }, MAPPING);
    assert.deepEqual(d, { action: "deliver", slug: "dependabot-scout", text: "read this", files });
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
    assert.equal(reasonOf(routeSlackMessage({ type: "message", subtype: "file_share", channel: "C123", user: "U1", text: "" }, MAPPING)), "empty");
  });

  test("slackToPlain unwraps links/mentions and unescapes entities", () => {
    assert.equal(slackToPlain("see <https://x.com|the docs> &amp; retry"), "see the docs (https://x.com) & retry");
    assert.match(slackToPlain("ping <@U123> now"), /ping\s+now/);
    assert.equal(slackToPlain("<https://ci.example/run>"), "https://ci.example/run");
  });
});

describe("formatReceivedMessage", () => {
  test("marks the injected prompt as a received message and italicizes the body", () => {
    const out = formatReceivedMessage("Good morning, review the open Dependabot PRs.");
    assert.equal(out, ">>> Received user message\n\n_Good morning, review the open Dependabot PRs._");
    assert.ok(out.startsWith(RECEIVED_MESSAGE_HEADER));
  });

  test("wraps multi-line bodies in italics under the header", () => {
    const body = "line one\nline two";
    assert.equal(formatReceivedMessage(body), `${RECEIVED_MESSAGE_HEADER}\n\n_${body}_`);
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
    assert.equal(m.settings.interactivity.is_enabled, true, "interactivity for picker buttons");
    assert.ok(m.oauth_config.scopes.bot.includes("commands"), "slash commands need the commands scope");
    const slashes = m.features.slash_commands ?? [];
    const stop = slashes.find((s: any) => s.command === "/stop");
    assert.ok(stop, "/stop slash command is registered");
  });
});
