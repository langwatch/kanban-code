use anyhow::{anyhow, Context, Result};
use chrono::Utc;
use std::collections::BTreeMap;
use std::path::{Path, PathBuf};
use tokio::fs;
use tokio::io::AsyncWriteExt;

use crate::channels::{
    gen_id, is_valid_channel_name, normalize_channel_name, Channel, ChannelMember,
    ChannelMessage, ChannelParticipant, ChannelsContainer, MessageType,
};
use crate::coordination_store::kanban_data_dir;

const CHANNELS_FILE: &str = "channels.json";
const READ_STATE_FILE: &str = "read-state.json";
const DRAFTS_FILE: &str = "drafts.json";

/// Per-channel / per-DM unread tracking, keyed by last-read message id.
/// Mirrors `ChannelsStore.ReadState` in the macOS reference.
#[derive(Debug, Default, Clone, serde::Serialize, serde::Deserialize)]
pub struct ReadState {
    #[serde(default)]
    pub channels: BTreeMap<String, String>,
    #[serde(default)]
    pub dms: BTreeMap<String, String>,
}

/// Per-channel / per-DM unsent draft text.
#[derive(Debug, Default, Clone, serde::Serialize, serde::Deserialize)]
pub struct DraftsState {
    #[serde(default)]
    pub channels: BTreeMap<String, String>,
    #[serde(default)]
    pub dms: BTreeMap<String, String>,
}

/// Disk-backed store for chat channels. Mirrors the file layout used by the
/// TypeScript CLI (`cli/src/channels.ts`) and the macOS reference store, so the
/// three implementations can read each other's state.
///
/// Layout under `base_dir` (default: `<kanban_data_dir>/channels`):
///   channels.json
///   <name>.jsonl
///   dm/<keyA>__<keyB>.jsonl
///   images/<msg_id>/<idx>.<ext>
///   read-state.json
///   drafts.json
pub struct ChannelsStore {
    base_dir: PathBuf,
}

impl ChannelsStore {
    pub fn new(base_dir: Option<PathBuf>) -> Self {
        let base = base_dir.unwrap_or_else(|| kanban_data_dir().join("channels"));
        Self { base_dir: base }
    }

    pub fn base_dir(&self) -> &Path { &self.base_dir }

    fn channels_path(&self) -> PathBuf { self.base_dir.join(CHANNELS_FILE) }
    fn read_state_path(&self) -> PathBuf { self.base_dir.join(READ_STATE_FILE) }
    fn drafts_path(&self) -> PathBuf { self.base_dir.join(DRAFTS_FILE) }
    fn dm_dir(&self) -> PathBuf { self.base_dir.join("dm") }
    fn images_dir(&self) -> PathBuf { self.base_dir.join("images") }

    pub fn log_path(&self, channel: &str) -> PathBuf {
        self.base_dir.join(format!("{}.jsonl", channel))
    }

    /// Stable DM file path. The keys are sorted so `(a, b)` and `(b, a)` map to
    /// the same file — matches Swift's `dmLogPath` and the TS CLI.
    pub fn dm_log_path(&self, a: &ChannelParticipant, b: &ChannelParticipant) -> PathBuf {
        let mut keys = [a.party_key(), b.party_key()];
        keys.sort();
        self.dm_dir().join(format!("{}__{}.jsonl", keys[0], keys[1]))
    }

    pub async fn ensure_dirs(&self) -> Result<()> {
        fs::create_dir_all(&self.base_dir).await.context("create channels dir")?;
        fs::create_dir_all(self.dm_dir()).await.context("create dm dir")?;
        fs::create_dir_all(self.images_dir()).await.context("create images dir")?;
        Ok(())
    }

    /// Write `data` to `path` via a uniquely-named tmp file + atomic rename.
    /// The uuid'd tmp name keeps concurrent writers from clobbering each other —
    /// matches the macOS reference (`tmp-<uuid>` suffix).
    async fn write_atomic(&self, path: &Path, data: &[u8]) -> Result<()> {
        if let Some(parent) = path.parent() {
            fs::create_dir_all(parent).await.context("ensure parent dir")?;
        }
        let file_name = path.file_name().and_then(|s| s.to_str()).unwrap_or("file");
        let tmp = path.with_file_name(format!(
            "{}.tmp-{}",
            file_name,
            uuid::Uuid::new_v4().simple()
        ));
        fs::write(&tmp, data).await.context("write tmp")?;
        if let Err(e) = fs::rename(&tmp, path).await {
            let _ = fs::remove_file(&tmp).await;
            return Err(e).context("rename tmp");
        }
        Ok(())
    }

