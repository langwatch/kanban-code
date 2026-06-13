use anyhow::Result;
use serde::{Deserialize, Serialize};
use serde_json::Value;
use std::collections::HashMap;

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct CheckRun {
    pub name: String,
    /// SUCCESS / FAILURE / NEUTRAL / CANCELLED / SKIPPED / TIMED_OUT /
    /// ACTION_REQUIRED / STALE / STARTUP_FAILURE — or None while running.
    pub conclusion: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct PullRequest {
    pub number: i64,
    pub title: String,
    pub url: String,
    pub state: String,
    pub head_ref: String,
    pub body: Option<String>,
    pub merge_state_status: Option<String>,
    /// APPROVED / CHANGES_REQUESTED / REVIEW_REQUIRED — None when no review yet.
    pub review_decision: Option<String>,
    /// Count of APPROVED reviews keyed on the latest review per author.
    pub approval_count: Option<i64>,
    /// Flattened statusCheckRollup. Empty Vec when no CI configured.
    pub check_runs: Vec<CheckRun>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Issue {
    pub number: i64,
    pub title: String,
    pub url: String,
    pub body: Option<String>,
}

/// Resolve the `gh` binary name. On WSL, fall back to `gh.exe` if `gh` is not
/// available in the WSL PATH (common when gh is installed on the Windows side only).
fn gh_bin() -> &'static str {
    #[cfg(not(target_os = "windows"))]
    if crate::shell_command::is_wsl() {
        // Check if `gh` exists in WSL PATH; if not, use `gh.exe`
        if std::process::Command::new("which")
            .arg("gh")
            .output()
            .map(|o| o.status.success())
            .unwrap_or(false)
        {
            return "gh";
        }
        return "gh.exe";
    }
    "gh"
}

/// Fetch open pull requests for the given repo root using `gh pr list`.
/// Pulls the rich field set so the PR tab can render body, CI status,
/// review decision, approval count, and the merge-state badge in a single
/// call (no per-PR follow-up needed).
pub async fn fetch_prs(repo_root: &str) -> Result<Vec<PullRequest>> {
    let output = tokio::process::Command::new(gh_bin())
        .args([
            "pr",
            "list",
            "--json",
            "number,title,url,state,headRefName,body,mergeStateStatus,reviewDecision,reviews,statusCheckRollup",
            "--limit",
            "100",
        ])
        .current_dir(repo_root)
        .output()
        .await?;

    if !output.status.success() {
        return Ok(vec![]);
    }

    let prs: Vec<Value> = serde_json::from_slice(&output.stdout).unwrap_or_default();
    let result = prs
        .into_iter()
        .filter_map(|pr| {
            Some(PullRequest {
                number: pr["number"].as_i64()?,
                title: pr["title"].as_str()?.to_string(),
                url: pr["url"].as_str()?.to_string(),
                state: pr["state"].as_str().unwrap_or("OPEN").to_string(),
                head_ref: pr["headRefName"].as_str()?.to_string(),
                body: pr["body"].as_str().filter(|s| !s.is_empty()).map(|s| s.to_string()),
                merge_state_status: pr["mergeStateStatus"].as_str().map(|s| s.to_string()),
                review_decision: pr["reviewDecision"].as_str().filter(|s| !s.is_empty()).map(|s| s.to_string()),
                approval_count: count_approvals(&pr["reviews"]),
                check_runs: parse_check_runs(&pr["statusCheckRollup"]),
            })
        })
        .collect();

    Ok(result)
}

/// Count APPROVED reviews, deduping to the most recent per author so a single
/// person's earlier "approved → changes_requested → approved" history counts
/// once (matching the GitHub PR header behaviour).
fn count_approvals(reviews: &Value) -> Option<i64> {
    let arr = reviews.as_array()?;
    if arr.is_empty() {
        return None;
    }
    let mut latest: HashMap<String, String> = HashMap::new();
    for r in arr {
        let author = r["author"]["login"].as_str().unwrap_or("").to_string();
        let state = r["state"].as_str().unwrap_or("").to_string();
        if !author.is_empty() {
            latest.insert(author, state); // later iterations win (gh returns oldest→newest)
        }
    }
    Some(latest.values().filter(|s| s.as_str() == "APPROVED").count() as i64)
}

fn parse_check_runs(rollup: &Value) -> Vec<CheckRun> {
    let arr = match rollup.as_array() {
        Some(a) => a,
        None => return vec![],
    };
    arr.iter()
        .filter_map(|c| {
            // gh statusCheckRollup mixes "CheckRun" entries (name, conclusion)
            // and "StatusContext" entries (context, state). Normalise both
            // shapes so the UI doesn't have to care.
            let name = c["name"].as_str().or_else(|| c["context"].as_str())?.to_string();
            let conclusion = c["conclusion"]
                .as_str()
                .or_else(|| c["state"].as_str())
                .filter(|s| !s.is_empty())
                .map(|s| s.to_string());
            Some(CheckRun { name, conclusion })
        })
        .collect()
}

/// Second-pass enrichment: ask the GraphQL API for unresolved review-thread
/// counts. `gh pr list --json` doesn't surface this, so we batch a single
/// GraphQL query per repo with one `pr<N>` alias per PR. Returns a map from
/// PR number → unresolved thread count. Best-effort: any failure returns an
/// empty map and the caller leaves the field as None.
///
/// Owner/repo are derived from the first PR's URL (every PR in `prs` is in
/// the same repo because the caller batches per project_path).
pub async fn fetch_unresolved_threads(prs: &[PullRequest]) -> std::collections::HashMap<i64, i64> {
    let mut out = std::collections::HashMap::new();
    if prs.is_empty() {
        return out;
    }
    let Some((owner, repo)) = prs.first().and_then(|p| parse_owner_repo(&p.url)) else {
        return out;
    };

    // Build a query body with one alias per PR.
    let mut aliases = String::new();
    for pr in prs {
        // Aliases must start with a letter; "pr" + number is safe.
        aliases.push_str(&format!(
            "pr{n}: pullRequest(number: {n}) {{ reviewThreads(first: 100) {{ nodes {{ isResolved }} }} }}\n",
            n = pr.number
        ));
    }
    let query = format!(
        "query {{ repository(owner: \"{owner}\", name: \"{repo}\") {{ {aliases} }} }}"
    );

    let output = match tokio::process::Command::new(gh_bin())
        .args(["api", "graphql", "-f", &format!("query={query}")])
        .output()
        .await
    {
        Ok(o) => o,
        Err(_) => return out,
    };
    if !output.status.success() {
        return out;
    }
    let body: Value = match serde_json::from_slice(&output.stdout) {
        Ok(v) => v,
        Err(_) => return out,
    };
    let repo_node = match body["data"]["repository"].as_object() {
        Some(o) => o,
        None => return out,
    };
    for (alias, node) in repo_node {
        // alias is "pr<n>"
        let Some(n_str) = alias.strip_prefix("pr") else { continue };
        let Ok(number) = n_str.parse::<i64>() else { continue };
        let unresolved = node["reviewThreads"]["nodes"]
            .as_array()
            .map(|arr| arr.iter().filter(|n| n["isResolved"].as_bool() != Some(true)).count() as i64)
            .unwrap_or(0);
        out.insert(number, unresolved);
    }
    out
}

/// Parse owner/repo from a PR HTML URL: https://github.com/owner/repo/pull/42
fn parse_owner_repo(url: &str) -> Option<(String, String)> {
    let idx = url.find("github.com/")?;
    let path = &url[idx + "github.com/".len()..];
    let mut parts = path.split('/');
    let owner = parts.next()?.to_string();
    let repo = parts.next()?.to_string();
    if owner.is_empty() || repo.is_empty() {
        return None;
    }
    Some((owner, repo))
}

// Frontend (CardView.tsx::worstCi) computes the worst conclusion from
// PrLink.check_runs directly; no Rust-side helper needed yet. If a future
// consumer wants it (e.g. badge in a system-tray menu), add it back here.

/// Fetch issues matching a filter using `gh issue list`.
pub async fn fetch_issues(repo_root: &str, filter: &str) -> Result<Vec<Issue>> {
    let output = tokio::process::Command::new(gh_bin())
        .args([
            "issue",
            "list",
            "--search",
            filter,
            "--json",
            "number,title,url,body",
            "--limit",
            "100",
        ])
        .current_dir(repo_root)
        .output()
        .await?;

    if !output.status.success() {
        return Ok(vec![]);
    }

    let issues: Vec<Value> = serde_json::from_slice(&output.stdout).unwrap_or_default();
    let result = issues
        .into_iter()
        .filter_map(|issue| {
            Some(Issue {
                number: issue["number"].as_i64()?,
                title: issue["title"].as_str()?.to_string(),
                url: issue["url"].as_str()?.to_string(),
                body: issue["body"].as_str().map(|s| s.to_string()),
            })
        })
        .collect();

    Ok(result)
}
