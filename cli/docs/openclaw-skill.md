---
name: kanban-remote
description: Start and follow coding tasks through Kanban Code with the `kanban remote` CLI, on this machine or on the user's Mac. Use when the user asks for code to be written, fixed, reviewed or run in one of their projects, when they ask what their coding agents are doing, or when a running coding task needs a follow-up instruction.
---

# kanban remote

Coding work runs inside Kanban Code. Each task is a card on the board with its own Claude Code (or Codex) session. Kanban Code has two masters that share one board: this machine (`kanban-code-server`, always on) and the user's Mac (the app, only while it is awake). The `kanban remote` CLI talks to the master it is logged into, and tasks run there unless you pick another machine.

## When to use

- The user asks for a change, a fix, a review or an investigation in one of their code projects.
- The user asks what is running, or how a task went.
- A task you started needs another instruction, a correction or a stop.

## Setup, once

Pair with the master on this machine and log in to it:

```bash
kanban-code-server pair openclaw --scope agent     # prints a token
kanban remote login http://127.0.0.1:7780 --token kc_...
kanban remote whoami
kanban remote machines
```

The login is saved in `~/.kanban-code/remote-client.json`. `KANBAN_REMOTE_URL` and `KANBAN_REMOTE_TOKEN` override it.

## Machines

```bash
kanban remote machines
```

Lists where a task can run: this master (marked `default`), the Mac with its online state, and any ssh machines. Tasks run on this machine by default. Send one to the Mac with `--machine mac` (or its name from `machines`) only when the user asks for the Mac, or the work needs it (macOS or iOS builds, Xcode, the Mac app itself, files only the Mac has). The Mac must be online.

## Start a task

```bash
kanban remote projects                       # names accepted by --project
kanban remote task --project langwatch --worktree --name "Fix flaky login test" \
  "The test 'login redirects after sign-in' in langwatch/app fails about 1 run in 5 on CI. Find the cause, fix it, run the test 20 times to confirm, and open a PR."
kanban remote task --project kanban --machine mac --worktree "Fix the toolbar layout on macOS."
```

- The output names the card and the machine it runs on: `Created card_... "..." in langwatch on rchaves-platform (In Progress).` Keep the card id for the next steps.
- Use `--worktree` for every task that changes code, so it runs on its own branch and does not touch the checkout. `--worktree <name>` picks the branch name.
- Long prompts: pipe them in with `-`: `cat prompt.md | kanban remote task --project langwatch --worktree -`.
- A task for the Mac is handed to it: it finds the project by its git origin, or clones it.
- `--no-launch` only creates the card in the backlog, on this machine.

Tasks run with the permissions Kanban Code gives its sessions, often with permission prompts skipped. Describe each task precisely: the project, the goal, what done looks like (tests passing, a PR opened), and anything that must not be touched. Do not start a task you would not let the user's own agent run unattended.

## Follow a task

```bash
kanban remote transcript <card> --follow     # prints new messages until the turn ends
kanban remote wait <card> --timeout 30m      # or block silently, exit 0 when idle, 124 on timeout
kanban remote transcript <card> --limit 5    # the last messages, for the result
kanban remote show <card>                    # branch, worktree, PRs
```

`<card>` is the id, a unique prefix of it, or the exact card title. These work for cards on either machine.

## Steer a task

```bash
kanban remote send <card> "Also update the changelog."   # delivered when the current turn ends
kanban remote send <card> --now "Stop, that is the wrong file. Only edit app/login.ts."
kanban remote interrupt <card>                           # stop the current turn
kanban remote resume <card>                              # restart a stopped session
```

`send` on a stopped card fails with 409: run `resume` first.

## Check status

```bash
kanban remote cards                          # every card: column, busy/idle/stopped, project, title
kanban remote cards --column waiting         # cards waiting for input
kanban remote cards --project langwatch --json
kanban remote cards --search "billing export" # any card of any master, archived and old ones too
```

Add `--json` to any command for machine-readable output.

## Errors

- `Cannot reach Kanban Code at http://127.0.0.1:7780`: `kanban-code-server` is down on this machine. Check `systemctl status kanban-code-server`, then tell the user.
- `No machine '...'`: the name is not in `kanban remote machines`.
- A card sent to the Mac that never starts: the Mac is offline (`machines` shows it). Tell the user, or run the task here.
- `401`: the token was revoked. Pair again.
- `403`: the `agent` scope does not allow that call (terminals need `full`).
