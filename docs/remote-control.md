# Remote control

The Mac app serves an HTTP API that lets other devices drive it: the iOS app on a phone, and other agents through `kanban remote`. The Mac stays the only place sessions run. Wire types live in `Sources/KanbanCodeRemoteKit/RemoteModels.swift`.

```
iPhone (KanbanCodeMobile) ─┐                      ┌─ rush hosts
                           ├─ HTTP + WebSocket ──▶ Mac app ─┼─ tmux sessions
agent: kanban remote ... ──┘   :7780, tailnet     └─ ~/.claude transcripts
```

## Network and auth

- Off by default. Settings > Remote Control turns it on.
- The server listens on port 7780 (configurable) on `127.0.0.1` and on the Mac's Tailscale addresses (`100.64.0.0/10`, `fd7a:115c:a1e0::/48`). It never binds `0.0.0.0`, so the LAN and public Wi-Fi cannot reach it. When Tailscale comes up later, the server binds its address then.
- `tailscale serve --bg --https=7780 http://127.0.0.1:7780` puts HTTPS with a valid certificate in front of it at `https://<mac>.<tailnet>.ts.net:7780`. Both forms work.
- Every request except `GET /v1/health` needs `Authorization: Bearer <token>`. WebSocket clients that cannot set headers may pass `?token=`.
- A token belongs to one device and has a scope:
  - `full`: everything, including terminals. For a phone.
  - `agent`: read the board and transcripts, create tasks, send prompts, interrupt. No terminal, no raw keys. For another agent such as OpenClaw.
  - `peer`: what a paired master calls (see "Peer scope" below). No terminal, no vault secrets. For the other master.
  - `terminal`: the terminal socket, plus reading the board to find the card. For showing a peer's card terminals.
- Tokens are `kc_` followed by 40 base62 characters. `~/.kanban-code/remote/devices.json` keeps only their SHA-256 with the device id, name, scope, `createdAt` and `lastSeenAt`. The server re-reads the file when it changes, so a revoked device is refused on its next request and its open sockets close.
- Pairing:
  - In the app, Settings > Remote Control > Add device shows the token once, plus a QR code of `kanbancode://pair?url=<base url>&token=<token>&name=<host name>`.
  - On the Mac, `kanban remote pair --name <device> [--scope agent]` writes the same file and prints the token and the link.
- Refusals: 401 with no token or an unknown one, 403 when the scope does not allow the call. Bodies are `{"error": "..."}`.

## Endpoints

JSON bodies, up to 48 MiB. Dates are ISO 8601 with milliseconds, UTC (`2026-09-26T10:00:00.000Z`). A card leaves out `isLive`, `isBusy`, `archived` and `pinned` when false, `queuedPromptCount` when 0, `queuedPrompts`, `terminals` and `prs` when empty, and every null field; read a missing key as that default. Responses over 8 KB are gzipped (`Content-Encoding: gzip`) when the request sends `Accept-Encoding: gzip`.

`GET /v1/health` lists `features`, the additions to API version 1 this server has. A client checks for one before using it; a server without the list has none of them:
- `images`: `images` on prompts and tasks.
- `queue`: `queuedPrompts` on cards and the `/v1/cards/{id}/queue/{promptId}` routes.
- `terminalScroll`: the `scroll` terminal control frame.
- `machines`: `GET /v1/machines`, and `machine` on tasks.
- `cardActions`: `pinned` on cards, `pinned` and `archived: false` on `PATCH /v1/cards/{id}`, and `DELETE /v1/cards/{id}`.
- `worktrees`: `POST /v1/cards/{id}/worktree/remove` and `POST /v1/cards/{id}/discover`.
- `sideChat`: the `/v1/cards/{id}/side-chat` routes, and `human` on prompts and tasks.
- `slashCommands`: `GET /v1/cards/{id}/slash-commands`.
- `cardSearch`: `GET /v1/cards/search`.

