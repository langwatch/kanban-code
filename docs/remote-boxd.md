# Boxd remote mode

Kanban Code can run a card on its own boxd cloud machine. The tmux session, the coding assistant and the repository checkout live on the machine. The Mac keeps the board, the channels, the DMs and a mirror of every transcript.

This document describes the file layout on the machine and the bridge protocol between the Mac app and the machine. Settings and user flows are in `specs/remote/boxd.feature`.

## Transport

A boxd machine is not reached over SSH (an ssh machine is, see "Ssh machines" below). Every interaction goes through the boxd CLI:

- `boxd machine exec <vm> -- <command>` runs a command. Stdout streams live, stdin is forwarded, the exit code is forwarded.
- `boxd machine cp - <vm>:<path>` uploads a file from stdin.
- `boxd machine new|get|pause|resume|wake|start|remove` control the machine.

The bridge is one long-lived exec per machine:

```
boxd machine exec <vm> -- /usr/local/bin/node /home/boxd/.kanban-code/cli/dist/kanban.js remote-agent
```

Both directions carry one JSON object per line.

## File layout on the machine

| Path | Content |
|---|---|
| `~/.kanban-code/cli/` | The kanban CLI copied from the app bundle (`dist/`, `node_modules/`, `package.json`). `VERSION` holds the app version that uploaded it. |
| `~/.local/bin/kanban` | Shim that runs `node ~/.kanban-code/cli/dist/kanban.js`. |
| `~/.kanban-code/hook.sh`, `statusline.sh` | Installed by `kanban hooks install` into `~/.claude/settings.json`. |
| `~/.kanban-code/hook-events.jsonl` | Hook events written on the machine. Streamed to the Mac. |
| `~/.kanban-code/context/<sessionId>.json` | Statusline context usage. Streamed to the Mac. |
| `~/.kanban-code/commands/proxy/<id>.json` | A `kanban` command that must run on the Mac (see proxy mode). |
| `~/.kanban-code/commands/proxy-responses/<id>.json` | The result of that command. |
| `~/.kanban-code/tmp/` | Prompt buffers and launch scripts written by the Mac. |
| `~/.kanban-code/images/<cardId>/` | Prompt images uploaded by the Mac. |
| `~/<repo_name>/` | The repository checkout (folder template in settings). Worktrees are under `<repo>/.claude/worktrees/<name>`, created on the machine only with `git worktree add -b <name>`; the branch reaches origin when the assistant pushes it. |

Card tmux sessions on the machine are created with the environment `KANBAN_REMOTE_PROXY=1`, `KANBAN_CARD_ID=<cardId>` and `KANBAN_CODE_HOME=/home/boxd/.kanban-code`.

## Path mapping

The Mac keeps one mapping table per machine, longest prefix first:

| Machine | Mac |
|---|---|
| `/home/boxd/<repo_name>` | The project path of the card |
| `/home/boxd/.kanban-code` | `~/.kanban-code` |
| `/home/boxd` | The user's home directory |

Every `.jsonl` line under `~/.claude/projects/` and `~/.codex/sessions/` is rewritten when it crosses the bridge: each string value in the JSON is walked and mapped prefixes are replaced. The mirror on the Mac is written to `~/.claude/projects/<encoded local cwd>/<sessionId>.jsonl`, so a local `claude --resume` works at any moment. Before a remote resume the Mac rewrites the local transcript to machine paths and uploads it.

### Pushing a transcript to the machine

Before a remote resume without a live tmux session the Mac compares the transcript on both sides by line count (`wc -l` on the machine). The rewrite changes the byte size of a copy, a Mac path is longer than a machine path, so a byte comparison would push the same file on every resume. The push happens only when the Mac has more lines.

The push is incremental: the transcript only grows, and the rewrite is deterministic, so when the machine already holds its first lines the Mac hashes that prefix on both sides (`sha256`) and sends only the tail, which one `cat` appends on the machine. A prefix that differs, or an empty machine, gets the whole file. The push sends `hold {path}` to the agent first, then the bytes (`put` under 2 MB, `boxd machine cp` above, always to a unique temporary name moved into place, because two uploads to one target destroy each other), then `release {path, offset}` with the byte count written. Only one push per transcript runs at a time; a second resume of the same card waits it out. A held path is skipped by the watcher, and the release sets the offset the agent streams from, so a transcript of a hundred megabytes does not come back over the bridge as one message. The sidecar files and the statusline context go through the same hold. The rewrite runs off the supervisor actor, and the launch progress shows "Preparing transcript (107 MB)" and "Pushing transcript (105 MB)".

