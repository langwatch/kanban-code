use anyhow::{Context, Result};

/// Returns true when the process is running inside WSL.
pub fn is_wsl() -> bool {
    std::fs::read_to_string("/proc/version")
        .map(|v| v.to_lowercase().contains("microsoft"))
        .unwrap_or(false)
}

/// Launch a brand-new Claude CLI session for a prompt in a given project dir.
///
/// On Windows: tries WSL first (where Claude Code CLI typically lives),
/// then falls back to native cmd.
/// On WSL/Linux: uses bash directly.
pub async fn launch_new_claude_session(prompt: &str, project: &str) -> Result<()> {
    #[cfg(target_os = "windows")]
    {
        // If the project path looks like a WSL path (/home/...) or a UNC WSL path,
        // route through WSL. Otherwise try native Windows.
        let is_wsl_path = project.starts_with("/")
            || project.starts_with("\\\\wsl")
            || project.contains("\\wsl$\\")
            || project.contains("\\wsl.localhost\\");

        if is_wsl_path {
            // Convert UNC path to Linux path if needed
            let linux_path = unc_to_linux_path(project);
            let safe_project = linux_path.replace('\'', "'\\''");
            let safe_prompt = prompt.replace('\'', "'\\''");
            let wsl_cmd = format!("source ~/.bashrc 2>/dev/null; cd '{}' && claude '{}'", safe_project, safe_prompt);

            let wt = tokio::process::Command::new("wt")
                .args(["new-tab", "wsl.exe", "--", "bash", "-ic", &wsl_cmd])
                .spawn();
            if wt.is_ok() {
                return Ok(());
            }
            let cmd = tokio::process::Command::new("cmd")
                .args(["/c", "start", "wsl.exe", "--", "bash", "-ic", &wsl_cmd])
                .spawn();
            if cmd.is_ok() {
                return Ok(());
            }
        }

        // Native Windows fallback
        let safe_project = project.replace('"', "\"\"");
        let safe_prompt = prompt.replace('"', "\"\"");
        let command = format!("cd /d \"{}\" && claude \"{}\"", safe_project, safe_prompt);
        return launch_terminal_command(&command).await;
    }

    #[cfg(not(target_os = "windows"))]
    {
        let safe_project = project.replace('\'', "'\\''");
        let safe_prompt = prompt.replace('\'', "'\\''");
        let command = format!("cd '{}' && claude '{}'", safe_project, safe_prompt);
        launch_terminal_command(&command).await
    }
}

/// Convert a \\wsl$\Distro\path or \\wsl.localhost\Distro\path to /path
#[cfg(target_os = "windows")]
fn unc_to_linux_path(path: &str) -> String {
    // \\wsl$\Ubuntu\home\user\project -> /home/user/project
    // \\wsl.localhost\Ubuntu\home\user\project -> /home/user/project
    let normalized = path.replace('\\', "/");
    // Remove //wsl$/Distro or //wsl.localhost/Distro prefix
    if let Some(rest) = normalized.strip_prefix("//wsl.localhost/") {
        if let Some(pos) = rest.find('/') {
            return rest[pos..].to_string();
        }
    }
    if let Some(rest) = normalized.strip_prefix("//wsl$/") {
        if let Some(pos) = rest.find('/') {
            return rest[pos..].to_string();
        }
    }
    // Already a Linux path
    path.to_string()
}

/// Launch a Claude CLI session resume in a new terminal window.
///
/// On native Windows: tries running via WSL first (since Claude Code CLI
/// sessions are typically created inside WSL), then falls back to native cmd.
pub async fn launch_claude_session(session_id: &str) -> Result<()> {
    #[cfg(target_os = "windows")]
    {
        // Source bashrc to get PATH, then run claude
        let wsl_cmd = format!("source ~/.bashrc 2>/dev/null; claude --resume {}", session_id);
        let wt = tokio::process::Command::new("wt")
            .args(["new-tab", "wsl.exe", "--", "bash", "-ic", &wsl_cmd])
            .spawn();
        if wt.is_ok() {
            return Ok(());
        }
        // Fallback: cmd start with wsl
        let cmd = tokio::process::Command::new("cmd")
            .args(["/c", "start", "wsl.exe", "--", "bash", "-ic", &wsl_cmd])
            .spawn();
        if cmd.is_ok() {
            return Ok(());
        }
        // Last resort: native Windows claude
        let native_cmd = format!("claude --resume {}", session_id);
        return launch_terminal_command(&native_cmd).await;
    }

    #[cfg(not(target_os = "windows"))]
    {
        let command = format!("claude --resume {}", session_id);
        launch_terminal_command(&command).await
    }
}