| Method and path | Scope | Returns |
|---|---|---|
| `GET /v1/health` | none | `RemoteHealth` |
| `GET /v1/me` | any | `RemoteDevice` |
| `GET /v1/board?all=1` | any | `RemoteBoard` |
| `GET /v1/cards/search?q=&limit=50&scope=&local=1` | full, agent, peer | `RemoteCardSearchResult`: `cards`, `truncated`, `unreachable` |
| `GET /v1/cards/{id}` | any | `RemoteCard` |
| `GET /v1/cards/{id}/transcript?limit=50&before=<cursor>` | any | `RemoteTranscript`, oldest first |
| `GET /v1/machines` | any | `RemoteMachineList`: this master (`kind` `this`), the other masters and the ssh machines |
| `POST /v1/tasks` | any | `RemoteTaskRequest` → `RemoteCard`, 201 |
| `POST /v1/cards/{id}/prompt` | any | `RemotePromptRequest` → 204 |
| `POST /v1/cards/{id}/queue/{promptId}` | any | 204 |
| `PATCH /v1/cards/{id}/queue/{promptId}` | any | `{"text"}` → 204 |
| `DELETE /v1/cards/{id}/queue/{promptId}` | any | 204 |
| `POST /v1/cards/{id}/side-chat` | any | `RemoteSideChatRequest` → `RemoteSideChatRun`, 201 |
| `GET /v1/cards/{id}/side-chat/{runId}` | any | `RemoteSideChatRun` with the answer so far |
| `DELETE /v1/cards/{id}/side-chat/{runId}` | any | 204, stops the run |
| `GET /v1/cards/{id}/slash-commands` | any | `[RemoteSlashCommand]`: `name`, `description`, `source` |
| `POST /v1/cards/{id}/pasted-image` | full, agent, peer | image bytes → `{"path"}`, 201 |
| `POST /v1/cards/{id}/interrupt` | any | 204 |
| `POST /v1/cards/{id}/resume` | any | `RemoteCard` |
| `PATCH /v1/cards/{id}` | any | `RemoteCardUpdate` (`name`, `column`, `archived`, `pinned`) → `RemoteCard` |
| `DELETE /v1/cards/{id}` | any | 204; 409 for a card that is not archived |
| `POST /v1/cards/{id}/move` | any | `RemoteMoveRequest` → `RemoteCard` |
| `POST /v1/cards/{id}/worktree/remove` | full | `RemoteWorktreeRemoval` (`machine`, `cardDeleted`) |
| `POST /v1/cards/{id}/discover` | any | 204 |
| `GET /v1/cards/{id}/handover` | any | `RemoteHandoverInfo` |
| `GET /v1/cards/{id}/transcript/raw?offset=0&limit=4194304` | any | transcript bytes, `X-Transcript-Size` header |
| `GET /v1/links?since=&epoch=`, `POST /v1/links/changed`, `GET /v1/peers` | any | peer sync |
| `GET /v1/sync/state`, `GET /v1/sync/file?entry=&path=`, `POST /v1/sync/changed?machine=&what=` | full, peer | agent sync (Settings > Sync) |
| `POST /v1/optmem/run` | full, peer | `{"id", "argv", "date"}` → `{"status", "stdout", "stderr"}`: a memo command on the OptMem home |
| `POST /v1/cli` | full, peer | `RemoteCLIRequest` → `RemoteCLIResult` (`kanban channel`/`dm` only) |
| `GET /v1/channels/files`, `GET /v1/channels/files/{path}?offset=` | any | channel files, for the mirror |
| `PUT /v1/channels/files/{path}` | full, peer | creates a missing channel file, 204 or 409 |
| `GET /v1/scrub/status`, `GET /v1/scrub/index`, `POST /v1/scrub/run`, `PUT /v1/scrub/schedule` | full, peer | the secret scrubber (see [`vault.md`](vault.md)) |
| `GET /v1/events?all=1` (WebSocket) | any | `RemoteEvent` text frames |
| `GET /v1/cards/{id}/terminal?session=<name>&cols=80&rows=24` (WebSocket) | full, terminal | terminal bytes |
| `GET /.well-known/openapi.json` | none | OpenAPI 3.1 of the above |

