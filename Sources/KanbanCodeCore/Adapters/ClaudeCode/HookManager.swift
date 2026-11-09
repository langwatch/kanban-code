import Foundation

/// Manages hook installation for coding assistants that expose settings hooks.
///
/// Claude Code and Gemini CLI use the same hook configuration format:
/// `settings.json` → `hooks` → `{ EventName: [{ matcher, hooks: [{ type, command }] }] }`
///
/// The same hook script (`~/.kanban-code/hook.sh`) works for both because both pass
/// `session_id`, `hook_event_name`, and `transcript_path` via stdin JSON.
/// The orchestrator normalizes Gemini-specific event names (e.g. `AfterAgent` → `Stop`).
public enum HookManager {

    /// Hook events needed per assistant. Event names differ but serve the same purpose.
    public static func requiredHooks(for assistant: CodingAssistant) -> [String] {
        switch assistant {
        case .claude:
            [
                "Stop", "Notification", "SessionStart", "SessionEnd", "UserPromptSubmit",
                "SubagentStart", "SubagentStop",
            ]
        case .gemini:
            ["AfterAgent", "Notification", "SessionStart", "SessionEnd", "BeforeAgent"]
        case .codex:
            []
        }
    }

    /// Claude Code's required hooks (backward compat).
    static let requiredHooks = requiredHooks(for: .claude)

    /// Normalize Gemini event names to the canonical names the orchestrator understands.
    public static func normalizeEventName(_ name: String) -> String {
        switch name {
        case "AfterAgent": "Stop"
        case "BeforeAgent": "UserPromptSubmit"
        default: name
        }
    }

    // MARK: - Check

    /// Check if hooks are already installed for the given assistant. With no
    /// `settingsPath`, Claude's hooks count as installed when every Claude
    /// config folder has them.
    public static func isInstalled(for assistant: CodingAssistant, settingsPath: String? = nil) -> Bool {
        isInstalled(for: assistant, settingsPaths: settingsPaths(for: assistant, settingsPath: settingsPath))
    }

    /// Installed in every file Kanban may write; one it leaves alone (not
    /// JSON) does not keep the hooks from counting as installed.
    static func isInstalled(for assistant: CodingAssistant, settingsPaths: [String]) -> Bool {
        guard assistant.supportsHooks else { return false }
        let writable = settingsPaths.count > 1 ? settingsPaths.filter(isRewritable) : settingsPaths
        return !writable.isEmpty && writable.allSatisfy { isInstalled(for: assistant, at: $0) }
    }

    private static func isInstalled(for assistant: CodingAssistant, at path: String) -> Bool {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let hooks = root["hooks"] as? [String: Any] else {
            return false
        }

        return requiredHooks(for: assistant).allSatisfy { eventName in
            guard let groups = hooks[eventName] as? [[String: Any]] else { return false }
            return groups.contains { group in
                guard let hookEntries = group["hooks"] as? [[String: Any]] else { return false }
                return hookEntries.contains { entry in
                    (entry["command"] as? String)?.contains(".kanban-code/hook.sh") == true
                }
            }
        }
    }

    /// Backward-compatible: check Claude hooks only.
    public static func isInstalled(claudeSettingsPath: String? = nil) -> Bool {
        isInstalled(for: .claude, settingsPath: claudeSettingsPath)
    }

    /// Add hook events a release needs that an earlier install did not have.
    ///
    /// Only for settings that already call the hook script: an assistant that
    /// never had hooks is left to the user to set up in Settings. Once one
    /// Claude config folder has them, a folder that has none (an account
    /// added later) gets them too, keeping a status line of its own and
    /// leaving a settings file that is not JSON alone.
    @discardableResult
    public static func addMissingHooks(for assistant: CodingAssistant, settingsPath: String? = nil)
        -> Bool
    {
        addMissingHooks(for: assistant, settingsPaths: settingsPaths(for: assistant, settingsPath: settingsPath))
    }

