# Side chat: /btw and /catchup

A side chat asks about a card's session without writing into it. It shows in a panel over the chat, on the Mac and on the phone, for Claude Code cards on both runtimes (rush and tmux).

## Commands

Type them in the chat composer:

- `/btw <question>` asks a question about the session. `/btw` alone opens an empty panel.
- `/catchup` sums up what happened since your last message. The clock button in the composer does the same.

The panel has a follow-up field with two actions:

- **Ask here** (Return on the Mac) continues in the side chat. Earlier questions and answers go along.
- **Send to main chat** (Command-Return on the Mac) sends your reply to the session, followed by the side chat as context for the agent. The panel closes at once, with no animation. On the phone the message shows right away as a pending bubble and the composer stays free while the machine takes it. A send that fails removes the bubble and puts the text in the composer, with what was typed there stashed.

Closing the panel (the x button, or Esc on the Mac) forgets the side chat and stops a run that is still answering. The fold button keeps it and shows the chat under it.

## Catch-up

The answer has up to six sections, each left out when empty: what you asked, where it stands, key facts, waiting on you, blocked or failed, what else happened. A "Full report" button links to the agent's long final report when there is one.

Every item ends with a link that shows the time of the message it comes from. A link scrolls the chat to that message and tints it for a few seconds. The panel folds so the message shows. A message that is not loaded is read first: around its place in the file on the Mac, by loading older pages on the phone.

The first line, "Since you sent", quotes your last message and links to it.

### Reopening

The master that owns the card keeps the card's last finished catch-up in `~/.kanban-code/side-chat/<cardId>.json`: the answer, the messages it cites, the session id, the transcript offset of the last message it covers, and the follow-ups asked in its side chat.

`/catchup` on a card whose session has no message after that one returns the kept catch-up at once, with no model run. It shows "From 14:02, nothing new since" and its follow-ups. This holds after the panel was closed, after an app restart, and from the other device: a catch-up made on the Mac reopens on the phone.

A new message in the session (from the agent, from you, or delivered by another agent), or a card that moved to another session, makes the next `/catchup` a new run, which replaces the kept one.

**Refresh**, under the summary, runs a new catch-up whatever the session holds.

## How a run works

The master that owns the card runs:

```
claude -p --resume <session id> --fork-session --no-session-persistence \
  --output-format stream-json --verbose --include-partial-messages --settings <file>
```

- The fork reads the session with its prompt cache and writes no session file, so the conversation and the board are unchanged.
- The settings file holds a `PreToolUse` hook that denies every tool call. The tools stay listed, which keeps the prompt cache valid.
- It runs in the session's folder with the user's login environment and the card's Claude account (`CLAUDE_CONFIG_DIR` for a rush card). `ANTHROPIC_API_KEY` and `ANTHROPIC_AUTH_TOKEN` are removed, so the run uses the logged-in plan.
- `KANBAN_SIDE_CHAT=1` is set, and the Kanban hook script exits at once under it, so the run adds no hook events.
- A rush card runs with the model of its rush session.
- A run ends after 10 minutes at most.

The prompt of a catch-up holds an index of the messages since your last one, one per line: `[m7] 14:02 assistant: first 100 characters`. An index over 400 messages keeps its first 40 and last 360. The model answers in JSON Lines, `{"section", "text", "refs"}`, so the panel fills in while the answer streams. One JSON document with `sections` and `report` parses too. An answer that is not JSON shows as markdown.

Not supported: Codex and Gemini cards, and sessions that run on an ssh or boxd machine.

## When the machine is offline

On the phone, a side chat request that gets no answer (a timeout, a lost connection), or any failure while the app shows the card's machine as offline, reads "<machine name> is offline. It may be asleep." with a Retry button. Retry asks the same question again in its place. An error the machine itself answered with shows as it is, also with Retry.

A request the phone makes to a card keeps a Mac awake for 10 minutes, so a run that started is not cut off by sleep. See "Staying awake for the phone" in [`remote-control.md`](remote-control.md).

## Your last message

A message is yours when you typed and sent it yourself: in the Kanban chat (Mac or phone), in the rush composer, or straight into the terminal of a tmux card. Messages from `kanban send`, DMs, channels, remote agents, prompts an agent queued, self-compact follow-ups and task notifications are not, even though the session stores them as user messages.

Kanban records what its chat sends in `~/.kanban-code/human-messages/<cardId>.jsonl`, one `{"at", "sessionId", "text"}` per line, at the time you wrote it. A prompt you queued is recorded when it joined the queue, so a catch-up also covers what happened while it waited. A card's first prompt is recorded when you start the card from the app.

For a rush card the chat also passes `--human` to `rush session send` and `rush session start`, when the installed rush lists the flag, and reads `rush session human <id> --json`. A message counts when it is in rush's record or in Kanban's.

Where no record covers a session, a user message with no delivery marker, no task notification and no harness wrapper counts as typed.

## API

See `side-chat` in [`remote-control.md`](remote-control.md). The feature name in `GET /v1/health` is `sideChat`.
