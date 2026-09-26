# kanban remote

`kanban remote` drives the Kanban Code app on a Mac over its HTTP API (`docs/remote-control.md` at the repo root). It runs on any machine with Node.js 20 or newer that can reach the Mac, usually over Tailscale. Sessions always run on the Mac; this CLI only reads the board and sends requests.

## Install on another machine

The package is not on the npm registry. Build a tarball on the Mac and install it on the other machine.

On the Mac:

```bash
cd ~/Projects/kanban/cli
pnpm install
npm pack --pack-destination /tmp        # runs tsc, writes /tmp/kanban-code-cli-0.1.0.tgz
scp /tmp/kanban-code-cli-0.1.0.tgz root@<vm>:/tmp/
```

On the machine (Linux works, no checkout needed):

```bash
node --version                          # 20 or newer
npm i -g /tmp/kanban-code-cli-0.1.0.tgz # installs the `kanban` binary and its dependencies
kanban remote --help
```

Without root, install into a prefix and put its `bin` on `PATH`: `npm i -g --prefix ~/.local /tmp/kanban-code-cli-0.1.0.tgz`.

Only the `kanban remote` commands are meant for that machine. The other `kanban` commands work on the Mac's local board.

## Pair and log in

1. On the Mac, turn on Settings > Remote Control in Kanban Code.
2. On the Mac, create a token for the machine:

   ```bash
   kanban remote pair --name openclaw --scope agent
   ```

   It prints the token once, the `kanbancode://pair` link, and the `login` command to run. The URL uses the Mac's Tailscale MagicDNS name when `tailscale status` works, else its Tailscale IP, on port 7780. Pass `--url` to use another address, for example the `https://<mac>.<tailnet>.ts.net:7780` of `tailscale serve`.
3. On the other machine:

   ```bash
   kanban remote login http://<mac>.<tailnet>.ts.net:7780 --token kc_...
   kanban remote whoami
   ```

`login` checks `GET /v1/health` and `GET /v1/me`, then saves the URL and token to `~/.kanban-code/remote-client.json` with mode 600. `KANBAN_REMOTE_URL` and `KANBAN_REMOTE_TOKEN` override the file, each on its own. `kanban remote logout` deletes the file.

`kanban remote devices` lists paired devices on the Mac and `kanban remote revoke <id|name>` removes one. The app re-reads `~/.kanban-code/remote/devices.json` on change, so a revoked token fails on its next request.

## Scopes

- `full`: everything, including terminals. For a phone.
- `agent`: board, transcripts, tasks, prompts, interrupt, resume. No terminals. For another agent.

## Commands

| Command | Does |
|---|---|
| `cards [--column c] [--project p] [--all]` | Lists cards. Archived cards only with `--all`. Columns: `backlog`, `in_progress`, `waiting`, `in_review`, `done`. |
| `projects` | Lists project names and paths that `task --project` accepts. |
| `show <card>` | One card: column, state, project, branch, worktree, PRs. |
| `task --project <name\|path> [--worktree [name]] [--name n] [--assistant a] [--model m] [--no-launch] [--image <path>]... <prompt...>` | Creates a card and launches it. `--worktree` without a name picks a random one. |
| `send <card> [--now] [--image <path>]... [text...]` | Queues a prompt for when the current turn ends. `--now` interrupts the turn first. `--image` attaches a PNG, JPEG, GIF or WebP file (up to 6, 5 MiB each); the text may be left out when there is an image. |
| `transcript <card> [--limit N] [--follow] [--timeout d]` | Prints the conversation, oldest first. `--follow` keeps printing new messages until the card is idle. |
| `wait <card> [--timeout d]` | Blocks until the card is idle and has no queued prompts. |
| `interrupt <card>` | Interrupts the current turn. |
| `resume <card>` | Starts or resumes the card's session. |

- `<card>` is a card id, a unique id prefix, or an exact title.
- A prompt or text of `-` is read from stdin.
- Every command takes `--json`. `transcript --follow --json` prints one message per line.
- Durations: `90`, `90s`, `15m`, `2h`.

A card state is `busy` (in a turn), `idle` (live session, waiting for input) or `stopped` (no live session). `send` and `interrupt` on a stopped card fail with 409; run `resume` first.

`wait` and `transcript --follow` poll every 3 seconds (`--interval`). A card that was never seen busy and changed in the last 15 seconds is treated as still launching, so waiting right after `task` does not return before the turn starts.

## Exit codes

- `0`: success.
- `1`: any error: not logged in, the Mac unreachable, 401, 403, 404, 409, or a bad request. The message is on stderr.
- `124`: `wait` or `transcript --follow` reached `--timeout` while the card was still busy.
