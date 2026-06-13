use crate::activity_detector::{ActivityState, ActivityTracker};
use crate::assign_column::update_card_column;
use crate::card_reconciler::reconcile;
use crate::coordination_store::{CoordinationStore, Link};
use crate::git_worktree;
use crate::session_discovery::{Session, SessionDiscovery};
use crate::settings_store::SettingsStore;
use anyhow::Result;
use chrono::{DateTime, Utc};
use serde::{Deserialize, Serialize};
use std::collections::HashMap;

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct CardDto {
    pub id: String,
    pub link: Link,
    pub session: Option<Session>,
    pub activity_state: Option<String>,
    pub display_title: String,
    pub project_name: Option<String>,
    pub relative_time: String,
    pub show_spinner: bool,
}

#[derive(Debug, Clone, Serialize, Deserialize, Default)]
#[serde(rename_all = "camelCase")]
pub struct BoardStateDto {
    pub cards: Vec<CardDto>,
    pub last_refresh: Option<DateTime<Utc>>,
}

/// Suppress duplicate notifications for the same card if a previous one
/// fired within this window. Mirrors NotificationDeduplicator.swift on Mac
/// (62 s — slightly longer than the activity poll cadence so a flapping
/// session that ping-pongs activelyWorking↔needsAttention can't spam).
const NOTIFICATION_DEDUP_SECS: i64 = 62;

#[derive(Debug, Default)]
pub struct BoardState {
    pub cards: Vec<CardDto>,
    pub last_refresh: Option<DateTime<Utc>>,
    /// Previous activity state per card id, used to detect transitions
    prev_activity: HashMap<String, String>,
    /// Wall-clock time we last emitted a notification for each card, used to
    /// suppress repeats within NOTIFICATION_DEDUP_SECS.
    last_notified_at: HashMap<String, DateTime<Utc>>,
    /// Tracks JSONL mtime changes across polls to detect active vs stopped
    activity_tracker: ActivityTracker,
}

impl BoardState {
    /// Refresh board state: discover sessions, load links, reconcile, assign columns.
    pub async fn refresh(
        &mut self,
        discovery: &SessionDiscovery,
        store: &CoordinationStore,
        _settings: &SettingsStore,
    ) -> Result<()> {
        let sessions = discovery.discover_sessions().await?;
        let existing_links = store.read_links().await?;

        // --- Reconcile: merge sessions into links without duplicates ---
        let mut all_links = reconcile(existing_links.clone(), sessions.clone());

        // --- Backfill worktree paths from `git worktree list` ---
        // Cards with a branch but a missing/empty path get matched against
        // the project's actual worktrees so the UI can show the real on-disk
        // location and the cleanup-from-Done flow has something to operate on.
        backfill_worktree_paths(&mut all_links).await;

        // --- Detect activity once per session, cache results ---
        let sessions_by_id: HashMap<String, Session> =
            sessions.into_iter().map(|s| (s.id.clone(), s)).collect();

        let mut activity_map: HashMap<String, ActivityState> = HashMap::new();
        for link in &all_links {
            if let Some(path) = link
                .session_link
                .as_ref()
                .and_then(|sl| sl.session_path.as_deref())
            {
                activity_map
                    .entry(link.id.clone())
                    .or_insert_with(|| self.activity_tracker.detect(path));
            }
        }

        // --- Assign columns using cached activity ---
        for link in &mut all_links {
            let activity = activity_map.get(&link.id);
            let has_worktree = link
                .worktree_link
                .as_ref()
                .map(|wl| !wl.path.is_empty())
                .unwrap_or(false);

            update_card_column(link, activity, has_worktree);
        }

        // --- Always persist — column changes must be written back ---
        let old_map: HashMap<String, &Link> =
            existing_links.iter().map(|l| (l.id.clone(), l)).collect();
        let has_changes = all_links.len() != existing_links.len()
            || all_links.iter().any(|l| {
                old_map
                    .get(&l.id)
                    .map(|old| old.column != l.column || old.updated_at != l.updated_at)
                    .unwrap_or(true)
            });
        if has_changes {
            let _ = store.write_links(&all_links).await;
        }

        // --- Build CardDtos using cached activity ---
        let mut cards = Vec::new();
        for link in &all_links {
            let session = link
                .session_link
                .as_ref()
                .and_then(|sl| sessions_by_id.get(&sl.session_id))
                .cloned();

            let activity = activity_map.get(&link.id);
            let activity_str = activity.map(ActivityState::as_str);

            let display_title = if let Some(name) = &link.name {
                if !name.is_empty() {
                    name.clone()
                } else {
                    link.display_title()
                }
            } else if let Some(s) = &session {
                s.display_title()
            } else {
                link.display_title()
            };

            let project_name = link
                .project_path
                .as_deref()
                .or_else(|| session.as_ref().and_then(|s| s.project_path.as_deref()))
                .and_then(|p| std::path::Path::new(p).file_name())
                .and_then(|n| n.to_str())
                .map(|s| s.to_string());

            let relative_time =
                format_relative_time(link.last_activity.unwrap_or(link.updated_at));

            let show_spinner = activity == Some(&ActivityState::ActivelyWorking)
                || link.is_launching == Some(true);

            cards.push(CardDto {
                id: link.id.clone(),
                link: link.clone(),
                session,
                activity_state: activity_str.map(|s| s.to_string()),
                display_title,
                project_name,
                relative_time,
                show_spinner,
            });
        }

        self.cards = cards;
        self.last_refresh = Some(Utc::now());
        Ok(())
    }

