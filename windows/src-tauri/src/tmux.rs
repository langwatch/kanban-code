//! tmux-in-WSL adapter — wraps `wsl.exe tmux …` (or bare `tmux` when this
//! binary itself runs under WSL/Linux) to provide a long-lived multiplexer
//! for embedded Claude terminals on Windows.
//!
//! Mirrors `Sources/KanbanCodeCore/Adapters/Tmux/TmuxAdapter.swift`:
//!   * idempotent session create (`has-session` → reuse, else `new-session -d`)
//!   * bracketed-paste prompt send via `load-buffer -` + `paste-buffer -p`
//!   * `ensure_prompt_sent` re-fires Enter up to 10× when the pasted text is
//!     still visible after `❯` (Claude's prompt char)
//!   * `capture-pane -p` for activity / debug
//!   * multi-window per session (one window per drawer tab)
//!
//! Gating: the caller is responsible for checking
//! `Settings.terminal_shell.contains("wsl")` before invoking these commands.
//! When the user has chosen native `cmd.exe` / `pwsh.exe`, tmux is unavailable
//! and the legacy one-shot PTY remains in effect (tracked TODO: PTY-pool).
//!
//! All commands run synchronously — tmux operations are quick and serializing
//! them avoids the lock-step ordering problems seen on macOS when paste and
//! Enter race.

use std::io::Write;
use std::process::{Command, Stdio};

use serde::{Deserialize, Serialize};

use crate::logging;

/// Wraps the platform-appropriate way to run `tmux …`.
///
/// On Windows we go through `wsl.exe -- tmux …`; on WSL/Linux we can call
/// `tmux` directly. Returned command has stdin/stdout/stderr piped so callers
/// can attach data if needed.
fn tmux_cmd<I, S>(args: I) -> Command
where
    I: IntoIterator<Item = S>,
    S: AsRef<std::ffi::OsStr>,
{
    #[cfg(target_os = "windows")]
    {
        let mut c = Command::new("wsl.exe");
        c.arg("--");
        c.arg("tmux");
        for a in args {
            c.arg(a);
        }
        c
    }
    #[cfg(not(target_os = "windows"))]
    {
        let mut c = Command::new("tmux");
        for a in args {
            c.arg(a);
        }
        c
    }
}

/// Returns `Ok(true)` iff `tmux -V` succeeds inside the chosen environment.
/// Used by the frontend to disable persistence + multi-tab UI when the user
/// hasn't set up WSL/tmux yet.
pub fn is_available() -> bool {
    tmux_cmd(["-V"])
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .status()
        .map(|s| s.success())
        .unwrap_or(false)
}

/// `tmux has-session -t {name}` — true if the named session exists.
pub fn has_session(name: &str) -> bool {
    tmux_cmd(["has-session", "-t", name])
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .status()
        .map(|s| s.success())
        .unwrap_or(false)
}

/// Translate a Windows path (`C:\foo\bar`) into a WSL path (`/mnt/c/foo/bar`)
/// using `wsl wslpath -a`. Returns the input unchanged on failure or when
/// the path already looks Unix-y.
pub fn windows_path_to_wsl(p: &str) -> String {
    if p.starts_with('/') {
        return p.to_string();
    }
    #[cfg(target_os = "windows")]
    {
        let out = Command::new("wsl.exe")
            .args(["--", "wslpath", "-a", p])
            .output();
        if let Ok(o) = out {
            if o.status.success() {
                let s = String::from_utf8_lossy(&o.stdout).trim().to_string();
                if !s.is_empty() {
                    return s;
                }
            }
        }
    }
    p.to_string()
}

/// Ensure a detached session exists named `name`, cwd `cwd_wsl_path`, running
/// `command`. Idempotent: returns immediately if the session already exists
/// (we never want to clobber an attached terminal). When `command` is empty,
/// the session is created with whatever WSL's default shell is.
///
/// `cwd_wsl_path` must already be a WSL path — call `windows_path_to_wsl`
/// upstream once if you have a Windows path.
pub fn ensure_session(name: &str, cwd_wsl_path: &str, command: &str) -> Result<(), String> {
    if has_session(name) {
        return Ok(());
    }
    // Mirrors the macOS adapter: -A reattaches if (rare race), -d detached.
    // `command` is passed as the session shell-command argument; an empty
    // string keeps the default shell.
    let mut args: Vec<String> = vec![
        "new-session".into(),
        "-A".into(),
        "-d".into(),
        "-s".into(),
        name.into(),
        "-c".into(),
        cwd_wsl_path.into(),
    ];
    if !command.is_empty() {
        args.push(command.into());
    }
    let out = tmux_cmd(&args).output().map_err(|e| e.to_string())?;
    if !out.status.success() {
        let err = String::from_utf8_lossy(&out.stderr).to_string();
        return Err(format!("tmux new-session failed: {}", err.trim()));
    }
    logging::info(
        "tmux",
        &format!("created session name={} cwd={}", name, cwd_wsl_path),
    );
    Ok(())
}