Every `file` message the agent sends carries at most 4 MB, cut at a newline, and the next chunk goes out on the next tick of the event loop. An `exec` answer never waits behind a large file.

## Messages from the machine to the Mac

| Type | Fields | Meaning |
|---|---|---|
| `hello` | `agentVersion`, `home`, `kanbanHome`, `vm` | First line after start. `home` is the user's home directory on the machine. |
| `file` | `path`, `cwd?`, `offset`, `data`, `eof` (a file that is not `.jsonl` always comes whole, at offset 0) | `data` is base64 of the bytes appended at `offset`. For `.jsonl` files the chunk ends on a line boundary. `cwd` is the transcript's own working directory, read from the file or derived from its directory name. |
| `removed` | `path` | The file was deleted. |
| `proxy` | `id`, `argv`, `cwd`, `stdin`, `env`, `images` | A `kanban` command to run on the Mac. `images` is a list of `{name, base64}`. |
| `exec-result` | `id`, `stdout`, `stderr`, `code` | Result of an `exec`. |
| `activity` | `kind` | `hook` or `transcript`. The Mac stamps the time of receipt. |
| `pong` | | Reply to `ping`. |

## Messages from the Mac to the machine

| Type | Fields | Meaning |
|---|---|---|
| `watch` | `roots`, `offsets` | `roots` is a list of `{path, globs}`. `offsets` maps a path to the byte count the Mac already has. Files below the offset are not resent. |
| `put` | `path`, `data`, `mode?` | Write base64 `data` to `path`, creating parent directories. |
| `exec` | `id`, `argv`, `stdin?`, `cwd?` | Run a command. `argv[0]` is the program. |
| `proxy-result` | `id`, `stdout`, `stderr`, `code` | Result of a `proxy` request. |
| `ping` | | Keepalive. |

Watched roots: `~/.claude/projects` (`**/*.jsonl` and the sidecar directories `**/tool-results/*`, `**/subagents/*`), `~/.codex/sessions` (`**/*.jsonl`), `~/.kanban-code/hook-events.jsonl`, `~/.kanban-code/context/*.json`, `~/.kanban-code/commands/proxy/*.json`.

## Proxy mode of the kanban CLI

When `KANBAN_REMOTE_PROXY` is set, the CLI does not run the command on the machine. It writes `{id, argv, cwd, stdin, env: {KANBAN_CARD_ID}, images}` to `commands/proxy/<id>.json`, waits for `commands/proxy-responses/<id>.json`, prints the stdout and stderr it contains and exits with the returned code.

Commands that always run on the machine: `remote-agent`, `hooks install`.

Commands refused in proxy mode: `channel share`, `slack *`, `daemon`, `launch`, `reconcile`, `open`, and any command with a `--project <path>` option.

On the Mac the app runs the bundled CLI with the same arguments and `KANBAN_CARD_ID` set. The CLI uses `KANBAN_CARD_ID` as the caller identity before it looks at the tmux session.

## Machine lifecycle

| Event | Action |
|---|---|
| Session stopped by itself | `boxd machine pause`, the machine keeps its tmux in standby |
| Terminal tab closed, card archived | `boxd machine stop`: the work is over, so the machine keeps its disk only. Resume starts it again, cold. |
| Idle for the whole window | `boxd machine stop` as well: standby keeps the memory of the machine on the bill, and a card left for hours costs its disk only. A machine a quick pause put in standby (a peek, sleep) is stopped too once the window passes it. A failed resume also leaves the machine in standby instead of running. |
| No activity for the idle window | `boxd machine pause`, the card shows the reason |
| A card comes into focus, or a click or a key reaches its terminal | The machine is resumed and the bridge connects again |
| App quit, system sleep | The machines keep running; killing the sessions from the quit sheet puts their machines in standby |
| Resume | `boxd machine get`, then `resume`, `wake` or `start` by status. If the tmux session still exists the app attaches to it. Otherwise it pushes the transcript when the Mac has more lines than the machine (see below) and starts `claude --resume`. |
| Archive or delete with a machine | The app asks before it runs `boxd machine remove`. |

### Which machine runs, and for how long