    pub fn to_dto(&self) -> BoardStateDto {
        BoardStateDto {
            cards: self.cards.clone(),
            last_refresh: self.last_refresh,
        }
    }

    /// Returns cards that just transitioned to NeedsAttention (Claude finished a turn).
    /// Should be called after `refresh()` to drive OS notifications.
    ///
    /// Applies a per-card dedup window: a card that already fired a
    /// notification within the last `NOTIFICATION_DEDUP_SECS` is skipped.
    /// This prevents a flapping activity detector from spamming the user
    /// when the JSONL mtime briefly flips back-and-forth.
    pub fn drain_notification_candidates(&mut self) -> Vec<CardDto> {
        let now = Utc::now();
        let mut notify = Vec::new();
        let mut new_states: HashMap<String, String> = HashMap::new();

        for card in &self.cards {
            let current = card.activity_state.as_deref().unwrap_or("").to_string();
            new_states.insert(card.id.clone(), current.clone());

            let prev = self.prev_activity.get(&card.id).map(|s| s.as_str()).unwrap_or("");

            // Notify when Claude just stopped working and needs the user's attention
            if current == "needsAttention" && prev == "activelyWorking" {
                let last = self.last_notified_at.get(&card.id).copied();
                let suppressed = last
                    .map(|t| (now - t).num_seconds() < NOTIFICATION_DEDUP_SECS)
                    .unwrap_or(false);
                if !suppressed {
                    self.last_notified_at.insert(card.id.clone(), now);
                    notify.push(card.clone());
                }
            }
        }

        self.prev_activity = new_states;
        notify
    }
}

/// Match each card's worktree_link.branch against the actual git worktrees
/// in its project, filling in `worktree_link.path` when missing. Skips cards
/// without a project_path or without a branch; bails on git failures (no
/// worktree info isn't fatal). Worktrees are listed at most once per
/// project_root so the polling loop doesn't fork git N times for one repo.
async fn backfill_worktree_paths(links: &mut [Link]) {
    use std::collections::HashMap;

    let project_roots: std::collections::HashSet<String> = links
        .iter()
        .filter_map(|l| l.project_path.clone())
        .collect();

    let mut worktrees_by_root: HashMap<String, Vec<git_worktree::Worktree>> = HashMap::new();
    for root in project_roots {
        if let Ok(list) = git_worktree::list_worktrees(&root).await {
            worktrees_by_root.insert(root, list);
        }
    }

    for link in links.iter_mut() {
        let Some(project) = link.project_path.as_deref() else { continue };
        let Some(wt) = link.worktree_link.as_mut() else { continue };
        let Some(branch) = wt.branch.as_deref() else { continue };
        if !wt.path.is_empty() {
            continue;
        }
        if let Some(matches) = worktrees_by_root.get(project) {
            if let Some(found) = matches.iter().find(|w| w.branch.as_deref() == Some(branch)) {
                wt.path = found.path.clone();
            }
        }
    }
}

fn format_relative_time(date: DateTime<Utc>) -> String {
    let secs = (Utc::now() - date).num_seconds();
    if secs < 60 {
        return "just now".to_string();
    }
    if secs < 3600 {
        return format!("{}m ago", secs / 60);
    }
    if secs < 86400 {
        return format!("{}h ago", secs / 3600);
    }
    let days = secs / 86400;
    if days == 1 {
        return "yesterday".to_string();
    }
    if days < 30 {
        return format!("{}d ago", days);
    }
    format!("{}mo ago", days / 30)
}
