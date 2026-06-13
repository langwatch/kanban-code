//! Card merge logic. Ported from Sources/KanbanCodeCore/UseCases/DragAndDrop.swift
//! `onMergeCards` + Sources/KanbanCodeCore/Domain/Entities/Link.swift
//! `mergeBlocked`.
//!
//! Two pure functions live here:
//! - [`merge_blocked`] runs the preconditions and returns a human-readable
//!   reason string if the merge cannot proceed.
//! - [`merge_into_target`] applies the field rules synthesised from the
//!   macOS source (see PR description for the full rule table).
//!
//! Deliberate Windows-side omissions:
//! - macOS has a `tmuxLink` precondition rule; Windows `Link` has no such
//!   field. The rule is dropped, not stubbed.
//! - macOS `mergeBlocked` covers `pinned_at` and `discovered_repos`. Neither
//!   exists on the Windows Link. Dropped.
//!
//! Source `queued_prompts` are intentionally discarded — there is no
//! macOS precedent and the prompts are tied to the source's session_link,
//! which is itself dropped in the precondition. Logged at info level when
//! non-empty so users notice.

use crate::coordination_store::{Link, PrLink};
use chrono::Utc;

/// Returns `Some(reason)` if a merge of `source` into `target` is blocked.
/// `None` means the merge can proceed.
pub fn merge_blocked(source: &Link, target: &Link) -> Option<String> {
    if source.id == target.id {
        return Some("cannot merge a card into itself".to_string());
    }
    if source.is_launching == Some(true) || target.is_launching == Some(true) {
        return Some(
            "card is mid-launch — finish the launch before merging".to_string(),
        );
    }
    if source.session_link.is_some() && target.session_link.is_some() {
        return Some(
            "both cards have a Claude session — cannot collapse two live sessions"
                .to_string(),
        );
    }
    if let (Some(s_wt), Some(t_wt)) = (
        source.worktree_link.as_ref(),
        target.worktree_link.as_ref(),
    ) {
        if s_wt.path != t_wt.path {
            return Some(format!(
                "worktrees differ: {} vs {}",
                s_wt.path, t_wt.path
            ));
        }
    }
    if let (Some(s_iss), Some(t_iss)) = (source.issue_link.as_ref(), target.issue_link.as_ref()) {
        if s_iss.number != t_iss.number {
            return Some(format!(
                "issue numbers differ: #{} vs #{}",
                s_iss.number, t_iss.number
            ));
        }
    }
    None
}

