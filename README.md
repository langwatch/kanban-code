<p align="center">
  <img src="assets/app-icon.png" width="128" height="128" alt="Kanban Code">
</p>

<h1 align="center">Kanban Code</h1>

<p align="center">
  <strong>A beautiful kanban board for managing Claude Code sessions.</strong><br>
  Native on macOS (SwiftUI liquid glass) and Windows (Tauri). The IDE for 2026.
</p>

<p align="center">
  <a href="#installation">Installation</a> ·
  <a href="#features">Features</a> ·
  <a href="#getting-started">Getting Started</a> ·
  <a href="#architecture">Architecture</a> ·
  <a href="#license">License</a>
</p>

---

Kanban Mode:
![Kanban Code](assets/screenshot.webp)

Productive Mode:
![Kanban Code Productive Mode](assets/productive-mode.webp)

## What is Kanban Code?

A native macOS app for running multiple Claude Code agents in parallel. Each task is a card on a Kanban board that automatically links your Claude session, git worktree, tmux terminals, and GitHub PR together — cards flow from backlog to done as Claude works, opens PRs, and gets them merged. Push notifications on your phone when agents need attention, remote execution to offload work to a server, and sleep prevention to keep your Mac awake while agents run.

Kanban Code's goal is to ease as much as possible the context switching bottleneck for modern development by centralizing all context needed for each Claude session into their cards.

