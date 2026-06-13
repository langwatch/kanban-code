//! Deploys the remote-shell.sh wrapper for Windows.
//!
//! Ports `RemoteShellManager.swift`. The bash script body is the same one the
//! macOS app ships — we only template the settings.json path and the
//! status-file directory so the wrapper can find configuration on Windows.
//!
//! HARD DEPENDENCY: Git for Windows must be installed (`bash.exe`, `perl.exe`,
//! `ssh.exe`, `sed.exe` all come from the same installer). `find_bash()`
//! returns `None` when missing; the rest of the remote subsystem stays
//! disabled rather than crashing.

use anyhow::{Context, Result};
use serde::Serialize;
use std::path::PathBuf;
use tokio::fs;

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct RemotePrereqs {
    pub mutagen_available: bool,
    pub bash_available: bool,
    pub ssh_available: bool,
    pub mutagen_path: Option<String>,
    pub bash_path: Option<String>,
}

/// Locate Git-for-Windows `bash.exe`. Checks PATH, then the two common installer
/// locations so we still find it when the user installed Git but didn't tick
/// the "Add to PATH" option.
pub fn find_bash() -> Option<String> {
    if let Some(p) = crate::mutagen::find_on_path("bash") {
        return Some(p);
    }
    let candidates = [
        r"C:\Program Files\Git\bin\bash.exe",
        r"C:\Program Files (x86)\Git\bin\bash.exe",
    ];
    for c in candidates {
        if std::path::Path::new(c).exists() {
            return Some(c.to_string());
        }
    }
    None
}

pub fn find_ssh() -> Option<String> {
    crate::mutagen::find_on_path("ssh")
}

pub fn prereqs() -> RemotePrereqs {
    let mutagen_path = crate::mutagen::find_mutagen();
    let bash_path = find_bash();
    RemotePrereqs {
        mutagen_available: mutagen_path.is_some(),
        bash_available: bash_path.is_some(),
        ssh_available: find_ssh().is_some(),
        mutagen_path,
        bash_path,
    }
}

fn remote_dir() -> PathBuf {
    crate::coordination_store::kanban_data_dir().join("remote")
}

fn script_path() -> PathBuf {
    remote_dir().join("remote-shell.sh")
}

/// Return the absolute path that the bash wrapper should read settings from,
/// in POSIX form so the wrapper's `/usr/bin/perl` `open()` call works.
/// E.g. `C:\Users\foo\AppData\Roaming\kanban-code\settings.json` →
/// `/c/Users/foo/AppData/Roaming/kanban-code/settings.json`.
fn settings_path_posix() -> String {
    let p = crate::coordination_store::kanban_data_dir().join("settings.json");
    to_posix_path(&p.to_string_lossy())
}

fn status_dir_posix() -> String {
    to_posix_path(&remote_dir().to_string_lossy())
}

/// Convert a Windows path (`C:\Users\foo\bar`) to the POSIX form Git-for-Windows
/// bash uses (`/c/Users/foo/bar`). Mirrors the heuristic in
/// `RemoteShellManager.swift` so the same settings file works on both ports.
pub fn to_posix_path(win: &str) -> String {
    let normalized = win.replace('\\', "/");
    if normalized.len() >= 2 && &normalized[1..2] == ":" {
        let drive = normalized[..1].to_lowercase();
        let rest = &normalized[2..];
        format!("/{drive}{rest}")
    } else {
        normalized
    }
}

/// Write the wrapper script and create same-content copies named `bash` and
/// `zsh` so coding assistants that hardcode either name as the shell pick up
/// the wrapper. Idempotent — call at app startup.
pub async fn deploy() -> Result<()> {
    let dir = remote_dir();
    fs::create_dir_all(&dir).await.context("create remote dir")?;

    let script = render_script();
    let script_file = script_path();
    fs::write(&script_file, script).await.context("write remote-shell.sh")?;

    // Sibling copies — Windows symlinks need admin/dev-mode, so we just
    // duplicate the file. Both `bash` and `zsh` get the same body because
    // the script reads `$0`/argv for itself, not its name.
    for name in ["bash", "zsh"] {
        let alias = dir.join(name);
        fs::write(&alias, render_script()).await.with_context(|| {
            format!("write {} alias", alias.to_string_lossy())
        })?;
    }

    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        for name in ["remote-shell.sh", "bash", "zsh"] {
            let p = dir.join(name);
            if let Ok(meta) = std::fs::metadata(&p) {
                let mut perm = meta.permissions();
                perm.set_mode(0o755);
                let _ = std::fs::set_permissions(&p, perm);
            }
        }
    }

    Ok(())
}

/// Directory to prepend to PATH so `bash`/`zsh` lookups by other tools resolve
/// to our wrapper. Returned for Phase 3 to consume — Phase 5 only deploys.
pub fn remote_dir_path() -> String {
    remote_dir().to_string_lossy().to_string()
}

