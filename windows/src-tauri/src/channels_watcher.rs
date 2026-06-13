use notify::RecursiveMode;
use notify_debouncer_mini::new_debouncer;
use std::path::{Path, PathBuf};
use std::time::Duration;
use tauri::{AppHandle, Emitter};

const DEBOUNCE_MS: u64 = 50;

/// Events emitted to the webview. Frontend subscribes to these via Tauri's
/// `listen()` and refetches the affected slice when one fires.
pub mod events {
    pub const CHANNELS_CHANGED: &str = "channels-changed";
    pub const CHANNEL_MESSAGES_CHANGED: &str = "channel-messages-changed";
    pub const DM_LOGS_CHANGED: &str = "dm-logs-changed";
    pub const READ_STATE_CHANGED: &str = "read-state-changed";
    pub const DRAFTS_CHANGED: &str = "drafts-changed";
}

/// Spin up a background thread that watches the channels dir + the dm subdir,
/// debounces events with a 50ms window, and forwards them as Tauri app events.
///
/// `base_dir` is `<kanban_data_dir>/channels`. The watcher creates the dir (and
/// `dm/`, `images/`) if missing so the directory-level subscriptions succeed
/// immediately on a clean install.
pub fn start(app: AppHandle, base_dir: PathBuf) {
    // The Swift watcher uses DispatchSource per-file with explicit re-attach on
    // atomic rename. The `notify` crate watches the *directory* on all platforms,
    // so the rename-orphan problem doesn't apply here — any write under the dir
    // produces an event.
    let _ = std::fs::create_dir_all(&base_dir);
    let _ = std::fs::create_dir_all(base_dir.join("dm"));
    let _ = std::fs::create_dir_all(base_dir.join("images"));
    let channels_file = base_dir.join("channels.json");
    if !channels_file.exists() {
        let _ = std::fs::write(&channels_file, b"{\"channels\":[]}\n");
    }

    std::thread::Builder::new()
        .name("channels-watcher".into())
        .spawn(move || run(app, base_dir))
        .ok(); // Best-effort; channel UI degrades to polling if the thread fails.
}

fn run(app: AppHandle, base_dir: PathBuf) {
    let (tx, rx) = std::sync::mpsc::channel();
    let mut debouncer = match new_debouncer(Duration::from_millis(DEBOUNCE_MS), tx) {
        Ok(d) => d,
        Err(e) => {
            eprintln!("channels watcher: failed to create debouncer: {e}");
            return;
        }
    };

    if let Err(e) = debouncer.watcher().watch(&base_dir, RecursiveMode::NonRecursive) {
        eprintln!("channels watcher: failed to watch {}: {}", base_dir.display(), e);
        return;
    }
    let dm_dir = base_dir.join("dm");
    if let Err(e) = debouncer.watcher().watch(&dm_dir, RecursiveMode::NonRecursive) {
        // Non-fatal: DM updates fall back to refresh-on-focus.
        eprintln!("channels watcher: failed to watch dm dir {}: {}", dm_dir.display(), e);
    }

    for batch in rx {
        let events = match batch {
            Ok(events) => events,
            Err(_) => continue,
        };
        for event in events {
            dispatch(&app, &base_dir, &event.path);
        }
    }
}

/// Map a changed path to the right Tauri app event.
fn dispatch(app: &AppHandle, base_dir: &Path, path: &Path) {
    // dm/<key>.jsonl — emit dm-logs-changed with the pair key.
    if path
        .parent()
        .and_then(|p| p.file_name())
        .and_then(|s| s.to_str())
        == Some("dm")
        && path.extension().and_then(|s| s.to_str()) == Some("jsonl")
    {
        if let Some(stem) = path.file_stem().and_then(|s| s.to_str()) {
            let _ = app.emit(events::DM_LOGS_CHANGED, serde_json::json!({ "dmKey": stem }));
        }
        return;
    }

    // Only honor files at the top level of the channels dir.
    if path.parent() != Some(base_dir) {
        return;
    }
    let Some(name) = path.file_name().and_then(|s| s.to_str()) else { return };
    match name {
        "channels.json" => {
            let _ = app.emit(events::CHANNELS_CHANGED, ());
        }
        "read-state.json" => {
            let _ = app.emit(events::READ_STATE_CHANGED, ());
        }
        "drafts.json" => {
            let _ = app.emit(events::DRAFTS_CHANGED, ());
        }
        _ if name.ends_with(".jsonl") => {
            if let Some(stem) = path.file_stem().and_then(|s| s.to_str()) {
                let _ = app.emit(
                    events::CHANNEL_MESSAGES_CHANGED,
                    serde_json::json!({ "channelName": stem }),
                );
            }
        }
        _ => {}
    }
}
