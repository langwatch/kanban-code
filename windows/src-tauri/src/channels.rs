use chrono::{DateTime, Utc};
use serde::{Deserialize, Serialize};
use uuid::Uuid;

/// A chat channel — a named room agents can join, send, and broadcast into.
///
/// Wire format mirrors the TypeScript CLI (`cli/src/channels.ts`) and the macOS
/// Swift app (`Sources/KanbanCodeCore/Domain/Entities/Channel.swift`). Both
/// parse leniently, so this Rust port stays interoperable as long as the field
/// names, types, and date format line up.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct Channel {
    pub id: String,
    pub name: String,
    #[serde(with = "iso8601_ms")]
    pub created_at: DateTime<Utc>,
    pub created_by: ChannelParticipant,
    #[serde(default)]
    pub members: Vec<ChannelMember>,
    /// Manual sidebar order. `None` falls back to creation time for entries
    /// written by older app/CLI versions.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub sort_order: Option<i32>,
}

/// A participant reference — either a real card (`card_id` Some) or the human
/// user (`card_id` None, serialized as JSON `null`).
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq, Hash)]
#[serde(rename_all = "camelCase")]
pub struct ChannelParticipant {
    pub card_id: Option<String>,
    pub handle: String,
}

impl ChannelParticipant {
    pub fn user(handle: impl Into<String>) -> Self {
        Self { card_id: None, handle: handle.into() }
    }

    pub fn card(card_id: impl Into<String>, handle: impl Into<String>) -> Self {
        Self { card_id: Some(card_id.into()), handle: handle.into() }
    }

    /// Stable key used as the DM file name half. Matches Swift's `partyKey` and
    /// the TS CLI's `dmLogPath` sort key.
    pub fn party_key(&self) -> String {
        self.card_id.clone().unwrap_or_else(|| format!("@{}", self.handle))
    }
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq, Hash)]
#[serde(rename_all = "camelCase")]
pub struct ChannelMember {
    pub card_id: Option<String>,
    pub handle: String,
    #[serde(with = "iso8601_ms")]
    pub joined_at: DateTime<Utc>,
}

#[derive(Debug, Clone, Copy, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "lowercase")]
pub enum MessageType {
    Message,
    Join,
    Leave,
    System,
    /// Append-only edit row referencing a prior message via `refs.editsMessageId`.
    /// Render layer collapses these into the original message (#113).
    Edit,
    /// Append-only delete row referencing a prior message via `refs.editsMessageId`.
    /// Render layer hides or stubs the referenced message (#113).
    Delete,
    /// Append-only reaction row referencing a prior message via
    /// `refs.reactionTo` and carrying an emoji in `refs.emoji`. Aggregated
    /// at render time; even-count = toggled off (#113).
    Reaction,
}

impl Default for MessageType {
    fn default() -> Self { MessageType::Message }
}

/// Cross-row references for the append-only edit/delete/reaction strategy
/// (#113). All fields optional so a single struct serves all three kinds.
/// Wire shape matches the macOS Swift app's `MessageRefs`.
#[derive(Debug, Clone, Default, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub struct MessageRefs {
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub edits_message_id: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub reaction_to: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub emoji: Option<String>,
}

#[derive(Debug, Clone, Copy, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "lowercase")]
pub enum MessageSource {
    /// Posted via a public share link by someone outside the team. Drives the
    /// warning prefix in tmux fanout.
    External,
}

/// A single message in a channel log (`<name>.jsonl`) or a DM log
/// (`dm/<keyA>__<keyB>.jsonl`).
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct ChannelMessage {
    pub id: String,
    #[serde(with = "iso8601_ms")]
    pub ts: DateTime<Utc>,
    pub from: ChannelParticipant,
    pub body: String,
    #[serde(rename = "type", default)]
    pub kind: MessageType,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub image_paths: Option<Vec<String>>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub source: Option<MessageSource>,
    /// Cross-row reference for Edit / Delete / Reaction rows (#113). None on
    /// plain message rows so pre-#113 jsonl loads unchanged.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub refs: Option<MessageRefs>,
    /// Handles mentioned in `body` (without the leading `@`). Populated at
    /// send time so notifications and search can read it without re-parsing.
    /// Optional so legacy rows continue to parse (#113).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub mentions: Option<Vec<String>>,
}

/// Extracts `@handle` mentions from a message body (#113). Matches the
/// same regex shape the TS CLI uses for syntactic mention rendering:
/// `@` followed by `[A-Za-z0-9_-]+`. Returns deduped, ordered-by-first-
/// occurrence handles (without the `@`).
pub fn extract_mentions(body: &str) -> Vec<String> {
    let mut out: Vec<String> = Vec::new();
    let bytes = body.as_bytes();
    let mut i = 0;
    while i < bytes.len() {
        if bytes[i] == b'@' {
            let start = i + 1;
            let mut end = start;
            while end < bytes.len()
                && (bytes[end].is_ascii_alphanumeric()
                    || bytes[end] == b'_'
                    || bytes[end] == b'-')
            {
                end += 1;
            }
            if end > start {
                if let Ok(handle) = std::str::from_utf8(&bytes[start..end]) {
                    let h = handle.to_string();
                    if !out.contains(&h) {
                        out.push(h);
                    }
                }
            }
            i = end.max(i + 1);
        } else {
            i += 1;
        }
    }
    out
}