    // ── channels.json ────────────────────────────────────────────────────────

    pub async fn load_channels(&self) -> Result<Vec<Channel>> {
        match fs::read(self.channels_path()).await {
            Ok(bytes) => Ok(serde_json::from_slice::<ChannelsContainer>(&bytes)
                .map(|c| c.channels)
                .unwrap_or_default()),
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => Ok(Vec::new()),
            Err(e) => Err(e).context("read channels.json"),
        }
    }

    pub async fn save_channels(&self, channels: &[Channel]) -> Result<()> {
        self.ensure_dirs().await?;
        let container = ChannelsContainer { channels: channels.to_vec() };
        let data = serde_json::to_vec_pretty(&container).context("serialize channels")?;
        self.write_atomic(&self.channels_path(), &data).await
    }

    // ── Channel CRUD ─────────────────────────────────────────────────────────

    pub async fn create_channel(&self, name: &str, by: ChannelParticipant) -> Result<Channel> {
        let clean = normalize_channel_name(name);
        if !is_valid_channel_name(&clean) {
            return Err(anyhow!("invalid channel name '{}'", clean));
        }
        let mut all = self.load_channels().await?;
        if all.iter().any(|c| c.name == clean) {
            return Err(anyhow!("channel '{}' already exists", clean));
        }
        let channel = Channel {
            id: gen_id("ch"),
            name: clean.clone(),
            created_at: Utc::now(),
            created_by: by,
            members: Vec::new(),
            sort_order: None,
        };
        all.push(channel.clone());
        self.save_channels(&all).await?;
        // Touch the log file so watchers can subscribe before the first message.
        let log = self.log_path(&clean);
        if !log.exists() {
            fs::write(&log, b"").await.context("touch log file")?;
        }
        Ok(channel)
    }

    pub async fn list_channels(&self) -> Result<Vec<Channel>> { self.load_channels().await }

    pub async fn delete_channel(&self, name: &str) -> Result<bool> {
        let clean = normalize_channel_name(name);
        let mut all = self.load_channels().await?;
        let before = all.len();
        all.retain(|c| c.name != clean);
        if all.len() == before { return Ok(false); }
        self.save_channels(&all).await?;
        Ok(true)
    }

    pub async fn rename_channel(&self, old: &str, new: &str) -> Result<bool> {
        let old_clean = normalize_channel_name(old);
        let new_clean = normalize_channel_name(new);
        if old_clean.is_empty() || new_clean.is_empty() || old_clean == new_clean {
            return Ok(false);
        }
        if !is_valid_channel_name(&new_clean) {
            return Err(anyhow!("invalid channel name '{}'", new_clean));
        }
        let mut all = self.load_channels().await?;
        let idx = match all.iter().position(|c| c.name == old_clean) {
            Some(i) => i,
            None => return Ok(false),
        };
        if all.iter().any(|c| c.name == new_clean) {
            return Err(anyhow!("channel '{}' already exists", new_clean));
        }
        all[idx].name = new_clean.clone();
        self.save_channels(&all).await?;

        let old_log = self.log_path(&old_clean);
        let new_log = self.log_path(&new_clean);
        if old_log.exists() {
            if new_log.exists() { let _ = fs::remove_file(&new_log).await; }
            fs::rename(&old_log, &new_log).await.context("move log file")?;
        }

        // Carry over read state under the new name.
        let mut rs = self.load_read_state().await?;
        if let Some(id) = rs.channels.remove(&old_clean) {
            rs.channels.insert(new_clean.clone(), id);
            self.save_read_state(&rs).await?;
        }
        Ok(true)
    }

    // ── Membership ───────────────────────────────────────────────────────────

