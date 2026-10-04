import { SlackClient } from "./client.js";

export interface PostResult {
  ok: boolean;
  channelId?: string;
  error?: string;
}

/// Resolve a channel name/id and post text as the bot, with any files attached
/// to the same message. Returns a structured result so callers can print a
/// clear, actionable error: `not_in_channel` means the bot must be invited to
/// that channel first, `missing_scope` on a file means the app lacks files:write.
export async function postToSlack(
  client: SlackClient,
  channel: string,
  text: string,
  files: string[] = [],
): Promise<PostResult> {
  const channelId = await client.resolveChannelId(channel);
  if (!channelId) {
    return { ok: false, error: `channel not found or not visible to the bot: ${channel}` };
  }
  try {
    if (files.length) await client.postFiles(channelId, text, files);
    else await client.post(channelId, text);
    return { ok: true, channelId };
  } catch (e: any) {
    const error = e?.data?.error || e?.message || String(e);
    return { ok: false, channelId, error };
  }
}
