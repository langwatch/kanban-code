//! Pushover push-notification client. Sends a single message to a user's
//! Pushover account. Pure HTTP via reqwest — no OS-specific bits.
//!
//! Mirrors `Sources/.../Adapters/Notifications/PushoverClient.swift`. The
//! Pushover API accepts both multipart and application/x-www-form-urlencoded;
//! we use form-encoded since we never attach images.

use anyhow::{anyhow, Result};
use std::time::Duration;

const PUSHOVER_URL: &str = "https://api.pushover.net/1/messages.json";

/// Send a notification through Pushover.
///
/// `card_id`, if provided, becomes a `kanbancode://card/<id>` deep link
/// rendered as "Open in Kanban Code" in the push. The URL scheme isn't
/// registered yet on Windows, but the link still shows on the phone and
/// is harmless when the scheme is missing — Pushover doesn't validate.
pub async fn send(
    token: &str,
    user_key: &str,
    title: &str,
    message: &str,
    card_id: Option<&str>,
) -> Result<()> {
    if token.is_empty() || user_key.is_empty() {
        return Err(anyhow!("pushover token/user key not configured"));
    }

    let mut form: Vec<(&str, String)> = vec![
        ("token", token.to_string()),
        ("user", user_key.to_string()),
        ("title", title.to_string()),
        ("message", message.to_string()),
        ("html", "1".to_string()),
    ];
    if let Some(id) = card_id {
        form.push(("url", format!("kanbancode://card/{id}")));
        form.push(("url_title", "Open in Kanban Code".to_string()));
    }

    let client = reqwest::Client::builder()
        .timeout(Duration::from_secs(10))
        .build()?;
    let resp = client.post(PUSHOVER_URL).form(&form).send().await?;
    let status = resp.status();
    if !status.is_success() {
        let body = resp.text().await.unwrap_or_default();
        return Err(anyhow!("pushover responded {status}: {body}"));
    }
    Ok(())
}
