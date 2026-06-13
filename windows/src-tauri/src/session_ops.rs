//! File-level session operations: fork + checkpoint (truncate).
//!
//! Ports `Sources/.../Adapters/ClaudeCode/ClaudeCodeSessionStore.swift`
//! `forkSession` and `truncateSession`. Both are OS-agnostic — pure file
//! reads / writes against the Claude Code `.jsonl` transcript.
//!
//! Why operate at the file level instead of via `claude` CLI: it's dramatically
//! faster (no process spawn, no LLM round-trip) and lets us branch / roll back
//! arbitrarily without disturbing the running CLI's view.

use anyhow::{anyhow, Context, Result};
use std::path::Path;
use tokio::fs;
use uuid::Uuid;

/// Fork the session at `session_path` into a new `.jsonl` next to it (or in
/// `target_dir` if provided), with a fresh UUID rewriting every occurrence of
/// the old session id. Returns the new session id.
///
/// Preserves the source file's mtime on the fork so the activity detector
/// (which keys off mtime) doesn't briefly mark the new session as actively
/// working — matches macOS behaviour.
pub async fn fork_session(session_path: &str, target_dir: Option<&str>) -> Result<String> {
    let src = Path::new(session_path);
    if !src.exists() {
        return Err(anyhow!("session file not found: {session_path}"));
    }

    let dir = match target_dir {
        Some(d) => Path::new(d).to_path_buf(),
        None => src
            .parent()
            .ok_or_else(|| anyhow!("session path has no parent"))?
            .to_path_buf(),
    };
    fs::create_dir_all(&dir).await.context("create fork target dir")?;

    let new_id = Uuid::new_v4().to_string().to_lowercase();
    let old_id = src
        .file_stem()
        .and_then(|s| s.to_str())
        .ok_or_else(|| anyhow!("invalid session filename"))?;
    let new_path = dir.join(format!("{new_id}.jsonl"));

    // Read+rewrite in-memory. Sessions are bounded (Claude caps them) and
    // rewriting line-by-line on disk would be more complex without a real
    // perf payoff.
    let contents = fs::read_to_string(src).await.context("read source session")?;
    let needle = format!("\"{old_id}\"");
    let replacement = format!("\"{new_id}\"");
    let rewritten = contents.replace(&needle, &replacement);

    fs::write(&new_path, rewritten.as_bytes())
        .await
        .context("write forked session")?;

    // Preserve source mtime on the new file. Best-effort — if filetime isn't
    // available (some FSes), we just leave the new file with `now` as mtime.
    if let Ok(meta) = std::fs::metadata(src) {
        if let Ok(mtime) = meta.modified() {
            let _ = std::fs::File::open(&new_path).and_then(|f| f.set_modified(mtime));
        }
    }

    Ok(new_id)
}

/// Checkpoint: keep the first `turn_count` user-or-assistant turns of the
/// transcript, discarding everything after. The original file is preserved at
/// `<session_path>.bkp` first so the user can recover if they cut too far.
///
/// `turn_count` is 1-based as the user thinks ("keep through turn 5"). System
/// / tool-result / metadata lines that aren't user/assistant don't count
/// toward the turn limit but ARE preserved when they appear inside the kept
/// prefix.
pub async fn truncate_session(session_path: &str, turn_count: usize) -> Result<()> {
    let src = Path::new(session_path);
    if !src.exists() {
        return Err(anyhow!("session file not found: {session_path}"));
    }
    if turn_count == 0 {
        return Err(anyhow!("turn_count must be >= 1"));
    }

    let bkp_path = format!("{session_path}.bkp");
    // Remove any prior .bkp so the copy can write fresh.
    let _ = fs::remove_file(&bkp_path).await;
    fs::copy(session_path, &bkp_path)
        .await
        .context("write .bkp backup")?;

    let contents = fs::read_to_string(src).await.context("read session")?;

    // Walk lines, counting user/assistant turns. Keep everything up through
    // the line that closes the Nth turn (inclusive of any trailing
    // tool_result lines that immediately follow it).
    let mut kept: Vec<&str> = Vec::new();
    let mut seen_turns: usize = 0;
    let mut hit_target = false;
    for line in contents.lines() {
        let role = role_from_line(line);
        let is_turn = matches!(role.as_deref(), Some("user") | Some("assistant"));
        if hit_target && is_turn {
            break;
        }
        if is_turn {
            seen_turns += 1;
            if seen_turns >= turn_count {
                hit_target = true;
            }
        }
        kept.push(line);
    }

    // Re-emit with trailing newline so the file shape matches Claude's writer.
    let mut out = kept.join("\n");
    if !out.is_empty() {
        out.push('\n');
    }
    fs::write(src, out.as_bytes())
        .await
        .context("write truncated session")?;
    Ok(())
}

fn role_from_line(line: &str) -> Option<String> {
    let v: serde_json::Value = serde_json::from_str(line).ok()?;
    v.get("type")
        .and_then(|t| t.as_str())
        .map(|s| s.to_string())
}
