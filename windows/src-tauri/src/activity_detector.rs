use std::time::{Duration, SystemTime};

#[derive(Debug, Clone, PartialEq)]
pub enum ActivityState {
    ActivelyWorking,
    WaitingForInput,
    Idle,
}

/// Detect session activity based on .jsonl file modification time.
/// If modified within the last 30 seconds → actively working.
/// If modified within the last 5 minutes → waiting for input.
/// Otherwise → idle.
pub fn detect_activity(jsonl_path: &str) -> ActivityState {
    let mtime = std::fs::metadata(jsonl_path)
        .and_then(|m| m.modified())
        .unwrap_or_else(|_| SystemTime::UNIX_EPOCH);

    let elapsed = SystemTime::now()
        .duration_since(mtime)
        .unwrap_or(Duration::MAX);

    if elapsed < Duration::from_secs(30) {
        ActivityState::ActivelyWorking
    } else if elapsed < Duration::from_secs(300) {
        ActivityState::WaitingForInput
    } else {
        ActivityState::Idle
    }
}
