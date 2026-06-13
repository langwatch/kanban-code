//! Mutagen CLI wrapper — ports macOS `MutagenAdapter.swift`.
//!
//! Manages a single named sync session labelled `kanban=true`. Calls out to
//! `mutagen.exe` (must be on PATH; detected at startup, never crashes if missing).

use anyhow::{anyhow, Result};
use serde::Serialize;
use std::process::Stdio;
use tokio::process::Command;

/// Default ignore patterns — must match `MutagenAdapter.defaultIgnores` exactly.
pub fn default_ignores() -> Vec<String> {
    vec![
        "node_modules", ".venv", ".cache", "dist", ".next*",
        "__pycache__", ".pytest_cache", ".mypy_cache", ".turbo",
        "*.pyc", ".DS_Store", "coverage", ".nyc_output",
        "target", "build", ".build", ".swiftpm",
    ]
    .into_iter()
    .map(String::from)
    .collect()
}

const LABEL: &str = "kanban";
const DEFAULT_SESSION_NAME: &str = "kanban-code-sync";

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct SyncStatus {
    pub kind: SyncStatusKind,
    pub session_name: Option<String>,
    pub conflict_count: u32,
    pub message: Option<String>,
}

#[derive(Debug, Clone, Copy, Serialize, PartialEq, Eq)]
#[serde(rename_all = "lowercase")]
pub enum SyncStatusKind {
    Disabled,
    Watching,
    Scanning,
    Staging,
    Conflicts,
    Paused,
    Error,
}

impl SyncStatus {
    pub fn disabled() -> Self {
        Self {
            kind: SyncStatusKind::Disabled,
            session_name: None,
            conflict_count: 0,
            message: None,
        }
    }
}

/// Locate an executable on PATH. Returns the resolved path or `None`.
pub(crate) fn find_on_path(name: &str) -> Option<String> {
    let path_var = std::env::var_os("PATH")?;
    let exts: Vec<&str> = if cfg!(target_os = "windows") {
        vec!["", ".exe", ".cmd", ".bat"]
    } else {
        vec![""]
    };
    for dir in std::env::split_paths(&path_var) {
        for ext in &exts {
            let candidate = dir.join(format!("{name}{ext}"));
            if candidate.is_file() {
                return Some(candidate.to_string_lossy().to_string());
            }
        }
    }
    None
}

/// Locate `mutagen` (or `mutagen.exe`) via PATH.
pub fn find_mutagen() -> Option<String> {
    find_on_path("mutagen")
}

pub fn is_available() -> bool {
    find_mutagen().is_some()
}

/// Spawn `mutagen daemon start` — idempotent; ignores failure (already running).
pub async fn ensure_daemon() {
    let Some(bin) = find_mutagen() else { return };
    let _ = Command::new(&bin)
        .args(["daemon", "start"])
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .status()
        .await;
}

async fn run_mutagen(args: &[&str]) -> Result<(bool, String, String)> {
    let bin = find_mutagen().ok_or_else(|| anyhow!("mutagen.exe not on PATH"))?;
    let out = Command::new(&bin).args(args).output().await?;
    let stdout = String::from_utf8_lossy(&out.stdout).to_string();
    let stderr = String::from_utf8_lossy(&out.stderr).to_string();
    Ok((out.status.success(), stdout, stderr))
}

pub async fn start_sync(
    local_path: &str,
    remote_host: &str,
    remote_path: &str,
    ignores: &[String],
) -> Result<()> {
    let label_selector = format!("{LABEL}=true");

    if let Ok((ok, stdout, _)) =
        run_mutagen(&["sync", "list", "--label-selector", &label_selector]).await
    {
        if ok && stdout.contains("Name:") {
            let _ = flush_sync().await;
            return Ok(());
        }
    }

    let remote = format!("{remote_host}:{remote_path}");
    let label_arg = format!("{LABEL}=true");
    let mut args: Vec<&str> = vec![
        "sync", "create",
        local_path, &remote,
        "--name", DEFAULT_SESSION_NAME,
        "--label", &label_arg,
        "--sync-mode", "two-way-resolved",
        "--default-file-mode-beta", "0644",
        "--default-directory-mode-beta", "0755",
    ];
    for pat in ignores {
        args.push("--ignore");
        args.push(pat);
    }

    let (ok, _, stderr) = run_mutagen(&args).await?;
    if !ok {
        return Err(anyhow!("mutagen sync create failed: {stderr}"));
    }
    Ok(())
}