/// Apply `source`'s fields into `target` in-place using the rules
/// synthesised from the macOS reference. Callers must run
/// [`merge_blocked`] first.
pub fn merge_into_target(source: &Link, target: &mut Link) {
    // nil-slot-wins: target keeps any field it already has set
    if target.name.is_none() {
        target.name = source.name.clone();
    }
    if target.project_path.is_none() {
        target.project_path = source.project_path.clone();
    }
    if target.prompt_body.is_none() {
        target.prompt_body = source.prompt_body.clone();
    }
    if target.session_link.is_none() {
        target.session_link = source.session_link.clone();
    }
    if target.worktree_link.is_none() {
        target.worktree_link = source.worktree_link.clone();
    }
    if target.issue_link.is_none() {
        target.issue_link = source.issue_link.clone();
    }

    // PR links — union deduped by `number`, target wins on conflict so the
    // user-visible enrichment snapshot stays internally consistent.
    let mut existing_numbers: std::collections::HashSet<i64> =
        target.pr_links.iter().map(|p: &PrLink| p.number).collect();
    for pr in &source.pr_links {
        if !existing_numbers.contains(&pr.number) {
            target.pr_links.push(pr.clone());
            existing_numbers.insert(pr.number);
        }
    }

    // discovered_branches — union, preserving target order
    match (&mut target.discovered_branches, &source.discovered_branches) {
        (None, Some(s)) => target.discovered_branches = Some(s.clone()),
        (Some(existing), Some(s)) => {
            for b in s {
                if !existing.contains(b) {
                    existing.push(b.clone());
                }
            }
        }
        _ => {}
    }

    // last_activity — max-wins
    match (target.last_activity, source.last_activity) {
        (None, Some(s)) => target.last_activity = Some(s),
        (Some(t), Some(s)) if s > t => target.last_activity = Some(s),
        _ => {}
    }

    // is_remote — logical OR
    target.is_remote = target.is_remote || source.is_remote;

    // updated_at — bump to now
    target.updated_at = Utc::now();

    // Deliberately left alone on the target side:
    //   id, column, created_at, manual_overrides, manually_archived,
    //   source, is_launching, queued_prompts, sort_order, assistant_id
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::coordination_store::{IssueLink, SessionLink, WorktreeLink};

    fn empty_link(id: &str) -> Link {
        let now = Utc::now();
        Link {
            id: id.to_string(),
            name: None,
            project_path: None,
            column: "backlog".to_string(),
            created_at: now,
            updated_at: now,
            last_activity: None,
            manual_overrides: Default::default(),
            manually_archived: false,
            source: "manual".to_string(),
            prompt_body: None,
            session_link: None,
            worktree_link: None,
            pr_links: vec![],
            issue_link: None,
            discovered_branches: None,
            is_remote: false,
            is_launching: None,
            queued_prompts: None,
            sort_order: None,
            assistant_id: "claude".to_string(),
        }
    }

    #[test]
    fn blocks_self_merge() {
        let a = empty_link("a");
        let same = a.clone();
        assert!(merge_blocked(&a, &same).is_some());
    }

    #[test]
    fn blocks_two_sessions() {
        let mut a = empty_link("a");
        let mut b = empty_link("b");
        a.session_link = Some(SessionLink {
            session_id: "sa".into(),
            session_path: None,
            session_number: None,
        });
        b.session_link = Some(SessionLink {
            session_id: "sb".into(),
            session_path: None,
            session_number: None,
        });
        assert!(merge_blocked(&a, &b).is_some());
    }

    #[test]
    fn blocks_different_worktrees() {
        let mut a = empty_link("a");
        let mut b = empty_link("b");
        a.worktree_link = Some(WorktreeLink {
            path: "C:/wt-a".into(),
            branch: None,
        });
        b.worktree_link = Some(WorktreeLink {
            path: "C:/wt-b".into(),
            branch: None,
        });
        assert!(merge_blocked(&a, &b).is_some());
    }

    #[test]
    fn allows_same_worktree() {
        let mut a = empty_link("a");
        let mut b = empty_link("b");
        a.worktree_link = Some(WorktreeLink {
            path: "C:/wt".into(),
            branch: Some("feat".into()),
        });
        b.worktree_link = Some(WorktreeLink {
            path: "C:/wt".into(),
            branch: Some("feat".into()),
        });
        assert!(merge_blocked(&a, &b).is_none());
    }

    #[test]
    fn blocks_launching() {
        let mut a = empty_link("a");
        let b = empty_link("b");
        a.is_launching = Some(true);
        assert!(merge_blocked(&a, &b).is_some());
    }

    #[test]
    fn blocks_different_issues() {
        let mut a = empty_link("a");
        let mut b = empty_link("b");
        a.issue_link = Some(IssueLink {
            number: 1,
            url: None,
            title: None,
            body: None,
        });
        b.issue_link = Some(IssueLink {
            number: 2,
            url: None,
            title: None,
            body: None,
        });
        assert!(merge_blocked(&a, &b).is_some());
    }

    #[test]
    fn nil_slot_wins_name() {
        let mut source = empty_link("a");
        let mut target = empty_link("b");
        source.name = Some("from source".into());
        merge_into_target(&source, &mut target);
        assert_eq!(target.name.as_deref(), Some("from source"));

        // Target name preserved when set
        let mut target2 = empty_link("c");
        target2.name = Some("kept".into());
        merge_into_target(&source, &mut target2);
        assert_eq!(target2.name.as_deref(), Some("kept"));
    }

    #[test]
    fn pr_links_dedup_by_number_target_wins() {
        let mut source = empty_link("a");
        let mut target = empty_link("b");
        source.pr_links = vec![
            PrLink {
                number: 1,
                url: Some("source-url".into()),
                status: None,
                title: Some("source-title".into()),
                body: None,
                approval_count: None,
                unresolved_threads: None,
                merge_state_status: None,
                review_decision: None,
                check_runs: vec![],
            },
            PrLink {
                number: 2,
                url: None,
                status: None,
                title: None,
                body: None,
                approval_count: None,
                unresolved_threads: None,
                merge_state_status: None,
                review_decision: None,
                check_runs: vec![],
            },
        ];
        target.pr_links = vec![PrLink {
            number: 1,
            url: Some("target-url".into()),
            status: None,
            title: Some("target-title".into()),
            body: None,
            approval_count: None,
            unresolved_threads: None,
            merge_state_status: None,
            review_decision: None,
            check_runs: vec![],
        }];
        merge_into_target(&source, &mut target);
        assert_eq!(target.pr_links.len(), 2);
        // PR #1 keeps the target's title/url
        let pr1 = target.pr_links.iter().find(|p| p.number == 1).unwrap();
        assert_eq!(pr1.url.as_deref(), Some("target-url"));
        assert_eq!(pr1.title.as_deref(), Some("target-title"));
        // PR #2 came from source
        let pr2 = target.pr_links.iter().find(|p| p.number == 2).unwrap();
        assert_eq!(pr2.number, 2);
    }

    #[test]
    fn discovered_branches_union_preserves_target_order() {
        let mut source = empty_link("a");
        let mut target = empty_link("b");
        target.discovered_branches = Some(vec!["a".into(), "b".into()]);
        source.discovered_branches = Some(vec!["b".into(), "c".into()]);
        merge_into_target(&source, &mut target);
        assert_eq!(
            target.discovered_branches.as_deref().unwrap(),
            ["a", "b", "c"]
        );
    }

    #[test]
    fn is_remote_is_logical_or() {
        let mut source = empty_link("a");
        let mut target = empty_link("b");
        source.is_remote = true;
        merge_into_target(&source, &mut target);
        assert!(target.is_remote);
    }

    #[test]
    fn last_activity_max_wins() {
        use chrono::Duration;
        let mut source = empty_link("a");
        let mut target = empty_link("b");
        let now = Utc::now();
        target.last_activity = Some(now - Duration::hours(1));
        source.last_activity = Some(now);
        merge_into_target(&source, &mut target);
        assert_eq!(target.last_activity, Some(now));

        // older source loses
        let mut target2 = empty_link("c");
        target2.last_activity = Some(now);
        let mut source2 = empty_link("d");
        source2.last_activity = Some(now - Duration::hours(1));
        merge_into_target(&source2, &mut target2);
        assert_eq!(target2.last_activity, Some(now));
    }

    #[test]
    fn target_column_preserved() {
        let mut source = empty_link("a");
        let mut target = empty_link("b");
        source.column = "in_progress".into();
        target.column = "done".into();
        merge_into_target(&source, &mut target);
        assert_eq!(target.column, "done");
    }
}
