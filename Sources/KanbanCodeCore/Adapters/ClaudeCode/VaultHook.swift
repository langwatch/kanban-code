import Foundation
#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif

/// The Claude Code and Codex PreToolUse hook of the vault: a Bash command
/// run in a project that has a `.env.vault` first loads the vault env
/// (`kv hook` rewrites it). The script finds no `.env.vault` in a few stat
/// calls and exits, so other projects pay nothing.
public enum VaultHook {
    public static let marker = ".kanban-code/vault-hook.sh"

    public static var scriptPath: String {
        (NSHomeDirectory() as NSString).appendingPathComponent(marker)
    }

    public static let scriptContent = #"""
    #!/bin/sh
    # Installed by Kanban Code: Claude Code and Codex PreToolUse hook for Bash.
    # Every command first passes the secret guard (below). Then, in a project
    # with a .env.vault, `kv hook` rewrites the command to load the vault env
    # first; anywhere else this exits without output.
    # A linked worktree without its own falls back to the main checkout's.
    input=$(cat)

    # The secret guard refuses commands that print the values of a *.env
    # under /etc or a whole environment: a multi-line value (a PEM key) has
    # lines without "=", so even `env | cut -d= -f1` prints them.
    cmd=$(printf '%s\n' "$input" | sed -nE 's/.*"command"[[:space:]]*:[[:space:]]*"(([^"\\]|\\.)*)".*/\1/p' |
      sed -e 's/\\n/; /g' -e 's/\\t/ /g' -e 's/\\"/"/g' -e 's#\\/#/#g' -e 's/\\\\/\\/g')
    q="'"
    start="(^|[;&|({\`\"$q])[[:space:]]*((sudo|xargs|exec|nice|nohup|setsid|time|command|env)([[:space:]]+-[a-zA-Z]+([[:space:]]+[^-[:space:]][^[:space:]]*)?)*[[:space:]]+)*"
    end="([[:space:]]*($|[;&|)><\`\"$q]))"
    etc="/etc/([^[:space:];&|<>\"$q]*/)?[^/[:space:];&|<>\"$q]*\.env($|[[:space:];&|<>)\"$q])"
    readers="(cat|tac|nl|bat|grep|egrep|fgrep|rg|ag|sed|awk|gawk|mawk|less|more|most|head|tail|cut|sort|uniq|strings|xxd|od|hexdump|base64|cp|scp|rsync|install|dd|tee|source|\.|diff|cmp|vi|vim|nvim|view|nano|emacs|jq|yq|python|python3|perl|ruby|node|php|openssl|gpg|curl|wget|nc)"
    refuse() {
      reason="Refused by the Kanban Code vault guard: $1 would print secret values, multi-line ones (PEM keys) included. To see which variables a file holds, run kv env --names <file>; to run a command with them, use kv env <file> -- <command>, which never prints them."
      printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"%s"}}\n' "$reason"
      exit 0
    }
    if [ -n "$cmd" ]; then
      has() { printf '%s\n' "$cmd" | grep -Eq -- "$1"; }
      has "$start$readers[[:space:]]([^;&|]*[[:space:]=\"$q])?$etc" && refuse "reading a .env file under /etc"
      has "<[[:space:]]*[\"$q]?$etc" && refuse "reading a .env file under /etc"
      has "(EnvironmentFile=|env-file[=[:space:]]+)[\"$q]?-?$etc" &&
        has "(^|[^a-zA-Z0-9_./-])(env|printenv|set|export|declare|typeset)([^a-zA-Z0-9_.=-]|$)" &&
        refuse "loading a .env file under /etc and listing the environment"
      has "$start(env|printenv)([[:space:]]+(-0|--null|-i))*$end" && refuse "printing the whole environment"
      has "$start(export|declare|typeset)[[:space:]]+-[a-zA-Z]*[px]" && refuse "printing the whole environment"
      has "$start(export|set)$end" && refuse "printing the whole environment"
      has "/proc/[^[:space:]]*/environ" && refuse "reading a process environment"
    fi

    hook() {
      kv="$HOME/.local/bin/kv"
      [ -x "$kv" ] || kv="$(command -v kv)" || exit 0
      printf '%s\n' "$input" | "$kv" hook "$@"
      exit $?
    }
    d="$PWD"
    while [ -n "$d" ]; do
      [ -f "$d/.env.vault" ] && hook "$@"
      if [ -f "$d/.git" ]; then
        main=$(sed -n 's#^gitdir: *\(.*\)/\.git/worktrees/[^/]*$#\1#p' "$d/.git")
        [ -n "$main" ] && [ -f "$main/.env.vault" ] && hook "$@"
        [ -n "$main" ] && [ -f "$main${PWD#"$d"}/.env.vault" ] && hook "$@"
        exit 0
      fi
      if [ -e "$d/.git" ] || [ "$d" = "$HOME" ] || [ "$d" = "/" ]; then exit 0; fi
      d=$(dirname "$d")
    done
    exit 0

    """#

    /// Installs it when the Kanban Code hooks of Claude Code are installed,
    /// and for Codex when Codex is set up on this machine.
    public static func installWhereHooked() {
        if HookManager.isInstalled(for: .claude), (try? install()) == true {
            KanbanCodeLog.info("hooks", "installed the vault Bash hook")
        }
        if FileManager.default.fileExists(atPath: codexHome), (try? installCodex()) == true {
            KanbanCodeLog.info("hooks", "installed the vault Bash hook for Codex")
        }
    }

    /// Writes the script and adds the hook to the Claude settings when
    /// missing. Returns whether anything changed.
    @discardableResult
    public static func install(settingsPath: String? = nil, scriptPath: String? = nil) throws -> Bool {
        let script = scriptPath ?? Self.scriptPath
        var changed = try writeScript(script)
        let path = settingsPath ?? HookManager.defaultSettingsPath(for: .claude)
        var root: [String: Any] = [:]
        if let data = FileManager.default.contents(atPath: path) {
            guard let parsed = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { return changed }
            root = parsed
        }
        var hooks = root["hooks"] as? [String: Any] ?? [:]
        var groups = hooks["PreToolUse"] as? [[String: Any]] ?? []
        let present = groups.contains { group in
            (group["hooks"] as? [[String: Any]] ?? []).contains { ($0["command"] as? String)?.contains(marker) == true }
        }
        guard !present else { return changed }
        groups.append(["matcher": "Bash", "hooks": [["type": "command", "command": script, "timeout": 900]]])
        hooks["PreToolUse"] = groups
        root["hooks"] = hooks
        let data = try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: URL(fileURLWithPath: path))
        return true
    }

    // MARK: - Codex

    /// `$CODEX_HOME`, else `~/.codex`.
    public static var codexHome: String {
        if let home = ProcessInfo.processInfo.environment["CODEX_HOME"], !home.isEmpty { return home }
        return (NSHomeDirectory() as NSString).appendingPathComponent(".codex")
    }

    static let codexTimeout = 900

    /// Adds the hook to Codex's `hooks.json` and trusts it in `config.toml`.
    /// Codex runs a user hook only once its exact definition is trusted: the
    /// trust is `hooks.state."<hooks.json>:pre_tool_use:<group>:<handler>"`
    /// holding the hash Codex computes (`codexTrustHash`). Codex answers need
    /// `kv hook --codex` (see `hookRewrite` in cli/src/vault.ts).
    /// Returns whether anything changed.
    @discardableResult
    public static func installCodex(codexHome: String? = nil, scriptPath: String? = nil) throws -> Bool {
        let home = codexHome ?? Self.codexHome
        let script = scriptPath ?? Self.scriptPath
        var changed = try writeScript(script)
        let command = "\(script) --codex"
        let hooksPath = (home as NSString).appendingPathComponent("hooks.json")
        var root: [String: Any] = [:]
        if let data = FileManager.default.contents(atPath: hooksPath) {
            guard let parsed = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { return changed }
            root = parsed
        }
        var hooks = root["hooks"] as? [String: Any] ?? [:]
        var groups = hooks["PreToolUse"] as? [[String: Any]] ?? []
        let index: Int
        if let found = groups.firstIndex(where: { group in
            (group["hooks"] as? [[String: Any]] ?? []).contains { ($0["command"] as? String) == command }
        }) {
            index = found
        } else {
            groups.append(["matcher": "Bash", "hooks": [["type": "command", "command": command, "timeout": codexTimeout]]])
            index = groups.count - 1
            hooks["PreToolUse"] = groups
            root["hooks"] = hooks
            try FileManager.default.createDirectory(atPath: home, withIntermediateDirectories: true)
            let data = try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
            try data.write(to: URL(fileURLWithPath: hooksPath))
            changed = true
        }
        let group = groups[index]
        let handlers = group["hooks"] as? [[String: Any]] ?? []
        guard let handlerIndex = handlers.firstIndex(where: { ($0["command"] as? String) == command }) else { return changed }
        let handler = handlers[handlerIndex]
        let hash = codexTrustHash(
            matcher: group["matcher"] as? String, command: command,
            timeout: (handler["timeout"] as? Int) ?? 600,
            async: (handler["async"] as? Bool) ?? false,
            statusMessage: handler["statusMessage"] as? String
        )
        let key = "\(hooksPath):pre_tool_use:\(index):\(handlerIndex)"
        let configPath = (home as NSString).appendingPathComponent("config.toml")
        let config = (try? String(contentsOfFile: configPath, encoding: .utf8)) ?? ""
        let updated = trustingCodexHook(config: config, key: key, hash: hash)
        if updated != config {
            try updated.write(toFile: configPath, atomically: true, encoding: .utf8)
            changed = true
        }
        return changed
    }

    /// Codex's trust hash of one PreToolUse command hook: sha256 of the
    /// compact, key-sorted JSON of the normalized hook identity.
    public static func codexTrustHash(matcher: String?, command: String, timeout: Int, async: Bool = false,
                                      statusMessage: String? = nil) -> String {
        var handler = "{\"async\":\(async),\"command\":\(jsonString(command))"
        if let statusMessage { handler += ",\"statusMessage\":\(jsonString(statusMessage))" }
        handler += ",\"timeout\":\(timeout),\"type\":\"command\"}"
        var identity = "{\"event_name\":\"pre_tool_use\",\"hooks\":[\(handler)]"
        if let matcher { identity += ",\"matcher\":\(jsonString(matcher))" }
        identity += "}"
        return "sha256:" + SHA256.hash(data: Data(identity.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// `config.toml` with `[hooks.state."<key>"] trusted_hash = "<hash>"`
    /// set, the rest of the file as it was.
    public static func trustingCodexHook(config: String, key: String, hash: String) -> String {
        let header = "[hooks.state.\(jsonString(key))]"
        let line = "trusted_hash = \"\(hash)\""
        var lines = config.components(separatedBy: "\n")
        if let start = lines.firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == header }) {
            var i = start + 1
            while i < lines.count, !lines[i].trimmingCharacters(in: .whitespaces).hasPrefix("[") {
                if lines[i].trimmingCharacters(in: .whitespaces).hasPrefix("trusted_hash") {
                    if lines[i] == line { return config }
                    lines[i] = line
                    return lines.joined(separator: "\n")
                }
                i += 1
            }
            lines.insert(line, at: start + 1)
            return lines.joined(separator: "\n")
        }
        var out = config
        if !out.isEmpty && !out.hasSuffix("\n") { out += "\n" }
        out += "\n\(header)\n\(line)\n"
        return out
    }

    /// A JSON string literal as serde_json writes it.
    static func jsonString(_ s: String) -> String {
        var out = "\""
        for scalar in s.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            case "\u{08}": out += "\\b"
            case "\u{0C}": out += "\\f"
            default:
                if scalar.value < 0x20 {
                    out += String(format: "\\u%04x", scalar.value)
                } else {
                    out.unicodeScalars.append(scalar)
                }
            }
        }
        return out + "\""
    }

    private static func writeScript(_ script: String) throws -> Bool {
        guard (try? String(contentsOfFile: script, encoding: .utf8)) != scriptContent else { return false }
        try FileManager.default.createDirectory(atPath: (script as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        try scriptContent.write(toFile: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script)
        return true
    }
}
