import { WebClient } from "@slack/web-api";

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

  async post(channel: string, text: string): Promise<void> {
    await this.web.chat.postMessage({
      channel,
      text,
      unfurl_links: false,
      unfurl_media: false,
    });
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
}
