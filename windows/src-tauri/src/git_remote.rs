//! Resolves a GitHub base URL (e.g. `https://github.com/owner/repo`) from a
//! local git repo, plus issue/PR URL helpers. Port of
//! `Sources/KanbanCodeCore/Adapters/Git/GitRemoteResolver.swift`.
//!
//! Results are cached in-process — `git remote get-url origin` is a local
//! `.git/config` read so it's fast, but spawning git per card every refresh
//! adds up.

use std::collections::HashMap;
use std::sync::Mutex;

use tokio::process::Command;

/// Internal cache: project path → `Some(base_url)` if resolved, `None` if the
/// remote isn't GitHub. The cache survives for the process lifetime; the next
/// app launch resolves fresh.
fn cache() -> &'static Mutex<HashMap<String, Option<String>>> {
    static CACHE: std::sync::OnceLock<Mutex<HashMap<String, Option<String>>>> =
        std::sync::OnceLock::new();
    CACHE.get_or_init(|| Mutex::new(HashMap::new()))
}

/// Returns the GitHub base URL for the repo at `project_path`
/// (e.g. `https://github.com/langwatch/kanban-code`), or `None` if the
/// remote isn't a GitHub URL or the directory isn't a git repo.
pub async fn github_base_url(project_path: &str) -> Option<String> {
    if let Some(hit) = cache().lock().ok().and_then(|c| c.get(project_path).cloned()) {
        return hit;
    }

    let output = Command::new("git")
        .args(["remote", "get-url", "origin"])
        .current_dir(project_path)
        .output()
        .await
        .ok()?;

    let url = if output.status.success() {
        let raw = String::from_utf8_lossy(&output.stdout);
        parse_github_url(raw.trim())
    } else {
        None
    };

    if let Ok(mut c) = cache().lock() {
        c.insert(project_path.to_string(), url.clone());
    }
    url
}

/// Construct a full issue URL: `<base>/issues/<n>`.
pub fn issue_url(base: &str, number: i64) -> String {
    format!("{base}/issues/{number}")
}

/// Construct a full PR URL: `<base>/pull/<n>`.
pub fn pr_url(base: &str, number: i64) -> String {
    format!("{base}/pull/{number}")
}

/// Parse a git remote URL into the canonical GitHub base URL.
/// Handles `git@github.com:owner/repo[.git]` (SSH), `https://github.com/owner/repo[.git]`,
/// and `http://…` (normalized to https). Returns None for non-GitHub remotes.
pub fn parse_github_url(remote: &str) -> Option<String> {
    // SSH form: git@github.com:owner/repo.git
    if let Some(idx) = remote.find("github.com:") {
        let path = remote[idx + "github.com:".len()..].trim_end_matches(".git");
        if path.is_empty() {
            return None;
        }
        return Some(format!("https://github.com/{path}"));
    }

    // HTTPS/HTTP form: https://github.com/owner/repo.git
    if let Some(idx) = remote.find("github.com/") {
        let path = remote[idx + "github.com/".len()..].trim_end_matches(".git");
        if path.is_empty() {
            return None;
        }
        return Some(format!("https://github.com/{path}"));
    }

    None
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_ssh_url() {
        assert_eq!(
            parse_github_url("git@github.com:langwatch/kanban-code.git"),
            Some("https://github.com/langwatch/kanban-code".to_string())
        );
    }

    #[test]
    fn parses_https_url_with_dot_git() {
        assert_eq!(
            parse_github_url("https://github.com/foo/bar.git"),
            Some("https://github.com/foo/bar".to_string())
        );
    }

    #[test]
    fn parses_https_url_without_suffix() {
        assert_eq!(
            parse_github_url("https://github.com/foo/bar"),
            Some("https://github.com/foo/bar".to_string())
        );
    }

    #[test]
    fn parses_http_normalizes_to_https() {
        // Both forms keep the github.com base; http→https normalization is
        // implicit because the rebuilt URL is `https://github.com/<path>`.
        assert_eq!(
            parse_github_url("http://github.com/foo/bar"),
            Some("https://github.com/foo/bar".to_string())
        );
    }

    #[test]
    fn rejects_non_github_remote() {
        assert_eq!(parse_github_url("git@gitlab.com:foo/bar.git"), None);
        assert_eq!(parse_github_url("https://bitbucket.org/foo/bar"), None);
        assert_eq!(parse_github_url(""), None);
    }

    #[test]
    fn url_helpers_compose() {
        let base = "https://github.com/foo/bar";
        assert_eq!(issue_url(base, 42), "https://github.com/foo/bar/issues/42");
        assert_eq!(pr_url(base, 7), "https://github.com/foo/bar/pull/7");
    }
}
