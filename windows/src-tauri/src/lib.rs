mod activity_detector;
mod assign_column;
mod board_state;
mod card_reconciler;
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
use tauri_plugin_notification::NotificationExt;
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
    launch: Option<bool>,
    state: tauri::State<'_, AppState>,
) -> Result<coordination_store::Link, String> {
    let link = state
        .coordination_store
        .create_card(prompt.clone(), title, project.clone())
        .await
        .map_err(|e| e.to_string())?;

    // launch flag is handled client-side now — the frontend auto-selects
    // the card and starts the embedded terminal with `claude '<prompt>'`
    let _ = launch; // suppress unused warning

    Ok(link)
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

#[tauri::command]
async fn add_queued_prompt(
    card_id: String,
    body: String,
    send_automatically: bool,
    state: tauri::State<'_, AppState>,
) -> Result<coordination_store::QueuedPrompt, String> {
    let prompt = coordination_store::QueuedPrompt::new(body, send_automatically);
    state
        .coordination_store
        .add_queued_prompt(&card_id, prompt)
        .await
        .map_err(|e| e.to_string())
}

#[tauri::command]
async fn update_queued_prompt(
    card_id: String,
    prompt_id: String,
    body: String,
    send_automatically: bool,
    state: tauri::State<'_, AppState>,
) -> Result<(), String> {
    state
        .coordination_store
        .update_queued_prompt(&card_id, &prompt_id, &body, send_automatically)
        .await
        .map_err(|e| e.to_string())
}

#[tauri::command]
async fn remove_queued_prompt(
    card_id: String,
    prompt_id: String,
    state: tauri::State<'_, AppState>,
) -> Result<(), String> {
    state
        .coordination_store
        .remove_queued_prompt(&card_id, &prompt_id)
        .await
        .map_err(|e| e.to_string())
}

#[derive(serde::Serialize)]
#[serde(rename_all = "camelCase")]
struct DependencyStatus {
    claude_available: bool,
    git_available: bool,
    gh_available: bool,
    gh_authenticated: bool,
}

async fn command_exists(name: &str) -> bool {
    tokio::process::Command::new("where")
        .arg(name)
        .stdout(std::process::Stdio::null())
        .stderr(std::process::Stdio::null())
        .status()
        .await
        .map(|s| s.success())
        .unwrap_or(false)
}

async fn gh_is_authed() -> bool {
    tokio::process::Command::new("gh")
        .args(["auth", "status"])
        .stdout(std::process::Stdio::null())
        .stderr(std::process::Stdio::null())
        .status()
        .await
        .map(|s| s.success())
        .unwrap_or(false)
}

#[tauri::command]
async fn check_dependencies() -> Result<DependencyStatus, String> {
    let (claude, git, gh) = tokio::join!(
        command_exists("claude"),
        command_exists("git"),
        command_exists("gh"),
    );
    let gh_auth = if gh { gh_is_authed().await } else { false };
    Ok(DependencyStatus {
        claude_available: claude,
        git_available: git,
        gh_available: gh,
        gh_authenticated: gh_auth,
    })
}

#[tauri::command]
async fn search_transcript(
    session_id: String,
    query: String,
    state: tauri::State<'_, AppState>,
) -> Result<Vec<usize>, String> {
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

    transcript_reader::search_transcript_turns(&path, &query)
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
                let notify_cards = bs.drain_notification_candidates();
                let dto = bs.to_dto();
                drop(bs);
                let _ = app.emit("board-updated", dto);

                // Send OS notifications for cards where Claude just finished a turn
                if !notify_cards.is_empty() {
                    let settings_ok = state
                        .settings_store
                        .read()
                        .await
                        .map(|s| s.notifications.notifications_enabled)
                        .unwrap_or(true);
                    if settings_ok {
                        for card in notify_cards {
                            let title = card.display_title.clone();
                            let body = "Claude finished — your input is needed.".to_string();
                            let _ = app.notification().builder().title(title).body(body).show();
                        }
                    }
                }
            }
        }
    });
}

