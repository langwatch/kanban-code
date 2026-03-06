use anyhow::Result;
use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Worktree {
    pub path: String,
    pub branch: Option<String>,
    pub is_main: bool,
}

/// Run `git worktree list --porcelain` and parse output.
pub async fn list_worktrees(repo_root: &str) -> Result<Vec<Worktree>> {
    let output = tokio::process::Command::new("git")
        .args(["worktree", "list", "--porcelain"])
        .current_dir(repo_root)
        .output()
        .await?;

    if !output.status.success() {
        return Ok(vec![]);
    }

    let stdout = String::from_utf8_lossy(&output.stdout);
    let mut worktrees = Vec::new();
    let mut current_path: Option<String> = None;
    let mut current_branch: Option<String> = None;
    let mut is_first = true;

    for line in stdout.lines() {
        if line.starts_with("worktree ") {
            if let Some(path) = current_path.take() {
                worktrees.push(Worktree {
                    path,
                    branch: current_branch.take(),
                    is_main: is_first,
                });
                is_first = false;
            }
            current_path = Some(line.trim_start_matches("worktree ").to_string());
        } else if line.starts_with("branch ") {
            let branch = line.trim_start_matches("branch refs/heads/").to_string();
            current_branch = Some(branch);
        }
    }
    if let Some(path) = current_path.take() {
        worktrees.push(Worktree {
            path,
            branch: current_branch.take(),
            is_main: is_first,
        });
    }

    Ok(worktrees)
}