    /// `addMissingHooks` over the given settings files.
    @discardableResult
    static func addMissingHooks(
        for assistant: CodingAssistant, settingsPaths paths: [String], hookScriptPath: String? = nil,
        statusLineScriptPath: String? = nil
    ) -> Bool {
        guard assistant.supportsHooks else { return false }
        let hooked = Set(paths.filter { registeredHooks(for: assistant, at: $0) > 0 })
        guard !hooked.isEmpty else { return false }
        var changed = false
        let standard = ClaudeConfigDirectories.current.standard + "/settings.json"
        for path in paths where !isInstalled(for: assistant, at: path) && isRewritable(path) {
            // As before in a file that had the hooks, `~/.claude`'s; any
            // other keeps a status line of its own.
            let added = hooked.contains(path) && (paths.count == 1 || path == standard)
            if (try? install(for: assistant, at: path, hookScriptPath: hookScriptPath, replaceStatusLine: added,
                             statusLineScriptPath: statusLineScriptPath)) != nil {
                changed = true
            }
        }
        return changed && paths.allSatisfy { isInstalled(for: assistant, at: $0) }
    }

    /// Rewrite the deployed hook script when a release changed its content.
    ///
    /// Only for a script that is already on disk: a machine that never
    /// installed hooks is left to the Settings flow.
    @discardableResult
    public static func refreshHookScript(at path: String? = nil) -> Bool {
        let scriptPath = path ?? defaultHookScriptPath()
        guard let current = try? String(contentsOfFile: scriptPath, encoding: .utf8),
            current != hookScriptContent
        else { return false }
        do {
            try deployHookScript(to: scriptPath)
            return true
        } catch {
            return false
        }
    }

    /// How many of the events this release needs already call the hook script.
    private static func registeredHooks(for assistant: CodingAssistant, at path: String) -> Int
    {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
            let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let hooks = root["hooks"] as? [String: Any]
        else { return 0 }

        return requiredHooks(for: assistant).count { eventName in
            guard let groups = hooks[eventName] as? [[String: Any]] else { return false }
            return groups.contains { group in
                guard let entries = group["hooks"] as? [[String: Any]] else { return false }
                return entries.contains {
                    ($0["command"] as? String)?.contains(".kanban-code/hook.sh") == true
                }
            }
        }
    }

    // MARK: - Install

    /// Install hooks for the given assistant. With no `settingsPath`,
    /// Claude's go into every Claude config folder.
    public static func install(
        for assistant: CodingAssistant,
        settingsPath: String? = nil,
        hookScriptPath: String? = nil,
        statusLineScriptPath: String? = nil
    ) throws {
        guard assistant.supportsHooks else {
            throw HookManagerError.unsupportedAssistant(assistant.displayName)
        }
        if let settingsPath {
            try install(for: assistant, at: settingsPath, hookScriptPath: hookScriptPath, replaceStatusLine: true,
                        statusLineScriptPath: statusLineScriptPath)
        } else {
            // The status line of `~/.claude` is replaced as it always was;
            // another folder keeps one of its own.
            let standard = ClaudeConfigDirectories.current.standard + "/settings.json"
            for path in settingsPaths(for: assistant, settingsPath: nil) {
                try install(for: assistant, settingsPaths: [path], hookScriptPath: hookScriptPath,
                            replacingOwnStatusLine: path == standard || assistant != .claude,
                            statusLineScriptPath: statusLineScriptPath)
            }
        }
    }

    /// `install` into each of several settings files. `replacingOwnStatusLine:
    /// false` keeps a status line a file already has.
    public static func install(
        for assistant: CodingAssistant, settingsPaths: [String], hookScriptPath: String? = nil,
        replacingOwnStatusLine: Bool = true, statusLineScriptPath: String? = nil
    ) throws {
        for path in settingsPaths {
            // One file of several that does not parse is skipped, not
            // replaced: it belongs to another account the user set up.
            if !isRewritable(path) {
                KanbanCodeLog.warn("hooks", "Not installing hooks into \(path): not a JSON object")
                continue
            }
            try install(for: assistant, at: path, hookScriptPath: hookScriptPath, replaceStatusLine: replacingOwnStatusLine,
                        statusLineScriptPath: statusLineScriptPath)
        }
    }