// ── PR polling ───────────────────────────────────────────────────────────────

fn start_pr_polling(app: tauri::AppHandle) {
    tauri::async_runtime::spawn(async move {
        // Offset the first run by 15s so it doesn't hit at the same time as the
        // board polling startup
        tokio::time::sleep(tokio::time::Duration::from_secs(15)).await;
        let mut interval = tokio::time::interval(tokio::time::Duration::from_secs(60));
        loop {
            interval.tick().await;
            let state = app.state::<AppState>();
            if let Ok(links) = state.coordination_store.read_links().await {
                // Collect unique project paths that have a worktree branch
                let mut project_paths: Vec<String> = links
                    .iter()
                    .filter_map(|l| {
                        if l.worktree_link.as_ref().and_then(|wl| wl.branch.as_ref()).is_some() {
                            l.project_path.clone()
                        } else {
                            None
                        }
                    })
                    .collect::<std::collections::HashSet<_>>()
                    .into_iter()
                    .collect();
                project_paths.dedup();

                let mut changed = false;
                let mut updated_links = links.clone();

                for project in &project_paths {
                    if let Ok(prs) = gh_cli::fetch_prs(project).await {
                        for pr in &prs {
                            // Find card whose worktree branch matches this PR's head ref
                            for link in &mut updated_links {
                                if link
                                    .worktree_link
                                    .as_ref()
                                    .and_then(|wl| wl.branch.as_ref())
                                    .map(|b| b == &pr.head_ref)
                                    .unwrap_or(false)
                                {
                                    let pr_link = coordination_store::PrLink {
                                        number: pr.number,
                                        url: Some(pr.url.clone()),
                                        status: Some(pr.state.clone()),
                                        title: Some(pr.title.clone()),
                                        body: None,
                                        approval_count: None,
                                        unresolved_threads: None,
                                        merge_state_status: pr.merge_state_status.clone(),
                                    };
                                    // Update if number matches, otherwise add
                                    if let Some(existing) =
                                        link.pr_links.iter_mut().find(|p| p.number == pr.number)
                                    {
                                        *existing = pr_link;
                                    } else {
                                        link.pr_links.push(pr_link);
                                    }
                                    changed = true;
                                }
                            }
                        }
                    }
                }

                if changed {
                    let _ = state.coordination_store.write_links(&updated_links).await;
                    // Trigger a board refresh so the UI sees the new PR data
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
            }
        }
    });
}

// ── GitHub issue polling ─────────────────────────────────────────────────────

fn start_issue_polling(app: tauri::AppHandle) {
    tauri::async_runtime::spawn(async move {
        // Offset by 10s so it doesn't collide with board/PR polling startup
        tokio::time::sleep(tokio::time::Duration::from_secs(10)).await;

        loop {
            let state = app.state::<AppState>();
            let poll_secs = state
                .settings_store
                .read()
                .await
                .map(|s| s.github.poll_interval_seconds)
                .unwrap_or(60);

            let interval_duration = tokio::time::Duration::from_secs(poll_secs);

            if let Ok(settings) = state.settings_store.read().await {
                let default_filter = &settings.github.default_filter;
                let issue_template = &settings.github_issue_prompt_template;

                // Collect (project_path, filter) pairs
                let project_filters: Vec<(String, String)> = settings
                    .projects
                    .iter()
                    .filter_map(|p| {
                        let filter = p
                            .github_filter
                            .as_deref()
                            .unwrap_or(default_filter.as_str());
                        if filter.is_empty() {
                            return None;
                        }
                        let repo_root = p.repo_root.as_deref().unwrap_or(&p.path);
                        Some((repo_root.to_string(), filter.to_string()))
                    })
                    .collect();

                if !project_filters.is_empty() {
                    if let Ok(existing_links) = state.coordination_store.read_links().await {
                        let mut fetched_keys: std::collections::HashSet<String> =
                            std::collections::HashSet::new();
                        let mut changed = false;

                        for (repo_root, filter) in &project_filters {
                            if let Ok(issues) =
                                gh_cli::fetch_issues(repo_root, filter).await
                            {
                                for issue in &issues {
                                    let key = format!("{}:{}", repo_root, issue.number);
                                    fetched_keys.insert(key);

                                    // Check if card already exists for this issue + project
                                    let exists = existing_links.iter().any(|l| {
                                        l.issue_link
                                            .as_ref()
                                            .map(|il| il.number == issue.number)
                                            .unwrap_or(false)
                                            && l.project_path.as_deref() == Some(repo_root.as_str())
                                    });

                                    if !exists {
                                        // Build prompt from template
                                        let prompt = issue_template
                                            .replace("${number}", &issue.number.to_string())
                                            .replace("${title}", &issue.title)
                                            .replace(
                                                "${body}",
                                                issue.body.as_deref().unwrap_or(""),
                                            )
                                            .replace("${url}", &issue.url);

                                        let _ = state
                                            .coordination_store
                                            .create_issue_card(
                                                repo_root,
                                                issue.number,
                                                &issue.title,
                                                &issue.url,
                                                issue.body.as_deref(),
                                                &prompt,
                                            )
                                            .await;
                                        changed = true;
                                    }
                                }
                            }
                        }

                        // Remove stale issue cards: source=github_issue, column=backlog,
                        // project matches a configured project, but issue no longer in fetched set
                        let project_roots: std::collections::HashSet<&str> =
                            project_filters.iter().map(|(r, _)| r.as_str()).collect();

                        let mut links_to_update = existing_links.clone();
                        let before_len = links_to_update.len();
                        links_to_update.retain(|l| {
                            // Keep everything that isn't a stale github issue in backlog
                            if l.source != "github_issue" || l.column != "backlog" {
                                return true;
                            }
                            let proj = match l.project_path.as_deref() {
                                Some(p) => p,
                                None => return true,
                            };
                            if !project_roots.contains(proj) {
                                return true;
                            }
                            let issue_num = match l.issue_link.as_ref() {
                                Some(il) => il.number,
                                None => return true,
                            };
                            let key = format!("{}:{}", proj, issue_num);
                            fetched_keys.contains(&key)
                        });

                        if links_to_update.len() != before_len {
                            let _ = state
                                .coordination_store
                                .write_links(&links_to_update)
                                .await;
                            changed = true;
                        }

                        if changed {
                            // Refresh board so UI updates
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
                    }
                }
            }

            tokio::time::sleep(interval_duration).await;
        }
    });
}

// ── Tray menu ────────────────────────────────────────────────────────────────

fn build_tray(app: &tauri::App) -> tauri::Result<()> {
    let show = MenuItem::with_id(app, "show", "Open Kanban Code", true, None::<&str>)?;
    let quit = MenuItem::with_id(app, "quit", "Quit", true, None::<&str>)?;
    let menu = Menu::with_items(app, &[&show, &quit])?;

    let icon = app
        .default_window_icon()
        .cloned()
        .unwrap_or_else(|| tauri::image::Image::from_bytes(include_bytes!("../icons/32x32.png")).expect("bundled icon"));

    TrayIconBuilder::new()
        .icon(icon)
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
        .plugin(tauri_plugin_pty::init())
        .plugin(tauri_plugin_dialog::init())
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
            add_queued_prompt,
            update_queued_prompt,
            remove_queued_prompt,
            search_transcript,
            check_dependencies,
        ])
        .setup(|app| {
            build_tray(app)?;
            start_polling(app.handle().clone());
            start_pr_polling(app.handle().clone());
            start_issue_polling(app.handle().clone());
            Ok(())
        })
        .run(tauri::generate_context!())
        .expect("error while running tauri application");
}
