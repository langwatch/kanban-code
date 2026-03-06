use crate::coordination_store::{Link, SessionLink, WorktreeLink};
use crate::session_discovery::Session;
use std::collections::HashMap;
use uuid::Uuid;

/// Port of CardReconciler.swift.
///
/// Matches discovered sessions/worktrees to existing cards.
/// Prevents duplicate card creation (the "triplication bug").
pub fn reconcile(existing: Vec<Link>, sessions: Vec<Session>) -> Vec<Link> {
    let mut links_by_id: HashMap<String, Link> =
        existing.into_iter().map(|l| (l.id.clone(), l)).collect();

    // Build reverse indexes
    let mut card_id_by_session_id: HashMap<String, String> = HashMap::new();
    let mut cards_by_branch: HashMap<String, Vec<String>> = HashMap::new();

    for link in links_by_id.values() {
        if let Some(sl) = &link.session_link {
            card_id_by_session_id.insert(sl.session_id.clone(), link.id.clone());
        }
        if let Some(wl) = &link.worktree_link {
            if let Some(branch) = &wl.branch {
                cards_by_branch
                    .entry(branch.clone())
                    .or_default()
                    .push(link.id.clone());
            }
        }
        if let Some(branches) = &link.discovered_branches {
            for branch in branches {
                let ids = cards_by_branch.entry(branch.clone()).or_default();
                if !ids.contains(&link.id) {
                    ids.push(link.id.clone());
                }
            }
        }
    }

    // A. Match each session to an existing card (or create a new one)
    for session in &sessions {
        let card_id = find_card_for_session(
            session,
            &card_id_by_session_id,
            &cards_by_branch,
            &links_by_id,
        );

        if let Some(card_id) = card_id {
            if let Some(link) = links_by_id.get_mut(&card_id) {
                if link.session_link.is_none() {
                    link.session_link = Some(SessionLink {
                        session_id: session.id.clone(),
                        session_path: session.jsonl_path.clone(),
                        session_number: None,
                    });
                    card_id_by_session_id.insert(session.id.clone(), card_id.clone());
                } else {
                    // Update path in case file moved
                    if let Some(sl) = &mut link.session_link {
                        sl.session_path = session.jsonl_path.clone();
                    }
                }
                link.last_activity = Some(session.modified_time);
                if link.project_path.is_none() {
                    link.project_path = session.project_path.clone();
                }
                if link.prompt_body.is_none() {
                    link.prompt_body = session.first_prompt.clone();
                }
            }
        } else {
            // Truly new session — create a card
            let new_link = new_discovered_link(session);
            card_id_by_session_id.insert(session.id.clone(), new_link.id.clone());
            // Index its branch
            if let Some(branch) = &session.git_branch {
                let base = strip_refs_heads(branch);
                if base != "main" && base != "master" {
                    cards_by_branch
                        .entry(base.to_string())
                        .or_default()
                        .push(new_link.id.clone());
                }
            }
            links_by_id.insert(new_link.id.clone(), new_link);
        }
    }

    // A2. Index session gitBranch into cards_by_branch
    for session in &sessions {
        if let Some(branch) = &session.git_branch {
            let base = strip_refs_heads(branch);
            if base == "main" || base == "master" {
                continue;
            }
            if let Some(card_id) = card_id_by_session_id.get(&session.id) {
                let ids = cards_by_branch.entry(base.to_string()).or_default();
                if !ids.contains(card_id) {
                    ids.push(card_id.clone());
                }
            }
        }
    }

    // B2. Dedup: absorb orphan worktree-only cards into real cards on the same branch
    let branches: Vec<String> = cards_by_branch
        .keys()
        .filter(|b| cards_by_branch[*b].len() > 1)
        .cloned()
        .collect();

    for branch in branches {
        let card_ids = cards_by_branch[&branch].clone();
        let orphan_ids: Vec<String> = card_ids
            .iter()
            .filter(|id| {
                links_by_id
                    .get(*id)
                    .map(|l| l.session_link.is_none() && l.source != "manual" && l.name.is_none())
                    .unwrap_or(false)
            })
            .cloned()
            .collect();

        if orphan_ids.is_empty() {
            continue;
        }

        let real_ids: Vec<String> = card_ids
            .iter()
            .filter(|id| !orphan_ids.contains(id))
            .cloned()
            .collect();

        let keeper_id = real_ids.first().or(orphan_ids.first()).cloned().unwrap();

        for orphan_id in &orphan_ids {
            if *orphan_id == keeper_id {
                continue;
            }
            if let Some(orphan) = links_by_id.remove(orphan_id) {
                if let Some(keeper) = links_by_id.get_mut(&keeper_id) {
                    if keeper.worktree_link.is_none() {
                        keeper.worktree_link = orphan.worktree_link;
                    }
                }
            }
        }

        let live_ids: Vec<String> = card_ids
            .into_iter()
            .filter(|id| !orphan_ids.contains(id) || *id == keeper_id)
            .collect();
        cards_by_branch.insert(branch, live_ids);
    }

    // Collect remaining links preserving order (newest last_activity first)
    let mut result: Vec<Link> = links_by_id.into_values().collect();
    result.sort_by(|a, b| {
        let ta = a.last_activity.unwrap_or(a.updated_at);
        let tb = b.last_activity.unwrap_or(b.updated_at);
        tb.cmp(&ta)
    });
    result
}

