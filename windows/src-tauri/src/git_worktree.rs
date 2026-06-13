use anyhow::{anyhow, Result};
use serde::{Deserialize, Serialize};
use std::path::Path;

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Worktree {
    pub path: String,
    pub branch: Option<String>,
    pub is_main: bool,
}

/// Create a new worktree at `<repo_root>/.worktrees/<name>` on a new branch
/// `<name>` (mirrors macOS GitWorktreeAdapter::createWorktree).
pub async fn create_worktree(repo_root: &str, name: &str) -> Result<Worktree> {
    let path = Path::new(repo_root).join(".worktrees").join(name);
    let path_str = path
        .to_str()
        .ok_or_else(|| anyhow!("non-UTF-8 worktree path"))?
        .to_string();
    let output = tokio::process::Command::new("git")
        .args(["worktree", "add", "-b", name, &path_str])
        .current_dir(repo_root)
        .output()
        .await?;
    if !output.status.success() {
        let stderr = String::from_utf8_lossy(&output.stderr);
        return Err(anyhow!("git worktree add failed: {stderr}"));
    }
    Ok(Worktree {
        path: path_str,
        branch: Some(name.to_string()),
        is_main: false,
    })
}

/// Remove a worktree. `force` adds `--force`. When `repo_root` is `None`,
/// derive it from the worktree path (strip `.worktrees/<name>` if present;
/// otherwise use the parent directory) — mirrors the macOS adapter's fallback.
pub async fn remove_worktree(path: &str, repo_root: Option<&str>, force: bool) -> Result<()> {
    let mut args = vec!["worktree", "remove"];
    if force {
        args.push("--force");
    }
    args.push(path);

    let effective_root: String = match repo_root {
        Some(r) => r.to_string(),
        None => {
            if let Some(idx) = path.find("\\.worktrees\\").or_else(|| path.find("/.worktrees/")) {
                path[..idx].to_string()
            } else {
                Path::new(path)
                    .parent()
                    .and_then(|p| p.to_str())
                    .unwrap_or(".")
                    .to_string()
            }
        }
    };

    let output = tokio::process::Command::new("git")
        .args(args)
        .current_dir(&effective_root)
        .output()
        .await?;
    if !output.status.success() {
        let stderr = String::from_utf8_lossy(&output.stderr);
        return Err(anyhow!("git worktree remove failed: {stderr}"));
    }
    Ok(())
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
