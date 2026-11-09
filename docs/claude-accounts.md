# Claude accounts

Claude Code keeps its login, settings, hooks and transcripts in one config folder: `~/.claude`, or the folder `CLAUDE_CONFIG_DIR` names. People who keep a work and a personal account apart usually give each its own folder (`CLAUDE_CONFIG_DIR=~/.claude-work`, often set by direnv for the work projects). Kanban Code reads and writes every such folder you list in Settings > Claude Accounts.

## Settings

Each account has:

- **Config folder**: the folder Claude Code runs with as `CLAUDE_CONFIG_DIR`. A full path or one starting with `~/`, not the home folder or above it. Run `CLAUDE_CONFIG_DIR=<folder> claude` once to create it and log in: Kanban only writes hooks and links into, and only scrubs, a folder Claude Code has used (one with `.claude.json`, `settings.json` or `projects/`).
- **Project folders**: the folders whose new cards start with this account, each with everything under it (worktrees included). The longest match wins; between equal ones, the first account.
- **GitHub login** (optional): the `gh` account for these projects, see [GitHub](#github).

`~/.claude` is always included and needs no entry. An account for `~/.claude` only adds project folders.

"Login for machines" picks whose Claude login boxd and ssh machines get, `~/.claude`'s unless you pick another. A machine holds one login, kept in sync with that account's on this Mac.

The settings live in `~/.kanban-code/settings.json` as `claudeAccounts` and `claudeMachineLoginDirectory`, written only when set:

```json
"claudeAccounts": [
  { "name": "Work", "configDirectory": "~/.claude-work", "projectPaths": ["~/work"], "githubUser": "me-at-work" }
]
```

## What changes with accounts

- **Sessions**: discovery reads the `projects/` folder of `~/.claude`, of `CLAUDE_CONFIG_DIR` as the login shell sets it, and of every account. A session id found in two folders (one copied from the other) shows the newer transcript; with equal times, the one already shown. When it goes, the other copy shows again.
- **New cards**: a card in an account's project folder starts Claude Code with `CLAUDE_CONFIG_DIR=<folder>`, in front of the command (so a direnv value in the pane does not win) and in the tmux session's environment (so a launch command of your own gets it too). A card in a folder no account claims starts as before: the shell decides. The new transcript is looked for in every folder.
- **Resumes**: a card resumes with the folder its transcript is in, since `claude --resume` only finds a session in the folder it runs with. For `~/.claude` the launch runs `unset CLAUDE_CONFIG_DIR` before the command, written for the shell tmux runs in the pane (fish: `set -eg`, which leaves a universal variable alone, and a universal `CLAUDE_CONFIG_DIR` then wins), never `CLAUDE_CONFIG_DIR=~/.claude`: Claude Code names its Keychain item after the variable's value whenever it is set, so that session would start logged out. For the same reason the folder `CLAUDE_CONFIG_DIR` names in the login shell is passed spelled as there, and a login shell that sets `~/.claude` explicitly gets it set again, not unset. The unset is a shell step rather than `env -u`, so an alias or function named `claude` (Claude Code's local install) keeps working.
- **Moves, forks and handovers** keep a transcript in its folder. A card handed over from another master lands in the folder of the account that claims its project.
- **Hooks**: "Install Hooks" (Settings > Assistants) installs into every folder. Once one folder has the hooks, a folder added later gets them on its own, with the status line unless it has one of its own; a `settings.json` that is not plain JSON is never rewritten. Each account row in Settings shows its folder's hooks. The vault and permission hooks and the kanban-code skill follow the same folders. All of this also runs when the accounts change, without a restart.
- The secret scrubber reads every folder's transcripts.

Nothing changes without accounts, unless the login shell sets `CLAUDE_CONFIG_DIR`: then its folder's sessions show and get the hooks like an account's (the machines keep `~/.claude`'s login until you pick another). An app started from a card's shell drops the `CLAUDE_CONFIG_DIR` and `GH_TOKEN` Kanban gave that card (marked by `KANBAN_CLAUDE_ACCOUNT`); ones you export yourself stay.

## GitHub

With a GitHub login set, `gh` runs for that account's projects with `GH_TOKEN` from `gh auth token --user <login>` (log in once with `gh auth login`): PR lookups, issue lists, merges. A card's tmux session gets the same `GH_TOKEN` in its environment, never typed into the pane. Tokens are kept ten minutes. A token that cannot be read is logged and the active `gh` account is used; the next try is a minute later.

The token is in the session's environment like any exported variable: processes of your user can read it (`tmux show-environment`, the agent's own shell), as they can read it with `gh auth token`.

Not covered: `git push` (it uses your ssh key or credential helper, and git's author comes from your git config), a `GH_TOKEN` your shell rc or `.envrc` exports itself (it wins inside the pane), rush cards, and GitHub Enterprise hosts.

## Limits

- Cards on boxd and ssh machines and in the mutagen mode run with the machine's single login, whatever account claims the project.
- rush keeps its own accounts (`~/.config/rush/claude/<account>`); rush cards are not routed.
- A launch command template that runs Claude Code somewhere else (ssh, docker) has to pass `CLAUDE_CONFIG_DIR` on itself, and one that sources a script setting `CLAUDE_CONFIG_DIR` (`source .envrc; ${cli_command}`) lets that script win.
- A folder new to Claude Code starts with its own trust list and onboarding: the first session in each project asks again.
- Extra terminals of a card do not get the account's variables.
- The `kanban` CLI reads the folder of its own `CLAUDE_CONFIG_DIR`, so inside a card it sees that card's account.
- An older Kanban Code drops the accounts the first time it saves the settings.