Kanban Code combines the lessons learned from [claude-resume](https://github.com/langwatch/claude-resume), [claude-remote](https://github.com/langwatch/claude-remote), [git-orchard](https://github.com/drewdrewthis/git-orchard), [claude-pushover](https://github.com/langwatch/claude-pushover), and [cc-amphetamine](https://github.com/rogeriochaves/cc-amphetamine) into one unified experience.

## Installation

### macOS

Grab the latest `.app` from [**Releases**](https://github.com/langwatch/kanban-code/releases/latest), unzip, and drag to Applications.

Since the app is not notarized, macOS will block it on first launch. To open it:

1. **Right-click** the app and select **Open**
2. Click **Open** in the dialog that appears
3. If blocked, go to **System Settings → Privacy & Security**, scroll down, and click **Open Anyway**

> Requires **macOS 26** (Tahoe) and [Claude Code](https://docs.anthropic.com/en/docs/claude-code) CLI installed.

#### Build from Source (macOS)

```bash
git clone https://github.com/langwatch/kanban-code.git
cd kanban-code
make run-app
```

### Windows

Requires [Node.js](https://nodejs.org/) (v18+), [Rust](https://rustup.rs/), and [Claude Code](https://docs.anthropic.com/en/docs/claude-code) CLI. Optionally [GitHub CLI](https://cli.github.com/) for PR/issue features.

```bash
git clone https://github.com/langwatch/kanban-code.git
cd kanban-code/windows
npm install
npm run tauri dev        # dev mode
npm run tauri build      # production .exe
```

An onboarding wizard checks your dependencies and walks you through setup on first launch.

## Features

### Kanban Board with Smart Columns

Six columns that cards flow through automatically based on real activity signals:

| Column | What goes here |
|---|---|
| **Backlog** | GitHub issues, manual tasks, ideas waiting to start |
| **In Progress** | Claude is actively working (confirmed via hooks) |
| **Waiting** | Claude stopped, needs plan approval, or hit a permission prompt |
| **In Review** | PR is open, waiting for CI or code review |
| **Done** | PR merged, worktree ready to clean up |
| **All Sessions** | Archive of every past session, searchable |

Cards move between columns automatically. When Claude starts working, the card jumps to In Progress. When it stops and needs input, it moves to Waiting and sends you a push notification. When a PR opens, it shifts to In Review. You can always drag cards manually to override.

### Tmux Sessions & Embedded Terminal

Every Claude task runs inside a tmux session. This means you can always take control — attach from your own terminal, send input, inspect output, or just watch Claude work. Kanban Code manages the tmux lifecycle for you: creating sessions on launch, reattaching on resume, killing on archive.

Each card can have multiple terminals associated with it — Claude's main session plus any extra shells you spin up. Start a dev server for one worktree, a test watcher for another, and they all live on the right card. When you have ten Claude agents running across five projects, you can see every terminal for every task at a glance, without losing track of which server belongs to which branch.

Inside the app, each card has a native terminal emulator (powered by [SwiftTerm](https://github.com/migueldeicaza/SwiftTerm)) that connects directly to the tmux session. True color, Unicode, mouse events, scrollback — the full terminal experience without switching windows. If Claude is waiting for input, hit Resume and you're typing to it immediately. Terminal state persists as you navigate between cards. Or copy the `tmux attach` command to connect from your own terminal instead.

### Session Discovery, Search, Fork & Checkpoint

Kanban Code automatically discovers all your Claude Code sessions from `~/.claude/projects/`. Past sessions, active sessions, sessions you started from the terminal — they all show up.

**BM25 full-text search** lets you find any session across your entire history. Search by prompt, conversation content, or project name. Results are ranked by relevance with a recency boost.

**Fork** any session to branch off a new conversation with the same history — perfect for spinning up parallel tasks that share context, or exploring a different approach without losing your place. **Checkpoint** lets you roll back to any point in a conversation and continue from there. Both are dramatically faster than Claude Code's built-in equivalents, operating directly on the session files instead of going through the CLI.

### Git Worktree Integration

Start a task and Kanban Code can create a git worktree automatically, giving Claude its own isolated branch. The app tracks which worktree belongs to which card, discovers orphaned worktrees, and offers cleanup when you're done.

Cards created from GitHub issues get named worktrees (`issue-123`). Manual tasks get auto-generated names. You can also link existing worktrees to cards.

### Remote Execution

Offload Claude to a remote machine and run even more agents in parallel without melting your laptop. Kanban Code manages a shell wrapper that transparently intercepts commands and executes them over SSH, with [Mutagen](https://mutagen.io/) handling bidirectional file sync. Local paths are automatically translated to remote paths — Claude doesn't know it's running remotely.

The UI shows Mutagen sync status in real time. If the remote host goes offline, Kanban Code automatically falls back to local execution and notifies you. Configure it globally or per-project.

### GitHub PR Tracking

Once Claude pushes a branch, Kanban Code discovers the PR via `gh` CLI and tracks it on the card:

- PR status (draft, open, merged, closed)
- CI check runs with individual pass/fail status
- Review decision (approved, changes requested)
- Unresolved review thread count
- Lazy-loaded PR description

Multiple PRs per card are supported. Click to open in browser, or copy the link.

### GitHub Issue Backlog

Configure per-project GitHub issue filters (e.g. `assignee:@me label:bug`) and Kanban Code populates your backlog automatically. Issues become cards with the full issue body as context. Start working on one and Claude gets the issue description as its prompt.

### Push Notifications

Get notified on your phone — and your Apple Watch — when Claude needs attention, via [Pushover](https://pushover.net/). Notifications include a full summary of what Claude did, rendered as Markdown so you can read the last assistant response right from the lock screen. Multi-line responses are rendered as images for readability.

Smart deduplication prevents notification spam — rapid Stop events are collapsed, and duplicate notifications within 62 seconds are suppressed. Each notification includes the session number so you know which agent is calling.

Falls back to macOS native notifications if Pushover isn't configured. Just add your Pushover user key and API token in settings.

### Amphetamine Integration

When Claude agents are actively working, Kanban Code spawns a lightweight companion process that keeps [Amphetamine](https://apps.apple.com/app/amphetamine/id937984704) triggered — preventing your Mac from sleeping mid-task. The companion quits automatically when all agents are idle. No more waking up to find Claude was interrupted by sleep mode.

### Multi-Project Support

Configure multiple projects, each with its own GitHub filters, prompt templates, and repository settings. A global view combines everything — or focus on a single project. Exclude side projects from the global view to keep work and personal separate.

### Keyboard-First

- **⌘K** — Search sessions
- **⌘N** — New task
- Drag and drop between columns
- Context menus on every card

## Optional Dependencies

These unlock additional features. Kanban Code works without them — it's all progressive enhancement.

| Tool | What it enables |
|---|---|
| [`tmux`](https://github.com/tmux/tmux) | Embedded terminal, session persistence, launch/resume |
| [`gh`](https://cli.github.com/) | GitHub PR tracking, issue backlog import |
| [`mutagen`](https://mutagen.io/) | Remote execution with bidirectional file sync |
| [Amphetamine](https://apps.apple.com/app/amphetamine/id937984704) | Prevent Mac sleep while agents are working |
| [Pushover](https://pushover.net/) | Push notifications to phone and Apple Watch |

## Getting Started

### 1. First Launch

Kanban Code scans your `~/.claude/projects/` directory and discovers all existing sessions. They'll appear in the **All Sessions** column immediately.

### 2. Add a Project

Open Settings and add your project path (e.g., `~/Projects/my-app`). If it's a git repo with `gh` configured, Kanban Code will start pulling GitHub issues into your backlog.

### 3. Configure Hooks

Kanban Code uses [Claude Code hooks](https://docs.anthropic.com/en/docs/claude-code/hooks) for real-time activity detection. On first launch, it offers to install them automatically. The hooks fire on:

- **Stop** — Claude finished or needs input
- **UserPromptSubmit** — User sent a message
- **Notification** — Claude raised a notification
- **SessionStart/End** — Session lifecycle

### 4. Start a Task

Click a card in the backlog and hit **Start**. Kanban Code will:

1. Optionally create a git worktree
2. Launch a tmux session
3. Start Claude with your prompt
4. Open the embedded terminal so you can watch

Or just start Claude yourself from your terminal — Kanban Code will discover the session and create a card for it.

### 5. Let it Flow

From here, cards move automatically. Claude working? In Progress. Claude stopped? Waiting (+ notification). PR opened? In Review. PR merged? Done. Clean up the worktree and it's archived.

## Configuration

Settings are stored in `~/.kanban-code/settings.json` — human-readable, version-controllable.

```jsonc
{
  "projects": [
    {
      "path": "/Users/you/Projects/my-app",
      "github": {
        "issueFilters": "assignee:@me state:open"
      }
    }
  ],
  "globalView": {
    "excludedPaths": ["/Users/you/Projects/side-project"]
  },
  "pushover": {
    "userKey": "your-key",
    "apiToken": "your-token"
  }
}
```

Card coordination lives in `~/.kanban-code/links.json` — the single source of truth linking sessions, worktrees, tmux sessions, and PRs together. You can inspect and edit it directly if needed.

## Architecture

Kanban Code follows **Clean Architecture** with an Elm-inspired unidirectional data flow:

```
User Action → dispatch(Action) → Reducer(State, Action) → (State', [Effect])
                                                              ↓          ↓
                                                           SwiftUI    EffectHandler
                                                           re-render  (async I/O)
```

All state lives in a single `AppState` struct. All mutations go through the `Reducer`. Side effects (disk, network, tmux) are returned as values and executed by the `EffectHandler`. Views never mutate state directly.

### Project Structure

```
Sources/                         # macOS app (SwiftUI)
├── KanbanCode/                  # SwiftUI + AppKit app
│   ├── BoardView.swift          # Kanban board with drag-and-drop
│   ├── CardView.swift           # Card rendering
│   ├── CardDetailView.swift     # Detail drawer with terminal, history, PR tabs
│   ├── SearchOverlay.swift      # BM25 search interface
│   └── ...
├── KanbanCodeCore/              # Pure Swift library, no UI
│   ├── Domain/
│   │   ├── Entities/            # Session, Link, Worktree, PullRequest
│   │   └── Ports/               # Protocol interfaces (adapter pattern)
│   ├── UseCases/                # BoardStore, CardReconciler, LaunchSession
│   ├── Adapters/                # Claude Code, Git, Tmux, Notifications
│   └── Infrastructure/          # CoordinationStore, KSUID, ShellCommand
└── Clawd/                       # Background helper for hook event handling

windows/                         # Windows app (Tauri 2)
├── src/                         # React + TypeScript frontend
│   ├── components/              # BoardView, CardDetailView, OnboardingWizard, etc.
│   ├── store/                   # Zustand state management
│   └── types/                   # TypeScript type definitions
└── src-tauri/                   # Rust backend
    └── src/                     # Tauri commands, coordination store, session discovery
```

The core library uses **port/adapter** pattern — all external integrations (Claude Code, git, tmux, GitHub, Pushover) are behind protocol interfaces. The same architecture could be adapted for other AI coding tools.

### Key Design Decisions

**Card as first-class entity.** A card can independently have (or not have) a session, worktree, tmux terminal, PR, and issue link. These are all optional typed sub-structs on the `Link` model. This prevents the "triplication bug" where the same work appears as three different cards.

**Reconciler, not poller.** Background reconciliation discovers external resources (sessions, worktrees, PRs) and merges them with existing cards using a matching algorithm (session ID → branch name → project path). New cards are only created for truly unmatched resources.

**In-memory state is truth.** The app uses in-memory state as the source of truth during reconciliation, not disk. Disk reads race with async writes — in-memory state eliminates that class of bugs.

**KSUID for card IDs.** Time-sortable unique IDs (`card_2MtCMwXZOHPSlEMDe7OYW6bRfXX`) that sort chronologically without a database.

## Contributing

Kanban Code is open source under the AGPLv3 license. Contributions are welcome.

```bash
# Run the full test suite
swift test

# Build and launch
make run-app
```

The spec files in `spec/` document every feature and edge case in detail.

## Testimonials

![This is an incredible vision.](assets/claude-testimonial.webp)

— Claude Code, after first seeing Kanban Code's [initial prompt](./initial-prompt.md)

## License

[AGPLv3](LICENSE) — Kanban Code is free software. You can use, modify, and distribute it under the terms of the GNU Affero General Public License v3.

---

<p align="center">
  Built by <a href="https://github.com/langwatch">LangWatch</a>
</p>