/// Kill a session by name. Silently succeeds if the session is already gone.
pub fn kill_session(name: &str) -> Result<(), String> {
    if !has_session(name) {
        return Ok(());
    }
    let out = tmux_cmd(["kill-session", "-t", name])
        .output()
        .map_err(|e| e.to_string())?;
    if !out.status.success() {
        let err = String::from_utf8_lossy(&out.stderr).to_string();
        return Err(format!("tmux kill-session failed: {}", err.trim()));
    }
    logging::info("tmux", &format!("killed session name={}", name));
    Ok(())
}

/// `tmux capture-pane -p -t {target}` — return the current pane content as
/// a String. `target` can be `session`, `session:window`, or `session:window.pane`.
pub fn capture_pane(target: &str) -> Result<String, String> {
    let out = tmux_cmd(["capture-pane", "-p", "-t", target])
        .output()
        .map_err(|e| e.to_string())?;
    if !out.status.success() {
        return Err(String::from_utf8_lossy(&out.stderr).trim().to_string());
    }
    Ok(String::from_utf8_lossy(&out.stdout).to_string())
}

/// Bracketed-paste `text` into `target` and submit with Enter.
///
/// Algorithm (mirrors the macOS adapter):
///   1. `send-keys -X cancel`  — exit copy-mode if active
///   2. `load-buffer -`         — read bytes from stdin into the paste buffer
///   3. `paste-buffer -p -t T`  — paste using bracketed paste sequence
///   4. `send-keys -t T Enter`  — submit
///   5. `ensure_prompt_sent`    — re-fire Enter up to 10× if the text is still
///                                 visible after the prompt character `❯`
pub fn send_prompt(target: &str, text: &str) -> Result<(), String> {
    // 1. Exit copy-mode (safe no-op if not in it).
    let _ = tmux_cmd(["send-keys", "-X", "-t", target, "cancel"])
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .status();

    // 2. Load the text into the paste buffer via stdin — robust for arbitrary
    //    UTF-8 and avoids any shell-escaping pitfalls.
    let mut load = tmux_cmd(["load-buffer", "-"])
        .stdin(Stdio::piped())
        .stdout(Stdio::null())
        .stderr(Stdio::piped())
        .spawn()
        .map_err(|e| format!("tmux load-buffer spawn: {}", e))?;
    {
        let stdin = load
            .stdin
            .as_mut()
            .ok_or_else(|| "tmux load-buffer: no stdin".to_string())?;
        stdin
            .write_all(text.as_bytes())
            .map_err(|e| format!("tmux load-buffer write: {}", e))?;
    }
    let lout = load.wait_with_output().map_err(|e| e.to_string())?;
    if !lout.status.success() {
        return Err(format!(
            "tmux load-buffer failed: {}",
            String::from_utf8_lossy(&lout.stderr).trim()
        ));
    }

    // 3. Paste with bracketed-paste flag (-p).
    let pout = tmux_cmd(["paste-buffer", "-p", "-t", target])
        .output()
        .map_err(|e| e.to_string())?;
    if !pout.status.success() {
        return Err(format!(
            "tmux paste-buffer failed: {}",
            String::from_utf8_lossy(&pout.stderr).trim()
        ));
    }

    // 4. Brief pause so Claude finishes processing the bracketed paste
    //    *event* before we send Enter. Without this, Claude occasionally
    //    treats the Enter as part of the paste and the prompt isn't submitted.
    std::thread::sleep(std::time::Duration::from_millis(100));
    let eout = tmux_cmd(["send-keys", "-t", target, "Enter"])
        .output()
        .map_err(|e| e.to_string())?;
    if !eout.status.success() {
        return Err(format!(
            "tmux send-keys Enter failed: {}",
            String::from_utf8_lossy(&eout.stderr).trim()
        ));
    }

    // 5. Verify the prompt was accepted; re-fire Enter if not.
    ensure_prompt_sent(target);
    Ok(())
}

