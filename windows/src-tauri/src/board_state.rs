use crate::activity_detector::{detect_activity, ActivityState};
use crate::coordination_store::{CoordinationStore, Link};
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

#[derive(Debug, Default)]
pub struct BoardState {
    pub cards: Vec<CardDto>,
    pub last_refresh: Option<DateTime<Utc>>,
}

impl BoardState {
    /// Refresh board state: discover sessions, load links, reconcile.
    pub async fn refresh(
        &mut self,
        discovery: &SessionDiscovery,
        store: &CoordinationStore,
        _settings: &SettingsStore,
    ) -> Result<()> {
        let sessions = discovery.discover_sessions().await?;
        let links = store.read_links().await?;

        let sessions_by_id: HashMap<String, Session> =
            sessions.iter().map(|s| (s.id.clone(), s.clone())).collect();

        // Upsert discovered sessions into links
        let mut all_links = links.clone();
        let existing_session_ids: std::collections::HashSet<String> = links
            .iter()
            .filter_map(|l| l.session_link.as_ref().map(|s| s.session_id.clone()))
            .collect();

        for session in &sessions {
            if existing_session_ids.contains(&session.id) {
                continue;
            }
            // Create a new link for this discovered session
            let now = Utc::now();
            let link = Link {
                id: format!("card_{}", session.id),
                name: session.name.clone(),
                project_path: session.project_path.clone(),
                column: "all_sessions".to_string(),
                created_at: session.modified_time,
                updated_at: session.modified_time,
                last_activity: Some(session.modified_time),
                manual_overrides: Default::default(),
                manually_archived: false,
                source: "discovered".to_string(),
                prompt_body: session.first_prompt.clone(),
                session_link: Some(crate::coordination_store::SessionLink {
                    session_id: session.id.clone(),
                    session_path: session.jsonl_path.clone(),
                    session_number: None,
                }),
                worktree_link: session.git_branch.as_ref().map(|b| {
                    crate::coordination_store::WorktreeLink {
                        path: String::new(),
                        branch: Some(b.clone()),
                    }
                }),
                pr_links: vec![],
                issue_link: None,
                discovered_branches: None,
                is_remote: false,
                is_launching: None,
            };
            all_links.push(link);
            let _ = now; // used in future for updatedAt
        }

        // Persist newly discovered links
        let existing_ids: std::collections::HashSet<String> =
            links.iter().map(|l| l.id.clone()).collect();
        let has_new = all_links.iter().any(|l| !existing_ids.contains(&l.id));
        if has_new {
            let _ = store.write_links(&all_links).await;
        }

        // Build cards
        let mut cards = Vec::new();
        for link in &all_links {
            let session = link
                .session_link
                .as_ref()
                .and_then(|sl| sessions_by_id.get(&sl.session_id))
                .cloned();

            let activity = link
                .session_link
                .as_ref()
                .and_then(|sl| sl.session_path.as_deref())
                .map(detect_activity);

            let activity_str = activity.as_ref().map(|a| match a {
                ActivityState::ActivelyWorking => "activelyWorking",
                ActivityState::WaitingForInput => "waitingForInput",
                ActivityState::Idle => "idle",
            });

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

            let relative_time = format_relative_time(
                link.last_activity
                    .unwrap_or(link.updated_at),
            );

            let show_spinner =
                activity == Some(ActivityState::ActivelyWorking) || link.is_launching == Some(true);

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

        // Sort newest first within each column
        cards.sort_by(|a, b| {
            let ta = a
                .link
                .last_activity
                .unwrap_or(a.link.updated_at);
            let tb = b
                .link
                .last_activity
                .unwrap_or(b.link.updated_at);
            tb.cmp(&ta)
        });

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
