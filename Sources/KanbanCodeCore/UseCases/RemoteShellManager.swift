import Foundation

/// Deploys the remote-shell.sh wrapper and provides shell/environment overrides
/// for projects configured with remote execution.
public enum RemoteShellManager {

    // MARK: - Public API

    /// Deploy the remote shell script and create symlinks for zsh and bash.
    /// Call once at app startup (idempotent — overwrites with latest version).
    /// Both symlinks are needed because Claude Code uses `$SHELL -c` (zsh)
    /// while Gemini CLI and Codex CLI may use `bash -c` directly via PATH lookup.
    public static func deploy() throws {
        let fm = FileManager.default
        let remoteDir = Self.remoteDir()
        try fm.createDirectory(atPath: remoteDir, withIntermediateDirectories: true)

        // Write the shell script
        let scriptPath = Self.scriptPath()
        try remoteShellScript.write(toFile: scriptPath, atomically: true, encoding: .utf8)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptPath)

        // Create symlinks: ~/.kanban-code/remote/{zsh,bash} -> remote-shell.sh
        for name in ["zsh", "bash"] {
            let link = (remoteDir as NSString).appendingPathComponent(name)
            if fm.fileExists(atPath: link) || (try? fm.attributesOfItem(atPath: link)) != nil {
                try? fm.removeItem(atPath: link)
            }
            try fm.createSymbolicLink(atPath: link, withDestinationPath: scriptPath)
        }
    }

    /// Returns the path to use as SHELL override for remote execution (zsh symlink).
    public static func shellOverridePath() -> String {
        (remoteDir() as NSString).appendingPathComponent("zsh")
    }

    /// Returns the remote directory path, for prepending to PATH.
    /// Some CLIs use `bash -c` directly, so we need our `bash` wrapper
    /// to appear before the system bash in PATH.
    public static func remoteDirPath() -> String {
        remoteDir()
    }

    /// Returns environment variables needed for remote execution.
    /// The script reads config from ~/.kanban-code/settings.json directly,
    /// so no env vars are needed.
    public static func setupEnvironment(remote: RemoteSettings, projectPath: String) -> [String: String] {
        [:] // Script reads config from ~/.kanban-code/settings.json directly
    }

    // MARK: - Paths

    private static func remoteDir() -> String {
        (NSHomeDirectory() as NSString).appendingPathComponent(".kanban-code/remote")
    }

    private static func scriptPath() -> String {
        (remoteDir() as NSString).appendingPathComponent("remote-shell.sh")
    }

    // MARK: - Embedded Script
    // Based on ~/Projects/claude-remote/scripts/remote-shell.sh (battle-tested).
    // Adapted to read config from ~/.kanban-code/settings.json instead of config.sh.

    private static let remoteShellScript = """
    #!/bin/bash
    #
    # Remote shell wrapper for coding assistants (Claude Code, Gemini CLI, Codex CLI)
    # Intercepts shell commands and executes them on the remote machine
    # Falls back to local execution if remote is unavailable
    #
    # Configuration: reads from ~/.kanban-code/settings.json (remote.host, remote.remotePath, remote.localPath)
    #
    # When used as a `bash` symlink in PATH (for CLIs that hardcode `bash -c`),
    # hooks and script files are detected and run locally to avoid SSH overhead.
    #

    # --- Recursion guard ---
    # Prevents infinite loops when this script is symlinked as `bash` in PATH.
    # The shebang uses /bin/bash directly, but nested scripts with #!/usr/bin/env bash
    # could still recurse. This guard catches any remaining edge cases.
    if [[ -n "${__KANBAN_REMOTE_WRAPPER:-}" ]]; then
        exec /bin/bash "$@"
    fi
    export __KANBAN_REMOTE_WRAPPER=1

    # --- Hook/script fast-path ---
    # Gemini CLI runs both tool commands and hooks as `bash -c "..."`.
    # Hooks are script file paths (e.g., /path/to/hook.sh), while tool
    # commands are inline bash (e.g., "git status", "cd /path && cat file").
    # Detect script invocations and run them locally — they need local
    # filesystem access (e.g., writing hook-events.jsonl) and shouldn't
    # incur SSH overhead.
    for __arg in "$@"; do
        if [[ "$__arg" == "-c" ]] || [[ "$__arg" == "-l" ]] || [[ "$__arg" == "-i" ]]; then
            continue
        fi
        # First non-flag argument is the command
        __first_word="${__arg%% *}"
        if [[ "$__first_word" == /* ]] && [[ -x "$__first_word" ]]; then
            # Command starts with an executable file path — likely a hook/script
            exec /bin/bash "$@"
        fi
        break
    done
    unset __arg __first_word

    # Read config from ~/.kanban-code/settings.json
    CONFIG_FILE="${HOME}/.kanban-code/settings.json"
    REMOTE_HOST=""
    REMOTE_DIR=""
    LOCAL_MOUNT=""

    if [[ -f "$CONFIG_FILE" ]]; then
        REMOTE_HOST=$(/usr/bin/perl -MJSON::PP -e 'open my $f,"<","'"$CONFIG_FILE"'" or exit;local $/;my $d=decode_json(<$f>);print $d->{remote}{host}//"" if $d->{remote}' 2>/dev/null || echo "")
        REMOTE_DIR=$(/usr/bin/perl -MJSON::PP -e 'open my $f,"<","'"$CONFIG_FILE"'" or exit;local $/;my $d=decode_json(<$f>);print $d->{remote}{remotePath}//"" if $d->{remote}' 2>/dev/null || echo "")
        LOCAL_MOUNT=$(/usr/bin/perl -MJSON::PP -e 'open my $f,"<","'"$CONFIG_FILE"'" or exit;local $/;my $d=decode_json(<$f>);print $d->{remote}{localPath}//"" if $d->{remote}' 2>/dev/null || echo "")
    fi

    SSH_OPTS="-o ControlMaster=auto -o ControlPath=/tmp/ssh-kanban-code-%r@%h:%p -o ControlPersist=600 -o ConnectTimeout=5"
    STATE_FILE="/tmp/kanban-code-remote-state"
    NOTIFY_COOLDOWN=300  # 5 minutes
    MUTAGEN=$(command -v mutagen 2>/dev/null || echo "")

    # Ensure mutagen sync session exists and flush
    ensure_sync() {
        [[ -n "$MUTAGEN" ]] || return 0
        if ! "$MUTAGEN" sync list --label-selector kanban=true 2>/dev/null | grep -q "Name:"; then
            "$MUTAGEN" sync create "$LOCAL_MOUNT" "${REMOTE_HOST}:${REMOTE_DIR}" \\
                --name kanban-code-sync \\
                --label kanban=true \\
                --sync-mode two-way-resolved \\
                --default-file-mode-beta 0644 \\
                --default-directory-mode-beta 0755 \\
                --ignore node_modules --ignore .venv --ignore .cache \\
                --ignore dist --ignore '.next*' --ignore __pycache__ \\
                --ignore .pytest_cache --ignore .mypy_cache --ignore .turbo \\
                --ignore '*.pyc' --ignore .DS_Store --ignore coverage \\
                --ignore .nyc_output --ignore target --ignore build \\
                --ignore .build --ignore .swiftpm \\
                >/dev/null 2>&1 || true
        fi
        "$MUTAGEN" sync flush --label-selector kanban=true >/dev/null 2>&1 || true
    }

    # Worktree path fix — git worktrees use absolute paths in .git files.
    # When Mutagen syncs between machines, those paths break.
    # These functions convert them to relative paths that survive sync.
    # Injected into SSH commands before/after the user's command.
    read -r -d '' WORKTREE_FIX_FN << 'WFIX' || true
    __relpath(){
      local t="$1" b="$2"; t="${t%/}"; b="${b%/}"
      local c="$b" r=""
      while [ "${t#"$c"}" = "$t" ]; do c=$(dirname "$c"); r="../$r"; done
      local f="${t#"$c"}"; f="${f#/}"; printf '%s\\n' "${r}${f}"
    }
    __fix_gitlink(){
      local f="$1" wp="$2" rp="$3"
      [ -f "$f" ] || return 0
      local c; c=$(cat "$f"); local ig=false p="$c"
      case "$c" in gitdir:*) ig=true; p="${c#gitdir: }";; esac
      p="${p//$wp/$rp}"
      case "$p" in /*) ;; *) return 0;; esac
      [ -e "$p" ] || return 0
      local d; d=$(dirname "$f")
      local rl; rl=$(__relpath "$p" "$d")
      [ -n "$rl" ] || return 0
      if $ig; then printf 'gitdir: %s\\n' "$rl" > "$f"; else printf '%s\\n' "$rl" > "$f"; fi
    }
    __fix_wt(){
      local wp="$1" rp="$2" d; d=$(pwd); local gr=""
      while [ "$d" != "/" ]; do
        if [ -d "$d/.git" ]; then gr="$d"; break
        elif [ -f "$d/.git" ]; then
          __fix_gitlink "$d/.git" "$wp" "$rp"
          local g; g=$(cat "$d/.git"); g="${g#gitdir: }"
          case "$g" in /*) gr="${g%/.git/worktrees/*}";; *) gr=$(cd "$d/$g/../../.." 2>/dev/null && pwd);; esac
          break
        fi
        d=$(dirname "$d")
      done
      [ -n "$gr" ] && [ -d "$gr/.git/worktrees" ] || return 0
      for m in "$gr/.git/worktrees"/*/; do
        [ -d "$m" ] || continue
        __fix_gitlink "${m}gitdir" "$wp" "$rp"
        local gc; [ -f "${m}gitdir" ] && gc=$(cat "${m}gitdir") || continue
        [ -n "$gc" ] || continue
        local wf
        case "$gc" in /*) wf="$gc";;
          *) wf=$(cd "$m" && cd "$(dirname "$gc")" 2>/dev/null && printf '%s/%s\\n' "$(pwd)" "$(basename "$gc")") || continue;;
        esac
        [ -n "$wf" ] && __fix_gitlink "$wf" "$wp" "$rp"
      done
    }
    WFIX

    # Map local path to remote path
    local_to_remote() {
        echo "${1/#$LOCAL_MOUNT/$REMOTE_DIR}"
    }

    # Map remote path to local path
    remote_to_local() {
        echo "${1/#$REMOTE_DIR/$LOCAL_MOUNT}"
    }

    # Send macOS notification with rate limiting
    notify() {
        local message="$1"
        local state="$2"  # "offline" or "online"
        local now=$(date +%s)
        local last_state=""
        local last_notify=0

        if [[ -f "$STATE_FILE" ]]; then
            last_state=$(head -1 "$STATE_FILE")
            last_notify=$(tail -1 "$STATE_FILE")
        fi

        # Only notify if state changed, or still offline after cooldown
        if [[ "$state" != "$last_state" ]] || { [[ "$state" == "offline" ]] && [[ $((now - last_notify)) -ge $NOTIFY_COOLDOWN ]]; }; then
            osascript -e "display notification \\"$message\\" with title \\"Kanban Remote\\"" 2>/dev/null
            echo -e "$state\\n$now" > "$STATE_FILE"
        fi
    }

    # Run a command with a timeout (macOS-compatible, no GNU coreutils needed)
    # Usage: run_with_timeout <seconds> <command...>
    run_with_timeout() {
        local secs="$1"; shift
        /usr/bin/perl -e 'alarm shift @ARGV; exec @ARGV' "$secs" "$@"
    }

    # Check if remote is reachable (fast check with hard timeout)
    is_remote_available() {
        # First check if control socket exists but is stale
        local socket="/tmp/ssh-kanban-code-${REMOTE_HOST}:22"
        if [[ -S "$socket" ]]; then
            # Test if socket is alive, remove if stale
            if ! run_with_timeout 1 /usr/bin/ssh -o ControlPath="$socket" -O check "$REMOTE_HOST" 2>/dev/null; then
                /bin/rm -f "$socket" 2>/dev/null
            fi
        fi
        # Plain SSH check without ControlMaster (ControlMaster=auto can hang when creating socket)
        run_with_timeout 5 /usr/bin/ssh -o ConnectTimeout=5 -o BatchMode=yes "$REMOTE_HOST" "exit 0" 2>/dev/null
    }

    # Parse flags - Claude Code sends: -c -l "command"
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -c) shift ;;
            -l|-i) shift ;;
            *) cmd="$1"; break ;;
        esac
    done

    if [[ -n "${cmd:-}" ]]; then
        # Extract pwd file if present
        pwd_file=""
        if [[ "$cmd" =~ (.*)(\\&\\&\\ pwd\\ -P\\ \\>\\|\\ ([^[:space:]]+))$ ]]; then
            cmd="${BASH_REMATCH[1]}"
            pwd_file="${BASH_REMATCH[3]}"
        fi

        LOCAL_CWD="$(pwd -P)"

        if [[ -z "$REMOTE_HOST" ]] || [[ -z "$REMOTE_DIR" ]] || [[ -z "$LOCAL_MOUNT" ]]; then
            # Not configured — run locally
            /bin/bash -c "$cmd"
            exit_code=$?
            [[ -n "$pwd_file" ]] && pwd -P > "$pwd_file"
            exit $exit_code
        fi

        # Check remote availability
        if is_remote_available; then
            # === REMOTE EXECUTION ===
            notify "Remote instance available" "online"

            REMOTE_CWD="$(local_to_remote "$LOCAL_CWD")"

            # Map local paths in command to remote
            cmd="${cmd//$LOCAL_MOUNT/$REMOTE_DIR}"

            # Neutralize macOS temp file paths that don't exist on remote.
            # Gemini CLI injects temp scripts (e.g., /var/folders/.../shell_pgrep_*.tmp)
            # for process group tracking. Replace with `true` (no-op) so they don't
            # cause "No such file or directory" errors on the remote machine.
            cmd=$(echo "$cmd" | /usr/bin/sed -E 's|/var/folders/[^[:space:];]+\\.tmp|true|g')

            # Ensure mutagen sync is running and flush before command
            ensure_sync

            # Build remote command
            # Source .profile and .bashrc (with non-interactive guard disabled)
            # Inject worktree fix: convert absolute .git/gitdir paths to relative
            # so worktrees synced between machines work correctly.
            MARKER="__KANBAN_CODE_REMOTE_PWD__"
            remote_cmd="${WORKTREE_FIX_FN}
            source ~/.profile 2>/dev/null; source <(sed 's/return;;/;;/' ~/.bashrc) 2>/dev/null; cd '$REMOTE_CWD' 2>/dev/null || cd '$REMOTE_DIR'; __fix_wt '$LOCAL_MOUNT' '$REMOTE_DIR'; /bin/bash -c $(printf '%q' "$cmd"); __fix_wt '$LOCAL_MOUNT' '$REMOTE_DIR'; echo $MARKER; pwd -P"

            # Run and capture output
            remote_output=$(/usr/bin/ssh $SSH_OPTS "$REMOTE_HOST" "$remote_cmd")
            exit_code=$?

            # Flush mutagen sync after command
            "$MUTAGEN" sync flush --label-selector kanban=true >/dev/null 2>&1 || true

            # Split output and handle pwd
            if [[ "$remote_output" == *"$MARKER"* ]]; then
                cmd_output="${remote_output%$MARKER*}"
                remote_pwd="${remote_output##*$MARKER}"
                remote_pwd=$(echo "$remote_pwd" | tr -d '\\n')
                printf "%s" "$cmd_output"
                if [[ -n "$pwd_file" ]]; then
                    echo "$(remote_to_local "$remote_pwd")" > "$pwd_file"
                fi
            else
                echo "$remote_output"
                [[ -n "$pwd_file" ]] && echo "$LOCAL_CWD" > "$pwd_file"
            fi
        else
            # === LOCAL FALLBACK ===
            notify "Remote unavailable - using local execution" "offline"

            # Map remote paths in command to local (in case command has hardcoded remote paths)
            cmd="${cmd//$REMOTE_DIR/$LOCAL_MOUNT}"

            # Run locally
            MARKER="__KANBAN_CODE_LOCAL_PWD__"
            local_output=$(/bin/bash -c "$cmd; echo $MARKER; pwd -P" 2>&1)
            exit_code=$?

            # Split output and handle pwd
            if [[ "$local_output" == *"$MARKER"* ]]; then
                cmd_output="${local_output%$MARKER*}"
                local_pwd="${local_output##*$MARKER}"
                local_pwd=$(echo "$local_pwd" | tr -d '\\n')
                printf "%s" "$cmd_output"
                [[ -n "$pwd_file" ]] && echo "$local_pwd" > "$pwd_file"
            else
                echo "$local_output"
                [[ -n "$pwd_file" ]] && echo "$LOCAL_CWD" > "$pwd_file"
            fi
        fi

        exit $exit_code
    else
        # Interactive shell
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
    """
}
