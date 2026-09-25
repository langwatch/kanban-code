import { WebClient } from "@slack/web-api";

/// One channel from a `conversations.list` snapshot. `isMember` reflects whether
/// THIS bot token is in the channel — the bridge gates mirroring on it because a
/// public channel is listed before the bot is invited (see matchPendingChannels).
export interface SlackChannelInfo {
  id: string;
  name: string;
  isMember: boolean;
  isPrivate: boolean;
}

/// Thin wrapper over the Slack Web API for what the bridge needs: identify the
/// bot, post messages, and resolve channel names to ids.
export class SlackClient {
  private web: WebClient;

  constructor(botToken: string) {
    this.web = new WebClient(botToken);
  }

  async botUserId(): Promise<string | undefined> {
    const r = await this.web.auth.test();
    return r.user_id as string | undefined;
  }

  /// Post a message and return its ts (usable as a thread parent). Pass
  /// threadTs to reply inside an existing thread.
  async post(channel: string, text: string, threadTs?: string): Promise<string | undefined> {
    const r = await this.web.chat.postMessage({
      channel,
      text,
      thread_ts: threadTs,
      unfurl_links: false,
      unfurl_media: false,
    });
    return r.ts as string | undefined;
  }

  /// Post a Block Kit message (e.g. the picker UI) with fallback text for
  /// notifications. Returns ts so callers can update or delete it later.
  async postBlocks(channel: string, text: string, blocks: any[], threadTs?: string): Promise<string | undefined> {
    const r = await this.web.chat.postMessage({
      channel,
      text,
      blocks,
      thread_ts: threadTs,
      unfurl_links: false,
      unfurl_media: false,
    });
    return r.ts as string | undefined;
  }

  /// Update an existing message in place (used to replace the picker buttons
  /// with a "selected: N" summary once the user clicks one).
  async update(channel: string, ts: string, text: string, blocks?: any[]): Promise<void> {
    await this.web.chat.update({ channel, ts, text, blocks });
  }

  /// Delete a message the bot posted (requires `chat:write` only). Used to
  /// remove the 👀 ack message once the agent's first real reply lands.
  async deleteMessage(channel: string, ts: string): Promise<void> {
    await this.web.chat.delete({ channel, ts });
  }

  /// Set the "working…" pill on a thread (Slack's Agents & Assistants UI).
  /// An empty status clears the pill explicitly; a normal post in the same
  /// thread also clears it automatically. Slack drops the pill on its own
  /// after a 2-minute idle TTL, so callers need to refresh it for long turns.
  async setStatus(channelId: string, threadTs: string, status: string): Promise<void> {
    await this.web.apiCall("assistant.threads.setStatus", {
      channel_id: channelId,
      thread_ts: threadTs,
      status,
    });
  }

  /// Resolve a Slack user id to a human-readable name (display name preferred,
  /// then real name, then the handle). Returns undefined if the lookup fails so
  /// callers can fall back gracefully.
  async resolveUserName(userId: string): Promise<string | undefined> {
    try {
      const r = await this.web.users.info({ user: userId });
      const u = r.user as any;
      const p = u?.profile ?? {};
      return p.display_name || p.real_name || u?.real_name || u?.name || undefined;
    } catch {
      return undefined;
    }
  }

  /// Resolve "#name" / "name" to a channel id. Ids (C…/G…) are returned as-is.
  async resolveChannelId(nameOrId: string): Promise<string | undefined> {
    if (/^[CG][A-Z0-9]+$/.test(nameOrId)) return nameOrId;
    const name = nameOrId.replace(/^#/, "");
    let cursor: string | undefined;
    do {
      const r = await this.web.conversations.list({
        types: "public_channel,private_channel",
        limit: 1000,
        cursor,
      });
      const found = (r.channels ?? []).find((c: any) => c.name === name);
      if (found?.id) return found.id as string;
      cursor = r.response_metadata?.next_cursor || undefined;
    } while (cursor);
    return undefined;
  }

  /// Page through every channel the bot can see in one pass and return a flat
  /// snapshot (id + name + membership). Public channels are returned regardless
  /// of membership (with isMember=false until the bot is invited); private
  /// channels only where the bot is already a member. The bridge calls this once
  /// per re-resolution pass and matches ALL pending agents against the single
  /// snapshot, rather than a paginated lookup per agent.
  async listChannels(): Promise<SlackChannelInfo[]> {
    const out: SlackChannelInfo[] = [];
    let cursor: string | undefined;
    do {
      const r = await this.web.conversations.list({
        types: "public_channel,private_channel",
        limit: 1000,
        cursor,
      });
      for (const c of (r.channels ?? []) as any[]) {
        if (c?.id && typeof c.name === "string") {
          out.push({ id: c.id, name: c.name, isMember: !!c.is_member, isPrivate: !!c.is_private });
        }
      }
      cursor = r.response_metadata?.next_cursor || undefined;
    } while (cursor);
    return out;
  }
}