/// Top-level container written to `channels.json`.
#[derive(Debug, Clone, Default, Serialize, Deserialize)]
pub struct ChannelsContainer {
    #[serde(default)]
    pub channels: Vec<Channel>,
}

// ── ID generation ────────────────────────────────────────────────────────────

/// `<prefix>_<16hex>`. Matches the TS CLI (`randomBytes(8).toString("hex")`).
/// Swift uses the first 12 chars of a UUID string instead, but both sides
/// treat ids as opaque so the mismatch is harmless on the wire.
pub fn gen_id(prefix: &str) -> String {
    let uuid = Uuid::new_v4();
    let bytes = uuid.as_bytes();
    let mut hex = String::with_capacity(16);
    for b in &bytes[..8] {
        use std::fmt::Write;
        let _ = write!(hex, "{:02x}", b);
    }
    format!("{}_{}", prefix, hex)
}

// ── Channel name validation ──────────────────────────────────────────────────

/// Maximum length of a channel name (matches TS regex `{0,63}` + 1 leading char).
pub const CHANNEL_NAME_MAX_LEN: usize = 64;

/// Strip a leading `#`, trim whitespace, lowercase. Mirrors `normalizeChannelName`
/// in the TS CLI.
pub fn normalize_channel_name(raw: &str) -> String {
    raw.trim().trim_start_matches('#').trim().to_lowercase()
}

/// Returns true when the name matches `/^[a-z0-9][a-z0-9_-]{0,63}$/`.
pub fn is_valid_channel_name(name: &str) -> bool {
    let bytes = name.as_bytes();
    if bytes.is_empty() || bytes.len() > CHANNEL_NAME_MAX_LEN {
        return false;
    }
    let first = bytes[0];
    if !(first.is_ascii_lowercase() || first.is_ascii_digit()) {
        return false;
    }
    bytes[1..].iter().all(|b| {
        b.is_ascii_lowercase() || b.is_ascii_digit() || *b == b'_' || *b == b'-'
    })
}

// ── ISO 8601 with millisecond precision + Z suffix ───────────────────────────

/// Serde adapter for chrono `DateTime<Utc>` that emits `2024-01-15T12:34:56.789Z`
/// — matching `Date.prototype.toISOString()` from the TS CLI and Swift's
/// `.iso8601` strategy with default fractional precision.
pub(crate) mod iso8601_ms {
    use chrono::{DateTime, SecondsFormat, Utc};
    use serde::{Deserialize, Deserializer, Serializer};

    pub fn serialize<S: Serializer>(dt: &DateTime<Utc>, s: S) -> Result<S::Ok, S::Error> {
        s.serialize_str(&dt.to_rfc3339_opts(SecondsFormat::Millis, true))
    }

    pub fn deserialize<'de, D: Deserializer<'de>>(d: D) -> Result<DateTime<Utc>, D::Error> {
        let s = String::deserialize(d)?;
        DateTime::parse_from_rfc3339(&s)
            .map(|dt| dt.with_timezone(&Utc))
            .map_err(serde::de::Error::custom)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn channel_round_trips_ts_cli_shape() {
        // A literal channel as the TS CLI would write it (note key order doesn't matter).
        let raw = r#"{
            "id": "ch_abcdef0123456789",
            "name": "general",
            "createdAt": "2024-01-15T12:34:56.789Z",
            "createdBy": { "cardId": null, "handle": "user" },
            "members": [
                { "cardId": "card_1", "handle": "alice", "joinedAt": "2024-01-15T12:35:00.000Z" }
            ]
        }"#;
        let ch: Channel = serde_json::from_str(raw).unwrap();
        assert_eq!(ch.name, "general");
        assert_eq!(ch.members.len(), 1);
        assert!(ch.sort_order.is_none());

        // Round-trip back — must still parse on both sides.
        let s = serde_json::to_string(&ch).unwrap();
        let ch2: Channel = serde_json::from_str(&s).unwrap();
        assert_eq!(ch, ch2);
    }

