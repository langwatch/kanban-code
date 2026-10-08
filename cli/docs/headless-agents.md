# Headless agents

Run long-lived Claude Code agents on a server with no macOS app. Each agent is a
persistent Claude Code session in a tmux session or on a rush host, driven
entirely by the `kanban` CLI + Claude Code hooks. This is what powers an always-on agent fleet (e.g. a
nightly dependency-review agent).

## Model

- **Stable, readable identity.** An agent is identified by a slug like
  `dependabot-scout`. The slug deterministically maps to a Claude session id
  (UUIDv5), and is also the `--name`, the tmux session name (on tmux), the kanban card name,
  and the git worktree name. `claude --session-id` needs a UUID, so the id is
  derived from the slug while everything you see and type stays readable.
- **Worktree-only.** An agent's working directory is always its per-agent worktree
  workspace under `workspacesDir/<slug>/`, never a canonical clone. It cannot dirty
  the canonical clone.
- **Repo hygiene is the deployer's job.** The CLI never clones, stashes, pulls, or
  resets repos. The host (your IaC) provisions the canonical clones under
  `reposDir` and keeps their `main` clean and current. The reconciler errors loudly
  if a canonical clone is missing.

## Config (`agents.yaml`)

```yaml
reposDir: /home/ubuntu/agent-repos
workspacesDir: /home/ubuntu/agent-workspaces
host: rush                           # optional, tmux (default) or rush, for every agent
agents:
  - slug: dependabot-scout
    host: tmux                       # optional, overrides the top-level host
    repos: [langwatch/langwatch, langwatch/scenario]
    model: opus                      # optional, claude --model
    slackChannel: "#agent-dependabot-scout"   # bridge mirrors here / steers from here
    schedule: "06:00"                # used by your scheduler (systemd timer)
    dailyPrompt: |
      It's a new day. Check open Dependabot PRs ...
```

Point the CLI at it with `--config` or `KANBAN_AGENTS_CONFIG`.

## Hosts (`host: tmux | rush`)

`tmux` (the default) runs `claude` in a tmux session named after the slug.

`rush` runs the agent on a [rush](https://github.com/0xdeafcafe/rush) host
started with `rush session start --agent claude`. Rush keeps several Claude
accounts signed in and moves the session to another one when the current account
runs low, so a fleet on one box does not stop on a single logout or empty plan.
Rush runs Claude only: a `runtime: codex` agent stays on tmux and the CLI prints a
warning if it asked for rush.

- The host id is the first eight hex digits of the agent's session id, and the
  card's session name is `rush-<host id>`. `kanban send`, `interrupt`,
  `self-compact`, the daemon and the Slack bridge all address the agent through
  that name, which maps to `rush session send | interrupt | stop`.
- The host carries the metas `kanban_session=rush-<id>`, `kanban_agent=<slug>`
  and `kanban_card=<card id>`. `rush session list --meta kanban_agent=<slug>`
  finds an agent's host.
- Reconcile never restarts a host that is running or resting after its turn (the
  next message wakes a resting one). A dead host with a transcript is started with
  `--resume`; a new agent is started fresh with `--session-id`.
- Switching an agent from tmux to rush kills its old tmux session before the host
  starts, and switching back stops the host, so two processes never run one
  conversation. The card keeps its id and gets the new session name.
- The Slack bridge cannot read a pane on a rush host. When the agent is blocked
  on a question, the bridge posts the question text (rush does not report its
  options) and the next message in the channel is sent with `rush session answer`.

## Commands

| Command | What it does |
|---|---|
| `kanban launch <slug> --cwd <dir> [--host tmux\|rush]` | Launch or resume one agent session (idempotent) |
| `kanban reconcile [--prune]` | Ensure every configured agent's worktree + session + card; `--prune` tears down de-configured agents |
| `kanban daemon [--poll-interval ms] [--no-self-compact]` | Always-on engine: auto-send queued prompts on Stop, auto-compact long sessions |
| `kanban hooks install` | Install Claude hooks + statusline into `~/.claude/settings.json` |
| `kanban slack manifest` | Print a Slack app manifest (Socket Mode) + setup steps |
| `kanban slack bridge` | Run the bidirectional Slack <-> agent bridge |
| `kanban channel send <channel> "<msg>"` | Send a room-visible message to a shared channel; run `kanban channel --help` for join/history/share options |
| `kanban dm <handle> "<msg>"` | Send a private direct message to one agent |
| `kanban send <slug> "<msg>"` | Low-level: paste a prompt directly into one agent's tmux session; use channel or dm for normal coordination |

## Auto-compaction

The daemon polls each session's context usage (written by the statusline hook to
`~/.kanban-code/context/<sessionId>.json`) and, by threshold:

- 500k / 600k / 700k tokens: queue a self-compact reminder for the agent (auto-sent
  on the next idle Stop). A reminder is dropped if context already fell back below
  its threshold.
- 750k tokens: send `/compact` to the session directly.

## Slack bridge

Socket Mode (a websocket from the box to Slack, no public webhook), one bot for all
agent channels:

- **agent -> Slack:** tails each agent's transcript and posts new assistant turns,
  with compact tool labels (`Bash(npm test)`, `Read(.../path)`), merging the
  thinking + reply lines Claude writes separately.
- **Slack -> agent:** a human message in a mapped channel is relayed into the
  agent's session (tmux or rush) as a prompt. The bot's own messages are ignored (no loops).
- Automated traffic (scheduled nudges via `kanban send`, auto-compact
  notes, auto-sent reminders) is posted to the channel; human relays are not
  re-posted (they already appear in Slack).

Set `SLACK_BOT_TOKEN` (xoxb) and `SLACK_APP_TOKEN` (xapp, `connections:write`) in the
bridge's environment. Run `kanban slack manifest` for the app manifest and setup
steps, then invite the bot to each agent's channel.

## Deploying as services (systemd sketch)

```
agents-reconcile.service   # oneshot on boot: kanban reconcile (resumes sessions)
agents-daemon.service      # long-running: kanban daemon
agents-slack-bridge.service# long-running: kanban slack bridge
agents-<slug>.timer        # daily: kanban send <slug> "<dailyPrompt>"
```

On reboot or spot reclaim, `agents-reconcile.service` resumes every agent with
`claude --resume`, so sessions survive indefinitely. Make the daily timers
`After=agents-reconcile.service` so a morning wake resumes before it nudges.

## State

All under `~/.kanban-code/` (override with `KANBAN_CODE_HOME`):
`links.json` (cards), `context/<sessionId>.json` (usage, from the statusline hook),
`hook-events.jsonl` (hook events the daemon tails), `hook.sh`, `statusline.sh`.