Only a person takes a machine out of standby, and always with one action. A card whose live session sits on a paused machine shows the transcript of the session in the skin of the terminal (see below) with a bar at the bottom: the reason the machine was paused and a "Resume machine" button, Cmd+Enter as well. In chat mode the same bar sits under the chat. While the machine comes back the bar says "Resuming machine <name>…" with no button, so there is nothing left to click; a machine that does not come back gets "did not answer. Resume tries again." and the button again. Opening the card, a click in the terminal or a key do nothing to the machine: a look at a paused card is free.

A prompt is the other action. A message sent from chat mode, a queued prompt sent by hand or a `kanban send` to a session on a paused machine brings the machine back first and is pasted once the bridge is connected. The prompt counts as work, so the machine keeps its normal idle window afterwards.

A machine brought back with the button is on approval: when its card leaves focus with no work done on it, it goes back to standby at once, so a quick look at the live session costs the seconds it took. The first hook event or transcript line on the machine ends that, and the machine then keeps the normal idle window. A machine that was already running before the look, or one with work on it, is never touched by this. Nothing else resumes a machine: cards nobody has open stay in standby.

Every machine gets the same idle window, the one in the settings (30 minutes by default), whether its card is open or not: an agent can be waiting on a watcher, a subagent or a review, with nothing on the screen to show for it. A machine with work on it is never paused: the check asks the board first and any card that is actively working keeps its machine.

Machines are created with `--auto-suspend-timeout` equal to the inactivity timeout. If the Mac disappears without pausing the machine, boxd suspends it when the bridge traffic stops.

`boxd machine connect` wakes a paused machine in half a second. The attach loop of the embedded terminal reconnects after a drop, so a plain retry would undo every pause. Before the app pauses a machine it writes `~/.kanban-code/remote-ready/<session>.paused` for every session on it; the loop reads that file at the top of every try, prints "Machine paused." and waits on it, and the file goes away when the bridge connects again. The check comes before the connect, not after it: a connect that succeeds takes the machine out of standby and leaves the loop, so a check that runs only after a failed try never sees the marker. The loop reads the machine name from the ready marker on every try, so a resume that moved the session to another machine is followed. The markers are also written at app start for a machine that is not running, so the terminal waits instead of waking it. When a paste or a wheel tick reaches a machine the app has as paused, the app asks boxd first and reconnects at once if the machine runs.

A machine the app paused can be running again through another path, for example `boxd machine resume` in a shell. Once a minute the supervisor lists the machines it holds paused; one that boxd reports as running gets its bridge reconnected, its cards leave the paused state, and the agent answers the proxied `kanban` commands that waited meanwhile (the CLI waits up to 120 seconds for an answer).

A reconnection of this kind keeps the activity clock of the machine: the machine gets 5 minutes, not a new inactivity timeout. A machine that woke without a person behind it goes back to standby at the next tick, and a machine somebody resumed keeps its full timeout as soon as work arrives.

Quit and Mac sleep leave the machines running: the work continues there while the Mac is off, and the bridges reconnect after wake. The quit sheet lists the sessions on machines with a cloud icon; "Kill managed sessions on quit" kills them and puts their machines in standby, bounded to 10 seconds ("Stopping boxd machines" panel meanwhile). A card whose session runs on a machine does not keep the Mac awake: the active-session helper that Amphetamine watches only runs for sessions on the Mac itself.

The launch dialog of a card offers the choice of its last run: a card whose last session ran on the Mac opens with "Run on boxd" off, even though it keeps its machine, and a card whose last session ran on a machine opens with the box on and that machine chosen. A card that never ran follows its machine, and a card with no machine follows the project default.

A card that resumes locally after it ran on a machine gets its worktree created on the Mac at that moment, tracking `origin/<branch>` when the branch was pushed and starting a new branch otherwise. While a machine is paused the card is never shown as working, whatever the last hook event said.

### Transcript in the skin of the terminal

When the session of a card is not on the screen, because the tmux session ended or because its machine is paused, the assistant tab does not go blank. It shows the transcript window the chat mode reads, drawn the way Claude Code draws it: the terminal font on the terminal background, the whole width, no markdown, `>` before a prompt, `●` before a message or a tool call, and the first four lines of every tool result behind `⎿` with "+N lines" for the rest. It scrolls, its text can be selected, and URLs and `owner/repo#123` references open like the ones in the chat. The bar at the bottom carries the way back: "Resume Claude Code" for an ended session, "Resume machine" for a paused one, both on Cmd+Enter. The rows are built by `TerminalTranscript.rows(from:)` in `TranscriptTerminalView.swift`.

