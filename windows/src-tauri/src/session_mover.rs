use anyhow::{anyhow, Context, Result};
use serde_json::Value;
use std::path::{Path, PathBuf};

/// Move a Claude Code session .jsonl from one project's encoded directory
/// to another, rewriting the `cwd` field in every line.
///
/// Mirrors macOS SessionFileMover.swift. The target directory name is the
/// project path with `/` and `.` replaced by `-`, so a file moved here will
/// be found by the macOS app and vice versa.
///
/// Returns the new absolute path on disk.
pub async fn move_session(
    session_id: &str,
    from_path: &str,
    to_project_path: &str,
) -> Result<String> {
    let projects_dir = claude_projects_dir().context("locate ~/.claude/projects")?;
    let target_dir_name = encode_project_path(to_project_path);
    let target_dir = projects_dir.join(&target_dir_name);
    let target_path = target_dir.join(format!("{session_id}.jsonl"));

    tokio::fs::create_dir_all(&target_dir)
        .await
        .with_context(|| format!("create {:?}", target_dir))?;

    let content = tokio::fs::read_to_string(from_path)
        .await
        .with_context(|| format!("read {}", from_path))?;

    let mut new_lines = Vec::<String>::new();
    for line in content.split('\n') {
        if line.trim().is_empty() {
            new_lines.push(line.to_string());
            continue;
        }
        match serde_json::from_str::<Value>(line) {
            Ok(mut obj) => {
                if obj.get("cwd").is_some() {
                    if let Some(map) = obj.as_object_mut() {
                        map.insert("cwd".to_string(), Value::String(to_project_path.to_string()));
                    }
                }
                match serde_json::to_string(&obj) {
                    Ok(s) => new_lines.push(s),
                    Err(_) => new_lines.push(line.to_string()),
                }
            }
            Err(_) => new_lines.push(line.to_string()),
        }
    }

    let new_content = new_lines.join("\n");
    let target_path_str = target_path.to_string_lossy().to_string();
    tokio::fs::write(&target_path, new_content)
        .await
        .with_context(|| format!("write {:?}", target_path))?;

    // Only delete the source if it ended up in a different file
    if Path::new(from_path) != target_path.as_path() {
        let _ = tokio::fs::remove_file(from_path).await;
    }

    Ok(target_path_str)
}

/// Encode a project path into Claude's projects-dir naming scheme.
/// Replaces both `/` and `.` with `-`. Backslashes are first normalized
/// to forward slashes so Windows paths produce the same encoding the
/// macOS app generates.
///
/// Example: `C:\Users\foo\repo` → `C:-Users-foo-repo` (after backslash
/// normalization) → final `C:-Users-foo-repo`.
pub fn encode_project_path(path: &str) -> String {
    path.replace('\\', "/").replace('/', "-").replace('.', "-")
}

fn claude_projects_dir() -> Result<PathBuf> {
    dirs::home_dir()
        .map(|h| h.join(".claude").join("projects"))
        .ok_or_else(|| anyhow!("no home dir"))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn encode_matches_swift() {
        // From the SessionFileMover.swift docstring.
        assert_eq!(
            encode_project_path("/Users/foo/.claude/worktrees/bar"),
            "-Users-foo--claude-worktrees-bar"
        );
    }
}
