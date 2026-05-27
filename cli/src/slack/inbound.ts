/// Pure routing for inbound Slack messages: decide whether a message should be
/// delivered to an agent's tmux session, and to which agent. Kept side-effect
/// free so the loop-prevention and channel-mapping rules are unit-testable.

/// Maps a Slack channel id to an agent slug.
export type ChannelMapping = Record<string, string>;

export interface SlackMessageEvent {
  type?: string;
  subtype?: string;
  channel?: string;
  user?: string;
  text?: string;
  bot_id?: string;
}

export type InboundDecision =
  | { action: "ignore"; reason: string }
  | { action: "deliver"; slug: string; text: string };

/// Convert Slack mrkdwn to plain text for the agent: unwrap links/mentions and
/// unescape HTML entities Slack adds.
export function slackToPlain(text: string): string {
  return text
    .replace(/<(https?:[^|>]+)\|([^>]+)>/g, "$2 ($1)") // <url|label> -> label (url)
    .replace(/<(https?:[^>]+)>/g, "$1") // <url> -> url
    .replace(/<@[^>]+>/g, "") // drop user mentions
    .replace(/<#[^|>]+\|([^>]+)>/g, "#$1") // channel mention -> #name
    .replace(/&amp;/g, "&")
    .replace(/&lt;/g, "<")
    .replace(/&gt;/g, ">")
    .trim();
}

/// Decide what to do with a Slack message event. Ignores anything that would
/// cause a loop (our own / any bot message), non-message events, edits/joins
/// (subtypes), unmapped channels, and empties.
export function routeSlackMessage(
  event: SlackMessageEvent | undefined,
  mapping: ChannelMapping,
  botUserId?: string
): InboundDecision {
  if (!event || event.type !== "message") return { action: "ignore", reason: "not-a-message" };
  if (event.subtype) return { action: "ignore", reason: `subtype:${event.subtype}` };
  if (event.bot_id) return { action: "ignore", reason: "bot-message" };
  if (botUserId && event.user === botUserId) return { action: "ignore", reason: "self" };

  const slug = event.channel ? mapping[event.channel] : undefined;
  if (!slug) return { action: "ignore", reason: "unmapped-channel" };

  const text = slackToPlain(event.text ?? "");
  if (!text) return { action: "ignore", reason: "empty" };

  return { action: "deliver", slug, text };
}
