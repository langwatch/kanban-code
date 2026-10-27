# Conversations

A card runs one session. Conversations split the chat with that session by topic: each has an id, a title and its own messages, and the session gets every prompt with a one-line header that names the conversation. The untagged chat is **Main**.

## Ids and titles

- An id is two lowercase words joined by a dash, such as `swift-otter`, unique within the card.
- A conversation starts without a title. The prompt of an untitled conversation asks the agent to set one with `--title` on its reply. The human renames it from the conversation's right-click menu or header on the Mac, or by pressing and holding it on the phone. A title the human gives wins: the agent's later titles are not applied (`kanban reply --title` says the title was kept, `kanban conversation title` fails) until the human clears it.

## What the session receives

A prompt sent from a conversation is the human's text with a header in front and the reply command after it:

```
[conversation swift-otter "Vault hardening"] ok, do it
(reply with: kanban reply swift-otter "<answer>")
```

An untitled conversation:

```
[conversation swift-otter, new] can we harden the vault next?
(reply with: kanban reply swift-otter --title "<3-6 word title>" "<answer>")
```

A conversation started from an agent message ("Continue in new conversation") adds the start of that message to the header until the agent first replies in it: `[conversation swift-otter, new, continues your message "The lease tiers are..."]`. A conversation started from one of the user's own messages names that message, and the agent's reply to it when there is one: `[conversation swift-otter, new, continues the user's message "Use a 15 min..." and your reply "Done, the ask..."]`.

The prompt goes through the card's normal send path: the queue, the prompt journal, images and the retry of a failed send. `QueuedPrompt.conversation` holds the id; the header is added when the prompt leaves the queue, so the queue shows the text as typed.

## What the conversation shows

- The human's messages, from when they were queued.
- The agent's replies, written with `kanban reply`.
- A working indicator while the card is in a turn and the last message is the human's.

Tool calls and the agent's plain text stay in Main.

## State per conversation

- **Unread**: the agent wrote after the human last opened it. Opening it on any device clears it everywhere.
- **Waiting**: the last message is the agent's. The API and `kanban conversation list` report it; the apps do not mark it.

The sidebar on the Mac and the card list on the phone show the conversations under their card, most recent first, with an unread one in bold. On the Mac, "New Conversation" sits next to "Queue Prompt" in the card toolbar; a conversation opens from its sidebar row, and a click on the card row goes back to Main.

## CLI

Run inside the card's session (`KANBAN_CARD_ID` names the card):

- `kanban reply <id> [--title <title>] "<text>"`, or `-` to read the text from stdin. Markdown is kept.
- `kanban conversation list [--json]`
- `kanban conversation new [--title <title>] ["<message>"]`: starts a conversation; with a message, the agent speaks first and it waits on the human.
- `kanban conversation show <id> [--json]`
- `kanban conversation title <id> "<title>"`

`--card <card>` acts on another card.

## Storage

The master that owns the card keeps an append-only log, `~/.kanban-code/conversations/<cardId>.jsonl`, one event per line:

```
{"type":"created","conv":"swift-otter","at":"2026-10-26T10:00:00.000Z","by":"human","quote":"..."}
{"type":"message","conv":"swift-otter","id":"<id>","role":"human","text":"...","at":"..."}
{"type":"message","conv":"swift-otter","id":"<id>","role":"agent","text":"...","at":"..."}
{"type":"title","conv":"swift-otter","title":"Vault hardening","at":"...","by":"agent"}
{"type":"read","conv":"swift-otter","at":"..."}
{"type":"retracted","conv":"swift-otter","id":"<id>","at":"..."}
{"type":"archived","conv":"swift-otter","at":"...","archived":true}
```

- A `message` with an id that is already in the log replaces that message's text (an edited queued prompt). `retracted` removes a message (a queued prompt removed before it went out).
- `quote` on `created` is the message a pop-off started from. `quoteRole` is `human` when it is the user's own message, and `quoteReply` then holds the agent's reply to it, if any.
- The app and the CLI append with `O_APPEND`, one write per line, so they never lock each other out. Readers skip a line that does not parse.
- Another master copies the log of each card it shows under `~/.kanban-code/peers/<machine>/conversations/<cardId>.jsonl`, by offset, like the transcript mirror. A master that adopts a card continues the copy it has.

## API

All routes forward to the master that owns the card. The feature name in `GET /v1/health` is `conversations`.

| Method and path | Returns |
|---|---|
| `GET /v1/cards/{id}/conversations` | `[RemoteConversation]`, most recent first |
| `POST /v1/cards/{id}/conversations` | `{"title"?, "quote"?}` → `RemoteConversation`, 201 |
| `GET /v1/cards/{id}/conversations/{conv}` | `RemoteConversationDetail`: the conversation and its messages, oldest first |
| `PATCH /v1/cards/{id}/conversations/{conv}` | `{"title"?, "read"?, "archived"?}` → `RemoteConversation` |
| `GET /v1/cards/{id}/conversations/{conv}/images?message=&index=` | the bytes of one image of a human message, read from the path the log keeps on the owning master |
| `GET /v1/cards/{id}/conversations-raw?offset=` | log bytes from `offset`, `X-Log-Size` header |

- `POST /v1/cards/{id}/prompt` takes `conversation`: the id the prompt belongs to. The owner adds the header.
- A card on the board carries `conversations`, the summaries of the ones not archived (id, title, updatedAt, messageCount, lastRole, preview, unread, waiting).
