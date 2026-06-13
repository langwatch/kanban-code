use anyhow::{Context, Result};
use serde::{Deserialize, Serialize};
use std::path::PathBuf;
use std::sync::OnceLock;
use tokio::fs;

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Project {
    pub path: String,
    pub name: Option<String>,
    pub github_filter: Option<String>,
    pub repo_root: Option<String>,
    /// Per-project prompt prefix. When set, overrides Settings.promptTemplate
    /// for tasks created against this project. Optional.
    #[serde(default)]
    pub prompt_template: Option<String>,
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

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct NotificationSettings {
    #[serde(default = "default_true")]
    pub notifications_enabled: bool,
    #[serde(default)]
    pub pushover_enabled: bool,
    pub pushover_token: Option<String>,
    pub pushover_user_key: Option<String>,
    #[serde(default)]
    pub render_markdown_image: bool,
}

fn default_true() -> bool {
    true
}

impl Default for NotificationSettings {
    fn default() -> Self {
        Self {
            notifications_enabled: true,
            pushover_enabled: false,
            pushover_token: None,
            pushover_user_key: None,
            render_markdown_image: false,
        }
    }
}

/// Byte-compatible with macOS `RemoteSettings` (Sources/.../SettingsStore.swift).
/// Field names — `host`, `remotePath`, `localPath`, `syncIgnores` — match exactly
/// so a settings.json moved between Mac and Windows keeps working.
#[derive(Debug, Clone, Serialize, Deserialize, Default)]
#[serde(rename_all = "camelCase")]
pub struct RemoteSettings {
    #[serde(default)]
    pub host: String,
    #[serde(default)]
    pub remote_path: String,
    #[serde(default)]
    pub local_path: String,
    /// nil = use mutagen::default_ignores()
    #[serde(default)]
    pub sync_ignores: Option<Vec<String>>,
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

#[derive(Debug, Clone, Copy, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub enum SelfCompactAction {
    QueuePrompt,
    CompactNow,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub struct SelfCompactRule {
    pub id: String,
    pub threshold_tokens: i64,
    pub action: SelfCompactAction,
    pub message: String,
}

impl SelfCompactRule {
    /// Byte-compatible defaults with macOS SelfCompactRule.defaults so a
    /// settings.json round-tripped between platforms keeps the same rule set.
    pub fn defaults() -> Vec<Self> {
        vec![
            Self {
                id: "ctx-500k".into(),
                threshold_tokens: 500_000,
                action: SelfCompactAction::QueuePrompt,
                message: "You are above the 500k context limit. Whenever it is convenient, use the kanban CLI to send yourself a self-compact.".into(),
            },
            Self {
                id: "ctx-600k".into(),
                threshold_tokens: 600_000,
                action: SelfCompactAction::QueuePrompt,
                message: "You are above the 600k context limit. Please compact yourself soon using the kanban CLI self-compact command.".into(),
            },
            Self {
                id: "ctx-700k".into(),
                threshold_tokens: 700_000,
                action: SelfCompactAction::QueuePrompt,
                message: "You are above the 700k context limit. Compact yourself IMMEDIATELY using the kanban CLI self-compact command.".into(),
            },
            Self {
                id: "ctx-750k".into(),
                threshold_tokens: 750_000,
                action: SelfCompactAction::CompactNow,
                message: "/compact".into(),
            },
        ]
    }
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct SelfCompactSettings {
    #[serde(default)]
    pub enabled: bool,
    #[serde(default = "default_self_compact_poll")]
    pub poll_interval_seconds: u64,
    #[serde(default = "SelfCompactRule::defaults")]
    pub rules: Vec<SelfCompactRule>,
}

fn default_self_compact_poll() -> u64 {
    30
}

impl Default for SelfCompactSettings {
    fn default() -> Self {
        Self {
            enabled: false,
            poll_interval_seconds: default_self_compact_poll(),
            rules: SelfCompactRule::defaults(),
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
    /// Terminal font size (8-24)
    #[serde(default = "default_terminal_font_size")]
    pub terminal_font_size: u32,
    /// Shell command used by the embedded terminal — space-separated tokens.
    /// Defaults to `cmd.exe` for a native Windows experience. Set to
    /// `wsl.exe` (or `pwsh.exe -NoLogo`, etc.) to run Claude in a different
    /// shell. The first token is the executable; remaining tokens are args.
    #[serde(default = "default_terminal_shell")]
    pub terminal_shell: String,
    #[serde(default)]
    pub remote: Option<RemoteSettings>,
    /// Automatic context-limit guard for Claude sessions. Byte-compatible
    /// with macOS Settings.selfCompact — a settings.json moved between Mac
    /// and Windows keeps its rule set.
    #[serde(default)]
    pub self_compact: SelfCompactSettings,
}

fn default_terminal_font_size() -> u32 {
    15
}

fn default_terminal_shell() -> String {
    #[cfg(target_os = "windows")]
    {
        "cmd.exe".to_string()
    }
    #[cfg(not(target_os = "windows"))]
    {
        "bash".to_string()
    }
}

fn default_issue_template() -> String {
    "#${number}: ${title}\n\n${body}".to_string()
}

/// First time the settings file is read on this process, peek at the raw JSON
/// to see whether it came from the macOS app. macOS doesn't write the
/// Windows-only keys (`terminalShell`, `terminalFontSize`, `editor`); when
/// they're absent serde's `#[serde(default)]` silently backfills the Windows
/// defaults. We use `terminalShell` alone as the sentinel — adding more keys
/// to the AND would just create false negatives if a Windows user explicitly
/// cleared one. A new Windows-only field does NOT need to be added to the
/// check; just keep this comment up to date.
///
/// No `schema_version` field is added — that would break the macOS byte-compat
/// invariant (sortedKeys+prettyPrinted JSON shared with the Swift app).
fn log_cross_platform_backfill_once(raw: &[u8]) {
    static LOGGED: OnceLock<()> = OnceLock::new();
    if LOGGED.get().is_some() {
        return;
    }
    let Ok(v) = serde_json::from_slice::<serde_json::Value>(raw) else { return };
    let obj = match v.as_object() {
        Some(o) => o,
        None => return,
    };
    if !obj.contains_key("terminalShell") {
        let _ = LOGGED.set(());
        crate::logging::info(
            "settings",
            "settings.json missing terminalShell/terminalFontSize — backfilling Windows defaults (file appears to originate from macOS)",
        );
    }
}

pub struct SettingsStore {
    file_path: PathBuf,
}

impl SettingsStore {
    pub fn new(base_path: Option<PathBuf>) -> Self {
        let base = base_path
            .unwrap_or_else(|| crate::coordination_store::kanban_data_dir());
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
        log_cross_platform_backfill_once(&data);
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
