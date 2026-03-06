use anyhow::{Context, Result};

/// Launch a Claude CLI session resume in a new terminal window.
pub async fn launch_claude_session(session_id: &str) -> Result<()> {
    let command = format!("claude --resume {}", session_id);

    #[cfg(target_os = "windows")]
    {
        // Open in Windows Terminal, fall back to cmd
        let result = tokio::process::Command::new("wt")
            .args(["new-tab", "--", "cmd", "/c", &command])
            .spawn();
        if result.is_err() {
            tokio::process::Command::new("cmd")
                .args(["/c", "start", "cmd", "/k", &command])
                .spawn()
                .context("launch claude in cmd")?;
        }
    }

    #[cfg(target_os = "macos")]
    {
        tokio::process::Command::new("osascript")
            .args([
                "-e",
                &format!(
                    r#"tell application "Terminal" to do script "{}""#,
                    command
                ),
            ])
            .spawn()
            .context("launch claude in Terminal")?;
    }

    #[cfg(target_os = "linux")]
    {
        // Try common terminal emulators
        for term in &["gnome-terminal", "xterm", "konsole"] {
            let result = tokio::process::Command::new(term)
                .args(["--", "bash", "-c", &command])
                .spawn();
            if result.is_ok() {
                return Ok(());
            }
        }
        anyhow::bail!("no terminal emulator found");
    }

    Ok(())
}

/// Open a path in the configured editor.
pub async fn open_in_editor(path: &str, editor: Option<&str>) -> Result<()> {
    let default_editor = std::env::var("EDITOR").unwrap_or_else(|_| "code".to_string());
    let editor = editor.unwrap_or(&default_editor);

    tokio::process::Command::new(editor)
        .arg(path)
        .spawn()
        .with_context(|| format!("open in editor '{editor}'"))?;

    Ok(())
}