    private static func install(
        for assistant: CodingAssistant,
        at resolvedSettingsPath: String,
        hookScriptPath: String?,
        replaceStatusLine: Bool,
        statusLineScriptPath: String? = nil
    ) throws {
        let scriptPath = hookScriptPath ?? defaultHookScriptPath()

        // Deploy the hook script to disk
        try deployHookScript(to: scriptPath)

        // Read existing settings
        var root: [String: Any]
        if let data = try? Data(contentsOf: URL(fileURLWithPath: resolvedSettingsPath)),
           let existing = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            root = existing
        } else {
            root = [:]
        }

        var hooks = root["hooks"] as? [String: Any] ?? [:]

        let hookEntry: [String: Any] = [
            "type": "command",
            "command": scriptPath,
        ]

        for eventName in requiredHooks(for: assistant) {
            var groups = hooks[eventName] as? [[String: Any]] ?? []

            // Check if .kanban-code/hook.sh already exists in any group
            let alreadyInstalled = groups.contains { group in
                guard let entries = group["hooks"] as? [[String: Any]] else { return false }
                return entries.contains { ($0["command"] as? String)?.contains(".kanban-code/hook.sh") == true }
            }

            if !alreadyInstalled {
                if groups.isEmpty {
                    groups.append(["matcher": "", "hooks": [hookEntry]])
                } else {
                    var firstGroup = groups[0]
                    var entries = firstGroup["hooks"] as? [[String: Any]] ?? []
                    entries.append(hookEntry)
                    firstGroup["hooks"] = entries
                    groups[0] = firstGroup
                }
            }

            hooks[eventName] = groups
        }

        root["hooks"] = hooks

        // Write back
        let fileManager = FileManager.default
        let dir = (resolvedSettingsPath as NSString).deletingLastPathComponent
        try fileManager.createDirectory(atPath: dir, withIntermediateDirectories: true)

