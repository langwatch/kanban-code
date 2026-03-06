mod activity_detector;
mod board_state;
mod coordination_store;
mod gh_cli;
mod git_worktree;
mod jsonl_parser;
mod session_discovery;
mod settings_store;
mod shell_command;
mod transcript_reader;

use board_state::BoardState;
use coordination_store::CoordinationStore;
use session_discovery::SessionDiscovery;
use settings_store::SettingsStore;

use std::sync::Arc;
use tauri::{
    menu::{Menu, MenuItem},
    tray::{MouseButton, MouseButtonState, TrayIconBuilder, TrayIconEvent},
    Emitter, Manager,
};
use tokio::sync::Mutex;

pub struct AppState {
    pub board_state: Arc<Mutex<BoardState>>,
    pub coordination_store: Arc<CoordinationStore>,
    pub settings_store: Arc<SettingsStore>,
    pub session_discovery: Arc<SessionDiscovery>,
}

// ── Tauri Commands ───────────────────────────────────────────────────────────

#[tauri::command]
async fn get_board_state(
    state: tauri::State<'_, AppState>,
) -> Result<board_state::BoardStateDto, String> {
    let mut bs = state.board_state.lock().await;
    bs.refresh(
        &state.session_discovery,
        &state.coordination_store,
        &state.settings_store,
    )
    .await
    .map_err(|e| e.to_string())?;
    Ok(bs.to_dto())
}

#[tauri::command]
async fn move_card(
    card_id: String,
    column: String,
    state: tauri::State<'_, AppState>,
) -> Result<(), String> {
    state
        .coordination_store
        .move_card(&card_id, &column)
        .await
        .map_err(|e| e.to_string())
}

#[tauri::command]
async fn create_card(
    prompt: String,
    title: Option<String>,
    project: String,
    state: tauri::State<'_, AppState>,
) -> Result<coordination_store::Link, String> {
    state
        .coordination_store
        .create_card(prompt, title, project)
        .await
        .map_err(|e| e.to_string())
}

#[tauri::command]
async fn delete_card(
    card_id: String,
    state: tauri::State<'_, AppState>,
) -> Result<(), String> {
    state
        .coordination_store
        .remove_link(&card_id)
        .await
        .map_err(|e| e.to_string())
}

#[tauri::command]
async fn archive_card(
    card_id: String,
    state: tauri::State<'_, AppState>,
) -> Result<(), String> {
    state
        .coordination_store
        .archive_link(&card_id)
        .await
        .map_err(|e| e.to_string())
}

#[tauri::command]
async fn rename_card(
    card_id: String,
    name: String,
    state: tauri::State<'_, AppState>,
) -> Result<(), String> {
    state
        .coordination_store
        .rename_link(&card_id, &name)
        .await
        .map_err(|e| e.to_string())
}

#[tauri::command]
async fn get_transcript(
    session_id: String,
    offset: usize,
    state: tauri::State<'_, AppState>,
) -> Result<transcript_reader::TranscriptPage, String> {
    let links = state
        .coordination_store
        .read_links()
        .await
        .map_err(|e| e.to_string())?;
    let session_path = links
        .iter()
        .find(|l| l.session_link.as_ref().map(|s| &s.session_id) == Some(&session_id))
        .and_then(|l| l.session_link.as_ref())
        .and_then(|s| s.session_path.clone());

    let path = match session_path {
        Some(p) => p,
        None => {
            // Fall back to discovery
            let sessions = state
                .session_discovery
                .discover_sessions()
                .await
                .map_err(|e| e.to_string())?;
            sessions
                .iter()
                .find(|s| s.id == session_id)
                .and_then(|s| s.jsonl_path.clone())
                .ok_or_else(|| format!("Session {session_id} not found"))?
        }
    };

    transcript_reader::read_transcript(&path, offset)
        .await
        .map_err(|e| e.to_string())
}

#[tauri::command]
async fn get_settings(state: tauri::State<'_, AppState>) -> Result<settings_store::Settings, String> {
    state
        .settings_store
        .read()
        .await
        .map_err(|e| e.to_string())
}

#[tauri::command]
async fn save_settings(
    settings: settings_store::Settings,
    state: tauri::State<'_, AppState>,
) -> Result<(), String> {
    state
        .settings_store
        .write(&settings)
        .await
        .map_err(|e| e.to_string())
}

