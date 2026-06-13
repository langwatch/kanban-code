//! Tails `%APPDATA%\kanban-code\hook-events.jsonl` for events emitted by the
//! WSL-side `hook.sh` Claude installs into `~/.claude/settings.json`.
//!
//! Mirrors `Sources/KanbanCodeCore/Adapters/ClaudeCode/HookEventStore.swift`:
//!   * Resumes from `last_read_offset` on each call — never re-emits.
//!   * Each line is a JSON envelope `{"timestamp": "<iso8601>", "payload": <…>}`
//!     where `payload` is whatever Claude piped to `hook.sh` on stdin.
//!   * Parsed events surface `session_id`, `event_name`, `transcript_path`,
//!     `notification_type` — the four fields the orchestrator cares about.
//!
//! All file I/O is sync (a single tokio::task::spawn_blocking from the poller
//! is enough; the file is small and reads are cheap).

use std::fs::{File, OpenOptions};
use std::io::{BufRead, BufReader, Seek, SeekFrom};
use std::path::PathBuf;
use std::sync::Mutex;

use chrono::{DateTime, Utc};
use serde::{Deserialize, Serialize};

use crate::coordination_store::kanban_data_dir;

/// File name appended to the kanban data dir.
const EVENTS_FILE_NAME: &str = "hook-events.jsonl";

/// A single parsed hook event.
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct HookEvent {
    pub session_id: String,
    pub event_name: String,
    pub transcript_path: Option<String>,
    pub notification_type: Option<String>,
    pub timestamp: DateTime<Utc>,
}

/// On-disk envelope. The `hook.sh` script wraps Claude's payload in this so we
/// always have a wall-clock timestamp even if Claude's payload doesn't include
/// one.
#[derive(Debug, Deserialize)]
struct Envelope {
    timestamp: Option<String>,
    payload: Option<serde_json::Value>,
}

/// Tails the hook events file from a persistent read offset.
pub struct HookEventStore {
    path: PathBuf,
    last_read_offset: Mutex<u64>,
}

impl HookEventStore {
    pub fn new() -> Self {
        let path = kanban_data_dir().join(EVENTS_FILE_NAME);
        Self {
            path,
            last_read_offset: Mutex::new(0),
        }
    }

    pub fn path(&self) -> &PathBuf {
        &self.path
    }

    /// Resume offset to the *current end of file* so existing events from
    /// previous runs aren't re-fired on startup. Call once at app boot.
    pub fn skip_to_tail(&self) {
        let Ok(meta) = std::fs::metadata(&self.path) else {
            return;
        };
        let mut guard = self.last_read_offset.lock().unwrap();
        *guard = meta.len();
    }

    /// Read all events appended since the last call. Returns an empty Vec if
    /// the file doesn't exist yet (Claude hasn't fired a hook), or if no new
    /// bytes were appended.
    pub fn read_new_events(&self) -> Vec<HookEvent> {
        let mut events = Vec::new();
        let mut file = match File::open(&self.path) {
            Ok(f) => f,
            Err(_) => return events,
        };
        let mut offset = self.last_read_offset.lock().unwrap();
        let cur_len = match file.metadata() {
            Ok(m) => m.len(),
            Err(_) => return events,
        };
        // File was truncated (e.g. user wiped it) — reset to 0.
        if cur_len < *offset {
            *offset = 0;
        }
        if file.seek(SeekFrom::Start(*offset)).is_err() {
            return events;
        }
        let reader = BufReader::new(&file);
        let mut bytes_read: u64 = 0;
        for line in reader.lines() {
            let Ok(line) = line else { break };
            // +1 for the newline that BufRead strips.
            bytes_read += line.len() as u64 + 1;
            if line.trim().is_empty() {
                continue;
            }
            if let Some(ev) = parse_line(&line) {
                events.push(ev);
            }
        }
        *offset += bytes_read;
        events
    }

    /// Best-effort: ensure the file exists so the tail loop has something to
    /// stat. (Hook.sh creates it on first event, but this lets us skip the
    /// "file missing" branch when running tests / when WSL has never fired.)
    pub fn touch(&self) {
        if let Some(parent) = self.path.parent() {
            let _ = std::fs::create_dir_all(parent);
        }
        let _ = OpenOptions::new()
            .create(true)
            .append(true)
            .open(&self.path);
    }
}

fn parse_line(line: &str) -> Option<HookEvent> {
    let env: Envelope = serde_json::from_str(line).ok()?;
    let payload = env.payload?;
    let session_id = payload
        .get("session_id")
        .or_else(|| payload.get("sessionId"))
        .and_then(|v| v.as_str())
        .unwrap_or("")
        .to_string();
    let event_name = payload
        .get("hook_event_name")
        .or_else(|| payload.get("event_name"))
        .and_then(|v| v.as_str())
        .unwrap_or("")
        .to_string();
    let transcript_path = payload
        .get("transcript_path")
        .and_then(|v| v.as_str())
        .map(|s| s.to_string());
    let notification_type = payload
        .get("type")
        .and_then(|v| v.as_str())
        .map(|s| s.to_string());
    if session_id.is_empty() && event_name.is_empty() {
        return None;
    }
    let timestamp = env
        .timestamp
        .as_deref()
        .and_then(parse_timestamp)
        .unwrap_or_else(Utc::now);
    Some(HookEvent {
        session_id,
        event_name,
        transcript_path,
        notification_type,
        timestamp,
    })
}

fn parse_timestamp(s: &str) -> Option<DateTime<Utc>> {
    DateTime::parse_from_rfc3339(s)
        .or_else(|_| DateTime::parse_from_str(s, "%Y-%m-%dT%H:%M:%S%.fZ"))
        .or_else(|_| DateTime::parse_from_str(s, "%Y-%m-%dT%H:%M:%SZ"))
        .ok()
        .map(|d| d.with_timezone(&Utc))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_simple_envelope() {
        let line = r#"{"timestamp":"2026-06-13T12:00:00.000Z","payload":{"session_id":"abc","hook_event_name":"Stop"}}"#;
        let ev = parse_line(line).unwrap();
        assert_eq!(ev.session_id, "abc");
        assert_eq!(ev.event_name, "Stop");
        assert!(ev.transcript_path.is_none());
    }

    #[test]
    fn handles_camelcase_keys_from_claude() {
        let line = r#"{"timestamp":"2026-06-13T12:00:00Z","payload":{"sessionId":"abc","event_name":"Notification","type":"input_required"}}"#;
        let ev = parse_line(line).unwrap();
        assert_eq!(ev.session_id, "abc");
        assert_eq!(ev.event_name, "Notification");
        assert_eq!(ev.notification_type.as_deref(), Some("input_required"));
    }

    #[test]
    fn rejects_lines_with_no_session_or_event() {
        let line = r#"{"timestamp":"2026-06-13T12:00:00Z","payload":{}}"#;
        assert!(parse_line(line).is_none());
    }

    #[test]
    fn falls_back_to_now_on_missing_timestamp() {
        let line = r#"{"payload":{"session_id":"abc","hook_event_name":"Stop"}}"#;
        let ev = parse_line(line).unwrap();
        let now = Utc::now();
        // Timestamp should be very recent (within last second).
        assert!((now - ev.timestamp).num_seconds().abs() <= 2);
    }
}
