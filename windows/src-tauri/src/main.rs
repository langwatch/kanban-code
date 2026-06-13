// Prevents additional console window on Windows in release
#![cfg_attr(not(debug_assertions), windows_subsystem = "windows")]

fn main() {
    // Install the panic backstop first so a crash anywhere — including during
    // Tauri's own startup — writes a report to
    // `%APPDATA%\kanban-code\logs\crash-<timestamp>.log` before the process
    // aborts (release builds use `panic = "abort"`).
    kanban_code_lib::crash_handler::install();
    kanban_code_lib::run();
}