### Embedded terminal

The terminal attaches through `boxd machine connect <machine>`, the interactive shell of the CLI, which is what a terminal app uses too: it puts the local pty in raw mode, sizes the remote pty, follows resizes, and the session lives as long as the shell. `boxd machine exec --tty` does none of that (canonical mode, remote pty 0x0) and hangs up a full-screen program such as tmux after a few seconds, so it is not used for the terminal.

The wheel is not forwarded to the machine as mouse events. As for a local session, the app turns wheel ticks into tmux copy-mode commands (`copy-mode`, `send-keys -X cursor-up`), and for a session on a machine those commands go through the bridge of the machine. A tick to a local server costs a process spawn; a tick to a machine costs a round trip, so the ticks of the last 60 ms are summed into one command. Esc and any other key leave copy-mode through the same route. The terminal never reports mouse events to the assistant, even when it asks for mouse tracking: a drag selects text in the terminal itself, as in a local session.

Images cannot be pasted through the clipboard: the assistant on the machine reads the machine's clipboard, which has nothing. An image pasted into the terminal with Cmd+V goes over the bridge to `~/.kanban-code/images/pasted/` on the machine, and the path is pasted into the session through the tmux server of the machine (`load-buffer`, `paste-buffer -p`). The bridge runs that after the upload, so the assistant finds the file when it checks the pasted path and shows it as an attached image. Typed through the terminal instead, the path raced the upload: `put` returns before the machine has written the file. A chat message with images uploads them the same way and the prompt points at them by path, which is also how a queued prompt with images already worked at launch.

`connect` takes no command, so `/usr/bin/expect` drives it: `spawn` connect, `expect` the prompt (20 seconds, then the command is sent anyway), `send " exec tmux -u -T hyperlinks attach-session -t <session>\r"`, then `interact`. `exec` replaces the shell, so a detach closes the connection and the script prints "Session ended.". A WINCH trap copies the local size to the pty of connect. The machine name reaches the Tcl program through `KANBAN_MACHINE`. Everything else (the bridge, tmux commands, file copies) stays on plain `boxd machine exec`, which runs for hours. The assistant runs with `LANG=C.UTF-8`.

### Sweep

At startup and every 10 minutes the app lists the machines and cleans up the ones it created (`kanban-<repo>-<card>`):

| Machine | Action |
|---|---|
| No card references it, or only archived cards do, and it is not running | `boxd machine remove` |
| No card references it and it is running | `boxd machine pause`; the next sweep removes it |
| A card references it, the card has no tmux session, the machine is running and has no bridge | `boxd machine pause` |

The source machine of the snapshot and machines with an open bridge are never touched. A running orphan is paused before it is removed so a machine another process is using (for example the end to end test) gets a grace period.

### Launch progress

A launch or resume on boxd reports every step (`Creating machine`, `Running the initialization command`, `Checking out <branch> on the machine`, ...) as an action. The card shows the current step under the "Starting session" spinner, and the step repeats every 10 seconds, which keeps the 30 second stale-launch timers of the reconciler and of the card from giving up during a long checkout.

The embedded terminal opens when the launch starts. For a remote session it waits for a marker file, `~/.kanban-code/remote-ready/<session>`, which the launch writes once the tmux session exists on the machine, and only then runs `boxd machine exec --tty <vm> -- tmux attach-session`. The marker contains the machine name. A launch flags its session as remote before it knows the machine, so a terminal that starts during the first seconds of a launch still takes the remote path and reads the machine from the marker. While a remote launch reports steps, the card shows the spinner and the step on top of the terminal.

The service graph of the app (store, boxd supervisor, session registry, tmux router) is built once in `AppComposition` and shared by every `ContentView` value SwiftUI creates. The supervisor sends its actions to that one store.

#A shell tab of a card on a machine (Cmd+T) opens on the machine, in the remote checkout. The app marks the name as remote before the tab opens, creates the session through the bridge, and writes the ready marker, which is what the terminal waits for. A shell that cannot be created takes only its own tab: the session of the card keeps running.

## Ssh machines

An ssh machine is an always-on host, for example a server on the tailnet, that runs cards the way a boxd machine does. Settings, Remote, mode "SSH machines" (the default mode) lists them: a name, the ssh target (`user@host` or a host alias of `~/.ssh/config`), and the folder the repositories are cloned into (`~/Projects` by default). A card stores the name as its machine.