fn find_card_for_session(
    session: &Session,
    card_id_by_session_id: &HashMap<String, String>,
    cards_by_branch: &HashMap<String, Vec<String>>,
    links_by_id: &HashMap<String, Link>,
) -> Option<String> {
    // 1. Exact sessionId match
    if let Some(id) = card_id_by_session_id.get(&session.id) {
        return Some(id.clone());
    }

    // 2. Branch match (session.gitBranch matches a card's worktreeLink.branch)
    if let Some(branch) = &session.git_branch {
        let base = strip_refs_heads(branch);
        if base != "main" && base != "master" {
            if let Some(ids) = cards_by_branch.get(base) {
                // Prefer cards without a session yet, same project
                let same_project: Vec<_> = ids
                    .iter()
                    .filter(|id| {
                        links_by_id
                            .get(*id)
                            .map(|l| project_matches(session, l))
                            .unwrap_or(false)
                    })
                    .collect();

                let pending = same_project
                    .iter()
                    .find(|id| {
                        links_by_id
                            .get(**id)
                            .map(|l| l.session_link.is_none())
                            .unwrap_or(false)
                    })
                    .cloned();

                if let Some(id) = pending.or(same_project.first().copied()) {
                    return Some(id.clone());
                }
            }
        }
    }

    None
}

fn project_matches(session: &Session, link: &Link) -> bool {
    let Some(session_path) = &session.project_path else {
        return true;
    };
    let Some(link_path) = &link.project_path else {
        return true;
    };
    session_path == link_path
        || session_path.starts_with(&format!("{}/", link_path))
        || session_path.contains("/.claude/worktrees/")
            && session_path.starts_with(&format!("{}/", link_path))
}

fn strip_refs_heads(branch: &str) -> &str {
    branch.strip_prefix("refs/heads/").unwrap_or(branch)
}

fn new_discovered_link(session: &Session) -> Link {
    let now = chrono::Utc::now();
    let id = format!("card_{}", Uuid::new_v4().simple());
    Link {
        id,
        name: session.name.clone(),
        project_path: session.project_path.clone(),
        column: "all_sessions".to_string(),
        created_at: session.modified_time,
        updated_at: now,
        last_activity: Some(session.modified_time),
        manual_overrides: Default::default(),
        manually_archived: false,
        source: "discovered".to_string(),
        prompt_body: session.first_prompt.clone(),
        session_link: Some(SessionLink {
            session_id: session.id.clone(),
            session_path: session.jsonl_path.clone(),
            session_number: None,
        }),
        worktree_link: session.git_branch.as_ref().and_then(|b| {
            let base = strip_refs_heads(b);
            if base != "main" && base != "master" {
                Some(WorktreeLink {
                    path: String::new(),
                    branch: Some(base.to_string()),
                })
            } else {
                None
            }
        }),
        pr_links: vec![],
        issue_link: None,
        discovered_branches: None,
        is_remote: false,
        is_launching: None,
    }
}