/// Internal: open a new terminal window and run `command` inside it.
async fn launch_terminal_command(command: &str) -> Result<()> {
    #[cfg(target_os = "windows")]
    {
        launch_in_windows_terminal(command).await?;
        return Ok(());
    }

    // Running in WSL — shell into WSL via Windows Terminal if available,
    // otherwise use a local Linux terminal
    #[cfg(not(target_os = "windows"))]
    if is_wsl() {
        // Try Windows Terminal (wt.exe) which is on PATH in WSL
        let wt = tokio::process::Command::new("wt.exe")
            .args(["new-tab", "wsl.exe", "--", "bash", "-lic", command])
            .spawn();
        if wt.is_ok() {
            return Ok(());
        }
        // Fall back: open a new cmd.exe window running wsl bash -c ...
        let cmd = tokio::process::Command::new("cmd.exe")
            .args(["/c", "start", "wt.exe", "wsl.exe", "--", "bash", "-lic", command])
            .spawn();
        if cmd.is_ok() {
            return Ok(());
        }
        // Last resort: local terminal emulator inside WSL
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
        return Ok(());
    }

    #[cfg(target_os = "linux")]
    {
        for term in &[
            "gnome-terminal",
            "konsole",
            "xfce4-terminal",
            "xterm",
            "alacritty",
            "kitty",
        ] {
            let args: &[&str] = if *term == "alacritty" || *term == "kitty" {
                &["-e", "bash", "-lic", command]
            } else {
                &["--", "bash", "-lic", command]
            };
            if tokio::process::Command::new(term).args(args).spawn().is_ok() {
                return Ok(());
            }
        }
        anyhow::bail!("no terminal emulator found; install gnome-terminal, xterm, or alacritty");
    }

    #[allow(unreachable_code)]
    Ok(())
}

/// Open a path in the configured editor.
///
/// In WSL, prefers the Windows-side editor (e.g. `code.cmd`, `cursor.cmd`) so the
/// editor opens natively on Windows with the WSL path converted via `wslpath`.
pub async fn open_in_editor(path: &str, editor: Option<&str>) -> Result<()> {
    let default_editor = std::env::var("EDITOR").unwrap_or_else(|_| "code".to_string());
    let editor_cmd = editor.unwrap_or(&default_editor);

    #[cfg(not(target_os = "windows"))]
    if is_wsl() {
        // Convert the Linux path to a Windows path for Windows editors
        let win_path_output = tokio::process::Command::new("wslpath")
            .args(["-w", path])
            .output()
            .await;

        let open_path = if let Ok(out) = win_path_output {
            String::from_utf8_lossy(&out.stdout).trim().to_string()
        } else {
            path.to_string()
        };

        // Try <editor>.cmd (how VS Code / Cursor install on Windows PATH in WSL)
        let cmd_variant = format!("{}.cmd", editor_cmd);
        let result = tokio::process::Command::new(&cmd_variant)
            .arg(&open_path)
            .spawn();
        if result.is_ok() {
            return Ok(());
        }
        // Try plain editor name (might be on WSL PATH as a shell script)
        tokio::process::Command::new(editor_cmd)
            .arg(&open_path)
            .spawn()
            .with_context(|| format!("open in editor '{editor_cmd}'"))?;
        return Ok(());
    }

    #[cfg(target_os = "windows")]
    {
        // Build a list of editor commands to try, with full paths for known editors
        let localappdata = std::env::var("LOCALAPPDATA").unwrap_or_default();
        let cursor_full = format!(r"{}\Programs\cursor\resources\app\bin\cursor.cmd", localappdata);
        let code_full = format!(r"{}\Programs\Microsoft VS Code\bin\code.cmd", localappdata);

        let mut editors_to_try: Vec<String> = Vec::new();
        if editor_cmd != "code" && editor_cmd != "cursor" {
            editors_to_try.push(editor_cmd.to_string());
        }
        editors_to_try.push(cursor_full);
        editors_to_try.push("cursor".to_string());
        editors_to_try.push(code_full);
        editors_to_try.push("code".to_string());

        let is_wsl_path = path.starts_with("\\\\wsl") || path.contains("\\wsl$\\") || path.contains("\\wsl.localhost\\");

        if is_wsl_path {
            let linux_path = unc_to_linux_path(path);
            for ed in &editors_to_try {
                // Editors like Cursor/VS Code handle WSL paths via: cursor --remote wsl+Ubuntu <path>
                let result = tokio::process::Command::new(ed)
                    .args(["--remote", "wsl+Ubuntu", &linux_path])
                    .spawn();
                if result.is_ok() {
                    return Ok(());
                }
            }
        }

        // Non-WSL path or WSL editors failed: try plain open
        for ed in &editors_to_try {
            if tokio::process::Command::new(ed).arg(path).spawn().is_ok() {
                return Ok(());
            }
        }
        anyhow::bail!("could not open editor; install Cursor or VS Code");
    }

    #[cfg(not(target_os = "windows"))]
    {
        tokio::process::Command::new(editor_cmd)
            .arg(path)
            .spawn()
            .with_context(|| format!("open in editor '{editor_cmd}'"))?;
    }

    Ok(())
}

// ── Windows helper ───────────────────────────────────────────────────────────

#[cfg(target_os = "windows")]
async fn launch_in_windows_terminal(command: &str) -> Result<()> {
    // Try Windows Terminal first (modern, tabbed)
    let wt = tokio::process::Command::new("wt")
        .args(["new-tab", "--", "cmd", "/k", command])
        .spawn();
    if wt.is_ok() {
        return Ok(());
    }
    // Fall back to a plain cmd window
    tokio::process::Command::new("cmd")
        .args(["/c", "start", "cmd", "/k", command])
        .spawn()
        .context("launch claude in cmd.exe")?;
    Ok(())
}
