use anyhow::{anyhow, Context, Result};
use chrono::Utc;
use std::collections::BTreeMap;
use std::io::{Read, Seek, SeekFrom};
use std::path::{Path, PathBuf};
use tokio::fs;
use tokio::io::AsyncWriteExt;

use crate::channels::{
    extract_mentions, gen_id, is_valid_channel_name, normalize_channel_name, Channel,
    ChannelMember, ChannelMessage, ChannelParticipant, ChannelsContainer, MessageRefs,
    MessageType,
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
            refs: None,
            mentions: None,
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
            refs: None,
            mentions: None,
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
        let mentions = extract_mentions(&body);
        let msg = ChannelMessage {
            id,
            ts: Utc::now(),
            from,
            body,
            kind: MessageType::Message,
            image_paths: if persisted.is_empty() { None } else { Some(persisted) },
            source: None,
            refs: None,
            mentions: if mentions.is_empty() { None } else { Some(mentions) },
        };
        self.append_message(&clean, &msg).await?;
        Ok(msg)
    }

    /// Appends an Edit row for `target_id`. The render layer collapses by
    /// taking the latest Edit for each target id (#113).
    pub async fn edit_channel_message(
        &self,
        channel: &str,
        target_id: &str,
        from: ChannelParticipant,
        new_body: String,
    ) -> Result<ChannelMessage> {
        let clean = normalize_channel_name(channel);
        let mentions = extract_mentions(&new_body);
        let msg = ChannelMessage {
            id: gen_id("msg"),
            ts: Utc::now(),
            from,
            body: new_body,
            kind: MessageType::Edit,
            image_paths: None,
            source: None,
            refs: Some(MessageRefs {
                edits_message_id: Some(target_id.to_string()),
                reaction_to: None,
                emoji: None,
            }),
            mentions: if mentions.is_empty() { None } else { Some(mentions) },
        };
        self.append_message(&clean, &msg).await?;
        Ok(msg)
    }

    /// Appends a Delete row for `target_id`; render layer hides it (#113).
    pub async fn delete_channel_message(
        &self,
        channel: &str,
        target_id: &str,
        from: ChannelParticipant,
    ) -> Result<ChannelMessage> {
        let clean = normalize_channel_name(channel);
        let msg = ChannelMessage {
            id: gen_id("msg"),
            ts: Utc::now(),
            from,
            body: String::new(),
            kind: MessageType::Delete,
            image_paths: None,
            source: None,
            refs: Some(MessageRefs {
                edits_message_id: Some(target_id.to_string()),
                reaction_to: None,
                emoji: None,
            }),
            mentions: None,
        };
        self.append_message(&clean, &msg).await?;
        Ok(msg)
    }

    /// Appends a Reaction row; render layer aggregates by (target, emoji)
    /// and toggles by count parity per sender (#113).
    pub async fn react_channel_message(
        &self,
        channel: &str,
        target_id: &str,
        from: ChannelParticipant,
        emoji: String,
    ) -> Result<ChannelMessage> {
        let clean = normalize_channel_name(channel);
        let msg = ChannelMessage {
            id: gen_id("msg"),
            ts: Utc::now(),
            from,
            body: String::new(),
            kind: MessageType::Reaction,
            image_paths: None,
            source: None,
            refs: Some(MessageRefs {
                edits_message_id: None,
                reaction_to: Some(target_id.to_string()),
                emoji: Some(emoji),
            }),
            mentions: None,
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
        let mentions = extract_mentions(&body);
        let msg = ChannelMessage {
            id,
            ts: Utc::now(),
            from: from.clone(),
            body,
            kind: MessageType::Message,
            image_paths: if persisted.is_empty() { None } else { Some(persisted) },
            source: None,
            refs: None,
            mentions: if mentions.is_empty() { None } else { Some(mentions) },
        };
        let path = self.dm_log_path(&from, &to);
        Self::append_jsonl(&path, &msg).await?;
        Ok(msg)
    }

    pub async fn edit_dm_message(
        &self,
        a: &ChannelParticipant,
        b: &ChannelParticipant,
        target_id: &str,
        from: ChannelParticipant,
        new_body: String,
    ) -> Result<ChannelMessage> {
        self.ensure_dirs().await?;
        let mentions = extract_mentions(&new_body);
        let msg = ChannelMessage {
            id: gen_id("msg"),
            ts: Utc::now(),
            from,
            body: new_body,
            kind: MessageType::Edit,
            image_paths: None,
            source: None,
            refs: Some(MessageRefs {
                edits_message_id: Some(target_id.to_string()),
                reaction_to: None,
                emoji: None,
            }),
            mentions: if mentions.is_empty() { None } else { Some(mentions) },
        };
        Self::append_jsonl(&self.dm_log_path(a, b), &msg).await?;
        Ok(msg)
    }

    pub async fn delete_dm_message(
        &self,
        a: &ChannelParticipant,
        b: &ChannelParticipant,
        target_id: &str,
        from: ChannelParticipant,
    ) -> Result<ChannelMessage> {
        self.ensure_dirs().await?;
        let msg = ChannelMessage {
            id: gen_id("msg"),
            ts: Utc::now(),
            from,
            body: String::new(),
            kind: MessageType::Delete,
            image_paths: None,
            source: None,
            refs: Some(MessageRefs {
                edits_message_id: Some(target_id.to_string()),
                reaction_to: None,
                emoji: None,
            }),
            mentions: None,
        };
        Self::append_jsonl(&self.dm_log_path(a, b), &msg).await?;
        Ok(msg)
    }

    pub async fn react_dm_message(
        &self,
        a: &ChannelParticipant,
        b: &ChannelParticipant,
        target_id: &str,
        from: ChannelParticipant,
        emoji: String,
    ) -> Result<ChannelMessage> {
        self.ensure_dirs().await?;
        let msg = ChannelMessage {
            id: gen_id("msg"),
            ts: Utc::now(),
            from,
            body: String::new(),
            kind: MessageType::Reaction,
            image_paths: None,
            source: None,
            refs: Some(MessageRefs {
                edits_message_id: None,
                reaction_to: Some(target_id.to_string()),
                emoji: Some(emoji),
            }),
            mentions: None,
        };
        Self::append_jsonl(&self.dm_log_path(a, b), &msg).await?;
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
        match limit {
            None => Self::read_jsonl_all(path).await,
            Some(n) => Self::read_jsonl_tail(path, n).await,
        }
    }

    async fn read_jsonl_all(path: &Path) -> Result<Vec<ChannelMessage>> {
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
        Ok(msgs)
    }

    /// Reverse-tail reader: walks back from EOF in 64 KB chunks until `n`
    /// complete lines are accumulated (or BOF). Memory is O(n × avg_line)
    /// for typical messages, with `pending` growing only when a single line
    /// exceeds the chunk size. See #114.
    async fn read_jsonl_tail(path: &Path, n: usize) -> Result<Vec<ChannelMessage>> {
        if n == 0 { return Ok(Vec::new()); }
        let path_buf = path.to_path_buf();
        let lines = tokio::task::spawn_blocking(move || -> Result<Vec<String>> {
            let mut file = match std::fs::File::open(&path_buf) {
                Ok(f) => f,
                Err(e) if e.kind() == std::io::ErrorKind::NotFound => return Ok(Vec::new()),
                Err(e) => return Err(e.into()),
            };
            let size = file.seek(SeekFrom::End(0))?;
            if size == 0 { return Ok(Vec::new()); }

            const CHUNK_SIZE: u64 = 64 * 1024;
            let mut pos: u64 = size;
            // Tail bytes of an in-progress line whose terminating '\n' lives
            // in a chunk we've already processed (later in the file).
            let mut pending = Vec::<u8>::new();
            let mut lines: Vec<String> = Vec::with_capacity(n);

            'outer: while pos > 0 {
                let read_size = CHUNK_SIZE.min(pos);
                let read_from = pos - read_size;
                file.seek(SeekFrom::Start(read_from))?;
                let mut new_chunk = vec![0u8; read_size as usize];
                file.read_exact(&mut new_chunk)?;
                pos = read_from;
                let reached_bof = pos == 0;

                // Indices of '\n' bytes within new_chunk (earliest first).
                let nl_positions: Vec<usize> = new_chunk
                    .iter()
                    .enumerate()
                    .filter_map(|(i, b)| (*b == b'\n').then_some(i))
                    .collect();

                if nl_positions.is_empty() {
                    // Whole chunk is body of an in-progress line — prepend
                    // to pending. At BOF that's the complete first line.
                    let mut combined = new_chunk;
                    combined.extend_from_slice(&pending);
                    if reached_bof {
                        push_line(&mut lines, &combined);
                        if lines.len() >= n { break 'outer; }
                    } else {
                        pending = combined;
                    }
                    continue;
                }

                let first_nl = *nl_positions.first().unwrap();
                let last_nl = *nl_positions.last().unwrap();

                // Bytes after the last '\n' + pending form one complete line
                // (its terminator was consumed in a previous iter, or, on
                // the very first chunk of an unterminated file, it's the
                // no-terminator trailing line).
                let trailing = &new_chunk[last_nl + 1..];
                if !trailing.is_empty() || !pending.is_empty() {
                    let mut combined = trailing.to_vec();
                    combined.extend_from_slice(&pending);
                    push_line(&mut lines, &combined);
                    if lines.len() >= n { break 'outer; }
                }
                pending.clear();

                // Interior complete lines (between consecutive '\n's),
                // newest first.
                for w in nl_positions.windows(2).rev() {
                    let s = w[0] + 1;
                    let e = w[1];
                    if e > s {
                        push_line(&mut lines, &new_chunk[s..e]);
                        if lines.len() >= n { break 'outer; }
                    }
                }

                // Bytes before the first '\n' are the tail of a line whose
                // head is in an even earlier chunk — save as pending. At
                // BOF they're a complete line.
                let head = &new_chunk[..first_nl];
                if reached_bof {
                    if !head.is_empty() {
                        push_line(&mut lines, head);
                        if lines.len() >= n { break 'outer; }
                    }
                } else if !head.is_empty() {
                    pending = head.to_vec();
                }
            }

            Ok(lines)
        })
        .await
        .context("spawn_blocking read_jsonl_tail")??;

        // `lines` is newest-first. Walk in chronological order, parsing
        // leniently — corrupt lines are dropped (matches the whole-file path).
        let mut msgs: Vec<ChannelMessage> = Vec::with_capacity(lines.len());
        for line in lines.into_iter().rev() {
            if let Ok(m) = serde_json::from_str::<ChannelMessage>(&line) {
                msgs.push(m);
            }
        }
        Ok(msgs)
    }
}

fn push_line(lines: &mut Vec<String>, bytes: &[u8]) {
    let s = String::from_utf8_lossy(bytes).trim().to_string();
    if !s.is_empty() {
        lines.push(s);
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

    // ── #113 edit/delete/react ───────────────────────────────────────────

    #[tokio::test]
    async fn edit_delete_react_round_trip() {
        let base = tmp_base();
        let store = ChannelsStore::new(Some(base.clone()));
        store.create_channel("eng", ChannelParticipant::user("user")).await.unwrap();
        let original = store
            .send_message(
                "eng",
                ChannelParticipant::user("user"),
                "hi @alice and @bob".into(),
                vec![],
            )
            .await
            .unwrap();
        // mentions populated on send
        assert_eq!(
            original.mentions.as_ref().map(|m| m.as_slice()),
            Some(["alice".to_string(), "bob".to_string()].as_slice())
        );

        let edit = store
            .edit_channel_message("eng", &original.id, ChannelParticipant::user("user"), "hi @carol".into())
            .await
            .unwrap();
        assert_eq!(edit.kind, MessageType::Edit);
        assert_eq!(
            edit.refs.as_ref().and_then(|r| r.edits_message_id.as_deref()),
            Some(original.id.as_str())
        );
        assert_eq!(
            edit.mentions.as_ref().map(|m| m.as_slice()),
            Some(["carol".to_string()].as_slice())
        );

        let react = store
            .react_channel_message("eng", &original.id, ChannelParticipant::user("user"), "🎉".into())
            .await
            .unwrap();
        assert_eq!(react.kind, MessageType::Reaction);
        assert_eq!(
            react.refs.as_ref().and_then(|r| r.emoji.as_deref()),
            Some("🎉")
        );

        let del = store
            .delete_channel_message("eng", &original.id, ChannelParticipant::user("user"))
            .await
            .unwrap();
        assert_eq!(del.kind, MessageType::Delete);

        // All four rows survive a re-read.
        let all = store.read_messages("eng", None).await.unwrap();
        assert_eq!(all.len(), 4);
        assert_eq!(all[0].kind, MessageType::Message);
        assert_eq!(all[1].kind, MessageType::Edit);
        assert_eq!(all[2].kind, MessageType::Reaction);
        assert_eq!(all[3].kind, MessageType::Delete);
        let _ = std::fs::remove_dir_all(&base);
    }

    // ── #114 chunked reverse-tail ────────────────────────────────────────

    fn synthetic_jsonl_line(idx: usize) -> String {
        format!(
            r#"{{"id":"msg_{idx:08x}","ts":"2024-01-15T12:34:56.789Z","from":{{"cardId":null,"handle":"user"}},"body":"line {idx}","type":"message"}}"#
        )
    }

    #[tokio::test]
    async fn read_tail_empty_file() {
        let base = tmp_base();
        std::fs::create_dir_all(&base).unwrap();
        let path = base.join("empty.jsonl");
        std::fs::write(&path, b"").unwrap();
        let msgs = ChannelsStore::read_jsonl(&path, Some(10)).await.unwrap();
        assert!(msgs.is_empty());
        let _ = std::fs::remove_dir_all(&base);
    }

    #[tokio::test]
    async fn read_tail_missing_file_is_empty() {
        let base = tmp_base();
        let path = base.join("ghost.jsonl");
        let msgs = ChannelsStore::read_jsonl(&path, Some(10)).await.unwrap();
        assert!(msgs.is_empty());
    }

    #[tokio::test]
    async fn read_tail_fewer_than_n() {
        let base = tmp_base();
        std::fs::create_dir_all(&base).unwrap();
        let path = base.join("few.jsonl");
        let lines: String = (0..3).map(|i| format!("{}\n", synthetic_jsonl_line(i))).collect();
        std::fs::write(&path, lines).unwrap();
        let msgs = ChannelsStore::read_jsonl(&path, Some(10)).await.unwrap();
        assert_eq!(msgs.len(), 3);
        assert_eq!(msgs[0].body, "line 0");
        assert_eq!(msgs[2].body, "line 2");
        let _ = std::fs::remove_dir_all(&base);
    }

    #[tokio::test]
    async fn read_tail_exactly_n() {
        let base = tmp_base();
        std::fs::create_dir_all(&base).unwrap();
        let path = base.join("exact.jsonl");
        let lines: String = (0..5).map(|i| format!("{}\n", synthetic_jsonl_line(i))).collect();
        std::fs::write(&path, lines).unwrap();
        let msgs = ChannelsStore::read_jsonl(&path, Some(5)).await.unwrap();
        assert_eq!(msgs.len(), 5);
        assert_eq!(msgs[0].body, "line 0");
        assert_eq!(msgs[4].body, "line 4");
        let _ = std::fs::remove_dir_all(&base);
    }

    #[tokio::test]
    async fn read_tail_many_more_than_n() {
        let base = tmp_base();
        std::fs::create_dir_all(&base).unwrap();
        let path = base.join("many.jsonl");
        let lines: String = (0..1000).map(|i| format!("{}\n", synthetic_jsonl_line(i))).collect();
        std::fs::write(&path, lines).unwrap();
        let msgs = ChannelsStore::read_jsonl(&path, Some(20)).await.unwrap();
        assert_eq!(msgs.len(), 20);
        // Last 20 messages, in chronological order.
        assert_eq!(msgs[0].body, "line 980");
        assert_eq!(msgs[19].body, "line 999");
        let _ = std::fs::remove_dir_all(&base);
    }

    #[tokio::test]
    async fn read_tail_oversized_single_line() {
        // One line bigger than the 64 KB chunk; verify pending grows.
        let base = tmp_base();
        std::fs::create_dir_all(&base).unwrap();
        let path = base.join("huge.jsonl");
        let big_body = "x".repeat(200_000);
        let huge_line = format!(
            r#"{{"id":"msg_huge","ts":"2024-01-15T12:34:56.789Z","from":{{"cardId":null,"handle":"user"}},"body":"{big_body}","type":"message"}}"#
        );
        let content = format!("{}\n{}\n", synthetic_jsonl_line(0), huge_line);
        std::fs::write(&path, content).unwrap();
        let msgs = ChannelsStore::read_jsonl(&path, Some(1)).await.unwrap();
        assert_eq!(msgs.len(), 1);
        assert_eq!(msgs[0].id, "msg_huge");
        assert_eq!(msgs[0].body.len(), 200_000);
        let msgs2 = ChannelsStore::read_jsonl(&path, Some(2)).await.unwrap();
        assert_eq!(msgs2.len(), 2);
        assert_eq!(msgs2[0].body, "line 0");
        assert_eq!(msgs2[1].id, "msg_huge");
        let _ = std::fs::remove_dir_all(&base);
    }

    #[tokio::test]
    async fn read_tail_skips_corrupt_lines() {
        let base = tmp_base();
        std::fs::create_dir_all(&base).unwrap();
        let path = base.join("corrupt.jsonl");
        let content = format!(
            "{}\n{}\n{}\n{}\n",
            synthetic_jsonl_line(0),
            "<not valid json at all>",
            synthetic_jsonl_line(1),
            "{ \"id\": \"oops\", broken",
        );
        std::fs::write(&path, content).unwrap();
        let msgs = ChannelsStore::read_jsonl(&path, Some(10)).await.unwrap();
        // Only the two well-formed rows survive.
        assert_eq!(msgs.len(), 2);
        assert_eq!(msgs[0].body, "line 0");
        assert_eq!(msgs[1].body, "line 1");
        let _ = std::fs::remove_dir_all(&base);
    }

    #[tokio::test]
    async fn read_tail_matches_whole_file_for_small_files() {
        // No-limit path is independent; verify the tail path agrees with it
        // on every line of a small file.
        let base = tmp_base();
        std::fs::create_dir_all(&base).unwrap();
        let path = base.join("small.jsonl");
        let lines: String = (0..7).map(|i| format!("{}\n", synthetic_jsonl_line(i))).collect();
        std::fs::write(&path, lines).unwrap();
        let all = ChannelsStore::read_jsonl(&path, None).await.unwrap();
        let tail = ChannelsStore::read_jsonl(&path, Some(7)).await.unwrap();
        assert_eq!(all.len(), 7);
        assert_eq!(tail.len(), 7);
        for (a, b) in all.iter().zip(tail.iter()) {
            assert_eq!(a.id, b.id);
            assert_eq!(a.body, b.body);
        }
        let _ = std::fs::remove_dir_all(&base);
    }

    #[tokio::test]
    async fn read_tail_handles_chunk_boundary_at_newline() {
        // Construct a file where the line offsets straddle the 64 KB chunk
        // boundary so the reverse walker has to stitch lines together
        // across chunks.
        let base = tmp_base();
        std::fs::create_dir_all(&base).unwrap();
        let path = base.join("boundary.jsonl");
        // ~80 KB of content with varying line lengths
        let mut content = String::new();
        for i in 0..2000 {
            content.push_str(&synthetic_jsonl_line(i));
            content.push('\n');
        }
        std::fs::write(&path, &content).unwrap();
        let tail50 = ChannelsStore::read_jsonl(&path, Some(50)).await.unwrap();
        assert_eq!(tail50.len(), 50);
        assert_eq!(tail50[0].body, "line 1950");
        assert_eq!(tail50[49].body, "line 1999");
        let all = ChannelsStore::read_jsonl(&path, None).await.unwrap();
        assert_eq!(all.len(), 2000);
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
