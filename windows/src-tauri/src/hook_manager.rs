//! Installs a WSL-side `hook.sh` and wires it into Claude's
//! `~/.claude/settings.json` so Claude pipes hook events back to us.
//!
//! Mirrors `Sources/KanbanCodeCore/Adapters/ClaudeCode/HookManager.swift` but
//! installs into the user's WSL home rather than the macOS home. Events are
//! appended to the *Windows*-side path
//! `%APPDATA%\kanban-code\hook-events.jsonl` (written through WSL's
//! `/mnt/c/...` mount), so the Rust tail can read directly without UNC paths.
//!
//! Skip-conditions (idempotent):
//!   * `terminalShell` doesn't include "wsl" → tracked TODO, no install.
//!   * `wsl.exe -- bash -lc "true"` fails → WSL not set up, log + skip.
//!   * `~/.kanban-code/hook.sh` already present AND `settings.json` already
//!     references it → no-op (re-runs are safe).

use std::path::PathBuf;
use std::process::{Command, Stdio};
use std::io::Write;

use crate::coordination_store::kanban_data_dir;
use crate::logging;
use crate::settings_store::SettingsStore;
use crate::tmux::windows_path_to_wsl;

const HOOK_EVENTS: &[&str] = &[
    "Stop",
    "Notification",
    "SessionStart",
    "SessionEnd",
    "UserPromptSubmit",
];

/// Top-level entry: install (or refresh) the WSL-side hook script + settings.
/// Reads the user's current `terminalShell` to decide whether to install at
/// all. Returns `Ok(false)` when intentionally skipped (e.g. non-wsl shell).
pub async fn install_if_needed(settings_store: &SettingsStore) -> Result<bool, String> {
    let settings = settings_store.read().await.map_err(|e| e.to_string())?;
    let shell = settings.terminal_shell.to_lowercase();
    if !shell.contains("wsl") {
        logging::info(
            "hooks",
            "skipping install — Settings.terminalShell is not wsl; native cmd.exe/pwsh hooks tracked as TODO",
        );
        return Ok(false);
    }

    if !wsl_ok() {
        logging::warn(
            "hooks",
            "wsl.exe is not responding — skipping hook install; will retry on next app launch",
        );
        return Ok(false);
    }

    // Where Claude will write events. This is a /mnt/c/ path inside WSL that
    // maps to the same file we tail from Windows-side Rust.
    let events_win_path = kanban_data_dir().join("hook-events.jsonl");
    let events_wsl_path = windows_path_to_wsl(&events_win_path.to_string_lossy());
    if events_wsl_path.is_empty() {
        return Err("could not translate events path to WSL".into());
    }

    let script = hook_script_content(&events_wsl_path);
    install_script(&script)?;
    merge_into_settings()?;
    logging::info(
        "hooks",
        &format!("installed hook.sh + settings.json entries — events → {}", events_wsl_path),
    );
    Ok(true)
}

/// Sanity check: `wsl.exe -- bash -lc "true"` should exit 0.
fn wsl_ok() -> bool {
    Command::new("wsl.exe")
        .args(["--", "bash", "-lc", "true"])
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .status()
        .map(|s| s.success())
        .unwrap_or(false)
}

/// The bash script Claude invokes for every hook event. The events path is
/// baked in at install time so the script has no run-time config dependency.
fn hook_script_content(events_wsl_path: &str) -> String {
    // Lines are intentionally simple — no jq/python dependency. The whole
    // Claude payload is captured verbatim under "payload"; the Rust side
    // pulls out session_id / hook_event_name etc.
    let banner = "# Managed by Kanban Code (Windows). Edits here will be overwritten.";
    format!(
        "#!/usr/bin/env bash\n\
{banner}\n\
set -u\n\
EVENTS_FILE='{events}'\n\
mkdir -p \"$(dirname \"$EVENTS_FILE\")\" 2>/dev/null || true\n\
PAYLOAD=$(cat)\n\
TS=$(date -u +%Y-%m-%dT%H:%M:%S.%3NZ)\n\
# Single-line JSON envelope so the Rust tail can parse line-by-line.\n\
printf '{{\"timestamp\":\"%s\",\"payload\":%s}}\\n' \"$TS\" \"$PAYLOAD\" >> \"$EVENTS_FILE\"\n\
",
        banner = banner,
        events = events_wsl_path.replace('\'', "'\\''"),
    )
}