/// Paste `text` into `target` WITHOUT submitting (no trailing Enter). Used by
/// queued-prompt editing in the UI.
pub fn paste_text(target: &str, text: &str) -> Result<(), String> {
    let _ = tmux_cmd(["send-keys", "-X", "-t", target, "cancel"])
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .status();
    let mut load = tmux_cmd(["load-buffer", "-"])
        .stdin(Stdio::piped())
        .stdout(Stdio::null())
        .stderr(Stdio::piped())
        .spawn()
        .map_err(|e| format!("tmux load-buffer spawn: {}", e))?;
    {
        let stdin = load
            .stdin
            .as_mut()
            .ok_or_else(|| "tmux load-buffer: no stdin".to_string())?;
        stdin
            .write_all(text.as_bytes())
            .map_err(|e| format!("tmux load-buffer write: {}", e))?;
    }
    let lout = load.wait_with_output().map_err(|e| e.to_string())?;
    if !lout.status.success() {
        return Err(format!(
            "tmux load-buffer failed: {}",
            String::from_utf8_lossy(&lout.stderr).trim()
        ));
    }
    let pout = tmux_cmd(["paste-buffer", "-p", "-t", target])
        .output()
        .map_err(|e| e.to_string())?;
    if !pout.status.success() {
        return Err(format!(
            "tmux paste-buffer failed: {}",
            String::from_utf8_lossy(&pout.stderr).trim()
        ));
    }
    Ok(())
}

/// Poll `capture-pane` up to 10 times looking for evidence the pasted text is
/// still sitting in Claude's input box. Indicators:
///   * a literal "[Pasted text" marker — Claude collapses big pastes
///   * any non-whitespace after `❯ ` on the last non-empty line
///
/// If either is seen, re-fire Enter. Best-effort: errors are swallowed.
fn ensure_prompt_sent(target: &str) {
    for i in 0..10 {
        let delay = if i == 0 { 300 } else { 500 };
        std::thread::sleep(std::time::Duration::from_millis(delay));
        let cap = match capture_pane(target) {
            Ok(s) => s,
            Err(_) => return,
        };
        if !needs_resubmit(&cap) {
            return;
        }
        let _ = tmux_cmd(["send-keys", "-t", target, "Enter"])
            .stdout(Stdio::null())
            .stderr(Stdio::null())
            .status();
    }
    logging::warn(
        "tmux",
        &format!("ensure_prompt_sent gave up after 10 attempts target={}", target),
    );
}

fn needs_resubmit(capture: &str) -> bool {
    if capture.contains("[Pasted text") || capture.contains("[Pasted Text") {
        return true;
    }
    // Look at the last non-empty line; if there's text after `❯ ` (the Claude
    // prompt glyph), the prompt didn't submit.
    for line in capture.lines().rev() {
        let t = line.trim_end();
        if t.is_empty() {
            continue;
        }
        if let Some(idx) = t.find('❯') {
            let after: &str = &t[idx + '❯'.len_utf8()..];
            return !after.trim().is_empty();
        }
        break;
    }
    false
}

/// `tmux new-window -t {session}` — opens a fresh shell window in the session,
/// optionally cd'd to `cwd_wsl_path` and running `command`. Returns the new
/// window index (parsed from `display-message -p '#I'`).
pub fn new_window(
    session: &str,
    cwd_wsl_path: Option<&str>,
    command: Option<&str>,
) -> Result<u32, String> {
    let mut args: Vec<String> = vec!["new-window".into(), "-P".into(), "-F".into(), "#I".into(), "-t".into(), session.into()];
    if let Some(c) = cwd_wsl_path {
        args.push("-c".into());
        args.push(c.into());
    }
    if let Some(cmd) = command {
        args.push(cmd.into());
    }
    let out = tmux_cmd(&args).output().map_err(|e| e.to_string())?;
    if !out.status.success() {
        return Err(format!(
            "tmux new-window failed: {}",
            String::from_utf8_lossy(&out.stderr).trim()
        ));
    }
    let idx_str = String::from_utf8_lossy(&out.stdout).trim().to_string();
    idx_str
        .parse::<u32>()
        .map_err(|e| format!("tmux new-window: couldn't parse window index '{}': {}", idx_str, e))
}

/// Kill a window by its `session:index` target.
pub fn kill_window(target: &str) -> Result<(), String> {
    let out = tmux_cmd(["kill-window", "-t", target])
        .output()
        .map_err(|e| e.to_string())?;
    if !out.status.success() {
        let err = String::from_utf8_lossy(&out.stderr).to_string();
        // tolerate "can't find window" — caller-side state may already be gone
        if err.contains("can't find") {
            return Ok(());
        }
        return Err(format!("tmux kill-window failed: {}", err.trim()));
    }
    Ok(())
}