Behaviour:
- `board` and `events` return the working set: no archived cards, no All Sessions cards, and only the 30 most recent Done cards (by `lastActivity`, else `updatedAt`). `?all=1` returns every card.
- `cards/search` looks at every card the master knows, archived and All Sessions included, which the working set leaves out. Every word of `q` must be in the card's title, the first lines of its prompt, its project name, a branch, or a pull request (`#N` or its title); case and accents do not count. Board cards come first, then the most recently active. `q` is read as a form field, so `+` is a space and `%2B` a plus. `limit` is 50 by default, 200 at most; `truncated` says more cards matched. `scope=older` leaves out the working set (what a client already holds), `scope=archived` keeps archived cards that are not subagents, and an empty `q` lists the most recent cards of the scope. No transcript is read: the folded text of each card is kept between searches, so a search over 2,500 cards takes a few milliseconds.
- A master does not have its peers' unclaimed All Sessions cards (they are not synced), so it asks each online peer the same search with `local=1` and merges the answers, each card once, the owner's copy kept. A peer has 2.5 seconds; one that is off, late or failing is named in `unreachable` and the answer goes out without it.
- `POST /v1/tasks` resolves `project` as a project path first, then as a project name (case-insensitive). An unknown project is a 400 that lists the known names. The card launches with the app's defaults for that project: runtime (`tmux`, or `agtop` for rush, its name before the rename, which older clients expect), skip permissions, and the command template. `machine` picks where it runs: `mac`, `local` or `here` for the master that answers, its own name from `GET /v1/machines`, or the name of an ssh machine, a boxd machine or a peer master. An ssh machine that runs a paired master is that master: the card is handed to it. Without it the card runs where the New Task dialog would start it for that project.
- `prompt` with `mode: queue` delivers the text when the current turn ends, or at once when the session is idle. `mode: now` interrupts the turn first. A card with no live session returns 409 until it is resumed.
- `prompt` and `tasks` take `images`: up to 6 `RemoteImage` objects, `{"mediaType": "image/png", "data": "<base64>"}`, each at most 5 MiB decoded, PNG, JPEG, GIF or WebP (the server reads the format from the bytes). `text` may be empty when there are images. The Mac writes them to files and sends them the way its own chat does: pasted into Claude in tmux, `--image` for rush. A bad image fails the whole request with 400. An older server ignores `images` and sends the text alone, so check the `images` feature first.
- A prompt's `text` places each image with an `[Image #N]` marker, N counting from 1 in `images` order, as in Claude Code. The server renumbers the markers in text order, reorders `images` to match and drops an image no marker names. Text with no marker keeps every image, after the text. In the transcript, a user message shows its images as those markers (images sent by file path too); a message whose images have no markers ends with `[image]` or `[N images]`.
- A card's `queuedPrompts` lists the prompts waiting for the turn to end, oldest first, each with `id`, `text` and `imageCount`. `POST /v1/cards/{id}/queue/{promptId}` sends one now, interrupting the turn when one runs; `DELETE` on the same path drops it. Both return 404 when the prompt is no longer queued (sent or removed).
- rush cards use rush's own queue. `mode: queue` hands the prompt to `rush session send` at once and rush holds it while Claude works; `mode: now` is `rush session send --now`, which gives it to Claude mid-turn without stopping the turn. Images always go at once. The card's `queuedPrompts` come from rush's queue (ids `agtop-<n>-<hash>`; `rush-<n>-<hash>` is accepted too), read on every session scan and every 2 seconds while something is queued, and `/queue/{promptId}` runs `rush queue send|remove <id> <n> --was <text>` (`agtop session queue <id> send|remove` where only agtop is installed).
- `side-chat` starts a `/btw` or `/catchup` run (see [`side-chat.md`](side-chat.md)): `{"kind": "btw", "question", "history"}` or `{"kind": "catchup"}`. The run reads the session and writes nothing into it. Poll the run until `state` is `done` or `failed`; `text` grows while it is `running`. A catch-up run carries `since` (the human's last message) and `refs` (the messages it can cite, each with the transcript `offset` a `RemoteMessage.id` starts with). A `catchup` request for a card whose session has no message after the last one its previous catch-up covers returns that run again at once: `state` `done`, `reopened: true`, `finishedAt`, and `followUps` (the exchanges asked in its side chat); `fresh: true` in the request runs a new one. A `btw` request that follows up on a catch-up passes that run's id as `catchUpId`, so its exchange is kept with it. Other runs are kept for 15 minutes. A card another master owns is forwarded there. 409 for a card with no conversation or a session that is not Claude Code.
- `slash-commands` lists what the chat composer offers after `/` (see [`slash-commands.md`](slash-commands.md)). The master that owns the card reads its disk; a card another master owns is forwarded there, and while that master does not answer the list is the last one it gave, else the chat's and the agent's commands. A list is kept for 30 seconds per card.
- `pasted-image` takes the bytes of one image as the body (PNG, JPEG, GIF or WebP, read from the bytes, at most 20 MiB) and writes them to `~/.kanban-code/images/pasted/` on the master that owns the card; a card another master owns is forwarded there. `path` is the file on that master. It is for a paste into the card's terminal: the assistant runs on the owner and reads the owner's clipboard, so the Mac uploads the image and types its path into the terminal, which the assistant takes as a dropped image file. Files older than 7 days go when the next one is stored.
- `human: true` on `prompt` and `tasks` says the human typed the text himself in a chat composer. The server records it per card and passes `--human` to rush. It is dropped for an agent-scope device.
- `transcript` pages back with `before=<olderCursor>` of the previous page; `olderCursor` is null at the start of the conversation.
- A user record the harness wrote is a `system` message, not a `user` one: the summary of a compaction is `{"role": "system", "text": "Conversation compacted", "detail": "<the summary>"}`, and the `/compact` command is a `system` message with the command as `text`. `detail` is absent on every other message. The chats show such a message as a centered note; one with `detail` opens to it. The rule is `HarnessNote` in `Sources/KanbanCodeRemoteKit/HarnessNotes.swift`, which the Mac chat applies to its own turns.
- `resume` on a card that never ran launches it.
- `PATCH /v1/cards/{id}` does what the Mac's card menu does. `archived: true` archives the card and ends its sessions; `archived: false` puts an archived card back in the backlog as a manual placement, so it stays there however old its session is; resuming it lets activity move it again. `pinned: true` pins it on top of the board and brings an archived card back; a subagent card cannot be pinned (409). `DELETE` removes an archived card with its subagents, sessions and conversation file, as Delete Card on the Mac; a card still on the board, or an archived GitHub issue, is refused with 409.
- `worktree/remove` runs where the worktree is: on this master's disk, over ssh on the ssh machine that runs the card, or on the master that owns the card (the request is forwarded there). Then the card loses its worktree, or is deleted when it has no session. A card on a disposable boxd machine is left alone: the worktree goes with the machine. A failure is a 409 that names the machine: `Worktree cleanup on <machine> failed: <git's answer>`. `discover` re-scans the card for pushed branches and pull requests on the owning master.
- `/v1/events` (also `?all=1`) sends a `board` event with the whole board on connect, then `cards` events at most once per second: `upserted` holds the cards whose value changed or that joined the set, `removed` the ids that left it (archived, moved out of the recent Done, deleted), and `projects` the project list when it changed. A client applies them by id (`RemoteEvent.apply(to:)` in RemoteKit). A text frame `{"type":"resync"}` from the client gets a whole `board` again; so does every new connection. A `ping` event arrives every 20 seconds.
- `terminal` without `session` opens the card's primary terminal. A terminal that is not running returns 409.

## Several masters

The Mac app and `kanban-code-server` (an always-on Linux box) are both masters: each runs the same engine, owns the cards it launched or adopted, and syncs light card state with its peers (Settings > Remote Control > Peers: a peer's URL and a device token that peer issued, `kanban-code-server pair <name>` on a box). A card carries `machineId`/`machineName`, the master that owns it.

- Any master answers for any card: prompts, queue, interrupt, resume, transcript and move on a card another master owns are forwarded to that master. The terminal of such a card on the Mac runs `kanban remote attach`, which bridges the owner's terminal socket with the peer's terminal token. An image pasted into that terminal is uploaded to the owner with `pasted-image` (peer token) and its path there is typed through the bridge; an image dropped on the card is sent to the owner as a prompt with that image.
- `POST /v1/tasks` with `machine` naming a peer creates the card here and hands it to that peer, which starts it. `project` may also be a repository URL: the master finds the project with that origin, or clones it into `~/Projects` (a box).
- `POST /v1/cards/{id}/move` with `{"to": "<machine id or name>"}` continues a card on a peer master, or `"mac"`/`"local"` for the master that answers. A move to a peer is a handover: the session ends, the worktree branch is pushed to origin, the card is released; the peer reads `handover` (origin, branch, uncommitted changes as a base64 git diff), checks out the worktree, copies the transcript through `transcript/raw` with its paths rewritten, adopts the card and resumes it. Only Claude conversations move. A name that is not a peer is a boxd or ssh machine this master drives.
- One machine is one choice. An ssh machine of Settings > Remote whose host is a paired peer (the ssh target host is the peer URL host, or the names match) is shown once, in the launch dialogs, Continue on, the API and `kancode://move`, and running a card there hands it to that master, so it keeps going while this Mac is off. A card that already ran there over ssh moves to that master on its next resume: the ssh session ends first, and the master continues in the same folder with the transcript it already has (`machineCwd` in `handover`), uncommitted work included. Until then it stays owned by the Mac, labelled with the Mac as its master.
- The Mac keeps a copy of each foreign card's transcript under `~/.kanban-code/peers/<machine>/transcripts/` for its chat view. When a peer is offline its cards stay on the board, marked offline.
- Shared card fields (name, column, order, pin, archive, prompt, pull requests...) merge per field: each carries its own stamp in `fieldRevs`, and the newer stamp wins, so edits of different fields on two masters both stay.
- A card archived on one master has its sessions ended by the master that owns it, when that master reads the archive. Removing its worktree (the cleanup offered after an archive) runs on the owner too, through `worktree/remove`.
- Liveness, turn state and the queue of a foreign card (rush's queue included) come from its owner's board, read every few seconds. Send now, edit (`PATCH /queue/{promptId}`), remove and new prompts go to the owner.
- A master that runs all the time (`kanban-code-server`, `alwaysOn` in its identity) polls GitHub for the pull requests of every card while it is online, and writes them on cards other masters own; the others do not poll. With no such master online, the master with the lowest machine id polls. Masters send the repository (`host/owner/name`) of their project paths with the links, so the poller needs no checkout of them.
- The always-on master is the channels home: channels and DMs live in its `~/.kanban-code/channels/`. Another master mirrors that directory (appends by offset, the rest whole, deletions follow; `read-state.json` and `drafts.json` stay local), writes `channels-home.json` for its CLI, and sends every channel write there: its `kanban channel`/`kanban dm` commands and its UI go through `POST /v1/cli`. The first time a Mac pairs with a home that has no channels, it copies its own there. Channel messages for a card another master runs are queued on that master (through the command inbox from the CLI).
- `kanban subagent` and the other command inbox operations run on the master whose CLI wrote them, the box included.

### Peer scope

The token a master holds for its peer has the `peer` scope, in both directions. It may call what pairing uses and nothing else (`RemoteScopePolicy`, an allow list: a route added later is refused until it is listed):

- Card sync: `GET /v1/links`, `POST /v1/links/changed`, `GET /v1/peers`, `GET /v1/board`, `GET /v1/machines`, `GET /v1/events`, `GET /v1/me`.
- What the human does to a card the peer owns: `POST /v1/tasks`, `GET /v1/cards/search`, and on `/v1/cards/{id}`: `GET`, `PATCH`, `DELETE`, `transcript`, `transcript/raw`, `prompt`, `queue/{promptId}`, `interrupt`, `resume`, `side-chat`, `slash-commands`, `pasted-image`, `discover`, `worktree/remove`.
- Moves between masters: `POST /v1/cards/{id}/move`, `GET /v1/cards/{id}/handover`.
- Approvals: `GET /v1/attention`, `POST /v1/attention/presence`, `POST /v1/attention/{id}/resolve`, `POST /v1/attention/{id}/note` (the note of a refused vault request, see [vault.md](vault.md)).
- Channels: `POST /v1/cli` (`kanban channel` and `dm` only), `GET` and `PUT /v1/channels/files`.
- Agent sync: `/v1/sync/state`, `/v1/sync/file`, `/v1/sync/changed`, `POST /v1/optmem/run` (memo `note`, `nap`, `forget`, `wake`, `recall`, `zoom` only).
- Vault: `GET` and `POST /v1/vault/replica` (the encrypted file), `POST /v1/vault/card-token`, and the audit log mirror (`GET /v1/vault/audit/hashes`, `GET` and `POST /v1/vault/audit/mirror`).
- Scrubber: `/v1/scrub/status`, `/v1/scrub/index`, `/v1/scrub/run`, `/v1/scrub/schedule`.

Refused with 403: the terminal socket, and every vault route that releases, lists or edits a secret. So a peer's token cannot open a shell here.

The Mac shows the terminals of the box's cards, so it holds a second token of the box, scope `terminal` (`kanban-code-server pair "<name> terminals" --scope terminal`), in the peer entry's `terminalToken` (Settings > Remote Control > Peers). The box holds no terminal token of the Mac: it never opens a terminal there.

Pairing: `kanban-code-server pair <name> --scope peer` on a box, Add Device > Peer master on the Mac. A peer entry whose token is still `full` keeps working; change its `scope` in `~/.kanban-code/remote/devices.json` on the machine that issued it (the server re-reads the file).

## Staying awake for the phone

A Mac with its lid closed wakes on its own for a moment now and then (a dark wake) and goes back to sleep within a minute or two. A phone request that arrives in that moment is answered, and anything longer, such as a catch-up, is cut off.

So a request the human makes to a card this Mac owns holds the Mac awake for 10 minutes after the last one (`RemoteWakeHold`):

- What counts: any `/v1/cards/{id}...` route called with a full-scope token (the phone), or by a paired master passing on such a request. A master sets `X-Kanban-For-Owner: 1` on what it forwards while it serves a full-scope device; its own calls (board and links sync, transcript mirror, agent sync, vault replica) carry no header and never count. Agent and terminal tokens never count, nor does `/v1/board`, `/v1/events` or any other route without a card.
- The hold is a `PreventSystemSleep` power assertion with its own timeout, so it ends by itself. macOS honours it on power, also with the lid closed; on battery with the lid closed it does not. The marker app that Amphetamine triggers on runs for the same time.
- A side chat run ends within 10 minutes, so the request that starts it covers the whole run; every poll of its answer extends the hold.
- Settings > Amphetamine > "Stay awake while a card on this Mac is used from the phone" turns it off. `[wake]` lines in `~/.kanban-code/logs/kanban-code.log` say when a hold starts; `pmset -g assertions` lists it.

A Mac that is fully asleep gets no request and is not woken. The phone then shows the machine as offline.

## Agent sync

Settings > Sync keeps the agent setup the same on every master. The list lives in `~/.kanban-code/sync.json`; the copy with the newest `updatedAt` wins, so entries edited on the Mac reach the box. Each master only writes its own disk: it scans its entries every 5 seconds, sends `POST /v1/sync/changed` to its peers when something changed, and pulls `GET /v1/sync/state` from each online peer every minute or when poked.

- `git` entries: cloned where missing (the origin URL comes from the entry or from a peer that has a clone), fetched and fast-forwarded every two minutes and when a peer says it pushed, local commits pushed. A clone that diverged from its upstream, or whose local changes block a fast-forward, is reported in Settings and left alone.
- `mirror` entries (files or folders): a manifest per entry (`~/.kanban-code/sync/manifests/`) keeps each file's hash, mtime and origin machine. The newest version of each file wins; a deletion is a version too, so it travels. The hash is taken with the home folder replaced by a marker, so the Mac and Linux copies of one file hash the same and nothing bounces. Text files and symlink targets are rewritten to the local home (`/Users/rchaves` and `/root`). A path the two machines never agreed on is never deleted by a peer, and when a peer's newer version replaces it the local copy stays as `<name>.sync-prev` (once). Exclude patterns per entry: a name (`*.log`), a folder (`.trash/`) or a path in the entry.
- `json` entries (Settings keys): for a JSON settings file that also holds what belongs to one machine (logins, window state). `keys` names the top-level keys kept the same; the rest of the file never leaves its machine. Each named key is a version of its own, keyed by its name in the manifest: what travels and is hashed is its value without whitespace, and the newest value of each key wins on its own, so a newer change to one key on a machine never undoes another key set elsewhere. A key the file drops is a deletion of the value it had, and a peer removes the key only when it holds that value or synced it before; a machine that never had the key takes it. Applying a key rewrites the file as text: that key is set, added or removed, every other key keeps its bytes, place and the file its permissions. The write is a temp file and a rename, and is dropped when the file changed since it was read (the next round merges again). A file that is not a JSON object at that moment is skipped and its last version stands. A machine that does not have the file is left without it, and a file removed on one machine is never removed on another. The local copy stays as `<name>.sync-prev` on first sync, as for a mirror.
- `paths` on a `mirror` or `json` entry gives the path on a machine that keeps it somewhere else, by machine name (any case) or id: `{"mode": "json", "path": "~/.config/app/config.json", "keys": ["theme"], "paths": {"box": "~/.config/old-name/config.json"}}`. A machine not named uses `path`. Changing an entry's path or keys on a machine starts its manifest for that entry over.
- A master older than the `json` mode cannot read a list that holds such an entry and stops syncing until it is updated, so update every master before adding one.
- `optmem` entry: the home (the always-on master unless the entry names one) keeps the memory. Every other master copies `memory/` and `WAKE.md` from it one way and writes `~/.optmem/home.json` (URL, token, optional ssh fallback). memo reads that file: `note`, `nap` and `forget` run on the home through `POST /v1/optmem/run` (or ssh), which numbers the memories and refreshes its `WAKE.md`; with the home unreachable they wait in `~/.optmem/spool/` and the master replays them in order once it answers. A home with fewer memories than a follower's copy was never seeded: the follower keeps writing locally and Settings asks to seed the home first.

## Terminal stream

`/v1/cards/{id}/terminal` runs, for each connection, the command the Mac's own card terminal would run:
- `rush open <id>` for a rush card (`agtop open <id> --solo` where only agtop is installed). Each viewer gets its own rush UI, sized to its own screen.
- `tmux attach -t <session>` for a tmux terminal. It shares the window with the Mac, and tmux sizes the window to whichever client was used last.

The command runs in a pseudo-terminal on the Mac.
- Binary frames carry bytes both ways: the terminal's output to the client, keystrokes to the terminal.
- A text frame `{"type":"resize","cols":N,"rows":M}` resizes the pseudo-terminal.
- A text frame `{"type":"scroll","lines":N}` scrolls a tmux terminal's history, up when N is positive, as the Mac's own terminal does with the wheel: tmux copy-mode, left again on reaching the bottom. rush ignores it; it turns on mouse reporting, so a client scrolls it with wheel events (`CSI < 64;col;row M` up, `65` down) in the byte stream. An older server types unknown text frames into the terminal, so send `scroll` only when health lists `terminalScroll`.
- Closing the socket ends that one viewer process. The session itself keeps running.

## Clients

- iOS app: `Apps/iOS`. See its README for building and installing on a phone.
- CLI: `kanban remote login <url> --token <token>` saves the server in `~/.kanban-code/remote-client.json`. `KANBAN_REMOTE_URL` and `KANBAN_REMOTE_TOKEN` override the file. Then:
  - `kanban remote cards [--all] [--search <text>]`
  - `kanban remote show <card>`
  - `kanban remote task --project <name|path> [--worktree [name]] [--name <n>] [--image <path>]... "<prompt>"`
  - `kanban remote send <card> [--now] [--image <path>]... "<text>"`
  - `kanban remote transcript <card> [--limit N] [--follow]`
  - `kanban remote wait <card> [--timeout 30m]`
  - `kanban remote interrupt <card>`
  - `kanban remote resume <card>`
  - `kanban remote projects`, `kanban remote whoami`, `kanban remote logout`
  - On the Mac: `kanban remote pair`, `kanban remote devices`, `kanban remote revoke <id|name>`

  Installing on another machine and every option: `cli/docs/remote.md`. An agent skill for it: `cli/docs/openclaw-skill.md`.
