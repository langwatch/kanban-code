//! Polls `%APPDATA%\kanban-code\remote\status-<host>.json` files and emits
//! `remote_status_changed` Tauri events on online/offline transitions.
//!
//! Ports `RemoteStatusWatcher.swift`. The bash wrapper writes these files
//! whenever it succeeds/fails an SSH reachability probe.

use serde::Serialize;
use std::collections::HashMap;
use std::path::PathBuf;
use std::sync::Mutex;
use tokio::fs;

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct RemoteHostStatus {
    pub host: String,
    pub online: bool,
    pub since: Option<String>,
}

#[derive(Debug, Clone)]
struct HostState {
    status: String,
    since: Option<String>,
}

#[derive(Debug)]
pub struct RemoteStatusWatcher {
    state_dir: PathBuf,
    known: Mutex<HashMap<String, HostState>>,
}

impl RemoteStatusWatcher {
    pub fn new() -> Self {
        let state_dir = crate::coordination_store::kanban_data_dir().join("remote");
        Self {
            state_dir,
            known: Mutex::new(HashMap::new()),
        }
    }

    pub fn state_dir(&self) -> &PathBuf {
        &self.state_dir
    }

    /// Synchronous read of one host's status — defaults to `online` if no file.
    pub async fn is_online(&self, host: &str) -> bool {
        let path = self.state_dir.join(format!("status-{host}.json"));
        let Ok(data) = fs::read(&path).await else {
            return true;
        };
        let Ok(json): Result<serde_json::Value, _> = serde_json::from_slice(&data) else {
            return true;
        };
        json.get("status").and_then(|v| v.as_str()) != Some("offline")
    }

    /// Read every `status-*.json` file, diff against in-memory state, and
    /// return the changes that need notifying. Caller fires the event.
    pub async fn poll(&self) -> Vec<RemoteHostStatus> {
        let Ok(mut rd) = fs::read_dir(&self.state_dir).await else {
            return vec![];
        };

        let mut changes = vec![];
        while let Ok(Some(entry)) = rd.next_entry().await {
            let name = entry.file_name();
            let Some(s) = name.to_str() else { continue };
            if !s.starts_with("status-") || !s.ends_with(".json") {
                continue;
            }
            let host = s.trim_start_matches("status-").trim_end_matches(".json");
            if host.is_empty() {
                continue;
            }

            let Ok(data) = fs::read(entry.path()).await else { continue };
            let Ok(json): Result<serde_json::Value, _> = serde_json::from_slice(&data) else {
                continue;
            };
            let Some(status) = json.get("status").and_then(|v| v.as_str()) else { continue };
            let since = json
                .get("since")
                .and_then(|v| v.as_str())
                .map(String::from);

            let mut map = self.known.lock().unwrap();
            let prev = map.insert(
                host.to_string(),
                HostState {
                    status: status.to_string(),
                    since: since.clone(),
                },
            );
            drop(map);

            let changed = match prev {
                Some(p) => p.status != status,
                None => status == "offline", // first-poll-while-offline = notify
            };

            if changed {
                changes.push(RemoteHostStatus {
                    host: host.to_string(),
                    online: status == "online",
                    since,
                });
            }
        }

        changes
    }
}

impl Default for RemoteStatusWatcher {
    fn default() -> Self {
        Self::new()
    }
}
