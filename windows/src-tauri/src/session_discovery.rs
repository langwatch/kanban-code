use crate::jsonl_parser;
use anyhow::Result;
use chrono::{DateTime, Utc};
use serde::{Deserialize, Serialize};
use std::path::PathBuf;

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Session {
    pub id: String,
    pub name: Option<String>,
    pub first_prompt: Option<String>,
    pub project_path: Option<String>,
    pub git_branch: Option<String>,
    pub message_count: usize,
    pub modified_time: DateTime<Utc>,
    pub jsonl_path: Option<String>,
}

impl Session {
    pub fn display_title(&self) -> String {
        if let Some(name) = &self.name {
            if !name.is_empty() {
                return name.clone();
            }
        }
        if let Some(prompt) = &self.first_prompt {
            if !prompt.is_empty() {
                return prompt.chars().take(100).collect();
            }
        }
        format!("{}...", &self.id[..self.id.len().min(8)])
    }
}

/// Discovers Claude Code sessions by scanning ~/.claude/projects/.
pub struct SessionDiscovery {
    claude_dir: PathBuf,
}

impl SessionDiscovery {
    pub fn new(claude_dir: Option<PathBuf>) -> Self {
        let dir = claude_dir.unwrap_or_else(|| {
            // Windows: %APPDATA%\Claude\projects or fallback to ~/.claude/projects
            #[cfg(target_os = "windows")]
            {
                let appdata = std::env::var("APPDATA").unwrap_or_default();
                let win_path = PathBuf::from(&appdata).join("Claude").join("projects");
                if win_path.exists() {
                    return win_path;
                }
            }
            dirs::home_dir()
                .expect("no home dir")
                .join(".claude")
                .join("projects")
        });
        Self { claude_dir: dir }
    }

    pub async fn discover_sessions(&self) -> Result<Vec<Session>> {
        if !self.claude_dir.exists() {
            return Ok(vec![]);
        }

        let mut sessions_by_id: std::collections::HashMap<String, Session> =
            std::collections::HashMap::new();

        let mut dir_entries = tokio::fs::read_dir(&self.claude_dir).await?;
        while let Some(entry) = dir_entries.next_entry().await? {
            let dir_path = entry.path();
            if !dir_path.is_dir() {
                continue;
            }

            let dir_name = dir_path
                .file_name()
                .and_then(|n| n.to_str())
                .unwrap_or("")
                .to_string();

            // Scan .jsonl files
            let mut sub_entries = match tokio::fs::read_dir(&dir_path).await {
                Ok(e) => e,
                Err(_) => continue,
            };

            while let Some(file_entry) = sub_entries.next_entry().await? {
                let file_path = file_entry.path();
                let file_name = file_path
                    .file_name()
                    .and_then(|n| n.to_str())
                    .unwrap_or("");

                if !file_name.ends_with(".jsonl") {
                    continue;
                }

                let session_id = file_name.trim_end_matches(".jsonl").to_string();
                let file_path_str = file_path.to_string_lossy().to_string();

                let mtime = match tokio::fs::metadata(&file_path).await {
                    Ok(m) => m
                        .modified()
                        .ok()
                        .map(|t| DateTime::<Utc>::from(t))
                        .unwrap_or_else(Utc::now),
                    Err(_) => continue,
                };

                if let Ok(Some(meta)) =
                    jsonl_parser::extract_metadata(&file_path_str).await
                {
                    let entry = sessions_by_id
                        .entry(session_id.clone())
                        .or_insert_with(|| Session {
                            id: session_id.clone(),
                            name: None,
                            first_prompt: None,
                            project_path: None,
                            git_branch: None,
                            message_count: 0,
                            modified_time: mtime,
                            jsonl_path: None,
                        });

                    entry.jsonl_path = Some(file_path_str);
                    entry.modified_time = mtime;
                    entry.message_count = meta.message_count;
                    if entry.first_prompt.is_none() {
                        entry.first_prompt = meta.first_prompt;
                    }
                    if entry.project_path.is_none() {
                        entry.project_path = meta
                            .project_path
                            .or_else(|| Some(jsonl_parser::decode_directory_name(&dir_name)));
                    }
                    if entry.git_branch.is_none() {
                        entry.git_branch = meta.git_branch;
                    }
                }
            }
        }

        let mut sessions: Vec<Session> = sessions_by_id
            .into_values()
            .filter(|s| s.message_count > 0)
            .collect();

        sessions.sort_by(|a, b| b.modified_time.cmp(&a.modified_time));
        Ok(sessions)
    }
}
