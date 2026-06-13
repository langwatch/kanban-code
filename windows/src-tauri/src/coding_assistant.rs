//! Multi-assistant abstraction. Mirrors the shape of macOS
//! `Sources/KanbanCodeCore/Domain/Entities/CodingAssistant.swift` so a
//! `links.json` carrying `assistantId` moves between platforms cleanly.
//!
//! This is the minimum-viable port: it covers the launch/resume command
//! shape so the embedded terminal can swap between Claude and Gemini, and
//! provides a `~/.gemini` discovery scaffolding for future use. Activity
//! detection and hooks remain Claude-only for now — see TODO in
//! `discover_gemini_sessions`.
//!
//! Adding a new assistant: extend `AssistantId`, fill in the per-arm
//! matches below, and (optionally) wire up discovery.

use serde::{Deserialize, Serialize};
use std::path::PathBuf;

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize, Hash)]
#[serde(rename_all = "lowercase")]
pub enum AssistantId {
    Claude,
    Gemini,
}

impl Default for AssistantId {
    fn default() -> Self {
        AssistantId::Claude
    }
}

impl AssistantId {
    pub fn all() -> &'static [AssistantId] {
        &[AssistantId::Claude, AssistantId::Gemini]
    }

    pub fn as_str(&self) -> &'static str {
        match self {
            AssistantId::Claude => "claude",
            AssistantId::Gemini => "gemini",
        }
    }

    pub fn from_str(s: &str) -> Option<Self> {
        match s {
            "claude" => Some(AssistantId::Claude),
            "gemini" => Some(AssistantId::Gemini),
            _ => None,
        }
    }

    pub fn display_name(&self) -> &'static str {
        match self {
            AssistantId::Claude => "Claude Code",
            AssistantId::Gemini => "Gemini CLI",
        }
    }

    /// Binary name on PATH. We don't take an absolute path — assume the
    /// user has the CLI installed via `npm install -g`, matching macOS
    /// behavior. Configurable paths are a follow-up.
    pub fn cli_command(&self) -> &'static str {
        match self {
            AssistantId::Claude => "claude",
            AssistantId::Gemini => "gemini",
        }
    }

    /// CLI flag for auto-approving all tool calls.
    pub fn auto_approve_flag(&self) -> &'static str {
        match self {
            AssistantId::Claude => "--dangerously-skip-permissions",
            AssistantId::Gemini => "--yolo",
        }
    }

    /// Resume an existing session id.
    pub fn resume_flag(&self) -> &'static str {
        match self {
            AssistantId::Claude | AssistantId::Gemini => "--resume",
        }
    }

    /// Config dir under $HOME (e.g. ".claude", ".gemini"). Used by discovery
    /// and by the macOS `owns(sessionPath:)` check.
    pub fn config_dir_name(&self) -> &'static str {
        match self {
            AssistantId::Claude => ".claude",
            AssistantId::Gemini => ".gemini",
        }
    }
}

/// Scaffolding for Gemini session discovery. Returns an empty list for
/// now — wiring through to the board state requires the full session
/// adapter that macOS has and is intentionally deferred. Existing in this
/// shape so the trait surface is stable for the follow-up PR.
///
/// Gemini stores sessions at:
///   `~/.gemini/tmp/<slug>/chats/session-<timestamp>.json`
/// with the slug→absolute-path mapping in `~/.gemini/projects.json`.
pub async fn discover_gemini_sessions() -> Vec<crate::session_discovery::Session> {
    // TODO(phase-4-followup): implement parser mirroring
    // Sources/KanbanCodeCore/Adapters/Gemini/GeminiSessionParser.swift
    let _ = gemini_dir();
    vec![]
}

fn gemini_dir() -> Option<PathBuf> {
    dirs::home_dir().map(|h| h.join(".gemini"))
}