fn install_script(content: &str) -> Result<(), String> {
    // mkdir + write atomically via stdin pipe — avoids shelling-out temp files.
    let mut child = Command::new("wsl.exe")
        .args([
            "--",
            "bash",
            "-lc",
            "mkdir -p ~/.kanban-code && cat > ~/.kanban-code/hook.sh && chmod +x ~/.kanban-code/hook.sh",
        ])
        .stdin(Stdio::piped())
        .stdout(Stdio::null())
        .stderr(Stdio::piped())
        .spawn()
        .map_err(|e| format!("spawn wsl bash for hook.sh write: {}", e))?;
    {
        let stdin = child.stdin.as_mut().ok_or("no stdin")?;
        stdin
            .write_all(content.as_bytes())
            .map_err(|e| format!("write hook.sh: {}", e))?;
    }
    let out = child.wait_with_output().map_err(|e| e.to_string())?;
    if !out.status.success() {
        return Err(format!(
            "hook.sh install failed: {}",
            String::from_utf8_lossy(&out.stderr).trim()
        ));
    }
    Ok(())
}

/// Read `~/.claude/settings.json`, merge our hook entries idempotently, write
/// back. Uses node-free, jq-free bash + python3 (present on every modern WSL
/// distro). If python3 is missing we fall through with a warning rather than
/// blocking — the user just loses hook events until they install it.
fn merge_into_settings() -> Result<(), String> {
    // Build the python merge script inline. The hook command we want
    // injected for every event is `~/.kanban-code/hook.sh`. Tildes are
    // expanded *inside* python via os.path.expanduser so the resulting
    // settings.json is portable across user accounts.
    let events_json: Vec<String> = HOOK_EVENTS.iter().map(|e| format!("\"{}\"", e)).collect();
    let events_arr = events_json.join(",");
    let py = format!(
        r#"
import json, os, sys
events = [{events}]
hook_cmd = os.path.expanduser('~/.kanban-code/hook.sh')
home = os.path.expanduser('~')
path = os.path.join(home, '.claude', 'settings.json')
os.makedirs(os.path.dirname(path), exist_ok=True)
try:
    with open(path) as f:
        data = json.load(f)
except FileNotFoundError:
    data = {{}}
except json.JSONDecodeError:
    # Salvage by archiving the bad file rather than silently overwriting.
    os.rename(path, path + '.bak')
    data = {{}}
hooks = data.setdefault('hooks', {{}})
for ev in events:
    groups = hooks.setdefault(ev, [])
    # Find or create a default group; idempotent across reruns.
    if not groups:
        groups.append({{'hooks': []}})
    inner = groups[0].setdefault('hooks', [])
    if not any(h.get('command') == hook_cmd for h in inner):
        inner.append({{'type': 'command', 'command': hook_cmd}})
with open(path, 'w') as f:
    json.dump(data, f, indent=2)
print('ok')
"#,
        events = events_arr
    );

    let mut child = Command::new("wsl.exe")
        .args(["--", "python3", "-"])
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .map_err(|e| format!("spawn wsl python3: {}", e))?;
    {
        let stdin = child.stdin.as_mut().ok_or("no stdin")?;
        stdin
            .write_all(py.as_bytes())
            .map_err(|e| format!("write python script: {}", e))?;
    }
    let out = child.wait_with_output().map_err(|e| e.to_string())?;
    if !out.status.success() {
        return Err(format!(
            "settings.json merge failed (is python3 installed in WSL?): {}",
            String::from_utf8_lossy(&out.stderr).trim()
        ));
    }
    Ok(())
}

/// Detection helper for diagnostic / status surface — returns true when the
/// hook script is present in WSL. Doesn't validate settings.json wiring.
pub fn is_installed() -> bool {
    Command::new("wsl.exe")
        .args(["--", "bash", "-lc", "test -x ~/.kanban-code/hook.sh"])
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .status()
        .map(|s| s.success())
        .unwrap_or(false)
}

/// Resolve the `%APPDATA%\kanban-code\hook-events.jsonl` path eagerly so
/// callers can pass it to the event-store before the WSL-side hook fires.
pub fn events_file_path() -> PathBuf {
    kanban_data_dir().join("hook-events.jsonl")
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn script_contains_events_path() {
        let script = hook_script_content("/mnt/c/Users/test/AppData/Roaming/kanban-code/hook-events.jsonl");
        assert!(script.contains("EVENTS_FILE='/mnt/c/Users/test/AppData/Roaming/kanban-code/hook-events.jsonl'"));
        assert!(script.contains("Managed by Kanban Code"));
    }

    #[test]
    fn script_quotes_paths_with_apostrophes() {
        let script = hook_script_content("/mnt/c/Users/o'connor/foo.jsonl");
        // The bashism `'\''` should appear, not a raw apostrophe inside the
        // single-quoted assignment.
        assert!(script.contains("/mnt/c/Users/o'\\''connor/foo.jsonl"));
    }
}
