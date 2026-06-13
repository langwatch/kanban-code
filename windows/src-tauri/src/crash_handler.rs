//! Crash backstop — writes a panic report to
//! `%APPDATA%\kanban-code\logs\crash-<timestamp>.log` before the process dies.
//!
//! Why this exists: `Cargo.toml` sets `panic = "abort"` in release, so without a
//! hook a panic ends the app with zero on-disk evidence. macOS has Apple's crash
//! reporter; Windows has nothing comparable by default. The hook runs *before*
//! the abort, so it must do its own synchronous I/O — at panic time the tokio
//! runtime may already be torn down, so `std::fs` is the only safe choice.
//!
//! Install once from `main()` *before* anything else (including `tauri::Builder`)
//! so a panic during Tauri startup is still captured.

use std::backtrace::Backtrace;
use std::fs::{self, OpenOptions};
use std::io::Write;
use std::path::PathBuf;

/// Set the panic hook. Call exactly once, as the first statement in `main()`.
pub fn install() {
    // `Backtrace::force_capture` always captures frames regardless of env var,
    // but rustc's libstd panic message only includes `note: run with
    // `RUST_BACKTRACE=1`…` formatting when the env var is set. Setting it here
    // gives users the familiar output on stderr in addition to our log file.
    if std::env::var_os("RUST_BACKTRACE").is_none() {
        // SAFETY: single-threaded at install time (called before Tauri starts).
        std::env::set_var("RUST_BACKTRACE", "1");
    }

    std::panic::set_hook(Box::new(|info| {
        let report = format_report(info);

        // Try the crash log first. Ignore failures — at panic time there is no
        // meaningful recovery path.
        let _ = write_crash_log(&report);

        // Mirror to the main log so a single tail catches it, but don't depend
        // on it (the logger has its own mutex and could itself be poisoned).
        crate::logging::error("panic", &report);

        // And stderr, so `npm run tauri dev` shows the report inline.
        let _ = writeln!(std::io::stderr(), "{report}");
    }));
}

fn format_report(info: &std::panic::PanicHookInfo<'_>) -> String {
    let payload = panic_payload(info);
    let location = info
        .location()
        .map(|l| format!("{}:{}:{}", l.file(), l.line(), l.column()))
        .unwrap_or_else(|| "<unknown location>".to_string());
    let thread = std::thread::current()
        .name()
        .unwrap_or("<unnamed>")
        .to_string();
    let backtrace = Backtrace::force_capture();
    format!(
        "panic at {location}\n  thread: {thread}\n  payload: {payload}\n  backtrace:\n{backtrace}"
    )
}

fn panic_payload(info: &std::panic::PanicHookInfo<'_>) -> String {
    let p = info.payload();
    if let Some(s) = p.downcast_ref::<&str>() {
        (*s).to_string()
    } else if let Some(s) = p.downcast_ref::<String>() {
        s.clone()
    } else {
        format!("<non-string payload, type_id={:?}>", p.type_id())
    }
}

/// Resolve the crash-log directory without going through `kanban_data_dir()` —
/// that helper `.expect()`s on `dirs::data_dir()`, which would cause a recursive
/// panic in the very situation this hook exists to defend against. Fall back to
/// the system temp dir so we always have *somewhere* to write evidence.
fn crash_log_dir() -> PathBuf {
    let base = dirs::data_dir()
        .map(|d| d.join("kanban-code"))
        .unwrap_or_else(|| std::env::temp_dir().join("kanban-code"));
    base.join("logs")
}

fn write_crash_log(report: &str) -> std::io::Result<()> {
    let dir = crash_log_dir();
    fs::create_dir_all(&dir)?;
    let stamp = chrono::Local::now().format("%Y%m%d-%H%M%S-%3f");
    // PID-suffix the filename: two Kanban Code processes panicking in the same
    // millisecond would otherwise clobber each other's reports.
    let pid = std::process::id();
    let path = dir.join(format!("crash-{stamp}-{pid}.log"));
    let mut f = OpenOptions::new()
        .create_new(true)
        .write(true)
        .open(&path)?;
    writeln!(f, "Kanban Code crash report — {}", chrono::Local::now().to_rfc3339())?;
    writeln!(f, "version: {}", env!("CARGO_PKG_VERSION"))?;
    writeln!(f, "pid: {pid}")?;
    writeln!(f)?;
    f.write_all(report.as_bytes())?;
    f.write_all(b"\n")?;
    // Force a flush to the kernel before we return — std::process::abort() may
    // follow immediately and we want the bytes on disk, not in a libc buffer.
    f.sync_all()?;
    Ok(())
}
