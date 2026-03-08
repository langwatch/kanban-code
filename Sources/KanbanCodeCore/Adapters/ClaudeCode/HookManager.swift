import Foundation

/// Manages hook installation for coding assistants (Claude Code, Gemini CLI).
///
/// Both Claude Code and Gemini CLI use the same hook configuration format:
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
            ["Stop", "Notification", "SessionStart", "SessionEnd", "UserPromptSubmit"]
        case .gemini:
            ["AfterAgent", "Notification", "SessionStart", "SessionEnd", "BeforeAgent"]
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

    /// Check if hooks are already installed for the given assistant.
    public static func isInstalled(for assistant: CodingAssistant, settingsPath: String? = nil) -> Bool {
        let path = settingsPath ?? defaultSettingsPath(for: assistant)
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

    // MARK: - Install

    /// Install hooks for the given assistant.
    public static func install(
        for assistant: CodingAssistant,
        settingsPath: String? = nil,
        hookScriptPath: String? = nil
    ) throws {
        let resolvedSettingsPath = settingsPath ?? defaultSettingsPath(for: assistant)
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
    }

    /// Backward-compatible: install Claude hooks only.
    public static func install(
        claudeSettingsPath: String? = nil,
        hookScriptPath: String? = nil
    ) throws {
        try install(for: .claude, settingsPath: claudeSettingsPath, hookScriptPath: hookScriptPath)
    }

    // MARK: - Uninstall

    /// Remove Kanban hooks from the given assistant's settings.
    public static func uninstall(for assistant: CodingAssistant, settingsPath: String? = nil) throws {
        let resolvedSettingsPath = settingsPath ?? defaultSettingsPath(for: assistant)

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

    # Append event line
    printf '{"sessionId":"%s","event":"%s","timestamp":"%s","transcriptPath":"%s"}\\n' \\
        "$session_id" "$hook_event" "$timestamp" "$transcript" >> "$EVENTS_FILE"
    """

    /// Settings file path per assistant.
    public static func defaultSettingsPath(for assistant: CodingAssistant) -> String {
        (NSHomeDirectory() as NSString).appendingPathComponent("\(assistant.configDirName)/settings.json")
    }

    private static func defaultSettingsPath() -> String {
        defaultSettingsPath(for: .claude)
    }

    private static func defaultHookScriptPath() -> String {
        (NSHomeDirectory() as NSString).appendingPathComponent(".kanban-code/hook.sh")
    }
}
