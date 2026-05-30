import { stringify } from "yaml";

export interface ManifestOptions {
  name?: string;
  displayName?: string;
}

/// Generate a modern Slack app manifest (v2 YAML) for the agents bridge. Socket
/// Mode (no public webhook), scoped to post and read messages in the channels
/// it is invited to (private channels use the `groups:*` scopes + message.groups).
export function slackAppManifest(opts: ManifestOptions = {}): string {
  const manifest = {
    display_information: {
      name: opts.name ?? "LangWatch Agents",
      description: "Observe and steer LangWatch's headless Claude Code agents",
      background_color: "#1a1a2e",
    },
    features: {
      bot_user: {
        display_name: opts.displayName ?? "langwatch-agents",
        always_online: true,
      },
      // Slash commands run over socket mode (no public request_url). The
      // bridge listens for slash_commands events on the same socket and acts
      // on the channel where the command was issued.
      slash_commands: [
        {
          command: "/stop",
          description: "Send Esc to the agent in this channel (interrupt the current turn)",
          should_escape: false,
        },
      ],
    },
    oauth_config: {
      scopes: {
        // Full read + write in any channel the bot is invited to (public,
        // private, DMs, group DMs), plus posting to public channels it is not a
        // member of. Agents read broader channels (e.g. #dev) on demand via the
        // Slack CLI with this same bot token.
        bot: [
          "channels:read",
          "channels:history",
          "groups:read",
          "groups:history",
          "im:read",
          "im:history",
          "mpim:read",
          "mpim:history",
          "chat:write",
          "chat:write.public",
          "files:read",
          "users:read",
          "app_mentions:read",
          // Required for /stop and any future slash commands the bridge handles.
          "commands",
        ],
      },
    },
    settings: {
      event_subscriptions: {
        bot_events: ["message.channels", "message.groups", "app_mention"],
      },
      // Interactivity is delivered over the same socket connection (no public
      // request_url needed) so the bridge can receive block_actions events
      // when a user clicks a button on the picker mirror.
      interactivity: { is_enabled: true },
      org_deploy_enabled: false,
      socket_mode_enabled: true,
      token_rotation_enabled: false,
    },
  };
  return stringify(manifest);
}

export const MANIFEST_INSTRUCTIONS = `To create the Slack app:
  1. Go to https://api.slack.com/apps  ->  "Create New App"  ->  "From a manifest"
  2. Pick the workspace, paste the manifest above, create the app.
  3. Under "Basic Information" -> "App-Level Tokens", generate a token with the
     "connections:write" scope. That is your SLACK_APP_TOKEN (xapp-...).
  4. Under "Install App", install to the workspace. Copy the Bot User OAuth Token.
     That is your SLACK_BOT_TOKEN (xoxb-...).
  5. Invite the bot to each agent's private channel, and to any channel you want
     it to read/post in (e.g. #dev):  /invite @langwatch-agents
  6. Map each AGENT channel to an agent in the agents config (slackChannel). Other
     channels the bot is in (like #dev) are readable/writable on demand by agents,
     they are just not relayed into a session.`;