The supervisor reaches it through `SshHostPort`, and `MachinePortRouter` sends every other machine name to boxd:

| boxd | ssh machine |
|---|---|
| `boxd machine get` | `ssh <target> -- printf "$HOME" and the path of node`; a machine that does not answer is unreachable, never created |
| `boxd machine exec` | `ssh <target> -- <command>` |
| `boxd machine cp` | `ssh <target> -- cat` into a temporary name, moved into place |
| bridge over `boxd machine exec` | `ssh -T <target> -- node ~/.kanban-code/cli/dist/kanban.js remote-agent` |
| terminal over `expect` and `boxd machine connect` | `ssh -tt <target> -- tmux attach-session -t <session>` |
| pause, stop, remove | nothing |

Every ssh call runs with `BatchMode=yes`, so the key must be loaded, and with keepalives, so a dead connection ends the bridge and the supervisor reconnects.

The machine is shared: several cards, of several projects, run on it over one bridge. The mirror maps the checkout of every project that ran there. The app never pauses or stops it: the idle window, the self-park watchdog, the sweep, the peek pause and the quit sheet leave it alone, and "Remove machine" is not offered. A card that ends its work there has its tmux sessions killed and nothing else.

A session of `root` gets `IS_SANDBOX=1`, without which Claude Code refuses `--dangerously-skip-permissions`.

### Colors

A session on a machine renders like a local one. The assistant gets `COLORTERM=truecolor`, its tmux session starts with `unset NO_COLOR`, and when the bridge connects the app removes `NO_COLOR` from the global environment of the machine's tmux server and sets `COLORTERM` there. A tmux server started from a shell with `NO_COLOR=1` (an agent's shell, for example) passes it to every session it creates afterwards, and Claude Code then prints no colors at all. The terminal attaches with `COLORTERM=truecolor` on the machine; ssh forwards `TERM` itself.

### rush

