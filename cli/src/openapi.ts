/**
 * OpenAPI 3.1 spec for the share-server's public API, served at
 * /.well-known/openapi.json. Agents (MCP, ChatGPT plugins, custom tooling)
 * can fetch this URL and immediately know what endpoints exist, how to
 * authenticate, and what the message payloads look like.
 *
 * The spec is built dynamically so `servers[0].url` reflects whichever
 * host the request arrived on (typically the trycloudflare.com hostname).
 */

export interface OpenApiContext {
  /** Absolute base URL the client reached the server on, e.g.
   *  `https://mailing-athens-diff-coupon.trycloudflare.com`. No trailing slash. */
  publicBaseUrl: string;
  /** The single channel this share exposes. Included in the spec as a
   *  concrete example so agents don't have to guess the channel name. */
  channelName: string;
}

export function buildOpenApiSpec(ctx: OpenApiContext): Record<string, unknown> {
  const { publicBaseUrl, channelName } = ctx;
  return {
    openapi: "3.1.0",
    info: {
      title: "Kanban Code — Live Channel Share",
      summary: "Send and receive messages in a Kanban Code chat channel over a public URL.",
      description: [
        "Every request must include the share token as a `?token=` query parameter.",
        "The token came with the share URL (`…/?token=tk_…`) — treat it as a bearer secret.",
        "",
        `This share exposes a single channel: \`#${channelName}\`.`,
        "",
        "Typical agent flow:",
        "  1. `GET /api/channels/{channel}/history` — backfill recent messages.",
        "  2. `GET /api/channels/{channel}/poll?since=<lastId>` — long-poll for new messages.",
        "  3. `POST /api/channels/{channel}/send` — post a reply.",
        "",
        "Messages you send are flagged as `source: external` and prefixed with a warning",
        "in each recipient's tmux session so human users know the traffic is untrusted.",
      ].join("\n"),
      version: "1.0.0",
    },
    servers: [{ url: publicBaseUrl }],
    security: [{ apiKey: [] }],
    components: {
      securitySchemes: {
        apiKey: {
          type: "apiKey",
          in: "query",
          name: "token",
          description: "Share token (starts with `tk_`). Passed on every request.",
        },
      },
      schemas: {
        ChannelMember: {
          type: "object",
          required: ["handle"],
          properties: {
            handle: { type: "string", description: "User or agent handle, e.g. `alice`." },
            cardId: { type: ["string", "null"], description: "Kanban card id when the member is an agent." },
            joinedAt: { type: "string", format: "date-time" },
          },
        },
        ChannelInfo: {
          type: "object",
          required: ["name", "members", "expiresAt", "remainingMs"],
          properties: {
            name: { type: "string", example: channelName },
            members: { type: "array", items: { $ref: "#/components/schemas/ChannelMember" } },
            expiresAt: { type: "string", format: "date-time" },
            remainingMs: { type: "integer", minimum: 0 },
          },
        },
        ChannelMessage: {
          type: "object",
          required: ["id", "ts", "from", "body"],
          properties: {
            id: { type: "string", example: "msg_9957cec5ff9bb6d7" },
            ts: { type: "string", format: "date-time" },
            type: {
              type: "string",
              enum: ["message", "join", "leave", "system"],
              description: "Poll/history filters real messages (type=message or omitted); join/leave/system are channel events.",
            },
            from: {
              type: "object",
              required: ["handle"],
              properties: {
                handle: { type: "string" },
                cardId: { type: ["string", "null"] },
              },
            },
            body: { type: "string" },
            source: { type: "string", enum: ["external"], description: "Present only on messages originating from the share link." },
            imagePaths: {
              type: "array",
              items: { type: "string" },
              description: "Absolute filesystem paths. Map each to HTTP via `/api/images/{msgId}/{filename}` (parse from path).",
            },
          },
        },
        SendRequest: {
          type: "object",
          required: ["handle", "body"],
          properties: {
            handle: { type: "string", example: "dana", description: "Display name. Will be auto-namespaced to `ext_<handle>`." },
            body: { type: "string", example: "hi team 👋" },
            imagePaths: {
              type: "array",
              items: { type: "string" },
              description: "Absolute paths returned by POST /images. Optional.",
            },
          },
        },
        PollResponse: {
          type: "object",
          required: ["messages", "lastId"],
          properties: {
            messages: { type: "array", items: { $ref: "#/components/schemas/ChannelMessage" } },
            lastId: { type: "string", description: "Pass this back as `?since=` on the next poll." },
          },
        },
      },
    },
    paths: {
      "/api/channels": {
        get: {
          summary: "List accessible channels",
          description: "Returns every channel this token has access to. Today that's always a single-item array.",
          responses: {
            "200": {
              description: "OK",
              content: {
                "application/json": {
                  schema: {
                    type: "object",
                    required: ["channels"],
                    properties: { channels: { type: "array", items: { $ref: "#/components/schemas/ChannelInfo" } } },
                  },
                },
              },
            },
            "401": { description: "Missing or invalid token." },
            "410": { description: "Share has expired." },
          },
        },
      },
      "/api/channels/{channel}/info": {
        get: {
          summary: "Channel metadata",
          parameters: [channelParam(channelName)],
          responses: {
            "200": { description: "OK", content: { "application/json": { schema: { $ref: "#/components/schemas/ChannelInfo" } } } },
            "401": { description: "Unauthorized" },
            "404": { description: "Channel not found" },
          },
        },
      },
      "/api/channels/{channel}/history": {
        get: {
          summary: "Full message history (tail)",
          description: "Returns every message in the jsonl, oldest first. Use this on mount; switch to /poll for live updates.",
          parameters: [channelParam(channelName)],
          responses: {
            "200": {
              description: "OK",
              content: {
                "application/json": {
                  schema: {
                    type: "object",
                    required: ["messages"],
                    properties: { messages: { type: "array", items: { $ref: "#/components/schemas/ChannelMessage" } } },
                  },
                },
              },
            },
          },
        },
      },
      "/api/channels/{channel}/poll": {
        get: {
          summary: "Long-poll for new messages",
          description: [
            "Returns immediately with every message appended after `since`, or — if there's nothing newer — ",
            "blocks for up to ~25 s waiting for the next append. Loop this endpoint in a tight `while` to get ",
            "real-time delivery. Pass the returned `lastId` back as `since` on the next call.",
          ].join(""),
          parameters: [
            channelParam(channelName),
            {
              name: "since", in: "query", required: false,
              schema: { type: "string" },
              description: "Message id the client has already seen. Empty string = cold start (returns empty so you don't replay history).",
            },
          ],
          responses: {
            "200": { description: "OK", content: { "application/json": { schema: { $ref: "#/components/schemas/PollResponse" } } } },
            "401": { description: "Unauthorized" },
          },
        },
      },
      "/api/channels/{channel}/send": {
        post: {
          summary: "Post a message",
          parameters: [channelParam(channelName)],
          requestBody: {
            required: true,
            content: { "application/json": { schema: { $ref: "#/components/schemas/SendRequest" } } },
          },
          responses: {
            "200": {
              description: "Persisted + fanned out to all members.",
              content: {
                "application/json": {
                  schema: {
                    type: "object",
                    required: ["msg"],
                    properties: { msg: { $ref: "#/components/schemas/ChannelMessage" } },
                  },
                },
              },
            },
            "400": { description: "Validation error (empty body, bad handle, etc)." },
            "401": { description: "Unauthorized" },
            "410": { description: "Share expired" },
          },
        },
      },
    },
  };
}

function channelParam(defaultChannel: string): Record<string, unknown> {
  return {
    name: "channel", in: "path", required: true,
    schema: { type: "string", example: defaultChannel },
    description: `Channel name — for this share, always \`${defaultChannel}\`.`,
  };
}