    /// Adds `member` to `channel`. Returns the updated channel and a flag that's
    /// true when the member was already present.
    pub async fn join_channel(
        &self,
        name: &str,
        member: ChannelParticipant,
    ) -> Result<(Channel, bool)> {
        let clean = normalize_channel_name(name);
        let mut all = self.load_channels().await?;
        let idx = all
            .iter()
            .position(|c| c.name == clean)
            .ok_or_else(|| anyhow!("channel '{}' does not exist", clean))?;
        let already = all[idx].members.iter().any(|m| same_party(m_as_participant(m), &member));
        if already {
            return Ok((all[idx].clone(), true));
        }
        all[idx].members.push(ChannelMember {
            card_id: member.card_id.clone(),
            handle: member.handle.clone(),
            joined_at: Utc::now(),
        });
        let channel_after = all[idx].clone();
        self.save_channels(&all).await?;
        let event = ChannelMessage {
            id: gen_id("msg"),
            ts: Utc::now(),
            from: member.clone(),
            body: format!("@{} joined #{}", member.handle, clean),
            kind: MessageType::Join,
            image_paths: None,
            source: None,
        };
        self.append_message(&clean, &event).await?;
        Ok((channel_after, false))
    }

    /// Removes `member` from `channel`. No-op when the channel doesn't exist or
    /// `member` isn't in it. Returns the updated channel (if it existed).
    pub async fn leave_channel(
        &self,
        name: &str,
        member: ChannelParticipant,
    ) -> Result<Option<Channel>> {
        let clean = normalize_channel_name(name);
        let mut all = self.load_channels().await?;
        let idx = match all.iter().position(|c| c.name == clean) {
            Some(i) => i,
            None => return Ok(None),
        };
        let leaving = all[idx].members.iter().find(|m| same_party(m_as_participant(m), &member)).cloned();
        let Some(leaving) = leaving else { return Ok(Some(all[idx].clone())); };
        all[idx].members.retain(|m| !same_party(m_as_participant(m), &member));
        let channel_after = all[idx].clone();
        self.save_channels(&all).await?;
        let event = ChannelMessage {
            id: gen_id("msg"),
            ts: Utc::now(),
            from: ChannelParticipant { card_id: leaving.card_id, handle: leaving.handle.clone() },
            body: format!("@{} left #{}", leaving.handle, clean),
            kind: MessageType::Leave,
            image_paths: None,
            source: None,
        };
        self.append_message(&clean, &event).await?;
        Ok(Some(channel_after))
    }

    // ── Messages ─────────────────────────────────────────────────────────────

    pub async fn append_message(&self, channel: &str, msg: &ChannelMessage) -> Result<()> {
        self.ensure_dirs().await?;
        let path = self.log_path(channel);
        Self::append_jsonl(&path, msg).await
    }

    pub async fn send_message(
        &self,
        channel: &str,
        from: ChannelParticipant,
        body: String,
        image_paths: Vec<String>,
    ) -> Result<ChannelMessage> {
        let clean = normalize_channel_name(channel);
        let all = self.load_channels().await?;
        if !all.iter().any(|c| c.name == clean) {
            return Err(anyhow!("channel '{}' does not exist", clean));
        }
        let id = gen_id("msg");
        let persisted = self.persist_images(&id, &image_paths).await?;
        let msg = ChannelMessage {
            id,
            ts: Utc::now(),
            from,
            body,
            kind: MessageType::Message,
            image_paths: if persisted.is_empty() { None } else { Some(persisted) },
            source: None,
        };
        self.append_message(&clean, &msg).await?;
        Ok(msg)
    }

    pub async fn read_messages(
        &self,
        channel: &str,
        limit: Option<usize>,
    ) -> Result<Vec<ChannelMessage>> {
        let path = self.log_path(&normalize_channel_name(channel));
        Self::read_jsonl(&path, limit).await
    }

    // ── DMs ──────────────────────────────────────────────────────────────────

    pub async fn send_dm(
        &self,
        from: ChannelParticipant,
        to: ChannelParticipant,
        body: String,
        image_paths: Vec<String>,
    ) -> Result<ChannelMessage> {
        self.ensure_dirs().await?;
        let id = gen_id("msg");
        let persisted = self.persist_images(&id, &image_paths).await?;
        let msg = ChannelMessage {
            id,
            ts: Utc::now(),
            from: from.clone(),
            body,
            kind: MessageType::Message,
            image_paths: if persisted.is_empty() { None } else { Some(persisted) },
            source: None,
        };
        let path = self.dm_log_path(&from, &to);
        Self::append_jsonl(&path, &msg).await?;
        Ok(msg)
    }

    pub async fn read_dm_messages(
        &self,
        a: &ChannelParticipant,
        b: &ChannelParticipant,
        limit: Option<usize>,
    ) -> Result<Vec<ChannelMessage>> {
        let path = self.dm_log_path(a, b);
        Self::read_jsonl(&path, limit).await
    }

