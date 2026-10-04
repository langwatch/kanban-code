# Slash commands in the chat composer

When the text of a card's chat composer starts with `/` and holds no whitespace, a list of matching commands shows above the composer, on the Mac and on the phone. Each row has the name, one line of description and where the command comes from.

## Keys

Mac:

- Up and Down move the selection, wrapping around.
- Tab completes the composer to `/name `.
- Return completes too. On a name already written in full it sends, as without the list.
- Esc closes the list. It stays closed until the text stops being a command name.

Phone: a tap on a row completes to `/name `.

The list is closed for a text with a second `/` (a path), for a message recalled with the up arrow, and while a secret offer is open. It never changes what Send does with a plain message.

## Matching

`SlashCommandMenu` in `Sources/KanbanCodeRemoteKit/SlashCommands.swift`, shared by both apps. Order: the exact name, names that start with the text, names with a part that starts with it (parts are split on `:`, `-` and `_`), names that contain it. Case is ignored. Descriptions are not searched.

## What is listed

In this order, each name once:

1. The chat's own commands, `source` `kanban`: `/catchup` and `/btw` (see [`side-chat.md`](side-chat.md)). Claude Code cards only.
2. The agent's commands that run when sent as a message, `source` `agent`. They take their arguments on the same line and open no dialog, so they work in a tmux session and in a rush session.
   - Claude Code: `compact`, `clear`, `context`, `init`, `model`, `effort`, `code-review`, `security-review`, `simplify`, `loop`.
   - Codex: `compact`, `new`, `init`.
   - Gemini: `compress`, `clear`.
3. Skills and custom commands on disk, by name. Claude Code cards only.

A skill or command on disk with the name of an agent command replaces it.

### Files read

`ClaudeCommandFiles` in `Sources/KanbanCodeCore/UseCases/SlashCommands/SlashCommandCatalog.swift` reads, in this order of precedence:

| `source` | Where |
|---|---|
| `project` | `.claude/skills/*/SKILL.md` and `.claude/commands/**/*.md` in the session's folder and each parent up to the repository root (the folder with `.git`). The home folder and above are not read. |
| `user` | `skills/*/SKILL.md` and `commands/**/*.md` in the configuration folder. |
| `user` | `skills/synced/<organization>_<account>/*/SKILL.md` for the login in `.claude.json`, named `anthropic-skills:<name>`. |
| `plugin` | `skills` and `commands` of each plugin in `plugins/installed_plugins.json` that `enabledPlugins` sets to `true`, named `<plugin>:<name>`. |

- The name of a skill is `name` in its frontmatter, else its folder. A command file's name is its path under `commands` with `:` for `/` (`git/push.md` is `git:push`).
- The description is `description` in the frontmatter (block scalars included), cut to one line of 200 characters. A command file with no frontmatter gives its first line of text.
- `user-invocable: false` leaves a skill or command out.
- `enabledPlugins` is read from `settings.json` in the configuration folder, then from `.claude/settings.json` and `.claude/settings.local.json` of the project folders, the nearer one winning.
- A plugin installed with scope `project` or `local` counts only for a session inside its `projectPath`.
- The plugin's name is `name` in its `.claude-plugin/plugin.json`, else the part of its key before `@`.

### Configuration folder

The folder is the session's `CLAUDE_CONFIG_DIR`:

- a rush card: the rush account in use, `~/.config/rush/claude/<account>`, where `<account>` is the content of `~/.config/rush/claude/using`;
- else the folder that holds the session's transcript (`<config>/projects/<folder>/<session>.jsonl`);
- else, for a card with no session yet, `CLAUDE_CONFIG_DIR` of the Kanban Code process;
- else `~/.claude`.

Symlinks are followed, so an account folder whose entries link to `~/.claude` reads the same files.

The session's folder is the one its transcript is filed under, else the card's worktree, else its project.

### Not listed

- Skills of a session that runs on an ssh or boxd machine: they are on that machine's disk. Such a card gets the agent's commands only.
- Commands of MCP servers, and skills bundled inside the agent's binary other than the ones named above.
- Custom prompts of Codex and custom commands of Gemini.

## Where the list comes from

Skills live on the disk of the master that owns the card, so that master builds the list:

- `GET /v1/cards/{id}/slash-commands` returns `[{"name", "description", "source"}]`. `full`, `agent` and `peer` devices may call it. The feature name in `GET /v1/health` is `slashCommands`.
- A master asked for a card another master owns forwards the call to the owner. While the owner does not answer, it returns the last list the owner gave, else the commands that need no disk.
- A master keeps a card's list for 30 seconds.

The Mac chat calls `MasterEngine.refreshSlashCommands(cardId:)` each time a command name starts. It dispatches `.slashCommandsLoaded`, and the composer reads `AppState.slashCommands[cardId]`. Before the first answer the composer shows the commands that need no disk. The phone keeps the lists in `BoardModel.slashCommands` and reads them the same way, when the master's health lists `slashCommands`; against an older master it offers `/catchup` and `/btw` only.

## Looking at the list without the app

```bash
KANBAN_SLASH_SNAPSHOT=<directory> swift test --filter SlashCommandListSnapshot
```

draws the Mac composer with its list to PNG files in that directory.
