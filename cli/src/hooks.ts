import { readFileSync, writeFileSync, mkdirSync, existsSync, chmodSync } from "node:fs";
import { dirname, join } from "node:path";
import { kanbanHome, claudeSettingsPath } from "./paths.js";
import { sortedStringify } from "./cards.js";

/// Claude Code hook events the runtime relies on. Stop drives auto-send;
/// UserPromptSubmit lets the daemon detect a human/relay prompt; the rest feed
/// activity tracking. Mirrors the Swift HookManager.
export const HOOK_EVENTS = ["Stop", "Notification", "SessionStart", "SessionEnd", "UserPromptSubmit"];

function defaultHookScriptPath(): string {
  return join(kanbanHome(), "hook.sh");
}

/// Appends one timestamped line per hook event to hook-events.jsonl. No jq
/// dependency (lightweight grep parsing). Honors KANBAN_CODE_HOME so the same
/// script works in tests and in alternate deployments.
const HOOK_SCRIPT = `#!/usr/bin/env bash
# Kanban hook handler. Receives JSON on stdin from Claude Code hooks and appends
# a timestamped event line to <kanban-home>/hook-events.jsonl.
set -euo pipefail

EVENTS_DIR="\${KANBAN_CODE_HOME:-\$HOME/.kanban-code}"
EVENTS_FILE="\${EVENTS_DIR}/hook-events.jsonl"
mkdir -p "$EVENTS_DIR"

input=$(cat)

session_id=$(echo "$input" | grep -o '"session_id":"[^"]*"' | head -1 | cut -d'"' -f4)
hook_event=$(echo "$input" | grep -o '"hook_event_name":"[^"]*"' | head -1 | cut -d'"' -f4)
transcript=$(echo "$input" | grep -o '"transcript_path":"[^"]*"' | head -1 | cut -d'"' -f4)

if [ -z "$session_id" ]; then
    session_id=$(echo "$input" | grep -o '"sessionId":"[^"]*"' | head -1 | cut -d'"' -f4)
fi
[ -z "$session_id" ] && exit 0

# For UserPromptSubmit, capture the whole payload (base64, so the prompt's
# quotes/newlines survive) so the daemon can mirror the exact text the agent
# received once receipt is confirmed.
payload_b64=""
if [ "$hook_event" = "UserPromptSubmit" ]; then
    payload_b64=$(printf '%s' "$input" | base64 | tr -d '\\n')
fi

timestamp=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
printf '{"sessionId":"%s","event":"%s","timestamp":"%s","transcriptPath":"%s","payloadB64":"%s"}\\n' \\
    "$session_id" "$hook_event" "$timestamp" "$transcript" "$payload_b64" >> "$EVENTS_FILE"
`;

/// Captures Claude Code's context/token usage per session into
/// <kanban-home>/context/<sessionId>.json after each assistant response.
const STATUSLINE_SCRIPT = `#!/usr/bin/env bash
# Kanban Code statusline - captures context/token usage per session.
set -euo pipefail

CONTEXT_DIR="\${KANBAN_CODE_HOME:-\$HOME/.kanban-code}/context"
mkdir -p "$CONTEXT_DIR"

input=$(cat)

session_id=$(echo "$input" | grep -oE '"session_id":"[^"]*"' | head -1 | cut -d'"' -f4)
[ -z "$session_id" ] && exit 0

used_pct=$(echo "$input" | grep -oE '"used_percentage":[0-9.]+' | head -1 | cut -d: -f2)
ctx_size=$(echo "$input" | grep -oE '"context_window_size":[0-9]+' | head -1 | cut -d: -f2)
input_tokens=$(echo "$input" | grep -oE '"total_input_tokens":[0-9]+' | head -1 | cut -d: -f2)
output_tokens=$(echo "$input" | grep -oE '"total_output_tokens":[0-9]+' | head -1 | cut -d: -f2)
cost=$(echo "$input" | grep -oE '"total_cost_usd":[0-9.]+' | head -1 | cut -d: -f2)
model=$(echo "$input" | grep -oE '"display_name":"[^"]*"' | head -1 | cut -d'"' -f4)

tmp_file="\${CONTEXT_DIR}/.\${session_id}.tmp"
out_file="\${CONTEXT_DIR}/\${session_id}.json"
printf '{"usedPercentage":%s,"contextWindowSize":%s,"totalInputTokens":%s,"totalOutputTokens":%s,"totalCostUsd":%s,"model":"%s"}' \\
    "\${used_pct:-0}" "\${ctx_size:-0}" "\${input_tokens:-0}" "\${output_tokens:-0}" "\${cost:-0}" "\${model:-}" > "$tmp_file"
mv -f "$tmp_file" "$out_file"
printf ''
`;