/// Absolute path of the wrapper, for use as a `SHELL` override.
pub fn shell_override_path() -> String {
    remote_dir().join("zsh").to_string_lossy().to_string()
}

/// Render the bash wrapper with paths templated for this Windows install.
/// Body is byte-identical to `RemoteShellManager.swift` *except*:
///   1. CONFIG_FILE / STATUS_DIR are templated absolute POSIX paths
///   2. `osascript ...` is replaced with a status-file write that the
///      Rust `RemoteStatusWatcher` already polls.
fn render_script() -> String {
    let config_file = settings_path_posix();
    let status_dir = status_dir_posix();

    // The macOS script lives in Sources/.../RemoteShellManager.swift — keep
    // diffs minimal so updates can be ported by hand.
    format!(
        r####"#!/bin/bash
#
# Remote shell wrapper for coding assistants (Claude Code, Gemini CLI, Codex CLI)
# Intercepts shell commands and executes them on the remote machine
# Falls back to local execution if remote is unavailable
#
# Windows port: requires Git for Windows (provides /bin/bash, /usr/bin/perl,
# /usr/bin/ssh, /usr/bin/sed). Configuration read from settings.json at the
# templated absolute POSIX path below. Online/offline notifications are
# delivered by writing JSON status files — the Rust watcher polls these and
# fires native Windows toasts.
#

# --- Recursion guard ---
if [[ -n "${{__KANBAN_REMOTE_WRAPPER:-}}" ]]; then
    exec /bin/bash "$@"
fi
export __KANBAN_REMOTE_WRAPPER=1

# --- Hook/script fast-path ---
for __arg in "$@"; do
    if [[ "$__arg" == "-c" ]] || [[ "$__arg" == "-l" ]] || [[ "$__arg" == "-i" ]]; then
        continue
    fi
    __first_word="${{__arg%% *}}"
    if [[ "$__first_word" == /* ]] && [[ -x "$__first_word" ]]; then
        exec /bin/bash "$@"
    fi
    break
done
unset __arg __first_word

CONFIG_FILE="{config_file}"
STATUS_DIR="{status_dir}"
REMOTE_HOST=""
REMOTE_DIR=""
LOCAL_MOUNT=""

if [[ -f "$CONFIG_FILE" ]]; then
    REMOTE_HOST=$(/usr/bin/perl -MJSON::PP -e 'open my $f,"<","'"$CONFIG_FILE"'" or exit;local $/;my $d=decode_json(<$f>);print $d->{{remote}}{{host}}//"" if $d->{{remote}}' 2>/dev/null || echo "")
    REMOTE_DIR=$(/usr/bin/perl -MJSON::PP -e 'open my $f,"<","'"$CONFIG_FILE"'" or exit;local $/;my $d=decode_json(<$f>);print $d->{{remote}}{{remotePath}}//"" if $d->{{remote}}' 2>/dev/null || echo "")
    LOCAL_MOUNT=$(/usr/bin/perl -MJSON::PP -e 'open my $f,"<","'"$CONFIG_FILE"'" or exit;local $/;my $d=decode_json(<$f>);print $d->{{remote}}{{localPath}}//"" if $d->{{remote}}' 2>/dev/null || echo "")
fi

# ControlMaster sockets in TMPDIR — Git-for-Windows bash maps that to a path
# native ssh.exe can also read. Falls back to /tmp on POSIX.
SSH_TMP="${{TMPDIR:-/tmp}}"
SSH_TMP="${{SSH_TMP%/}}"
SSH_OPTS="-o ControlMaster=auto -o ControlPath=${{SSH_TMP}}/ssh-kanban-code-%r@%h:%p -o ControlPersist=600 -o ConnectTimeout=5"
STATE_FILE="${{SSH_TMP}}/kanban-code-remote-state"
NOTIFY_COOLDOWN=300
MUTAGEN=$(command -v mutagen 2>/dev/null || echo "")

ensure_sync() {{
    [[ -n "$MUTAGEN" ]] || return 0
    if ! "$MUTAGEN" sync list --label-selector kanban=true 2>/dev/null | grep -q "Name:"; then
        "$MUTAGEN" sync create "$LOCAL_MOUNT" "${{REMOTE_HOST}}:${{REMOTE_DIR}}" \
            --name kanban-code-sync \
            --label kanban=true \
            --sync-mode two-way-resolved \
            --default-file-mode-beta 0644 \
            --default-directory-mode-beta 0755 \
            --ignore node_modules --ignore .venv --ignore .cache \
            --ignore dist --ignore '.next*' --ignore __pycache__ \
            --ignore .pytest_cache --ignore .mypy_cache --ignore .turbo \
            --ignore '*.pyc' --ignore .DS_Store --ignore coverage \
            --ignore .nyc_output --ignore target --ignore build \
            --ignore .build --ignore .swiftpm \
            >/dev/null 2>&1 || true
    fi
    "$MUTAGEN" sync flush --label-selector kanban=true >/dev/null 2>&1 || true
}}

read -r -d '' WORKTREE_FIX_FN << 'WFIX' || true
__relpath(){{
  local t="$1" b="$2"; t="${{t%/}}"; b="${{b%/}}"
  local c="$b" r=""
  while [ "${{t#"$c"}}" = "$t" ]; do c=$(dirname "$c"); r="../$r"; done
  local f="${{t#"$c"}}"; f="${{f#/}}"; printf '%s\n' "${{r}}${{f}}"
}}
__fix_gitlink(){{
  local f="$1" wp="$2" rp="$3"
  [ -f "$f" ] || return 0
  local c; c=$(cat "$f"); local ig=false p="$c"
  case "$c" in gitdir:*) ig=true; p="${{c#gitdir: }}";; esac
  p="${{p//$wp/$rp}}"
  case "$p" in /*) ;; *) return 0;; esac
  [ -e "$p" ] || return 0
  local d; d=$(dirname "$f")
  local rl; rl=$(__relpath "$p" "$d")
  [ -n "$rl" ] || return 0
  if $ig; then printf 'gitdir: %s\n' "$rl" > "$f"; else printf '%s\n' "$rl" > "$f"; fi
}}
__fix_wt(){{
  local wp="$1" rp="$2" d; d=$(pwd); local gr=""
  while [ "$d" != "/" ]; do
    if [ -d "$d/.git" ]; then gr="$d"; break
    elif [ -f "$d/.git" ]; then
      __fix_gitlink "$d/.git" "$wp" "$rp"
      local g; g=$(cat "$d/.git"); g="${{g#gitdir: }}"
      case "$g" in /*) gr="${{g%/.git/worktrees/*}}";; *) gr=$(cd "$d/$g/../../.." 2>/dev/null && pwd);; esac
      break
    fi
    d=$(dirname "$d")
  done
  [ -n "$gr" ] && [ -d "$gr/.git/worktrees" ] || return 0
  for m in "$gr/.git/worktrees"/*/; do
    [ -d "$m" ] || continue
    __fix_gitlink "${{m}}gitdir" "$wp" "$rp"
    local gc; [ -f "${{m}}gitdir" ] && gc=$(cat "${{m}}gitdir") || continue
    [ -n "$gc" ] || continue
    local wf
    case "$gc" in /*) wf="$gc";;
      *) wf=$(cd "$m" && cd "$(dirname "$gc")" 2>/dev/null && printf '%s/%s\n' "$(pwd)" "$(basename "$gc")") || continue;;
    esac
    [ -n "$wf" ] && __fix_gitlink "$wf" "$wp" "$rp"
  done
}}
WFIX

local_to_remote() {{ echo "${{1/#$LOCAL_MOUNT/$REMOTE_DIR}}"; }}
remote_to_local() {{ echo "${{1/#$REMOTE_DIR/$LOCAL_MOUNT}}"; }}

# Notification = write a status JSON file. The Rust RemoteStatusWatcher polls
# these and fires the OS toast. Rate-limited identically to the macOS path.
notify() {{
    local message="$1" state="$2"
    local now=$(date +%s) last_state="" last_notify=0
    if [[ -f "$STATE_FILE" ]]; then
        last_state=$(head -1 "$STATE_FILE")
        last_notify=$(tail -1 "$STATE_FILE")
    fi
    if [[ "$state" != "$last_state" ]] || {{ [[ "$state" == "offline" ]] && [[ $((now - last_notify)) -ge $NOTIFY_COOLDOWN ]]; }}; then
        mkdir -p "$STATUS_DIR" 2>/dev/null
        local iso=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
        local safe_host="${{REMOTE_HOST//\//_}}"
        safe_host="${{safe_host//:/_}}"
        printf '{{"status":"%s","since":"%s","message":"%s"}}\n' "$state" "$iso" "$message" \
            > "$STATUS_DIR/status-${{safe_host}}.json"
        echo -e "$state\n$now" > "$STATE_FILE"
    fi
}}

run_with_timeout() {{
    local secs="$1"; shift
    /usr/bin/perl -e 'alarm shift @ARGV; exec @ARGV' "$secs" "$@"
}}

is_remote_available() {{
    local socket="${{SSH_TMP}}/ssh-kanban-code-${{REMOTE_HOST}}:22"
    if [[ -S "$socket" ]]; then
        if ! run_with_timeout 1 /usr/bin/ssh -o ControlPath="$socket" -O check "$REMOTE_HOST" 2>/dev/null; then
            /bin/rm -f "$socket" 2>/dev/null
        fi
    fi
    run_with_timeout 5 /usr/bin/ssh -o ConnectTimeout=5 -o BatchMode=yes "$REMOTE_HOST" "exit 0" 2>/dev/null
}}

while [[ $# -gt 0 ]]; do
    case "$1" in
        -c) shift ;;
        -l|-i) shift ;;
        *) cmd="$1"; break ;;
    esac
done

if [[ -n "${{cmd:-}}" ]]; then
    pwd_file=""
    if [[ "$cmd" =~ (.*)(\&\&\ pwd\ -P\ \>\|\ ([^[:space:]]+))$ ]]; then
        cmd="${{BASH_REMATCH[1]}}"
        pwd_file="${{BASH_REMATCH[3]}}"
    fi

    LOCAL_CWD="$(pwd -P)"

    if [[ -z "$REMOTE_HOST" ]] || [[ -z "$REMOTE_DIR" ]] || [[ -z "$LOCAL_MOUNT" ]]; then
        /bin/bash -c "$cmd"
        exit_code=$?
        [[ -n "$pwd_file" ]] && pwd -P > "$pwd_file"
        exit $exit_code
    fi

    if is_remote_available; then
        notify "Remote instance available" "online"
        REMOTE_CWD="$(local_to_remote "$LOCAL_CWD")"
        cmd="${{cmd//$LOCAL_MOUNT/$REMOTE_DIR}}"
        cmd=$(echo "$cmd" | /usr/bin/sed -E 's|/var/folders/[^[:space:];]+\.tmp|true|g')
        ensure_sync
        MARKER="__KANBAN_CODE_REMOTE_PWD__"
        remote_cmd="${{WORKTREE_FIX_FN}}
        source ~/.profile 2>/dev/null; source <(sed 's/return;;/;;/' ~/.bashrc) 2>/dev/null; cd '$REMOTE_CWD' 2>/dev/null || cd '$REMOTE_DIR'; __fix_wt '$LOCAL_MOUNT' '$REMOTE_DIR'; /bin/bash -c $(printf '%q' "$cmd"); __fix_wt '$LOCAL_MOUNT' '$REMOTE_DIR'; echo $MARKER; pwd -P"
        remote_output=$(/usr/bin/ssh $SSH_OPTS "$REMOTE_HOST" "$remote_cmd")
        exit_code=$?
        "$MUTAGEN" sync flush --label-selector kanban=true >/dev/null 2>&1 || true
        if [[ "$remote_output" == *"$MARKER"* ]]; then
            cmd_output="${{remote_output%$MARKER*}}"
            remote_pwd="${{remote_output##*$MARKER}}"
            remote_pwd=$(echo "$remote_pwd" | tr -d '\n')
            printf "%s" "$cmd_output"
            if [[ -n "$pwd_file" ]]; then
                echo "$(remote_to_local "$remote_pwd")" > "$pwd_file"
            fi
        else
            echo "$remote_output"
            [[ -n "$pwd_file" ]] && echo "$LOCAL_CWD" > "$pwd_file"
        fi
    else
        notify "Remote unavailable - using local execution" "offline"
        cmd="${{cmd//$REMOTE_DIR/$LOCAL_MOUNT}}"
        MARKER="__KANBAN_CODE_LOCAL_PWD__"
        local_output=$(/bin/bash -c "$cmd; echo $MARKER; pwd -P" 2>&1)
        exit_code=$?
        if [[ "$local_output" == *"$MARKER"* ]]; then
            cmd_output="${{local_output%$MARKER*}}"
            local_pwd="${{local_output##*$MARKER}}"
            local_pwd=$(echo "$local_pwd" | tr -d '\n')
            printf "%s" "$cmd_output"
            [[ -n "$pwd_file" ]] && echo "$local_pwd" > "$pwd_file"
        else
            echo "$local_output"
            [[ -n "$pwd_file" ]] && echo "$LOCAL_CWD" > "$pwd_file"
        fi
    fi

    exit $exit_code
else
    if [[ -z "$REMOTE_HOST" ]] || [[ -z "$REMOTE_DIR" ]] || [[ -z "$LOCAL_MOUNT" ]]; then
        exec /bin/bash -l
    fi

    if is_remote_available; then
        notify "Remote instance available" "online"
        REMOTE_CWD="$(local_to_remote "$(pwd -P)")"
        /usr/bin/ssh $SSH_OPTS -t "$REMOTE_HOST" "cd '$REMOTE_CWD' 2>/dev/null || cd '$REMOTE_DIR'; /bin/bash -l"
    else
        notify "Remote unavailable - using local shell" "offline"
        /bin/bash -l
    fi
fi
"####
    )
}