[rush](https://github.com/0xdeafcafe/rush) was named agtop before a rename. The app runs `rush` and falls back to `agtop` on a machine that has only the older build. New hosts get the session name `rush-<id>`, also passed as `--meta kanban_session=rush-<id>`; a host without that meta was started before the rename and keeps `agtop-<id>`. The settings value and the remote board runtime stay `agtop` on the wire, since older builds read only that. On the Mac and on a master box, `rush session start` gets `--binary <absolute path of claude>`, so a host rush restarts later from a process with a bare PATH still finds claude; a card on an ssh machine leaves the lookup to that machine.

When Settings > Assistants runs Claude on rush and the machine has `rush` (or `agtop`) on its PATH (checked when the bridge connects), a card launched or resumed there runs on the machine's rush instead of tmux:

- `rush session start --agent claude|send|info|interrupt|stop` and `rush queue send|remove` run on the machine through the bridge. A prompt goes on stdin (`--prompt-file -`); images are copied to `~/.kanban-code/tmp/rush/` there first. With agtop the queue commands are `agtop session queue <id> send|remove`, and `start` takes no `--agent`.
- The terminal runs `ssh -tt <target> -- rush open <id>` (`agtop open <id> --solo` with agtop), opened again when it is quit or the connection drops.
- The session list of the machine includes the live hosts this Mac started there (the names it assigned), with their queues. Hosts another master runs on the same machine are left out.
- A resume first ends the card's tmux sessions, so the conversation never runs twice. A card whose tmux session is still alive on the machine keeps it: it attaches as before, and moves to rush on the next resume after that session ends.
- A command template or an API service launcher wraps `claude` in a script of the Mac, so those cards stay on tmux on the machine. boxd machines stay on tmux as well.

rush and agtop speak the same host protocol: rush drives hosts an agtop build started, and agtop drives hosts rush started. Replacing the binary leaves running hosts on the old one until they end.

The app logs a warning when the commit in the machine's `rush --version` differs from the Mac's. `Scripts/rush-to-machine.sh <ssh target>` cross-builds rush at the Mac's commit from a clone in `~/.kanban-code/rush-src` (`GOOS=linux GOARCH=amd64 CGO_ENABLED=0 go build ./cmd/rush`, or `RUSH_SRC=<checkout>`) and installs it at `/usr/local/bin/rush`.

### Moving a card

A card moves between the Mac and a machine through a resume on the other side, from the resume dialog ("Run on"), from `kanbancode://move/<cardId>?to=mac|<machine>`, or, for a new task, from the `machine` field of `POST /v1/tasks`.

- To a machine: the session on the Mac (tmux or rush) ends first, so the conversation never runs in two places, then the transcript is pushed as described above and `claude --resume` starts there.
- To the Mac: on an ssh machine every tmux session of the card is killed and the app waits up to 10 seconds for the last transcript lines to reach the mirror; a boxd machine is stopped as before. The resume then runs on the Mac from the mirror, in the card's runtime (rush or tmux), and a worktree that only existed on the machine is created from origin.

The launch dialogs list, under "Run on", this Mac and then the machines of the mode: in the SSH machines mode each ssh machine with whether it answers over ssh, in the boxd mode the boxd machines. A card already on a machine the mode does not list still gets that machine offered. The pick of the last launch of a project is offered again while it exists.

## Files that are rewritten

Only `.jsonl` files grow by appending, so only they are streamed by offset. The machine rewrites the other watched files in place, such as `context/<sessionId>.json` from the statusline, and their new content has nothing to do with the bytes the Mac holds. The agent sends those whole, at offset 0, and only when the content changes; the Mac replaces its copy. Sent as a tail, a shorter rewrite left the end of the last one behind, the file stopped being valid JSON, and the card lost its model name and its context measure.

The machine records the installed CLI in `~/.kanban-code/cli/VERSION` as the app version plus a digest of the bundle. Two builds of one version have different digests, so a fix in the CLI reaches the machines that already have it.

## Logins

Claude Code keeps its OAuth tokens in the Keychain on macOS (`Claude Code-credentials`) and in `~/.claude/.credentials.json` on Linux, with the same JSON inside. Codex keeps `~/.codex/auth.json` on both. Both rotate the refresh token on every refresh, so a machine made from the snapshot drifts from the Mac within hours and one side shows "Login expired".

The supervisor keeps the copies equal. When a bridge connects, and then once a minute, it reads the login files of the machine with one `exec` and compares each with the Mac's copy. The newest copy wins: `claudeAiOauth.expiresAt` for Claude, `last_refresh` for Codex. A newer local copy is written to the machine (`put`, mode 600) together with the `oauthAccount` block of `~/.claude.json`; a newer remote copy is written to the Keychain (`security add-generic-password -U`) or to `~/.codex/auth.json`, and reaches the other machines on their next tick. Running assistants read the shared copy before they refresh, so an account switch on the Mac reaches every session, local and remote. When the two are signed in as different accounts, the side that switched since they last agreed keeps its account: an account switch on the Mac goes to the machine, and an account switch made on the machine (rush moving to another account at a usage limit, a login run there) stays, and its tokens are left alone until the two agree again. The account each machine last agreed on is kept in `~/.kanban-code/login-accounts.json`; a machine with no record there (one just started from a snapshot) gets the Mac's. A token rotation stays quiet. An account switch on the Mac (the `accountUuid` of `~/.claude.json` changed) and a login taken from a machine show a notice with the time.

Two machines that refresh the same token in the same minute leave one of them with a rejected refresh until the next tick. A long-lived token from `claude setup-token`, set in Settings, Assistants, is exported as `CLAUDE_CODE_OAUTH_TOKEN` in every remote session and takes precedence over the synced login.

## What the machines cost

`scripts/boxd-spend.py` tracks the spend outside the app. `install` writes the LaunchAgent `ai.langwatch.boxd-spend`, which runs `sample` every 5 minutes; `report [--days N]` prints the result.

Every sample stores one line in `~/.kanban-code/boxd-spend/samples.jsonl`: the credit balance and the accruing amount of the org from `boxd manage billing --json`, and for every machine of the org its status and the cost of the interval from the rate card (vCPU while running, memory in use while running or in standby, disk in use always). The spend boxd counts is the drop of the balance plus the rise of the accruing amount between two samples. The rate card gives the split per machine, per owner and per Kanban card (from `~/.kanban-code/links.json`).

`boxd machine get` does not report the size or the memory use of a machine. The script reads `nproc`, `free` and `df` with `boxd machine exec` on the machines of this account while they run, never on a paused one (an exec wakes it), and keeps the last values for the standby hours. A machine never seen running is priced with the org default size and an assumed memory use, and the report marks it.