pub async fn stop_sync() -> Result<()> {
    let label_selector = format!("{LABEL}=true");
    let (ok, _, stderr) =
        run_mutagen(&["sync", "terminate", "--label-selector", &label_selector]).await?;
    if !ok {
        return Err(anyhow!("mutagen sync terminate failed: {stderr}"));
    }
    Ok(())
}

pub async fn reset_sync() -> Result<()> {
    let label_selector = format!("{LABEL}=true");
    let _ = run_mutagen(&["sync", "pause", "--label-selector", &label_selector]).await;
    let (ok, _, stderr) =
        run_mutagen(&["sync", "resume", "--label-selector", &label_selector]).await?;
    if !ok {
        return Err(anyhow!("mutagen sync resume failed: {stderr}"));
    }
    Ok(())
}

pub async fn flush_sync() -> Result<()> {
    let label_selector = format!("{LABEL}=true");
    let (ok, _, stderr) =
        run_mutagen(&["sync", "flush", "--label-selector", &label_selector]).await?;
    if !ok {
        return Err(anyhow!("mutagen sync flush failed: {stderr}"));
    }
    Ok(())
}

/// Parse current sync status. Returns `SyncStatus::disabled()` when no
/// session is running (or mutagen isn't available at all).
pub async fn status() -> SyncStatus {
    if !is_available() {
        return SyncStatus::disabled();
    }
    let label_selector = format!("{LABEL}=true");
    // Mirror MutagenAdapter.status template
    let template = "{{range .}}{{.Name}}|{{.Status}}|{{len .Conflicts}}|{{.Paused}}\n{{end}}";

    let Ok((ok, stdout, _)) = run_mutagen(&[
        "sync", "list",
        "--label-selector", &label_selector,
        "--template", template,
    ])
    .await
    else {
        return SyncStatus::disabled();
    };

    if !ok || stdout.trim().is_empty() {
        return SyncStatus::disabled();
    }

    for line in stdout.lines() {
        let parts: Vec<&str> = line.splitn(4, '|').collect();
        if parts.len() < 4 {
            continue;
        }
        let name = parts[0].to_string();
        let status_str = parts[1].to_lowercase();
        let conflicts: u32 = parts[2].parse().unwrap_or(0);
        let paused = parts[3].trim() == "true";

        let kind = if paused {
            SyncStatusKind::Paused
        } else if conflicts > 0 {
            SyncStatusKind::Conflicts
        } else {
            match status_str.as_str() {
                "watching" => SyncStatusKind::Watching,
                "scanning" => SyncStatusKind::Scanning,
                "staging" | "transitioning" | "reconciling" | "saving" => SyncStatusKind::Staging,
                "halted" => SyncStatusKind::Paused,
                _ => SyncStatusKind::Error,
            }
        };

        return SyncStatus {
            kind,
            session_name: Some(name),
            conflict_count: conflicts,
            message: Some(status_str),
        };
    }
    SyncStatus::disabled()
}

/// Raw `mutagen sync list -l` output, for the "show details" button.
pub async fn raw_status() -> Result<String> {
    let (ok, stdout, stderr) = run_mutagen(&["sync", "list", "-l"]).await?;
    let trimmed = stdout.trim();
    if !ok && trimmed.is_empty() {
        return Err(anyhow!("mutagen sync list failed: {stderr}"));
    }
    if trimmed.is_empty() {
        return Ok("No sync sessions running.".to_string());
    }
    Ok(trimmed.to_string())
}
