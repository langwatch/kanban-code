use anyhow::Result;
use regex::Regex;
use serde_json::Value;
use std::path::Path;
use tokio::io::{AsyncBufReadExt, BufReader};

#[derive(Debug, Clone)]
pub struct SessionMetadata {
    pub session_id: String,
    pub first_prompt: Option<String>,
    pub project_path: Option<String>,
    pub git_branch: Option<String>,
    pub message_count: usize,
}

/// Extract session metadata from a .jsonl file.
/// Returns None if the file has no messages.
pub async fn extract_metadata(file_path: &str) -> Result<Option<SessionMetadata>> {
    let path = Path::new(file_path);
    if !path.exists() {
        return Ok(None);
    }

    let session_id = path
        .file_stem()
        .and_then(|s| s.to_str())
        .unwrap_or("")
        .to_string();

    let file = tokio::fs::File::open(path).await?;
    let reader = BufReader::new(file);
    let mut lines = reader.lines();

    let mut meta = SessionMetadata {
        session_id,
        first_prompt: None,
        project_path: None,
        git_branch: None,
        message_count: 0,
    };
    let mut found_first_user = false;

    while let Some(line) = lines.next_line().await? {
        if line.is_empty() || !line.contains("\"type\"") {
            continue;
        }
        let obj: Value = match serde_json::from_str(&line) {
            Ok(v) => v,
            Err(_) => continue,
        };

        let msg_type = obj["type"].as_str().unwrap_or("");

        if meta.project_path.is_none() {
            if let Some(cwd) = obj["cwd"].as_str() {
                meta.project_path = Some(cwd.to_string());
            }
        }
        if meta.git_branch.is_none() {
            if let Some(branch) = obj["gitBranch"].as_str() {
                meta.git_branch = Some(branch.to_string());
            }
        }

        if msg_type == "user" || msg_type == "assistant" {
            meta.message_count += 1;
        }

        if msg_type == "user" && !found_first_user {
            found_first_user = true;
            meta.first_prompt = extract_text_content(&obj);
        }

        // Early exit once we have enough data
        if meta.message_count >= 5 && found_first_user {
            break;
        }
    }

    if meta.message_count == 0 {
        return Ok(None);
    }
    Ok(Some(meta))
}

fn extract_text_content(obj: &Value) -> Option<String> {
    let message = obj.get("message")?;
    let content = message.get("content")?;

    if let Some(text) = content.as_str() {
        return Some(text.to_string());
    }

    if let Some(blocks) = content.as_array() {
        let texts: Vec<&str> = blocks
            .iter()
            .filter(|b| b["type"].as_str() == Some("text"))
            .filter_map(|b| b["text"].as_str())
            .collect();
        let joined = texts.join("\n");
        if !joined.is_empty() {
            return Some(joined);
        }
    }

    None
}

/// Decode a Claude projects directory name to a filesystem path.
/// e.g., "-Users-rchaves-Projects-remote-langwatch" → "/Users/rchaves/Projects/remote/langwatch"
pub fn decode_directory_name(name: &str) -> String {
    let mut result = name.to_string();
    if result.starts_with('-') {
        result = format!("/{}", &result[1..]);
    }
    result.replace('-', "/")
}

/// Extract branches pushed from a session JSONL.
pub async fn extract_pushed_branches(
    file_path: &str,
    start_offset: Option<u64>,
) -> Result<Vec<String>> {
    let path = Path::new(file_path);
    if !path.exists() {
        return Ok(vec![]);
    }

    let push_re = Regex::new(r"git\s+push\s+(?:-\S+\s+)*(?:origin|upstream)\s+(\S+)")?;
    let checkout_re = Regex::new(r"git\s+checkout\s+-[bB]\s+(\S+)")?;
    let switch_re = Regex::new(r"git\s+switch\s+(?:-c|--create)\s+(\S+)")?;
    let worktree_re = Regex::new(r"git\s+worktree\s+add\s+\S+\s+-b\s+(\S+)")?;

    let file = tokio::fs::File::open(path).await?;
    let reader = BufReader::new(file);
    let mut lines = reader.lines();

    let mut branches = std::collections::HashSet::new();

    // If start_offset is set, skip that many bytes
    // (Simplified: we just scan all lines; incremental scanning is a nice-to-have)
    let _ = start_offset;

    while let Some(line) = lines.next_line().await? {
        if line.is_empty() || !line.contains("\"tool_use\"") {
            continue;
        }
        let obj: Value = match serde_json::from_str(&line) {
            Ok(v) => v,
            Err(_) => continue,
        };

        let content = match obj["message"]["content"].as_array() {
            Some(c) => c,
            None => continue,
        };

        for block in content {
            if block["type"].as_str() != Some("tool_use") {
                continue;
            }
            if block["name"].as_str() != Some("Bash") {
                continue;
            }
            let command = match block["input"]["command"].as_str() {
                Some(c) => c,
                None => continue,
            };

            for cap in push_re.captures_iter(command) {
                let b = &cap[1];
                if b != "main" && b != "master" && !b.starts_with('-') {
                    branches.insert(b.to_string());
                }
            }
            for cap in checkout_re.captures_iter(command) {
                let b = &cap[1];
                if b != "main" && b != "master" && !b.starts_with('-') {
                    branches.insert(b.to_string());
                }
            }
            for cap in switch_re.captures_iter(command) {
                let b = &cap[1];
                if b != "main" && b != "master" && !b.starts_with('-') {
                    branches.insert(b.to_string());
                }
            }
            for cap in worktree_re.captures_iter(command) {
                let b = &cap[1];
                if b != "main" && b != "master" && !b.starts_with('-') {
                    branches.insert(b.to_string());
                }
            }
        }
    }

    let mut result: Vec<String> = branches.into_iter().collect();
    result.sort();
    Ok(result)
}
