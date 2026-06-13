//! Centralized logging for the Windows port — writes ISO8601 lines to
//! `%APPDATA%\kanban-code\logs\kanban-code.log` (mirrors macOS `KanbanCodeLog.swift`).
//!
//! Thread-safe, fire-and-forget: a transient I/O failure drops a line rather
//! than crashing the app. Lines are also mirrored to stderr so they show up in
//! `npm run tauri dev`. Use from anywhere: `logging::info("reconciler", "...")`.

use std::fs::{self, OpenOptions};
use std::io::Write;
use std::path::PathBuf;
use std::sync::{Mutex, OnceLock};

use chrono::Utc;

use crate::coordination_store::kanban_data_dir;

/// Max log size before startup rotation (10 MB).
const MAX_LOG_SIZE: u64 = 10 * 1024 * 1024;
/// Bytes of tail to keep after rotation (5 MB).
const KEEP_AFTER_ROTATION: usize = 5 * 1024 * 1024;

/// Resolved log file path (`…/kanban-code/logs/kanban-code.log`).
/// Rotation runs once, the first time the path is resolved.
fn log_path() -> &'static PathBuf {
    static PATH: OnceLock<PathBuf> = OnceLock::new();
    PATH.get_or_init(|| {
        let dir = kanban_data_dir().join("logs");
        let _ = fs::create_dir_all(&dir);
        let path = dir.join("kanban-code.log");
        rotate_if_needed(&path);
        path
    })
}

/// Serializes concurrent writes from background polling tasks + commands.
fn write_lock() -> &'static Mutex<()> {
    static LOCK: OnceLock<Mutex<()>> = OnceLock::new();
    LOCK.get_or_init(|| Mutex::new(()))
}

/// Verbose diagnostics are off unless `KANBAN_CODE_DEBUG_LOGS=1` / `KANBAN_DEBUG=1`.
fn debug_enabled() -> bool {
    static ENABLED: OnceLock<bool> = OnceLock::new();
    *ENABLED.get_or_init(|| {
        std::env::var("KANBAN_CODE_DEBUG_LOGS").as_deref() == Ok("1")
            || std::env::var("KANBAN_DEBUG").as_deref() == Ok("1")
    })
}

/// On startup, if the log exceeds `MAX_LOG_SIZE`, keep only the tail and trim to
/// the first newline so the file never starts mid-line.
fn rotate_if_needed(path: &PathBuf) {
    let Ok(meta) = fs::metadata(path) else { return };
    if meta.len() <= MAX_LOG_SIZE {
        return;
    }
    let Ok(data) = fs::read(path) else { return };
    let start = data.len().saturating_sub(KEEP_AFTER_ROTATION);
    let tail = &data[start..];
    let clean = match tail.iter().position(|&b| b == b'\n') {
        Some(i) => &tail[i + 1..],
        None => tail,
    };
    let _ = fs::write(path, clean);
}

fn write(level: &str, subsystem: &str, message: &str) {
    let line = format!(
        "[{}] [{}] [{}] {}\n",
        Utc::now().to_rfc3339(),
        level,
        subsystem,
        message
    );
    // Mirror to stderr for `tauri dev` visibility.
    eprint!("{line}");
    // Hold the lock across the append. Recover from a poisoned mutex rather than
    // panicking — a logging failure must never take down the app.
    let _guard = match write_lock().lock() {
        Ok(g) => g,
        Err(poisoned) => poisoned.into_inner(),
    };
    if let Ok(mut f) = OpenOptions::new().create(true).append(true).open(log_path()) {
        let _ = f.write_all(line.as_bytes());
    }
}

/// Informational message. `subsystem` is a short tag, e.g. "reconciler", "poll".
pub fn info(subsystem: &str, message: &str) {
    write("INFO", subsystem, message);
}

/// Recoverable problem worth noting.
pub fn warn(subsystem: &str, message: &str) {
    write("WARN", subsystem, message);
}

/// Failure that affected behavior.
pub fn error(subsystem: &str, message: &str) {
    write("ERROR", subsystem, message);
}

/// Verbose diagnostics; suppressed unless the debug env var is set.
#[allow(dead_code)] // public logging API; first callers land in later phases
pub fn debug(subsystem: &str, message: &str) {
    if debug_enabled() {
        write("DEBUG", subsystem, message);
    }
}
