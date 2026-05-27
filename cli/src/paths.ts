import { homedir } from "node:os";
import { join } from "node:path";

/// Root of the Kanban Code state dir. Honors KANBAN_CODE_HOME so tests (and
/// alternate deployments) can sandbox into a temp dir; defaults to ~/.kanban-code.
export function kanbanHome(): string {
  return process.env.KANBAN_CODE_HOME || join(homedir(), ".kanban-code");
}

export function linksPath(): string {
  return join(kanbanHome(), "links.json");
}

export function settingsPath(): string {
  return join(kanbanHome(), "settings.json");
}

export function contextDir(): string {
  return join(kanbanHome(), "context");
}

export function hookEventsPath(): string {
  return join(kanbanHome(), "hook-events.jsonl");
}

/// Claude Code's config dir. Honors CLAUDE_CONFIG_DIR so a sandboxed test can
/// point it elsewhere.
export function claudeConfigDir(): string {
  return process.env.CLAUDE_CONFIG_DIR || join(homedir(), ".claude");
}

/// Where Claude Code writes per-project session transcripts.
export function claudeProjectsDir(): string {
  return join(claudeConfigDir(), "projects");
}

export function claudeSettingsPath(): string {
  return join(claudeConfigDir(), "settings.json");
}