        let data = try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: URL(fileURLWithPath: resolvedSettingsPath))

        // Also install statusline for context tracking (Claude only)
        if assistant == .claude {
            try? installStatusLine(
                for: assistant, settingsPath: resolvedSettingsPath, scriptPath: statusLineScriptPath,
                replacingOwn: replaceStatusLine)
        }
    }

    /// Backward-compatible: install Claude hooks only.
    public static func install(
        claudeSettingsPath: String? = nil,
        hookScriptPath: String? = nil
    ) throws {
        try install(for: .claude, settingsPath: claudeSettingsPath, hookScriptPath: hookScriptPath)
    }

    // MARK: - Uninstall

    /// Remove Kanban hooks from the given assistant's settings, from every
    /// Claude config folder with no `settingsPath`.
    public static func uninstall(for assistant: CodingAssistant, settingsPath: String? = nil) throws {
        guard assistant.supportsHooks else { return }
        // Every folder is tried; the first failure is thrown after.
        var failure: Error?
        for path in settingsPaths(for: assistant, settingsPath: settingsPath) {
            do { try uninstall(for: assistant, at: path) } catch { failure = failure ?? error }
        }
        if let failure { throw failure }
    }

    private static func uninstall(for assistant: CodingAssistant, at resolvedSettingsPath: String) throws {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: resolvedSettingsPath)),
              var root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              var hooks = root["hooks"] as? [String: Any] else {
            return
        }

        for eventName in requiredHooks(for: assistant) {
            if var groups = hooks[eventName] as? [[String: Any]] {
                for i in groups.indices {
                    if var entries = groups[i]["hooks"] as? [[String: Any]] {
                        entries.removeAll { ($0["command"] as? String)?.contains(".kanban-code/hook.sh") == true }
                        groups[i]["hooks"] = entries
                    }
                }
                groups.removeAll { group in
                    guard let entries = group["hooks"] as? [[String: Any]] else { return true }
                    return entries.isEmpty
                }
                if groups.isEmpty {
                    hooks.removeValue(forKey: eventName)
                } else {
                    hooks[eventName] = groups
                }
            }
        }

        root["hooks"] = hooks

        let newData = try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys])
        try newData.write(to: URL(fileURLWithPath: resolvedSettingsPath))
    }

    /// Backward-compatible: uninstall Claude hooks only.
    public static func uninstall(claudeSettingsPath: String? = nil) throws {
        try uninstall(for: .claude, settingsPath: claudeSettingsPath)
    }

    // MARK: - Private

    private static func deployHookScript(to path: String) throws {
        let fm = FileManager.default
        let dir = (path as NSString).deletingLastPathComponent
        try fm.createDirectory(atPath: dir, withIntermediateDirectories: true)

        try hookScriptContent.write(toFile: path, atomically: true, encoding: .utf8)

        try fm.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: path
        )
    }

    private static let hookScriptContent = """
    #!/usr/bin/env bash
    # Kanban hook handler for coding assistants (Claude Code, Gemini CLI).
    # Receives JSON on stdin from hooks, appends a timestamped
    # event line to ~/.kanban-code/hook-events.jsonl.

    set -euo pipefail

    # A side chat (/btw, /catchup) forks a session to answer a question and
    # writes nothing: it is not a session of the board.
    if [ -n "${KANBAN_SIDE_CHAT:-}" ]; then cat > /dev/null; exit 0; fi

    EVENTS_DIR="${HOME}/.kanban-code"
    EVENTS_FILE="${EVENTS_DIR}/hook-events.jsonl"

    # Ensure directory exists
    mkdir -p "$EVENTS_DIR"

    # Read the JSON payload from stdin
    input=$(cat)

    # Extract fields using lightweight parsing (no jq dependency)
    session_id=$(echo "$input" | grep -o '"session_id":"[^"]*"' | head -1 | cut -d'"' -f4)
    hook_event=$(echo "$input" | grep -o '"hook_event_name":"[^"]*"' | head -1 | cut -d'"' -f4)
    transcript=$(echo "$input" | grep -o '"transcript_path":"[^"]*"' | head -1 | cut -d'"' -f4)

    # Fallback: try sessionId (different hook formats)
    if [ -z "$session_id" ]; then
        session_id=$(echo "$input" | grep -o '"sessionId":"[^"]*"' | head -1 | cut -d'"' -f4)
    fi

    # Skip if we couldn't extract a session ID
    [ -z "$session_id" ] && exit 0

    # Get current timestamp
    timestamp=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

    # SessionStart carries a source (startup, resume, clear, compact) that
    # tells a real fresh start apart from a compaction of a live session.
    # Gated on the event name: other payloads can carry a "source" key
    # inside user text or tool input, and that must not leak in here.
    extra=""
    if [ "$hook_event" = "SessionStart" ]; then
        start_source=$(echo "$input" | grep -o '"source":"[^"]*"' | head -1 | cut -d'"' -f4 || true)
        if [ -n "$start_source" ]; then
            extra=",\\"source\\":\\"$start_source\\""
        fi
    fi
    # A Notification carries its type (permission_prompt, idle_prompt, ...)
    # and text; the whole payload goes along, base64 so quotes survive.
    if [ "$hook_event" = "Notification" ]; then
        payload_b64=$(printf '%s' "$input" | base64 | tr -d '\\n')
        extra="$extra,\\"payloadB64\\":\\"$payload_b64\\""
    fi

    # Append event line
    printf '{"sessionId":"%s","event":"%s","timestamp":"%s","transcriptPath":"%s"%s}\\n' \\
        "$session_id" "$hook_event" "$timestamp" "$transcript" "$extra" >> "$EVENTS_FILE"
    """

    // MARK: - Statusline

    /// Check if the statusline script is installed for the given assistant.
    public static func isStatusLineInstalled(for assistant: CodingAssistant = .claude, settingsPath: String? = nil) -> Bool {
        guard assistant == .claude else { return false }
        return settingsPaths(for: assistant, settingsPath: settingsPath).allSatisfy(isStatusLineInstalled(at:))
    }

    private static func isStatusLineInstalled(at path: String) -> Bool {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let statusLine = root["statusLine"] as? [String: Any],
              let command = statusLine["command"] as? String else {
            return false
        }
        return command.contains(".kanban-code/statusline.sh")
    }

    /// Install the statusline script for context tracking, into every
    /// Claude config folder with no `settingsPath`. `replacingOwn: false`
    /// keeps a status line the user set.
    public static func installStatusLine(
        for assistant: CodingAssistant = .claude,
        settingsPath: String? = nil,
        scriptPath: String? = nil,
        replacingOwn: Bool = true
    ) throws {
        guard assistant == .claude else { return }
        for path in settingsPaths(for: assistant, settingsPath: settingsPath) where settingsPath != nil || isRewritable(path) {
            try installStatusLine(at: path, scriptPath: scriptPath, replacingOwn: replacingOwn)
        }
    }

    private static func installStatusLine(at resolvedSettingsPath: String, scriptPath: String?, replacingOwn: Bool) throws {
        let resolvedScriptPath = scriptPath ?? defaultStatusLineScriptPath()

        // Deploy script
        try deployStatusLineScript(to: resolvedScriptPath)

        // Read existing settings
        var root: [String: Any]
        if let data = try? Data(contentsOf: URL(fileURLWithPath: resolvedSettingsPath)),
           let existing = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            root = existing
        } else {
            root = [:]
        }

        // Check if already installed
        if let existing = root["statusLine"] as? [String: Any],
           let cmd = existing["command"] as? String,
           cmd.contains(".kanban-code/statusline.sh") {
            return // Already installed
        }
        if !replacingOwn, root["statusLine"] != nil { return }

        root["statusLine"] = [
            "type": "command",
            "command": resolvedScriptPath
        ] as [String: Any]

        // Write back
        let fm = FileManager.default
        let dir = (resolvedSettingsPath as NSString).deletingLastPathComponent
        try fm.createDirectory(atPath: dir, withIntermediateDirectories: true)

        let data = try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: URL(fileURLWithPath: resolvedSettingsPath))
    }

    // MARK: - Paths

    /// Settings file path per assistant.
    public static func defaultSettingsPath(for assistant: CodingAssistant) -> String {
        (NSHomeDirectory() as NSString).appendingPathComponent("\(assistant.configDirName)/settings.json")
    }

    /// The `settings.json` of every Claude config folder that exists and
    /// looks like Claude Code's (`ClaudeConfigLayout.writableDirectories`),
    /// or of `~/.claude` when none does yet.
    public static func claudeSettingsPaths(layout: ClaudeConfigLayout = ClaudeConfigDirectories.current) -> [String] {
        var isDir: ObjCBool = false
        let existing = layout.writableDirectories.filter {
            FileManager.default.fileExists(atPath: $0, isDirectory: &isDir) && isDir.boolValue
        }
        // Folders often share one settings file through a symlink: once,
        // spelled as ~/.claude's when it is that one.
        var seen = Set<String>()
        let folders = existing.isEmpty ? [layout.standard] : existing
        let ordered = folders.filter { $0 == layout.standard } + folders.filter { $0 != layout.standard }
        let kept = ordered.map { $0 + "/settings.json" }.filter { seen.insert(ClaudeConfigLayout.resolve($0)).inserted }
        return folders.map { $0 + "/settings.json" }.filter { kept.contains($0) }
    }

    /// The files a nil `settingsPath` stands for.
    static func settingsPaths(for assistant: CodingAssistant, settingsPath: String?) -> [String] {
        if let settingsPath { return [settingsPath] }
        return assistant == .claude ? claudeSettingsPaths() : [defaultSettingsPath(for: assistant)]
    }

    /// A settings file Kanban may rewrite: missing, or a JSON object. One
    /// it cannot parse would be replaced by an empty one.
    public static func isRewritable(_ path: String) -> Bool {
        guard let data = FileManager.default.contents(atPath: path) else {
            return !FileManager.default.fileExists(atPath: path)
        }
        if data.allSatisfy({ $0 == 0x20 || $0 == 0x0A || $0 == 0x0D || $0 == 0x09 }) { return true }
        return (try? JSONSerialization.jsonObject(with: data)) is [String: Any]
    }

    private static func defaultSettingsPath() -> String {
        defaultSettingsPath(for: .claude)
    }

    private static func defaultHookScriptPath() -> String {
        (NSHomeDirectory() as NSString).appendingPathComponent(".kanban-code/hook.sh")
    }

    private static func defaultStatusLineScriptPath() -> String {
        (NSHomeDirectory() as NSString).appendingPathComponent(".kanban-code/statusline.sh")
    }

    private static func deployStatusLineScript(to path: String) throws {
        let fm = FileManager.default
        let dir = (path as NSString).deletingLastPathComponent
        try fm.createDirectory(atPath: dir, withIntermediateDirectories: true)

        try statusLineScriptContent.write(toFile: path, atomically: true, encoding: .utf8)

        try fm.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: path
        )
    }

    private static let statusLineScriptContent = """
    #!/usr/bin/env bash
    # Kanban Code statusline — captures context/token usage per session.
    # Claude Code sends JSON via stdin after each assistant response.
    # We write a summary to ~/.kanban-code/context/<session_id>.json
    # and output a short status for the terminal.

    set -euo pipefail

    CONTEXT_DIR="${HOME}/.kanban-code/context"
    mkdir -p "$CONTEXT_DIR"

    input=$(cat)

    # Extract session_id
    session_id=$(echo "$input" | grep -oE '"session_id":"[^"]*"' | head -1 | cut -d'"' -f4)
    [ -z "$session_id" ] && exit 0

    # Extract context window fields
    used_pct=$(echo "$input" | grep -oE '"used_percentage":[0-9.]+' | head -1 | cut -d: -f2)
    ctx_size=$(echo "$input" | grep -oE '"context_window_size":[0-9]+' | head -1 | cut -d: -f2)
    input_tokens=$(echo "$input" | grep -oE '"total_input_tokens":[0-9]+' | head -1 | cut -d: -f2)
    output_tokens=$(echo "$input" | grep -oE '"total_output_tokens":[0-9]+' | head -1 | cut -d: -f2)

    # Extract cost and model
    cost=$(echo "$input" | grep -oE '"total_cost_usd":[0-9.]+' | head -1 | cut -d: -f2)
    model=$(echo "$input" | grep -oE '"display_name":"[^"]*"' | head -1 | cut -d'"' -f4)

    # Write context file (atomic via temp + mv)
    tmp_file="${CONTEXT_DIR}/.${session_id}.tmp"
    out_file="${CONTEXT_DIR}/${session_id}.json"
    printf '{"usedPercentage":%s,"contextWindowSize":%s,"totalInputTokens":%s,"totalOutputTokens":%s,"totalCostUsd":%s,"model":"%s"}' \\
        "${used_pct:-0}" "${ctx_size:-0}" "${input_tokens:-0}" "${output_tokens:-0}" "${cost:-0}" "${model:-}" > "$tmp_file"
    mv -f "$tmp_file" "$out_file"

    # Empty output — data is consumed by Kanban Code, not displayed in terminal
    printf ''
    """
}

public enum HookManagerError: LocalizedError {
    case unsupportedAssistant(String)

    public var errorDescription: String? {
        switch self {
        case .unsupportedAssistant(let name):
            "\(name) does not support Kanban hook installation"
        }
    }
}