export interface InstallHooksOptions {
  settingsPath?: string;
  hookScriptPath?: string;
  statuslinePath?: string;
}

export interface InstallHooksResult {
  settingsPath: string;
  hookScriptPath: string;
  statuslinePath: string;
  events: string[];
}

function deployScript(path: string, content: string): void {
  mkdirSync(dirname(path), { recursive: true });
  writeFileSync(path, content);
  chmodSync(path, 0o755);
}

function readJson(path: string): Record<string, any> {
  if (!existsSync(path)) return {};
  try {
    return JSON.parse(readFileSync(path, "utf-8")) ?? {};
  } catch {
    return {};
  }
}

/// Install Claude Code hooks + statusline for headless operation. Idempotent:
/// the hook command is added to each event only if not already present, and the
/// statusline is set only if not already ours. Mirrors HookManager.install.
export function installHooks(opts: InstallHooksOptions = {}): InstallHooksResult {
  const settingsPath = opts.settingsPath ?? claudeSettingsPath();
  const hookScriptPath = opts.hookScriptPath ?? defaultHookScriptPath();
  const statuslinePath = opts.statuslinePath ?? join(kanbanHome(), "statusline.sh");

  deployScript(hookScriptPath, HOOK_SCRIPT);
  deployScript(statuslinePath, STATUSLINE_SCRIPT);

  const root = readJson(settingsPath);
  const hooks = (root.hooks ?? {}) as Record<string, any[]>;
  const hookEntry = { type: "command", command: hookScriptPath };

  for (const event of HOOK_EVENTS) {
    const groups: any[] = Array.isArray(hooks[event]) ? hooks[event] : [];
    // Idempotent by exact script path (robust regardless of where the kanban
    // home lives), preserving any other tools' hooks already registered.
    const present = groups.some((g) =>
      (g?.hooks ?? []).some((h: any) => h?.command === hookScriptPath)
    );
    if (!present) {
      if (groups.length === 0) {
        groups.push({ matcher: "", hooks: [hookEntry] });
      } else {
        groups[0].hooks = [...(groups[0].hooks ?? []), hookEntry];
      }
    }
    hooks[event] = groups;
  }
  root.hooks = hooks;

  if (root.statusLine?.command !== statuslinePath) {
    root.statusLine = { type: "command", command: statuslinePath };
  }

  mkdirSync(dirname(settingsPath), { recursive: true });
  writeFileSync(settingsPath, sortedStringify(root));

  return { settingsPath, hookScriptPath, statuslinePath, events: HOOK_EVENTS };
}

/// True if our hook script is registered for every required event.
export function areHooksInstalled(settingsPath?: string, hookScriptPath?: string): boolean {
  const root = readJson(settingsPath ?? claudeSettingsPath());
  const hooks = (root.hooks ?? {}) as Record<string, any[]>;
  const path = hookScriptPath ?? defaultHookScriptPath();
  return HOOK_EVENTS.every((event) =>
    (hooks[event] ?? []).some((g: any) => (g?.hooks ?? []).some((h: any) => h?.command === path))
  );
}
