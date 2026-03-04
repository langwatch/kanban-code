import Foundation

/// Deploys the remote-shell.sh wrapper and provides shell/environment overrides
/// for projects configured with remote execution.
public enum RemoteShellManager {

    // MARK: - Public API

    /// Deploy the remote shell script and create the zsh symlink.
    /// Call once at app startup (idempotent — overwrites with latest version).
    public static func deploy() throws {
        let fm = FileManager.default
        let remoteDir = Self.remoteDir()
        try fm.createDirectory(atPath: remoteDir, withIntermediateDirectories: true)

        // Write the shell script
        let scriptPath = Self.scriptPath()
        try remoteShellScript.write(toFile: scriptPath, atomically: true, encoding: .utf8)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptPath)

        // Create symlink: ~/.kanban-code/remote/zsh -> remote-shell.sh
        let symlinkPath = Self.symlinkPath()
        if fm.fileExists(atPath: symlinkPath) || (try? fm.attributesOfItem(atPath: symlinkPath)) != nil {
            try? fm.removeItem(atPath: symlinkPath)
        }
        try fm.createSymbolicLink(atPath: symlinkPath, withDestinationPath: scriptPath)
    }

    /// Returns the path to use as SHELL override for remote execution.
    public static func shellOverridePath() -> String {
        symlinkPath()
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

    private static func symlinkPath() -> String {
        (remoteDir() as NSString).appendingPathComponent("zsh")
    }

    // MARK: - Embedded Script
    // Based on ~/Projects/claude-remote/scripts/remote-shell.sh (battle-tested).
    // Adapted to read config from ~/.kanban-code/settings.json instead of config.sh.

    private static let remoteShellScript = """
    #!/usr/bin/env bash
    #
    # Remote shell wrapper for Claude Code
    # Intercepts shell commands and executes them on the remote machine
    # Falls back to local execution if remote is unavailable
    #
    # Configuration: reads from ~/.kanban-code/settings.json (remote.host, remote.remotePath, remote.localPath)
    #

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

            # Flush mutagen sync before command
            mutagen sync flush >/dev/null 2>&1 || true

            # Build remote command
            # Source .profile and .bashrc (with non-interactive guard disabled)
            MARKER="__KANBAN_CODE_REMOTE_PWD__"
            remote_cmd="source ~/.profile 2>/dev/null; source <(sed 's/return;;/;;/' ~/.bashrc) 2>/dev/null; cd '$REMOTE_CWD' 2>/dev/null || cd '$REMOTE_DIR'; /bin/bash -c $(printf '%q' "$cmd"); echo $MARKER; pwd -P"

            # Run and capture output
            remote_output=$(/usr/bin/ssh $SSH_OPTS "$REMOTE_HOST" "$remote_cmd")
            exit_code=$?

            # Flush mutagen sync after command
            mutagen sync flush >/dev/null 2>&1 || true

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