/// One window in a tmux session.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct TmuxWindow {
    pub index: u32,
    pub name: String,
    pub active: bool,
}

/// `tmux list-windows -t {session} -F '#I\t#W\t#{window_active}'`
pub fn list_windows(session: &str) -> Result<Vec<TmuxWindow>, String> {
    if !has_session(session) {
        return Ok(vec![]);
    }
    let out = tmux_cmd([
        "list-windows",
        "-t",
        session,
        "-F",
        "#I\t#W\t#{window_active}",
    ])
    .output()
    .map_err(|e| e.to_string())?;
    if !out.status.success() {
        return Err(String::from_utf8_lossy(&out.stderr).trim().to_string());
    }
    let s = String::from_utf8_lossy(&out.stdout);
    let mut windows = Vec::new();
    for line in s.lines() {
        let parts: Vec<&str> = line.split('\t').collect();
        if parts.len() < 3 {
            continue;
        }
        let Ok(index) = parts[0].parse::<u32>() else {
            continue;
        };
        windows.push(TmuxWindow {
            index,
            name: parts[1].to_string(),
            active: parts[2] == "1",
        });
    }
    Ok(windows)
}

// ─────────────────────────── Tauri command surface ───────────────────────────
// Thin async wrappers exposed to the JS layer. All run blocking tmux ops on a
// blocking thread so we don't stall the Tauri runtime.

#[tauri::command]
pub async fn tmux_available() -> bool {
    tokio::task::spawn_blocking(is_available).await.unwrap_or(false)
}

#[tauri::command]
pub async fn tmux_ensure_session(
    name: String,
    cwd_windows: String,
    command: String,
) -> Result<(), String> {
    tokio::task::spawn_blocking(move || {
        let wsl_cwd = windows_path_to_wsl(&cwd_windows);
        ensure_session(&name, &wsl_cwd, &command)
    })
    .await
    .map_err(|e| e.to_string())?
}

#[tauri::command]
pub async fn tmux_send_prompt(target: String, text: String) -> Result<(), String> {
    tokio::task::spawn_blocking(move || send_prompt(&target, &text))
        .await
        .map_err(|e| e.to_string())?
}

#[tauri::command]
pub async fn tmux_paste(target: String, text: String) -> Result<(), String> {
    tokio::task::spawn_blocking(move || paste_text(&target, &text))
        .await
        .map_err(|e| e.to_string())?
}

#[tauri::command]
pub async fn tmux_capture(target: String) -> Result<String, String> {
    tokio::task::spawn_blocking(move || capture_pane(&target))
        .await
        .map_err(|e| e.to_string())?
}

#[tauri::command]
pub async fn tmux_kill_session(name: String) -> Result<(), String> {
    tokio::task::spawn_blocking(move || kill_session(&name))
        .await
        .map_err(|e| e.to_string())?
}

#[tauri::command]
pub async fn tmux_new_window(
    session: String,
    cwd_windows: Option<String>,
    command: Option<String>,
) -> Result<u32, String> {
    tokio::task::spawn_blocking(move || {
        let cwd_wsl = cwd_windows.as_deref().map(windows_path_to_wsl);
        new_window(&session, cwd_wsl.as_deref(), command.as_deref())
    })
    .await
    .map_err(|e| e.to_string())?
}

#[tauri::command]
pub async fn tmux_kill_window(target: String) -> Result<(), String> {
    tokio::task::spawn_blocking(move || kill_window(&target))
        .await
        .map_err(|e| e.to_string())?
}

#[tauri::command]
pub async fn tmux_list_windows(session: String) -> Result<Vec<TmuxWindow>, String> {
    tokio::task::spawn_blocking(move || list_windows(&session))
        .await
        .map_err(|e| e.to_string())?
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn needs_resubmit_detects_pasted_marker() {
        assert!(needs_resubmit("foo\n[Pasted text #1 +5 lines]\n❯ "));
    }

    #[test]
    fn needs_resubmit_detects_text_after_prompt() {
        assert!(needs_resubmit("welcome\n❯ hello world"));
    }

    #[test]
    fn needs_resubmit_clean_prompt_is_false() {
        assert!(!needs_resubmit("welcome\n❯ "));
    }

    #[test]
    fn needs_resubmit_no_prompt_glyph_is_false() {
        assert!(!needs_resubmit("just some stale capture"));
    }
}