    /// Lists DM pair keys (filenames without extension) currently in `dm/`.
    pub async fn list_dm_pairs(&self) -> Result<Vec<String>> {
        let dir = self.dm_dir();
        let mut entries = match fs::read_dir(&dir).await {
            Ok(e) => e,
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => return Ok(Vec::new()),
            Err(e) => return Err(e).context("read dm dir"),
        };
        let mut out = Vec::new();
        while let Some(entry) = entries.next_entry().await.context("read dm entry")? {
            let path = entry.path();
            if path.extension().and_then(|s| s.to_str()) != Some("jsonl") { continue; }
            if let Some(stem) = path.file_stem().and_then(|s| s.to_str()) {
                out.push(stem.to_string());
            }
        }
        out.sort();
        Ok(out)
    }

    // ── Images ───────────────────────────────────────────────────────────────

    /// Copies each source image into `<base>/images/<msg_id>/<idx>.<ext>` and
    /// returns the persistent paths. Sources that don't exist are silently
    /// skipped — matches the TS CLI's behavior so callers can pass user-supplied
    /// paths without pre-validating.
    pub async fn persist_images(&self, message_id: &str, sources: &[String]) -> Result<Vec<String>> {
        if sources.is_empty() { return Ok(Vec::new()); }
        self.ensure_dirs().await?;
        let msg_dir = self.images_dir().join(message_id);
        fs::create_dir_all(&msg_dir).await.context("create message images dir")?;
        let mut out = Vec::new();
        for (i, src_str) in sources.iter().enumerate() {
            let src = Path::new(src_str);
            if !src.exists() { continue; }
            let ext = src
                .extension()
                .and_then(|s| s.to_str())
                .map(|s| s.to_ascii_lowercase())
                .filter(|s| !s.is_empty())
                .unwrap_or_else(|| "png".to_string());
            let dest = msg_dir.join(format!("{}.{}", i, ext));
            if dest.exists() { let _ = fs::remove_file(&dest).await; }
            fs::copy(src, &dest).await.context("copy image")?;
            out.push(dest.to_string_lossy().into_owned());
        }
        Ok(out)
    }

    // ── Read state ───────────────────────────────────────────────────────────

    pub async fn load_read_state(&self) -> Result<ReadState> {
        match fs::read(self.read_state_path()).await {
            Ok(bytes) => Ok(serde_json::from_slice(&bytes).unwrap_or_default()),
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => Ok(ReadState::default()),
            Err(e) => Err(e).context("read read-state.json"),
        }
    }

    pub async fn save_read_state(&self, state: &ReadState) -> Result<()> {
        self.ensure_dirs().await?;
        let data = serde_json::to_vec_pretty(state).context("serialize read state")?;
        self.write_atomic(&self.read_state_path(), &data).await
    }

    // ── Drafts ───────────────────────────────────────────────────────────────

    pub async fn load_drafts(&self) -> Result<DraftsState> {
        match fs::read(self.drafts_path()).await {
            Ok(bytes) => Ok(serde_json::from_slice(&bytes).unwrap_or_default()),
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => Ok(DraftsState::default()),
            Err(e) => Err(e).context("read drafts.json"),
        }
    }

    pub async fn save_drafts(&self, drafts: &DraftsState) -> Result<()> {
        self.ensure_dirs().await?;
        let data = serde_json::to_vec_pretty(drafts).context("serialize drafts")?;
        self.write_atomic(&self.drafts_path(), &data).await
    }

    // ── jsonl helpers ────────────────────────────────────────────────────────

    async fn append_jsonl(path: &Path, msg: &ChannelMessage) -> Result<()> {
        if let Some(parent) = path.parent() {
            fs::create_dir_all(parent).await.context("ensure parent dir")?;
        }
        // jsonl invariant: one JSON object per line, no embedded newlines.
        let mut line = serde_json::to_string(msg).context("serialize message")?;
        if line.contains('\n') {
            line = line.replace('\n', " ");
        }
        line.push('\n');
        let mut file = fs::OpenOptions::new()
            .create(true)
            .append(true)
            .open(path)
            .await
            .context("open jsonl")?;
        file.write_all(line.as_bytes()).await.context("write jsonl line")?;
        file.flush().await.context("flush jsonl")?;
        Ok(())
    }