#[tauri::command]
async fn search_sessions(
    query: String,
    state: tauri::State<'_, AppState>,
) -> Result<Vec<session_discovery::Session>, String> {
    let sessions = state
        .session_discovery
        .discover_sessions()
        .await
        .map_err(|e| e.to_string())?;

    let q = query.to_lowercase();
    let results = sessions
        .into_iter()
        .filter(|s| {
            s.id.to_lowercase().contains(&q)
                || s.first_prompt.as_deref().unwrap_or("").to_lowercase().contains(&q)
                || s.project_path.as_deref().unwrap_or("").to_lowercase().contains(&q)
        })
        .take(20)
        .collect();

    Ok(results)
}

#[tauri::command]
async fn launch_session(session_id: String) -> Result<(), String> {
    shell_command::launch_claude_session(&session_id)
        .await
        .map_err(|e| e.to_string())
}

#[tauri::command]
async fn open_in_editor(path: String, editor: Option<String>) -> Result<(), String> {
    shell_command::open_in_editor(&path, editor.as_deref())
        .await
        .map_err(|e| e.to_string())
}

// ── Background polling ───────────────────────────────────────────────────────

fn start_polling(app: tauri::AppHandle) {
    tauri::async_runtime::spawn(async move {
        let mut interval = tokio::time::interval(tokio::time::Duration::from_secs(5));
        loop {
            interval.tick().await;
            let state = app.state::<AppState>();
            let mut bs = state.board_state.lock().await;
            if let Ok(()) = bs
                .refresh(
                    &state.session_discovery,
                    &state.coordination_store,
                    &state.settings_store,
                )
                .await
            {
                let dto = bs.to_dto();
                drop(bs);
                let _ = app.emit("board-updated", dto);
            }
        }
    });
}

// ── Tray menu ────────────────────────────────────────────────────────────────

fn build_tray(app: &tauri::App) -> tauri::Result<()> {
    let show = MenuItem::with_id(app, "show", "Open Kanban Code", true, None::<&str>)?;
    let quit = MenuItem::with_id(app, "quit", "Quit", true, None::<&str>)?;
    let menu = Menu::with_items(app, &[&show, &quit])?;

    TrayIconBuilder::new()
        .icon(app.default_window_icon().unwrap().clone())
        .menu(&menu)
        .show_menu_on_left_click(false)
        .on_menu_event(|app, event| match event.id.as_ref() {
            "show" => {
                if let Some(win) = app.get_webview_window("main") {
                    let _ = win.show();
                    let _ = win.set_focus();
                }
            }
            "quit" => app.exit(0),
            _ => {}
        })
        .on_tray_icon_event(|tray, event| {
            if let TrayIconEvent::Click {
                button: MouseButton::Left,
                button_state: MouseButtonState::Up,
                ..
            } = event
            {
                let app = tray.app_handle();
                if let Some(win) = app.get_webview_window("main") {
                    let _ = win.show();
                    let _ = win.set_focus();
                }
            }
        })
        .build(app)?;

    Ok(())
}

// ── Entry point ──────────────────────────────────────────────────────────────

#[cfg_attr(mobile, tauri::mobile_entry_point)]
pub fn run() {
    let coordination_store = Arc::new(CoordinationStore::new(None));
    let settings_store = Arc::new(SettingsStore::new(None));
    let session_discovery = Arc::new(SessionDiscovery::new(None));
    let board_state = Arc::new(Mutex::new(BoardState::default()));

    tauri::Builder::default()
        .plugin(tauri_plugin_notification::init())
        .plugin(tauri_plugin_shell::init())
        .manage(AppState {
            board_state,
            coordination_store,
            settings_store,
            session_discovery,
        })
        .invoke_handler(tauri::generate_handler![
            get_board_state,
            move_card,
            create_card,
            delete_card,
            archive_card,
            rename_card,
            get_transcript,
            get_settings,
            save_settings,
            search_sessions,
            launch_session,
            open_in_editor,
        ])
        .setup(|app| {
            build_tray(app)?;
            start_polling(app.handle().clone());
            Ok(())
        })
        .run(tauri::generate_context!())
        .expect("error while running tauri application");
}
