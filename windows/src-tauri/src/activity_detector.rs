use std::time::{Duration, SystemTime};

/// Mirrors the macOS ActivityState enum exactly.
/// Without hook events we approximate from JSONL mtime — good enough for WSL.
#[derive(Debug, Clone, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub enum ActivityState {
    /// Claude is actively writing/running tools right now (mtime < 30s)
    ActivelyWorking,
    /// Claude stopped and is waiting for the user to respond (30s–5min)
    NeedsAttention,
    /// Claude is idle, session still open (5min–24h)
    IdleWaiting,
    /// Session ended cleanly (24h–7d)
    Ended,
    /// Very stale — no hook data, file old (> 7d)
    Stale,
}

use serde::Serialize;

impl ActivityState {
    pub fn as_str(&self) -> &'static str {
        match self {
            Self::ActivelyWorking => "activelyWorking",
            Self::NeedsAttention => "needsAttention",
            Self::IdleWaiting => "idleWaiting",
            Self::Ended => "ended",
            Self::Stale => "stale",
        }
    }
}

/// Detect session activity from JSONL mtime.
///
/// The JSONL transcript file is actively written to while Claude processes.
/// A file modified very recently means Claude is likely generating output
/// or running tools right now.
///
/// Thresholds:
///   < 15s   → actively working (file being written → In Progress + spinner)
///   < 5min  → needs attention (Claude stopped → Waiting, no spinner)
///   < 24h   → ended
///   else    → stale
pub fn detect_activity(jsonl_path: &str) -> ActivityState {
    let mtime = std::fs::metadata(jsonl_path)
        .and_then(|m| m.modified())
        .unwrap_or(SystemTime::UNIX_EPOCH);

    let elapsed = SystemTime::now()
        .duration_since(mtime)
        .unwrap_or(Duration::MAX);

    if elapsed < Duration::from_secs(15) {
        ActivityState::ActivelyWorking
    } else if elapsed < Duration::from_secs(5 * 60) {
        ActivityState::NeedsAttention
    } else if elapsed < Duration::from_secs(86400) {
        ActivityState::Ended
    } else {
        ActivityState::Stale
    }
}
