mod activity_detector;
mod assign_column;
mod bm25;
mod board_state;
mod card_reconciler;
mod coding_assistant;
pub mod crash_handler;
mod coordination_store;
mod gh_cli;
mod git_remote;
mod git_worktree;
mod hook_event_store;
mod hook_manager;
mod jsonl_parser;
mod ksuid;
mod logging;
mod merge_ops;
mod mutagen;
mod pushover;
mod remote_shell;
mod remote_status;
mod session_ops;
mod session_discovery;
mod session_mover;
mod settings_store;
mod shell_command;
mod tmux;
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
async fn reorder_cards(
    ordered_ids: Vec<String>,
    state: tauri::State<'_, AppState>,
) -> Result<(), String> {
    state
        .coordination_store
        .reorder_cards(&ordered_ids)
        .await
        .map_err(|e| e.to_string())
}

#[tauri::command]
async fn create_card(
    prompt: String,
    title: Option<String>,
    project: String,
    launch: Option<bool>,
    assistant_id: Option<String>,
    state: tauri::State<'_, AppState>,
) -> Result<coordination_store::Link, String> {
    let assistant = assistant_id
        .as_deref()
        .and_then(coding_assistant::AssistantId::from_str)
        .unwrap_or_default()
        .as_str()
        .to_string();
    let link = state
        .coordination_store
        .create_card(prompt.clone(), title, project.clone(), assistant)
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

    let q = query.trim();
    if q.is_empty() {
        return Ok(sessions.into_iter().take(20).collect());
    }

    // Tokenize the query once. If nothing left after dropping <2-char tokens,
    // fall back to the cheap substring filter so the user still gets *some*
    // result for queries like "a" or "C++".
    let terms = bm25::tokenize(q);
    if terms.is_empty() {
        let q_lower = q.to_lowercase();
        return Ok(sessions
            .into_iter()
            .filter(|s| {
                s.id.to_lowercase().contains(&q_lower)
                    || s.first_prompt.as_deref().unwrap_or("").to_lowercase().contains(&q_lower)
                    || s.project_path.as_deref().unwrap_or("").to_lowercase().contains(&q_lower)
            })
            .take(20)
            .collect());
    }

    // Read every .jsonl once. Tokenize on the raw text — JSON keys repeat
    // across every session so their IDF goes to zero and they don't bias
    // ranking. Much cheaper than properly parsing every line.
    let mut docs: Vec<(usize, Vec<String>, i64)> = Vec::with_capacity(sessions.len());
    for (idx, s) in sessions.iter().enumerate() {
        let Some(path) = s.jsonl_path.as_deref() else { continue };
        let Ok(content) = tokio::fs::read_to_string(path).await else { continue };
        let tokens = bm25::tokenize(&content);
        if tokens.is_empty() {
            continue;
        }
        // Age in seconds from now → recency boost. session.modified_time is
        // already DateTime<Utc> from the discovery layer.
        let age_secs = (chrono::Utc::now() - s.modified_time).num_seconds();
        docs.push((idx, tokens, age_secs));
    }
    if docs.is_empty() {
        return Ok(vec![]);
    }

    // Corpus stats.
    let doc_count = docs.len();
    let avg_doc_length =
        docs.iter().map(|(_, t, _)| t.len() as f64).sum::<f64>() / doc_count as f64;
    let mut doc_freqs: std::collections::HashMap<String, usize> = std::collections::HashMap::new();
    for (_, tokens, _) in &docs {
        let unique: std::collections::HashSet<&String> = tokens.iter().collect();
        for t in unique {
            *doc_freqs.entry(t.clone()).or_insert(0) += 1;
        }
    }

    // Score each doc; keep top 20 by descending score.
    let mut scored: Vec<(f64, &session_discovery::Session)> = docs
        .iter()
        .filter_map(|(idx, tokens, age)| {
            let boost = bm25::recency_boost(*age);
            let s = bm25::score(&terms, tokens, avg_doc_length, doc_count, &doc_freqs, boost);
            if s > 0.0 {
                Some((s, &sessions[*idx]))
            } else {
                None
            }
        })
        .collect();
    scored.sort_by(|a, b| b.0.partial_cmp(&a.0).unwrap_or(std::cmp::Ordering::Equal));
    Ok(scored.into_iter().take(20).map(|(_, s)| s.clone()).collect())
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
    #[cfg(target_os = "linux")]
    {
        let home = std::env::var("HOME").unwrap_or_default();
        let direct_paths = vec![
            format!("{}/.local/bin/{}", home, name),
            format!("/usr/local/bin/{}", name),
            format!("/usr/bin/{}", name),
        ];
        for path in &direct_paths {
            if std::path::Path::new(path).exists() {
                return true;
            }
        }
        let nvm_versions = format!("{}/.nvm/versions/node", home);
        if let Ok(entries) = std::fs::read_dir(&nvm_versions) {
            for entry in entries.flatten() {
                let bin = entry.path().join("bin").join(name);
                if bin.exists() {
                    return true;
                }
            }
        }
    }
    tokio::process::Command::new(if cfg!(target_os = "windows") { "where" } else { "which" })
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
async fn discover_projects(state: tauri::State<'_, AppState>) -> Result<Vec<String>, String> {
    // Project discovery for the Settings UI suggestions: walk every session
    // discovered so far, collect unique project_path values, return sorted.
    // The Settings UI filters out paths already configured.
    let sessions = state
        .session_discovery
        .discover_sessions()
        .await
        .map_err(|e| e.to_string())?;
    let mut seen: std::collections::BTreeSet<String> = std::collections::BTreeSet::new();
    for s in sessions {
        if let Some(p) = s.project_path {
            if !p.is_empty() {
                seen.insert(p);
            }
        }
    }
    Ok(seen.into_iter().collect())
}

#[tauri::command]
async fn fork_session(session_path: String, target_dir: Option<String>) -> Result<String, String> {
    session_ops::fork_session(&session_path, target_dir.as_deref())
        .await
        .map_err(|e| e.to_string())
}

#[tauri::command]
async fn truncate_session(session_path: String, turn_count: usize) -> Result<(), String> {
    session_ops::truncate_session(&session_path, turn_count)
        .await
        .map_err(|e| e.to_string())
}

/// Merge `source_card_id` into `target_card_id`. Source is deleted; target
/// absorbs source's optional fields per the rules in [`merge_ops`].
///
/// No undo. Callers should confirm intent before invoking.
#[tauri::command]
async fn merge_cards(
    source_card_id: String,
    target_card_id: String,
    state: tauri::State<'_, AppState>,
) -> Result<(), String> {
    let mut links = state
        .coordination_store
        .read_links()
        .await
        .map_err(|e| e.to_string())?;

    let source_idx = links
        .iter()
        .position(|l| l.id == source_card_id)
        .ok_or_else(|| format!("source card {source_card_id} not found"))?;
    let target_idx = links
        .iter()
        .position(|l| l.id == target_card_id)
        .ok_or_else(|| format!("target card {target_card_id} not found"))?;

    if let Some(reason) = merge_ops::merge_blocked(&links[source_idx], &links[target_idx]) {
        return Err(reason);
    }

    // Snapshot source. Then mutate target in-place and drop source.
    let source = links[source_idx].clone();

    // If source has queued prompts the user might lose, log them.
    if let Some(prompts) = &source.queued_prompts {
        if !prompts.is_empty() {
            logging::warn(
                "merge",
                &format!(
                    "dropping {} queued prompt(s) from source card {}",
                    prompts.len(),
                    &source.id
                ),
            );
        }
    }

    merge_ops::merge_into_target(&source, &mut links[target_idx]);

    // Remove source (do this AFTER mutating target since target_idx > source_idx
    // would shift; use retain to avoid index bookkeeping).
    let source_id = source.id.clone();
    links.retain(|l| l.id != source_id);

    state
        .coordination_store
        .write_links(&links)
        .await
        .map_err(|e| e.to_string())?;

    logging::info(
        "merge",
        &format!(
            "merged {} → {}",
            short_id(&source_card_id),
            short_id(&target_card_id)
        ),
    );

    Ok(())
}

fn short_id(id: &str) -> String {
    id.chars().take(8).collect()
}

#[tauri::command]
async fn move_card_to_project(
    card_id: String,
    target_project_path: String,
    state: tauri::State<'_, AppState>,
) -> Result<(), String> {
    let mut links = state
        .coordination_store
        .read_links()
        .await
        .map_err(|e| e.to_string())?;

    let idx = links
        .iter()
        .position(|l| l.id == card_id)
        .ok_or_else(|| format!("card {card_id} not found"))?;

    let (session_id, session_path) = match links[idx].session_link.as_ref() {
        Some(sl) => (sl.session_id.clone(), sl.session_path.clone()),
        None => (String::new(), None),
    };

    // If the card has a session jsonl, rewrite it into the target project's
    // encoded directory and update `cwd` in every line so macOS/CLI find it.
    let new_session_path = if let Some(path) = session_path {
        if !session_id.is_empty() {
            match session_mover::move_session(&session_id, &path, &target_project_path).await {
                Ok(new_path) => Some(new_path),
                Err(e) => {
                    logging::warn(
                        "move-card",
                        &format!("failed to move session jsonl for {card_id}: {e}"),
                    );
                    // Continue anyway — the link metadata still gets updated.
                    None
                }
            }
        } else {
            None
        }
    } else {
        None
    };

    let link = &mut links[idx];
    link.project_path = Some(target_project_path);
    if let (Some(sl), Some(new_path)) = (link.session_link.as_mut(), new_session_path) {
        sl.session_path = Some(new_path);
    }
    link.updated_at = chrono::Utc::now();

    state
        .coordination_store
        .write_links(&links)
        .await
        .map_err(|e| e.to_string())
}

#[tauri::command]
async fn list_worktrees(repo_root: String) -> Result<Vec<git_worktree::Worktree>, String> {
    git_worktree::list_worktrees(&repo_root)
        .await
        .map_err(|e| e.to_string())
}

#[tauri::command]
async fn create_worktree(repo_root: String, name: String) -> Result<git_worktree::Worktree, String> {
    git_worktree::create_worktree(&repo_root, &name)
        .await
        .map_err(|e| e.to_string())
}

#[tauri::command]
async fn remove_worktree(path: String, repo_root: Option<String>, force: bool) -> Result<(), String> {
    git_worktree::remove_worktree(&path, repo_root.as_deref(), force)
        .await
        .map_err(|e| e.to_string())
}

#[tauri::command]
async fn merge_pr(
    project_path: String,
    number: i64,
    state: tauri::State<'_, AppState>,
) -> Result<String, String> {
    // Look up the user-configured merge template
    // (Settings → GitHub → Merge command, e.g.
    //  "gh pr merge ${number} --squash --delete-branch").
    let template = state
        .settings_store
        .read()
        .await
        .map(|s| s.github.merge_command.clone())
        .map_err(|e| e.to_string())?;
    let command = template.replace("${number}", &number.to_string());
    if command.trim().is_empty() {
        return Err("merge command template is empty".to_string());
    }

    logging::info("merge-pr", &format!("running `{command}` in {project_path}"));

    // Use the platform shell so users can write whatever template they want
    // (pipes, &&, --flag args). Same shape as macOS LaunchSession.
    #[cfg(target_os = "windows")]
    let output = tokio::process::Command::new("cmd")
        .args(["/c", &command])
        .current_dir(&project_path)
        .output()
        .await
        .map_err(|e| format!("spawn merge command: {e}"))?;
    #[cfg(not(target_os = "windows"))]
    let output = tokio::process::Command::new("sh")
        .args(["-c", &command])
        .current_dir(&project_path)
        .output()
        .await
        .map_err(|e| format!("spawn merge command: {e}"))?;

    let stdout = String::from_utf8_lossy(&output.stdout).into_owned();
    let stderr = String::from_utf8_lossy(&output.stderr).into_owned();

    if !output.status.success() {
        logging::warn(
            "merge-pr",
            &format!("merge failed (exit {:?}): {stderr}", output.status.code()),
        );
        let msg = if !stderr.trim().is_empty() {
            stderr.trim().to_string()
        } else if !stdout.trim().is_empty() {
            stdout.trim().to_string()
        } else {
            format!("merge exited with status {:?}", output.status.code())
        };
        return Err(msg);
    }

    Ok(if !stdout.trim().is_empty() {
        stdout.trim().to_string()
    } else {
        format!("Merged PR #{number}")
    })
}

#[tauri::command]
async fn resolve_github_base_url(project_path: String) -> Result<Option<String>, String> {
    Ok(git_remote::github_base_url(&project_path).await)
}

#[tauri::command]
async fn open_github_pr(project_path: String, number: i64) -> Result<(), String> {
    let base = git_remote::github_base_url(&project_path)
        .await
        .ok_or_else(|| format!("no GitHub remote for {project_path}"))?;
    shell_command::open_url(&git_remote::pr_url(&base, number)).await
        .map_err(|e| e.to_string())
}

#[tauri::command]
async fn open_github_issue(project_path: String, number: i64) -> Result<(), String> {
    let base = git_remote::github_base_url(&project_path)
        .await
        .ok_or_else(|| format!("no GitHub remote for {project_path}"))?;
    shell_command::open_url(&git_remote::issue_url(&base, number)).await
        .map_err(|e| e.to_string())
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
            let refresh_result = bs
                .refresh(
                    &state.session_discovery,
                    &state.coordination_store,
                    &state.settings_store,
                )
                .await;
            if let Err(e) = &refresh_result {
                logging::warn("poll", &format!("board refresh failed: {e}"));
            }
            if refresh_result.is_ok() {
                let notify_cards = bs.drain_notification_candidates();
                let dto = bs.to_dto();
                drop(bs);
                let _ = app.emit("board-updated", dto);

                // Send OS notifications for cards where Claude just finished a turn
                if !notify_cards.is_empty() {
                    let settings = state.settings_store.read().await.ok();
                    let os_enabled = settings
                        .as_ref()
                        .map(|s| s.notifications.notifications_enabled)
                        .unwrap_or(true);
                    let push_cfg = settings.and_then(|s| {
                        if s.notifications.pushover_enabled {
                            Some((
                                s.notifications.pushover_token.clone(),
                                s.notifications.pushover_user_key.clone(),
                            ))
                        } else {
                            None
                        }
                    });

                    if os_enabled || push_cfg.is_some() {
                        logging::info(
                            "notify",
                            &format!("dispatching {} notification(s)", notify_cards.len()),
                        );
                    }

                    for card in notify_cards {
                        let title = card.display_title.clone();
                        // Prefer the last assistant message as the body so
                        // the notification actually says something useful
                        // (matches macOS TranscriptNotificationReader).
                        // Fall back to a generic prompt when the JSONL
                        // can't be read or the turn has no text content.
                        let body = match card
                            .link
                            .session_link
                            .as_ref()
                            .and_then(|sl| sl.session_path.clone())
                        {
                            Some(p) => transcript_reader::read_last_assistant_message(&p, 240)
                                .await
                                .unwrap_or_else(|| {
                                    "Claude finished — your input is needed.".to_string()
                                }),
                            None => "Claude finished — your input is needed.".to_string(),
                        };

                        if os_enabled {
                            let _ = app
                                .notification()
                                .builder()
                                .title(title.clone())
                                .body(body.clone())
                                .show();
                        }
                        if let Some((Some(token), Some(user))) = push_cfg.as_ref().map(|(t, u)| (t.clone(), u.clone())) {
                            // Fire-and-forget — Pushover is best-effort and
                            // shouldn't block the polling loop on network I/O.
                            let card_id = card.id.clone();
                            let t = title.clone();
                            let b = body.clone();
                            tokio::spawn(async move {
                                match pushover::send(&token, &user, &t, &b, Some(&card_id)).await {
                                    Ok(()) => logging::info(
                                        "pushover",
                                        &format!("sent for card {card_id}"),
                                    ),
                                    Err(e) => logging::warn(
                                        "pushover",
                                        &format!("send failed for card {card_id}: {e}"),
                                    ),
                                }
                            });
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
                        // Batch one GraphQL query per repo for unresolved-thread
                        // counts. Empty map on any failure → field stays None.
                        let threads = gh_cli::fetch_unresolved_threads(&prs).await;
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
                                        body: pr.body.clone(),
                                        approval_count: pr.approval_count,
                                        unresolved_threads: threads.get(&pr.number).copied(),
                                        merge_state_status: pr.merge_state_status.clone(),
                                        review_decision: pr.review_decision.clone(),
                                        check_runs: pr.check_runs
                                            .iter()
                                            .map(|cr| coordination_store::PrCheckRun {
                                                name: cr.name.clone(),
                                                conclusion: cr.conclusion.clone(),
                                            })
                                            .collect(),
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
                    if let Err(e) = state.coordination_store.write_links(&updated_links).await {
                        logging::error("pr-poll", &format!("failed to write links: {e}"));
                    }
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
                            if let Err(e) = state
                                .coordination_store
                                .write_links(&links_to_update)
                                .await
                            {
                                logging::error("issue-poll", &format!("failed to write links: {e}"));
                            }
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

/// Install the WSL-side hook script + tail `hook-events.jsonl`, re-emitting
/// each parsed event over the Tauri event bus as `"hook-event"`. The
/// frontend listens for these to drive activity detection and queued-prompt
/// auto-send (Phase 3 step 5). Polls at 1s — events are bursty but small.
fn start_hook_polling(app: tauri::AppHandle) {
    tauri::async_runtime::spawn(async move {
        // Install asynchronously so a slow WSL boot doesn't block startup.
        let state = app.state::<AppState>();
        match hook_manager::install_if_needed(&state.settings_store).await {
            Ok(true) => {}
            Ok(false) => return, // intentionally skipped — no tail loop
            Err(e) => {
                logging::warn("hooks", &format!("install failed: {} — tail loop will still run", e));
            }
        }
        drop(state);

        let store = std::sync::Arc::new(hook_event_store::HookEventStore::new());
        store.touch();
        // On boot we don't want to re-fire historical events left over from a
        // previous run — jump straight to the tail.
        store.skip_to_tail();

        loop {
            tokio::time::sleep(tokio::time::Duration::from_secs(1)).await;
            let store = std::sync::Arc::clone(&store);
            let events = match tokio::task::spawn_blocking(move || store.read_new_events()).await {
                Ok(ev) => ev,
                Err(e) => {
                    logging::warn("hooks", &format!("blocking read panic: {}", e));
                    continue;
                }
            };
            for ev in events {
                logging::debug(
                    "hooks",
                    &format!(
                        "event session={} name={} at={}",
                        ev.session_id, ev.event_name, ev.timestamp
                    ),
                );
                if let Err(e) = app.emit("hook-event", &ev) {
                    logging::warn("hooks", &format!("emit failed: {}", e));
                }
            }
        }
    });
}


// ── Remote / sync commands (Phase 5) ─────────────────────────────────────────

#[tauri::command]
async fn remote_prereqs() -> Result<remote_shell::RemotePrereqs, String> {
    Ok(remote_shell::prereqs())
}

#[tauri::command]
async fn remote_deploy_shell() -> Result<(), String> {
    remote_shell::deploy().await.map_err(|e| e.to_string())
}

#[tauri::command]
async fn mutagen_status() -> Result<mutagen::SyncStatus, String> {
    Ok(mutagen::status().await)
}

#[tauri::command]
async fn mutagen_raw_status() -> Result<String, String> {
    mutagen::raw_status().await.map_err(|e| e.to_string())
}

#[tauri::command]
async fn mutagen_start(
    state: tauri::State<'_, AppState>,
) -> Result<(), String> {
    let settings = state.settings_store.read().await.map_err(|e| e.to_string())?;
    let Some(remote) = settings.remote.as_ref() else {
        return Err("Remote settings not configured".to_string());
    };
    if remote.host.is_empty() || remote.remote_path.is_empty() || remote.local_path.is_empty() {
        return Err("Remote host / remotePath / localPath must all be set".to_string());
    }
    let ignores = remote
        .sync_ignores
        .clone()
        .unwrap_or_else(mutagen::default_ignores);

    mutagen::ensure_daemon().await;
    mutagen::start_sync(&remote.local_path, &remote.host, &remote.remote_path, &ignores)
        .await
        .map_err(|e| e.to_string())
}

#[tauri::command]
async fn mutagen_stop() -> Result<(), String> {
    mutagen::stop_sync().await.map_err(|e| e.to_string())
}

#[tauri::command]
async fn mutagen_reset() -> Result<(), String> {
    mutagen::reset_sync().await.map_err(|e| e.to_string())
}

#[tauri::command]
async fn mutagen_flush() -> Result<(), String> {
    mutagen::flush_sync().await.map_err(|e| e.to_string())
}

fn start_remote_polling(app: tauri::AppHandle) {
    tauri::async_runtime::spawn(async move {
        let watcher = remote_status::RemoteStatusWatcher::new();
        let _ = tokio::fs::create_dir_all(watcher.state_dir()).await;
        let mut interval = tokio::time::interval(tokio::time::Duration::from_secs(5));
        let mut last_status: Option<mutagen::SyncStatus> = None;
        loop {
            interval.tick().await;

            let status = mutagen::status().await;
            let changed = match (&last_status, &status) {
                (Some(prev), curr) => prev.kind != curr.kind || prev.conflict_count != curr.conflict_count,
                (None, _) => true,
            };
            if changed {
                let _ = app.emit("sync_status_event", &status);
                last_status = Some(status);
            }

            for change in watcher.poll().await {
                let _ = app.emit("remote_status_changed", &change);
            }
        }
    });
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
            reorder_cards,
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
            resolve_github_base_url,
            open_github_pr,
            open_github_issue,
            merge_pr,
            list_worktrees,
            create_worktree,
            remove_worktree,
            fork_session,
            truncate_session,
            discover_projects,
            tmux::tmux_available,
            tmux::tmux_ensure_session,
            tmux::tmux_send_prompt,
            tmux::tmux_paste,
            tmux::tmux_capture,
            tmux::tmux_kill_session,
            tmux::tmux_new_window,
            tmux::tmux_kill_window,
            tmux::tmux_list_windows,
            move_card_to_project,
            merge_cards,
            remote_prereqs,
            remote_deploy_shell,
            mutagen_status,
            mutagen_raw_status,
            mutagen_start,
            mutagen_stop,
            mutagen_reset,
            mutagen_flush,
        ])
        .setup(|app| {
            logging::info(
                "startup",
                &format!(
                    "Kanban Code (Windows) v{} starting; data dir: {}",
                    env!("CARGO_PKG_VERSION"),
                    coordination_store::kanban_data_dir().display()
                ),
            );
            build_tray(app)?;
            start_polling(app.handle().clone());
            start_pr_polling(app.handle().clone());
            start_issue_polling(app.handle().clone());
            start_hook_polling(app.handle().clone());
            start_remote_polling(app.handle().clone());

            // Deploy the remote-shell wrapper at startup (idempotent).
            tauri::async_runtime::spawn(async {
                if let Err(e) = remote_shell::deploy().await {
                    logging::warn("startup", &format!("remote-shell deploy failed: {e}"));
                }
            });
            Ok(())
        })
        .run(tauri::generate_context!())
        .expect("error while running tauri application");
}