    async fn read_jsonl(path: &Path, limit: Option<usize>) -> Result<Vec<ChannelMessage>> {
        let bytes = match fs::read(path).await {
            Ok(b) => b,
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => return Ok(Vec::new()),
            Err(e) => return Err(e).context("read jsonl"),
        };
        let text = String::from_utf8_lossy(&bytes);
        let mut msgs: Vec<ChannelMessage> = Vec::new();
        for line in text.split('\n') {
            let trimmed = line.trim();
            if trimmed.is_empty() { continue; }
            if let Ok(m) = serde_json::from_str::<ChannelMessage>(trimmed) {
                msgs.push(m);
            }
            // Silently skip corrupt lines — matches Swift/TS leniency.
        }
        if let Some(n) = limit {
            if msgs.len() > n {
                msgs.drain(0..msgs.len() - n);
            }
        }
        Ok(msgs)
    }
}

fn m_as_participant(m: &ChannelMember) -> ChannelParticipant {
    ChannelParticipant { card_id: m.card_id.clone(), handle: m.handle.clone() }
}

/// Match by `card_id` when both sides have one; otherwise fall back to `handle`.
fn same_party(a: ChannelParticipant, b: &ChannelParticipant) -> bool {
    if a.card_id.is_some() && b.card_id.is_some() {
        a.card_id == b.card_id
    } else {
        a.handle == b.handle
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::channels::{ChannelParticipant, MessageType};

    fn tmp_base() -> PathBuf {
        std::env::temp_dir()
            .join(format!("kanban-channels-{}", uuid::Uuid::new_v4().simple()))
    }

    #[tokio::test]
    async fn create_then_list_roundtrip() {
        let base = tmp_base();
        let store = ChannelsStore::new(Some(base.clone()));
        let ch = store
            .create_channel("general", ChannelParticipant::user("user"))
            .await
            .unwrap();
        assert_eq!(ch.name, "general");
        let listed = store.list_channels().await.unwrap();
        assert_eq!(listed.len(), 1);
        assert_eq!(listed[0].name, "general");
        let _ = std::fs::remove_dir_all(&base);
    }

    #[tokio::test]
    async fn duplicate_create_is_rejected() {
        let base = tmp_base();
        let store = ChannelsStore::new(Some(base.clone()));
        store.create_channel("dup", ChannelParticipant::user("user")).await.unwrap();
        let err = store
            .create_channel("dup", ChannelParticipant::user("user"))
            .await
            .unwrap_err();
        assert!(err.to_string().contains("already exists"));
        let _ = std::fs::remove_dir_all(&base);
    }

    #[tokio::test]
    async fn send_then_read_messages() {
        let base = tmp_base();
        let store = ChannelsStore::new(Some(base.clone()));
        store.create_channel("eng", ChannelParticipant::user("user")).await.unwrap();
        let sent = store
            .send_message("eng", ChannelParticipant::user("user"), "hi".into(), vec![])
            .await
            .unwrap();
        assert!(sent.id.starts_with("msg_"));
        let msgs = store.read_messages("eng", None).await.unwrap();
        assert_eq!(msgs.len(), 1);
        assert_eq!(msgs[0].body, "hi");
        assert_eq!(msgs[0].kind, MessageType::Message);
        let _ = std::fs::remove_dir_all(&base);
    }

    #[tokio::test]
    async fn join_appends_event_and_marks_membership() {
        let base = tmp_base();
        let store = ChannelsStore::new(Some(base.clone()));
        store.create_channel("ops", ChannelParticipant::user("user")).await.unwrap();
        let (_, already) = store
            .join_channel("ops", ChannelParticipant::card("card_1", "alice"))
            .await
            .unwrap();
        assert!(!already);
        let (_, already2) = store
            .join_channel("ops", ChannelParticipant::card("card_1", "alice"))
            .await
            .unwrap();
        assert!(already2);
        let msgs = store.read_messages("ops", None).await.unwrap();
        // exactly one join event
        assert_eq!(msgs.iter().filter(|m| m.kind == MessageType::Join).count(), 1);
        let _ = std::fs::remove_dir_all(&base);
    }

    #[tokio::test]
    async fn rename_moves_log_and_keeps_messages() {
        let base = tmp_base();
        let store = ChannelsStore::new(Some(base.clone()));
        store.create_channel("old", ChannelParticipant::user("user")).await.unwrap();
        store
            .send_message("old", ChannelParticipant::user("user"), "carryover".into(), vec![])
            .await
            .unwrap();
        let moved = store.rename_channel("old", "new").await.unwrap();
        assert!(moved);
        let msgs = store.read_messages("new", None).await.unwrap();
        assert_eq!(msgs.len(), 1);
        assert_eq!(msgs[0].body, "carryover");
        let _ = std::fs::remove_dir_all(&base);
    }

    #[tokio::test]
    async fn dm_path_is_pair_stable() {
        let base = tmp_base();
        let store = ChannelsStore::new(Some(base.clone()));
        let a = ChannelParticipant::card("card_a", "alice");
        let b = ChannelParticipant::card("card_b", "bob");
        let p1 = store.dm_log_path(&a, &b);
        let p2 = store.dm_log_path(&b, &a);
        assert_eq!(p1, p2);
        let _ = std::fs::remove_dir_all(&base);
    }

    #[tokio::test]
    async fn dm_send_then_read() {
        let base = tmp_base();
        let store = ChannelsStore::new(Some(base.clone()));
        let a = ChannelParticipant::user("alice");
        let b = ChannelParticipant::user("bob");
        let msg = store
            .send_dm(a.clone(), b.clone(), "hello bob".into(), vec![])
            .await
            .unwrap();
        let read = store.read_dm_messages(&b, &a, None).await.unwrap();
        assert_eq!(read.len(), 1);
        assert_eq!(read[0].id, msg.id);
        assert_eq!(read[0].body, "hello bob");
        let _ = std::fs::remove_dir_all(&base);
    }

    #[tokio::test]
    async fn tail_returns_last_n_only() {
        let base = tmp_base();
        let store = ChannelsStore::new(Some(base.clone()));
        store.create_channel("t", ChannelParticipant::user("user")).await.unwrap();
        for i in 0..5 {
            store
                .send_message("t", ChannelParticipant::user("user"), format!("m{}", i), vec![])
                .await
                .unwrap();
        }
        let tail = store.read_messages("t", Some(2)).await.unwrap();
        assert_eq!(tail.len(), 2);
        assert_eq!(tail[0].body, "m3");
        assert_eq!(tail[1].body, "m4");
        let _ = std::fs::remove_dir_all(&base);
    }

    #[tokio::test]
    async fn read_state_roundtrip() {
        let base = tmp_base();
        let store = ChannelsStore::new(Some(base.clone()));
        let mut rs = ReadState::default();
        rs.channels.insert("general".into(), "msg_abc".into());
        store.save_read_state(&rs).await.unwrap();
        let loaded = store.load_read_state().await.unwrap();
        assert_eq!(loaded.channels.get("general"), Some(&"msg_abc".to_string()));
        let _ = std::fs::remove_dir_all(&base);
    }

    #[tokio::test]
    async fn ts_cli_channel_shape_parses() {
        let base = tmp_base();
        std::fs::create_dir_all(&base).unwrap();
        // Drop a TS-CLI-shaped channels.json directly on disk and load it.
        let raw = r#"{
  "channels": [
    {
      "id": "ch_abcdef0123456789",
      "name": "general",
      "createdAt": "2024-01-15T12:34:56.789Z",
      "createdBy": { "cardId": null, "handle": "user" },
      "members": []
    }
  ]
}"#;
        std::fs::write(base.join("channels.json"), raw).unwrap();
        let store = ChannelsStore::new(Some(base.clone()));
        let channels = store.load_channels().await.unwrap();
        assert_eq!(channels.len(), 1);
        assert_eq!(channels[0].name, "general");
        let _ = std::fs::remove_dir_all(&base);
    }

    #[tokio::test]
    async fn jsonl_line_replaces_embedded_newlines() {
        let base = tmp_base();
        let store = ChannelsStore::new(Some(base.clone()));
        store.create_channel("multiline", ChannelParticipant::user("user")).await.unwrap();
        let sent = store
            .send_message(
                "multiline",
                ChannelParticipant::user("user"),
                "line1\nline2".into(),
                vec![],
            )
            .await
            .unwrap();
        // Body keeps the newline (serialized as \n inside the JSON string), but
        // the file line itself must be a single physical line — so reading and
        // re-parsing yields exactly one message.
        let msgs = store.read_messages("multiline", None).await.unwrap();
        assert_eq!(msgs.len(), 1);
        assert_eq!(msgs[0].id, sent.id);
        assert_eq!(msgs[0].body, "line1\nline2");
        let _ = std::fs::remove_dir_all(&base);
    }
}