    #[test]
    fn message_type_defaults_to_message_when_absent() {
        // Legacy jsonl lines without a `type` field still parse.
        let raw = r#"{
            "id": "msg_1",
            "ts": "2024-01-15T12:34:56.789Z",
            "from": { "cardId": null, "handle": "user" },
            "body": "hello"
        }"#;
        let m: ChannelMessage = serde_json::from_str(raw).unwrap();
        assert_eq!(m.kind, MessageType::Message);
        assert!(m.image_paths.is_none());
        assert!(m.source.is_none());
    }

    #[test]
    fn optional_fields_drop_when_none() {
        let m = ChannelMessage {
            id: "msg_1".into(),
            ts: "2024-01-15T12:34:56.789Z".parse::<DateTime<Utc>>().unwrap(),
            from: ChannelParticipant::user("user"),
            body: "hi".into(),
            kind: MessageType::Message,
            image_paths: None,
            source: None,
            refs: None,
            mentions: None,
        };
        let s = serde_json::to_string(&m).unwrap();
        assert!(!s.contains("imagePaths"));
        assert!(!s.contains("source"));
        assert!(!s.contains("refs"));
        assert!(!s.contains("mentions"));
        assert!(s.contains("\"type\":\"message\""));
    }

    #[test]
    fn iso_serializes_with_millis_and_z() {
        let dt: DateTime<Utc> = "2024-01-15T12:34:56.789Z".parse().unwrap();
        let m = ChannelMessage {
            id: "msg_1".into(),
            ts: dt,
            from: ChannelParticipant::user("user"),
            body: "hi".into(),
            kind: MessageType::Message,
            image_paths: None,
            source: None,
            refs: None,
            mentions: None,
        };
        let s = serde_json::to_string(&m).unwrap();
        assert!(s.contains("2024-01-15T12:34:56.789Z"), "got: {s}");
    }

    #[test]
    fn id_generator_shape() {
        let id = gen_id("ch");
        assert!(id.starts_with("ch_"));
        let suffix = &id["ch_".len()..];
        assert_eq!(suffix.len(), 16);
        assert!(suffix.chars().all(|c| c.is_ascii_hexdigit()));
    }

    #[test]
    fn name_validation_matches_ts_regex() {
        assert!(is_valid_channel_name("general"));
        assert!(is_valid_channel_name("a"));
        assert!(is_valid_channel_name("a-b_c0"));
        assert!(is_valid_channel_name("0abc"));
        assert!(!is_valid_channel_name(""));
        assert!(!is_valid_channel_name("-leading-dash"));
        assert!(!is_valid_channel_name("UPPER"));
        assert!(!is_valid_channel_name("has space"));
        assert!(!is_valid_channel_name(&"x".repeat(65)));
    }

    #[test]
    fn name_normalize_strips_hash_and_lowercases() {
        assert_eq!(normalize_channel_name("#General"), "general");
        assert_eq!(normalize_channel_name("  #foo  "), "foo");
        assert_eq!(normalize_channel_name("Bar"), "bar");
    }

    #[test]
    fn extracts_mentions_in_first_occurrence_order() {
        assert_eq!(extract_mentions("hi @alice and @bob"), vec!["alice", "bob"]);
        // Dedup, keep first.
        assert_eq!(
            extract_mentions("@alice @bob @alice"),
            vec!["alice", "bob"]
        );
        // Underscores and dashes are allowed; punctuation terminates.
        assert_eq!(
            extract_mentions("ping @user_1, @ops-team!"),
            vec!["user_1", "ops-team"]
        );
        // Bare `@` is dropped.
        assert!(extract_mentions("email@example.com").contains(&"example".to_string()));
        assert!(extract_mentions("ping @").is_empty());
    }

    #[test]
    fn message_with_refs_round_trips() {
        let raw = r#"{
            "id": "msg_2",
            "ts": "2024-01-15T12:34:56.789Z",
            "from": {"cardId": null, "handle": "alice"},
            "body": "",
            "type": "reaction",
            "refs": {"reactionTo": "msg_1", "emoji": "👍"}
        }"#;
        let m: ChannelMessage = serde_json::from_str(raw).unwrap();
        assert_eq!(m.kind, MessageType::Reaction);
        assert_eq!(m.refs.as_ref().and_then(|r| r.reaction_to.as_deref()), Some("msg_1"));
        assert_eq!(m.refs.as_ref().and_then(|r| r.emoji.as_deref()), Some("👍"));
        let s = serde_json::to_string(&m).unwrap();
        // refs round-trips
        let m2: ChannelMessage = serde_json::from_str(&s).unwrap();
        assert_eq!(m, m2);
    }

    #[test]
    fn pre_113_message_still_parses() {
        // A jsonl row written by Phase 7 (no refs, no mentions, no edit kind).
        let raw = r#"{
            "id": "msg_legacy",
            "ts": "2024-01-15T12:34:56.789Z",
            "from": {"cardId": null, "handle": "user"},
            "body": "old message",
            "type": "message"
        }"#;
        let m: ChannelMessage = serde_json::from_str(raw).unwrap();
        assert_eq!(m.kind, MessageType::Message);
        assert!(m.refs.is_none());
        assert!(m.mentions.is_none());
        // And serializing back doesn't introduce phantom fields.
        let s = serde_json::to_string(&m).unwrap();
        assert!(!s.contains("refs"));
        assert!(!s.contains("mentions"));
    }

    #[test]
    fn party_key_uses_card_id_or_at_handle() {
        assert_eq!(
            ChannelParticipant::card("card_1", "alice").party_key(),
            "card_1"
        );
        assert_eq!(ChannelParticipant::user("user").party_key(), "@user");
    }
}
