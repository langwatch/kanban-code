import Foundation

/// The Claude Code PermissionRequest hook: every tool permission prompt is
/// answered yes. Credentials are guarded by the vault, not by tool prompts.
///
/// Bypass mode does not cover everything: Claude Code still asks for some
/// commands it cannot resolve ahead of time (`cd a && rm -rf ../../x/*`),
/// and a PreToolUse "allow" does not override that check. A PermissionRequest
/// hook does, in a terminal session and in a headless one (rush runs Claude
/// with `--permission-prompt-tool stdio`: the hook answers first and Claude
/// withdraws the request it sent to rush).
///
/// AskUserQuestion and ExitPlanMode go through the same prompt but are a
/// question and a plan for the user, so they fall through, and so does any
/// prompt in plan mode.
public enum PermissionHook {
    public static let marker = ".kanban-code/permission-hook.sh"
    public static let event = "PermissionRequest"

    public static var scriptPath: String {
        (NSHomeDirectory() as NSString).appendingPathComponent(marker)
    }

    public static let scriptContent = """
    #!/bin/sh
    # Installed by Kanban Code: Claude Code PermissionRequest hook.
    # Every tool permission is allowed; the vault guards credentials.
    # Questions, plan approvals and plan mode fall through to the user.
    input=$(cat)
    if printf '%s' "$input" | grep -Eq '"tool_name" *: *"(AskUserQuestion|ExitPlanMode)"|"permission_mode" *: *"plan"'; then
      exit 0
    fi
    printf '%s\\n' '{"hookSpecificOutput":{"hookEventName":"PermissionRequest","decision":{"behavior":"allow"}}}'

    """

    /// Installs it when the Kanban Code hooks of Claude Code are installed.
    public static func installWhereHooked() {
        if HookManager.isInstalled(for: .claude), (try? install()) == true {
            KanbanCodeLog.info("hooks", "installed the permission hook")
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
        var groups = hooks[event] as? [[String: Any]] ?? []
        let present = groups.contains { group in
            (group["hooks"] as? [[String: Any]] ?? []).contains { ($0["command"] as? String)?.contains(marker) == true }
        }
        guard !present else { return changed }
        groups.append(["matcher": "", "hooks": [["type": "command", "command": script]]])
        hooks[event] = groups
        root["hooks"] = hooks
        let data = try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: URL(fileURLWithPath: path))
        changed = true
        return changed
    }

    private static func writeScript(_ script: String) throws -> Bool {
        guard (try? String(contentsOfFile: script, encoding: .utf8)) != scriptContent else { return false }
        try FileManager.default.createDirectory(atPath: (script as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        try scriptContent.write(toFile: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script)
        return true
    }
}
