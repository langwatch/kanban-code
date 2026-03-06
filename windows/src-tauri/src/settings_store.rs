use anyhow::{Context, Result};
use serde::{Deserialize, Serialize};
use std::path::PathBuf;
use tokio::fs;

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Project {
    pub path: String,
    pub name: Option<String>,
    pub github_filter: Option<String>,
    pub repo_root: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize, Default)]
#[serde(rename_all = "camelCase")]
pub struct GlobalViewSettings {
    #[serde(default)]
    pub excluded_paths: Vec<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct GitHubSettings {
    #[serde(default = "default_gh_filter")]
    pub default_filter: String,
    #[serde(default = "default_poll_interval")]
    pub poll_interval_seconds: u64,
    #[serde(default = "default_merge_command")]
    pub merge_command: String,
}

fn default_gh_filter() -> String {
    "assignee:@me is:open".to_string()
}
fn default_poll_interval() -> u64 {
    60
}
fn default_merge_command() -> String {
    "gh pr merge ${number} --squash --delete-branch".to_string()
}

impl Default for GitHubSettings {
    fn default() -> Self {
        Self {
            default_filter: default_gh_filter(),
            poll_interval_seconds: default_poll_interval(),
            merge_command: default_merge_command(),
        }
    }
}

#[derive(Debug, Clone, Serialize, Deserialize, Default)]
#[serde(rename_all = "camelCase")]
pub struct NotificationSettings {
    #[serde(default)]
    pub pushover_enabled: bool,
    pub pushover_token: Option<String>,
    pub pushover_user_key: Option<String>,
    #[serde(default)]
    pub render_markdown_image: bool,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct SessionTimeoutSettings {
    #[serde(default = "default_timeout_minutes")]
    pub active_threshold_minutes: u64,
}

fn default_timeout_minutes() -> u64 {
    1440
}

impl Default for SessionTimeoutSettings {
    fn default() -> Self {
        Self {
            active_threshold_minutes: default_timeout_minutes(),
        }
    }
}

#[derive(Debug, Clone, Serialize, Deserialize, Default)]
#[serde(rename_all = "camelCase")]
pub struct Settings {
    #[serde(default)]
    pub projects: Vec<Project>,
    #[serde(default)]
    pub global_view: GlobalViewSettings,
    #[serde(default)]
    pub github: GitHubSettings,
    #[serde(default)]
    pub notifications: NotificationSettings,
    #[serde(default)]
    pub session_timeout: SessionTimeoutSettings,
    #[serde(default)]
    pub prompt_template: String,
    #[serde(default = "default_issue_template")]
    pub github_issue_prompt_template: String,
    #[serde(default)]
    pub has_completed_onboarding: bool,
    /// Editor command (e.g. "code", "cursor", "nvim")
    #[serde(default)]
    pub editor: String,
}

fn default_issue_template() -> String {
    "#${number}: ${title}\n\n${body}".to_string()
}

pub struct SettingsStore {
    file_path: PathBuf,
}

impl SettingsStore {
    pub fn new(base_path: Option<PathBuf>) -> Self {
        let base = base_path.unwrap_or_else(|| {
            // On Windows use %APPDATA%\kanban-code, on others ~/.kanban-code
            #[cfg(target_os = "windows")]
            {
                dirs::data_dir()
                    .expect("no data dir")
                    .join("kanban-code")
            }
            #[cfg(not(target_os = "windows"))]
            {
                dirs::home_dir()
                    .expect("no home dir")
                    .join(".kanban-code")
            }
        });
        Self {
            file_path: base.join("settings.json"),
        }
    }

    pub async fn read(&self) -> Result<Settings> {
        if !self.file_path.exists() {
            let defaults = Settings::default();
            self.write(&defaults).await?;
            return Ok(defaults);
        }
        let data = fs::read(&self.file_path).await.context("read settings.json")?;
        let settings: Settings = serde_json::from_slice(&data).unwrap_or_default();
        Ok(settings)
    }

    pub async fn write(&self, settings: &Settings) -> Result<()> {
        if let Some(parent) = self.file_path.parent() {
            fs::create_dir_all(parent).await.context("create settings dir")?;
        }
        let data = serde_json::to_vec_pretty(settings).context("serialize settings")?;
        let tmp = self.file_path.with_extension("json.tmp");
        fs::write(&tmp, &data).await.context("write settings tmp")?;
        fs::rename(&tmp, &self.file_path).await.context("rename settings tmp")?;
        Ok(())
    }
}
