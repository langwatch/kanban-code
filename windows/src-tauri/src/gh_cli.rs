use anyhow::Result;
use serde::{Deserialize, Serialize};
use serde_json::Value;

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct PullRequest {
    pub number: i64,
    pub title: String,
    pub url: String,
    pub state: String,
    pub head_ref: String,
    pub merge_state_status: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Issue {
    pub number: i64,
    pub title: String,
    pub url: String,
    pub body: Option<String>,
}

/// Fetch open pull requests for the given repo root using `gh pr list`.
pub async fn fetch_prs(repo_root: &str) -> Result<Vec<PullRequest>> {
    let output = tokio::process::Command::new("gh")
        .args([
            "pr",
            "list",
            "--json",
            "number,title,url,state,headRefName",
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
                merge_state_status: pr["mergeStateStatus"].as_str().map(|s| s.to_string()),
            })
        })
        .collect();

    Ok(result)
}

/// Fetch issues matching a filter using `gh issue list`.
pub async fn fetch_issues(repo_root: &str, filter: &str) -> Result<Vec<Issue>> {
    let output = tokio::process::Command::new("gh")
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
