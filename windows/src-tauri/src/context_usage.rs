//! Reads context-window usage written by Claude Code's statusline script.
//! Mirrors Sources/KanbanCodeCore/Adapters/ClaudeCode/ContextUsageReader.swift.
//!
//! Files live at `<data_dir>/context/<sessionId>.json` and contain the
//! fields the statusline emits (camelCase, matching macOS exactly so a
//! shared statusline binary works on both platforms):
//!
//! ```text
//! { "usedPercentage": 42.5,
//!   "contextWindowSize": 200000,
//!   "totalInputTokens": 12345,
//!   "totalOutputTokens": 6789,
//!   "totalCostUsd": 0.42,
//!   "model": "claude-opus-4-7" }
//! ```
//!
//! The polling loop that *generates* self-compact prompts (when usage
//! crosses a threshold) is not yet ported. This reader is the consumer
//! side — already enough for the drop-guard path that drops stale
//! compact prompts when usage drops back below threshold post-compact.

use serde::Deserialize;
use std::path::PathBuf;

use crate::coordination_store::kanban_data_dir;

#[derive(Debug, Clone, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ContextUsage {
    pub used_percentage: f64,
    pub context_window_size: i64,
    pub total_input_tokens: i64,
    pub total_output_tokens: i64,
    #[serde(default)]
    pub total_cost_usd: Option<f64>,
    #[serde(default)]
    pub model: Option<String>,
}

impl ContextUsage {
    /// Claude's current context-window usage in tokens. Mirrors the macOS
    /// `currentContextTokens` derivation: when percentage data is present
    /// we trust it (the lifetime input+output sum stays high after a
    /// compaction, so it's the wrong number to compare against thresholds).
    pub fn current_context_tokens(&self) -> i64 {
        if self.context_window_size > 0 && self.used_percentage > 0.0 {
            ((self.context_window_size as f64) * self.used_percentage / 100.0).round() as i64
        } else {
            self.total_input_tokens + self.total_output_tokens
        }
    }
}

fn context_path(session_id: &str, base: Option<&PathBuf>) -> PathBuf {
    let dir = base
        .cloned()
        .unwrap_or_else(|| kanban_data_dir().join("context"));
    dir.join(format!("{}.json", session_id))
}

/// Returns `None` when no statusline JSON exists for this session yet
/// (statusline never ran, or it ran on a host that doesn't share this
/// data dir). Callers should treat that as "unknown" — they should
/// not derive any threshold conclusion from absence alone.
pub fn read(session_id: &str) -> Option<ContextUsage> {
    read_with_base(session_id, None)
}

pub fn read_with_base(session_id: &str, base: Option<&PathBuf>) -> Option<ContextUsage> {
    let path = context_path(session_id, base);
    let bytes = std::fs::read(&path).ok()?;
    serde_json::from_slice(&bytes).ok()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn current_context_uses_percentage_when_available() {
        let u = ContextUsage {
            used_percentage: 50.0,
            context_window_size: 200_000,
            total_input_tokens: 999_999,
            total_output_tokens: 999_999,
            total_cost_usd: None,
            model: None,
        };
        assert_eq!(u.current_context_tokens(), 100_000);
    }

    #[test]
    fn current_context_falls_back_to_io_sum_without_percentage() {
        let u = ContextUsage {
            used_percentage: 0.0,
            context_window_size: 0,
            total_input_tokens: 1000,
            total_output_tokens: 234,
            total_cost_usd: None,
            model: None,
        };
        assert_eq!(u.current_context_tokens(), 1234);
    }
}
