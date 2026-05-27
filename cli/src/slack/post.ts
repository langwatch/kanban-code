import { SlackClient } from "./client.js";

export interface PostResult {
  ok: boolean;
  channelId?: string;
  error?: string;
}

/// Resolve a channel name/id and post text as the bot. Returns a structured
/// result so callers can print a clear, actionable error — most importantly
/// `not_in_channel`, which means the bot must be invited to that channel first.
export async function postToSlack(client: SlackClient, channel: string, text: string): Promise<PostResult> {
  const channelId = await client.resolveChannelId(channel);
  if (!channelId) {
    return { ok: false, error: `channel not found or not visible to the bot: ${channel}` };
  }
  try {
    await client.post(channelId, text);
    return { ok: true, channelId };
  } catch (e: any) {
    const error = e?.data?.error || e?.message || String(e);
    return { ok: false, channelId, error };
  }
}
