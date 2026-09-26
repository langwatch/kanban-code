# Remote control

The Mac app serves an HTTP API that lets other devices drive it: the iOS app on a phone, and other agents through `kanban remote`. The Mac stays the only place sessions run. Wire types live in `Sources/KanbanCodeRemoteKit/RemoteModels.swift`.

```
iPhone (KanbanCodeMobile) ─┐                      ┌─ agtop hosts
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
- Tokens are `kc_` followed by 40 base62 characters. `~/.kanban-code/remote/devices.json` keeps only their SHA-256 with the device id, name, scope, `createdAt` and `lastSeenAt`. The server re-reads the file when it changes, so a revoked device is refused on its next request and its open sockets close.
- Pairing:
  - In the app, Settings > Remote Control > Add device shows the token once, plus a QR code of `kanbancode://pair?url=<base url>&token=<token>&name=<host name>`.
  - On the Mac, `kanban remote pair --name <device> [--scope agent]` writes the same file and prints the token and the link.
- Refusals: 401 with no token or an unknown one, 403 when the scope does not allow the call. Bodies are `{"error": "..."}`.

## Endpoints

JSON bodies, up to 48 MiB. Dates are ISO 8601 with milliseconds, UTC (`2026-09-26T10:00:00.000Z`). A card leaves out `isLive`, `isBusy` and `archived` when false, `queuedPromptCount` when 0, `queuedPrompts`, `terminals` and `prs` when empty, and every null field; read a missing key as that default. Responses over 8 KB are gzipped (`Content-Encoding: gzip`) when the request sends `Accept-Encoding: gzip`.

`GET /v1/health` lists `features`, the additions to API version 1 this server has. A client checks for one before using it; a server without the list has none of them:
- `images`: `images` on prompts and tasks.
- `queue`: `queuedPrompts` on cards and the `/v1/cards/{id}/queue/{promptId}` routes.
- `terminalScroll`: the `scroll` terminal control frame.

| Method and path | Scope | Returns |
|---|---|---|
| `GET /v1/health` | none | `RemoteHealth` |
| `GET /v1/me` | any | `RemoteDevice` |
| `GET /v1/board?all=1` | any | `RemoteBoard` |
| `GET /v1/cards/{id}` | any | `RemoteCard` |
| `GET /v1/cards/{id}/transcript?limit=50&before=<cursor>` | any | `RemoteTranscript`, oldest first |
| `POST /v1/tasks` | any | `RemoteTaskRequest` → `RemoteCard`, 201 |
| `POST /v1/cards/{id}/prompt` | any | `RemotePromptRequest` → 204 |
| `POST /v1/cards/{id}/queue/{promptId}` | any | 204 |
| `DELETE /v1/cards/{id}/queue/{promptId}` | any | 204 |
| `POST /v1/cards/{id}/interrupt` | any | 204 |
| `POST /v1/cards/{id}/resume` | any | `RemoteCard` |
| `GET /v1/events?all=1` (WebSocket) | any | `RemoteEvent` text frames |
| `GET /v1/cards/{id}/terminal?session=<name>&cols=80&rows=24` (WebSocket) | full | terminal bytes |
| `GET /.well-known/openapi.json` | none | OpenAPI 3.1 of the above |

Behaviour:
- `board` and `events` return the working set: no archived cards, no All Sessions cards, and only the 30 most recent Done cards (by `lastActivity`, else `updatedAt`). `?all=1` returns every card.
- `POST /v1/tasks` resolves `project` as a project path first, then as a project name (case-insensitive). An unknown project is a 400 that lists the known names. The card launches with the app's defaults for that project: runtime (tmux or agtop), skip permissions, and the command template.
- `prompt` with `mode: queue` delivers the text when the current turn ends, or at once when the session is idle. `mode: now` interrupts the turn first. A card with no live session returns 409 until it is resumed.
- `prompt` and `tasks` take `images`: up to 6 `RemoteImage` objects, `{"mediaType": "image/png", "data": "<base64>"}`, each at most 5 MiB decoded, PNG, JPEG, GIF or WebP (the server reads the format from the bytes). `text` may be empty when there are images. The Mac writes them to files and sends them the way its own chat does: pasted into Claude in tmux, `--image` for agtop. A bad image fails the whole request with 400. An older server ignores `images` and sends the text alone, so check the `images` feature first.
- A card's `queuedPrompts` lists the prompts waiting for the turn to end, oldest first, each with `id`, `text` and `imageCount`. `POST /v1/cards/{id}/queue/{promptId}` sends one now, interrupting the turn when one runs; `DELETE` on the same path drops it. Both return 404 when the prompt is no longer queued (sent or removed).
- agtop cards use agtop's own queue. `mode: queue` hands the prompt to `agtop session send` at once and agtop holds it while Claude works; `mode: now` is `agtop session send --now`, which gives it to Claude mid-turn without stopping the turn. Images always go at once. The card's `queuedPrompts` come from agtop's queue (ids `agtop-<n>-<hash>`), read on every session scan and every 2 seconds while something is queued, and `/queue/{promptId}` runs `agtop session queue <id> send|remove <n> --was <text>`.
- `transcript` pages back with `before=<olderCursor>` of the previous page; `olderCursor` is null at the start of the conversation.
- `resume` on a card that never ran launches it.
- `/v1/events` (also `?all=1`) sends a `board` event with the whole board on connect, then `cards` events at most once per second: `upserted` holds the cards whose value changed or that joined the set, `removed` the ids that left it (archived, moved out of the recent Done, deleted), and `projects` the project list when it changed. A client applies them by id (`RemoteEvent.apply(to:)` in RemoteKit). A text frame `{"type":"resync"}` from the client gets a whole `board` again; so does every new connection. A `ping` event arrives every 20 seconds.
- `terminal` without `session` opens the card's primary terminal. A terminal that is not running returns 409.

## Terminal stream

`/v1/cards/{id}/terminal` runs, for each connection, the command the Mac's own card terminal would run:
- `agtop open <id> --solo` for an agtop card. Each viewer gets its own agtop UI, sized to its own screen.
- `tmux attach -t <session>` for a tmux terminal. It shares the window with the Mac, and tmux sizes the window to whichever client was used last.

The command runs in a pseudo-terminal on the Mac.
- Binary frames carry bytes both ways: the terminal's output to the client, keystrokes to the terminal.
- A text frame `{"type":"resize","cols":N,"rows":M}` resizes the pseudo-terminal.
- A text frame `{"type":"scroll","lines":N}` scrolls a tmux terminal's history, up when N is positive, as the Mac's own terminal does with the wheel: tmux copy-mode, left again on reaching the bottom. agtop ignores it; it turns on mouse reporting, so a client scrolls it with wheel events (`CSI < 64;col;row M` up, `65` down) in the byte stream. An older server types unknown text frames into the terminal, so send `scroll` only when health lists `terminalScroll`.
- Closing the socket ends that one viewer process. The session itself keeps running.

## Clients

- iOS app: `Apps/iOS`. See its README for building and installing on a phone.
- CLI: `kanban remote login <url> --token <token>` saves the server in `~/.kanban-code/remote-client.json`. `KANBAN_REMOTE_URL` and `KANBAN_REMOTE_TOKEN` override the file. Then:
  - `kanban remote cards`
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
