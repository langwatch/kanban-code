import type { SlackChannelInfo } from "./client.js";

/// A roster agent that wants Slack mirroring but whose channel is not yet
/// usable — the channel does not exist yet, or the bot has not been invited.
/// Held in the bridge's `pending` set and retried against fresh channel
/// snapshots until it becomes mirrorable, so a channel created (or a bot
/// invited) AFTER the bridge last started is picked up without a restart.
export interface PendingAgent {
  slug: string;
  /// The agent's configured slackChannel: "#name", "name", or a raw id.
  channel: string;
}

export interface ResolvedAgent {
  slug: string;
  channelId: string;
}

/// Match pending agents against a single channel snapshot (one
/// `conversations.list` page-through per pass, shared across all pending
/// agents — never a lookup per agent, which would throttle the token bucket
/// the post/pill path also uses).
///
/// An agent resolves ONLY when its channel is found AND the bot is a member.
/// `conversations.list` returns a PUBLIC channel as soon as it exists — before
/// the bot is invited — so promoting on mere presence would mirror a channel
/// the bot cannot post to (`not_in_channel`) and receives no message events
/// from: a silent half-mirrored agent, the exact bug this guards against. A
/// PRIVATE channel is only listed once the bot is a member, so the gate is
/// implied there. A raw channel id in the config is taken as-is (the operator
/// wired it explicitly; membership is their responsibility), mirroring
/// `resolveChannelId`.
///
/// Resolved agents are removed from the returned `stillPending` set, so the
/// caller's next pass never re-resolves them (promote-once).
export function matchPendingChannels(
  pending: PendingAgent[],
  channels: SlackChannelInfo[],
): { resolved: ResolvedAgent[]; stillPending: PendingAgent[] } {
  const byName = new Map<string, SlackChannelInfo>();
  for (const c of channels) byName.set(c.name, c);
  const resolved: ResolvedAgent[] = [];
  const stillPending: PendingAgent[] = [];
  for (const a of pending) {
    if (/^[CG][A-Z0-9]+$/.test(a.channel)) {
      resolved.push({ slug: a.slug, channelId: a.channel });
      continue;
    }
    const hit = byName.get(a.channel.replace(/^#/, ""));
    if (hit && hit.isMember) resolved.push({ slug: a.slug, channelId: hit.id });
    else stillPending.push(a);
  }
  return { resolved, stillPending };
}
