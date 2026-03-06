use anyhow::{Context, Result};
use chrono::{DateTime, Utc};
use serde::{Deserialize, Serialize};
use std::path::PathBuf;
use tokio::fs;
use uuid::Uuid;

// ── Sub-structs ──────────────────────────────────────────────────────────────

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct SessionLink {
    pub session_id: String,
    pub session_path: Option<String>,
    pub session_number: Option<i64>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct WorktreeLink {
    pub path: String,
    pub branch: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct PrLink {
    pub number: i64,
    pub url: Option<String>,
    pub status: Option<String>,
    pub title: Option<String>,
    pub body: Option<String>,
    pub approval_count: Option<i64>,
    pub unresolved_threads: Option<i64>,
    pub merge_state_status: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct IssueLink {
    pub number: i64,
    pub url: Option<String>,
    pub title: Option<String>,
    pub body: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize, Default)]
#[serde(rename_all = "camelCase")]
pub struct ManualOverrides {
    #[serde(default)]
    pub worktree_path: bool,
    #[serde(default)]
    pub tmux_session: bool,
    #[serde(default)]
    pub name: bool,
    #[serde(default)]
    pub column: bool,
    #[serde(default)]
    pub pr_link: bool,
    #[serde(default)]
    pub issue_link: bool,
    pub dismissed_prs: Option<Vec<i64>>,
    pub branch_watermark: Option<usize>,
}

// ── Link (Card entity) ───────────────────────────────────────────────────────

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Link {
    pub id: String,
    pub name: Option<String>,
    pub project_path: Option<String>,
    pub column: String,
    pub created_at: DateTime<Utc>,
    pub updated_at: DateTime<Utc>,
    pub last_activity: Option<DateTime<Utc>>,
    #[serde(default)]
    pub manual_overrides: ManualOverrides,
    #[serde(default)]
    pub manually_archived: bool,
    #[serde(default = "default_source")]
    pub source: String,
    pub prompt_body: Option<String>,
    pub session_link: Option<SessionLink>,
    pub worktree_link: Option<WorktreeLink>,
    #[serde(default)]
    pub pr_links: Vec<PrLink>,
    pub issue_link: Option<IssueLink>,
    pub discovered_branches: Option<Vec<String>>,
    #[serde(default = "default_false")]
    pub is_remote: bool,
    pub is_launching: Option<bool>,
}

fn default_source() -> String {
    "discovered".to_string()
}

fn default_false() -> bool {
    false
}

impl Link {
    pub fn display_title(&self) -> String {
        if let Some(name) = &self.name {
            if !name.is_empty() {
                return name.clone();
            }
        }
        if let Some(body) = &self.prompt_body {
            if !body.is_empty() {
                return body.chars().take(100).collect();
            }
        }
        if let Some(wt) = &self.worktree_link {
            if let Some(branch) = &wt.branch {
                if !branch.is_empty() {
                    return branch.clone();
                }
            }
        }
        if let Some(pr) = self.pr_links.first() {
            if let Some(title) = &pr.title {
                if !title.is_empty() {
                    return title.clone();
                }
            }
        }
        if let Some(sl) = &self.session_link {
            return sl.session_id.clone();
        }
        self.id.clone()
    }

    fn new_card(prompt: String, title: Option<String>, project: String) -> Self {
        let now = Utc::now();
        let id = format!("card_{}", Uuid::new_v4().simple());
        Link {
            id,
            name: title,
            project_path: Some(project),
            column: "backlog".to_string(),
            created_at: now,
            updated_at: now,
            last_activity: None,
            manual_overrides: ManualOverrides::default(),
            manually_archived: false,
            source: "manual".to_string(),
            prompt_body: Some(prompt),
            session_link: None,
            worktree_link: None,
            pr_links: vec![],
            issue_link: None,
            discovered_branches: None,
            is_remote: false,
            is_launching: None,
        }
    }
}

// ── Container format ─────────────────────────────────────────────────────────

#[derive(Debug, Serialize, Deserialize, Default)]
struct LinksContainer {
    links: Vec<Link>,
}

// ── CoordinationStore ────────────────────────────────────────────────────────

pub struct CoordinationStore {
    file_path: PathBuf,
}

impl CoordinationStore {
    pub fn new(base_path: Option<PathBuf>) -> Self {
        let base = base_path.unwrap_or_else(|| {
            dirs::home_dir()
                .expect("no home dir")
                .join(".kanban-code")
        });
        Self {
            file_path: base.join("links.json"),
        }
    }

    pub async fn read_links(&self) -> Result<Vec<Link>> {
        if !self.file_path.exists() {
            return Ok(vec![]);
        }
        let data = fs::read(&self.file_path)
            .await
            .context("read links.json")?;
        let container: LinksContainer = serde_json::from_slice(&data).unwrap_or_default();
        Ok(container.links)
    }

    pub async fn write_links(&self, links: &[Link]) -> Result<()> {
        if let Some(parent) = self.file_path.parent() {
            fs::create_dir_all(parent).await.context("create .kanban-code dir")?;
        }
        let container = LinksContainer {
            links: links.to_vec(),
        };
        let data = serde_json::to_vec_pretty(&container).context("serialize links")?;
        let tmp = self.file_path.with_extension("json.tmp");
        fs::write(&tmp, &data).await.context("write tmp")?;
        fs::rename(&tmp, &self.file_path).await.context("rename tmp")?;
        Ok(())
    }

    pub async fn upsert_link(&self, link: &Link) -> Result<()> {
        let mut links = self.read_links().await?;
        if let Some(idx) = links.iter().position(|l| l.id == link.id) {
            links[idx] = link.clone();
        } else {
            links.push(link.clone());
        }
        self.write_links(&links).await
    }

    pub async fn move_card(&self, card_id: &str, column: &str) -> Result<()> {
        let mut links = self.read_links().await?;
        if let Some(link) = links.iter_mut().find(|l| l.id == card_id) {
            link.column = column.to_string();
            link.manual_overrides.column = true;
            if column == "all_sessions" {
                link.manually_archived = true;
            } else if link.manually_archived {
                link.manually_archived = false;
            }
            link.updated_at = Utc::now();
        }
        self.write_links(&links).await
    }

    pub async fn create_card(
        &self,
        prompt: String,
        title: Option<String>,
        project: String,
    ) -> Result<Link> {
        let link = Link::new_card(prompt, title, project);
        self.upsert_link(&link).await?;
        Ok(link)
    }

    pub async fn remove_link(&self, card_id: &str) -> Result<()> {
        let mut links = self.read_links().await?;
        links.retain(|l| l.id != card_id);
        self.write_links(&links).await
    }

    pub async fn archive_link(&self, card_id: &str) -> Result<()> {
        let mut links = self.read_links().await?;
        if let Some(link) = links.iter_mut().find(|l| l.id == card_id) {
            link.manually_archived = true;
            link.column = "all_sessions".to_string();
            link.updated_at = Utc::now();
        }
        self.write_links(&links).await
    }

    pub async fn rename_link(&self, card_id: &str, name: &str) -> Result<()> {
        let mut links = self.read_links().await?;
        if let Some(link) = links.iter_mut().find(|l| l.id == card_id) {
            link.name = Some(name.to_string());
            link.manual_overrides.name = true;
            link.updated_at = Utc::now();
        }
        self.write_links(&links).await
    }
}
