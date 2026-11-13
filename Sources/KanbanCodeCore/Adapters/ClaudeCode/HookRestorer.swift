import Foundation

/// Puts back the Kanban Code entries of an assistant's settings when
/// something else rewrote the file without them (a test, a tool, a sync of
/// a broken copy), for a machine whose user opted into the hooks.
///
/// Only the missing Kanban entries are added: other keys and other hooks
/// stay as they are, and a file that already has every entry is not
/// written, so two machines mirroring one settings file settle after one
/// write each.
public enum HookRestorer {

    /// `~/.kanban-code`, where the hook scripts and the opt-in record live.
    public static var defaultKanbanHome: String {
        (NSHomeDirectory() as NSString).appendingPathComponent(".kanban-code")
    }

    static func optInPath(kanbanHome: String) -> String {
        (kanbanHome as NSString).appendingPathComponent("hooks-opt-in.json")
    }

    // MARK: - Opt-in

    /// The recorded choice per assistant, nil when none was recorded.
    public static func recordedOptIn(for assistant: CodingAssistant, kanbanHome: String = defaultKanbanHome) -> Bool? {
        readOptIns(kanbanHome: kanbanHome)[assistant.rawValue]
    }

    /// Records that the user installed (true) or removed (false) the hooks.
    public static func setOptedIn(_ optedIn: Bool, for assistant: CodingAssistant, kanbanHome: String = defaultKanbanHome) {
        var all = readOptIns(kanbanHome: kanbanHome)
        guard all[assistant.rawValue] != optedIn else { return }
        all[assistant.rawValue] = optedIn
        guard let data = try? JSONSerialization.data(withJSONObject: all, options: [.prettyPrinted, .sortedKeys]) else { return }
        try? FileManager.default.createDirectory(atPath: kanbanHome, withIntermediateDirectories: true)
        try? data.write(to: URL(fileURLWithPath: optInPath(kanbanHome: kanbanHome)), options: .atomic)
    }

    /// Whether the hooks of this assistant are kept in place. Without a
    /// recorded choice, a machine whose settings call the hook script, or
    /// (for Claude Code) that has the deployed hook script, installed them
    /// before the choice was recorded; that is recorded now.
    public static func isOptedIn(
        for assistant: CodingAssistant,
        settingsPath: String? = nil,
        kanbanHome: String = defaultKanbanHome
    ) -> Bool {
        guard assistant.supportsHooks else { return false }
        if let recorded = recordedOptIn(for: assistant, kanbanHome: kanbanHome) { return recorded }
        let path = settingsPath ?? HookManager.defaultSettingsPath(for: assistant)
        var inferred = !missingHookEvents(for: assistant, root: readRoot(path) ?? [:])
            .elementsEqual(HookManager.requiredHooks(for: assistant))
        if !inferred, assistant == .claude {
            inferred = FileManager.default.fileExists(atPath: hookScript(kanbanHome))
        }
        if inferred { setOptedIn(true, for: assistant, kanbanHome: kanbanHome) }
        return inferred
    }

    // MARK: - Restore

    /// Adds the missing Kanban entries for an opted-in assistant and
    /// returns their names (empty when nothing was missing or written).
    /// A settings folder that does not exist or a file that does not parse
    /// is left alone.
    @discardableResult
    public static func restoreMissing(
        for assistant: CodingAssistant,
        settingsPath: String? = nil,
        kanbanHome: String = defaultKanbanHome
    ) -> [String] {
        guard isOptedIn(for: assistant, settingsPath: settingsPath, kanbanHome: kanbanHome) else { return [] }
        let path = settingsPath ?? HookManager.defaultSettingsPath(for: assistant)
        let dir = (path as NSString).deletingLastPathComponent
        guard FileManager.default.fileExists(atPath: dir) else { return [] }
        let original = FileManager.default.contents(atPath: path)
        var root: [String: Any] = [:]
        if let original {
            guard let parsed = (try? JSONSerialization.jsonObject(with: original)) as? [String: Any] else { return [] }
            root = parsed
        }

        let restored = merge(into: &root, for: assistant, kanbanHome: kanbanHome)
        ensureScripts(for: assistant, kanbanHome: kanbanHome)
        guard !restored.isEmpty else { return [] }
        // The file changed under us (Claude Code saving its own settings):
        // the next pass sees the new content.
        guard FileManager.default.contents(atPath: path) == original,
              let data = try? JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys]),
              (try? writeSettings(data, to: path)) != nil
        else { return [] }
        return restored
    }

    /// Adds the missing entries to a parsed settings root and returns
    /// their names.
    static func merge(into root: inout [String: Any], for assistant: CodingAssistant, kanbanHome: String) -> [String] {
        var hooks = root["hooks"] as? [String: Any] ?? [:]
        var restored: [String] = []

        for event in missingHookEvents(for: assistant, root: root) {
            append(["matcher": "", "hooks": [["type": "command", "command": hookScript(kanbanHome)]]],
                   to: event, in: &hooks)
            restored.append(event)
        }
        if assistant == .claude {
            let vault = (kanbanHome as NSString).appendingPathComponent("vault-hook.sh")
            if !has(marker: VaultHook.marker, event: "PreToolUse", in: hooks) {
                append(["matcher": "Bash", "hooks": [["type": "command", "command": vault, "timeout": 900]]],
                       to: "PreToolUse", in: &hooks)
                restored.append("PreToolUse vault hook")
            }
            let permission = (kanbanHome as NSString).appendingPathComponent("permission-hook.sh")
            if !has(marker: PermissionHook.marker, event: PermissionHook.event, in: hooks) {
                append(["matcher": "", "hooks": [["type": "command", "command": permission]]],
                       to: PermissionHook.event, in: &hooks)
                restored.append("\(PermissionHook.event) permission hook")
            }
        }
        if !restored.isEmpty { root["hooks"] = hooks }
        // A statusline of the user's own is theirs: only an empty slot is filled.
        if assistant == .claude, root["statusLine"] == nil {
            root["statusLine"] = ["type": "command", "command": statusLineScript(kanbanHome)] as [String: Any]
            restored.append("statusLine")
        }
        return restored
    }

    /// The events of this assistant whose settings do not call the hook script.
    static func missingHookEvents(for assistant: CodingAssistant, root: [String: Any]) -> [String] {
        let hooks = root["hooks"] as? [String: Any] ?? [:]
        return HookManager.requiredHooks(for: assistant).filter {
            !has(marker: ".kanban-code/hook.sh", event: $0, in: hooks)
        }
    }

    private static func has(marker: String, event: String, in hooks: [String: Any]) -> Bool {
        (hooks[event] as? [[String: Any]] ?? []).contains { group in
            (group["hooks"] as? [[String: Any]] ?? []).contains { ($0["command"] as? String)?.contains(marker) == true }
        }
    }

    private static func append(_ group: [String: Any], to event: String, in hooks: inout [String: Any]) {
        var groups = hooks[event] as? [[String: Any]] ?? []
        groups.append(group)
        hooks[event] = groups
    }

    /// The scripts the entries call, written when missing.
    private static func ensureScripts(for assistant: CodingAssistant, kanbanHome: String) {
        let fm = FileManager.default
        if !fm.fileExists(atPath: hookScript(kanbanHome)) {
            try? HookManager.deployHookScript(to: hookScript(kanbanHome))
        }
        guard assistant == .claude else { return }
        if !fm.fileExists(atPath: statusLineScript(kanbanHome)) {
            try? HookManager.deployStatusLineScript(to: statusLineScript(kanbanHome))
        }
        _ = try? VaultHook.writeScript((kanbanHome as NSString).appendingPathComponent("vault-hook.sh"))
        _ = try? PermissionHook.writeScript((kanbanHome as NSString).appendingPathComponent("permission-hook.sh"))
    }

    private static func hookScript(_ kanbanHome: String) -> String {
        (kanbanHome as NSString).appendingPathComponent("hook.sh")
    }

    private static func statusLineScript(_ kanbanHome: String) -> String {
        (kanbanHome as NSString).appendingPathComponent("statusline.sh")
    }

    private static func readRoot(_ path: String) -> [String: Any]? {
        guard let data = FileManager.default.contents(atPath: path) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    private static func readOptIns(kanbanHome: String) -> [String: Bool] {
        guard let data = FileManager.default.contents(atPath: optInPath(kanbanHome: kanbanHome)),
              let parsed = (try? JSONSerialization.jsonObject(with: data)) as? [String: Bool]
        else { return [:] }
        return parsed
    }

    /// Writes a settings file in one rename, through a symlink to its
    /// target, so a reader (Claude Code, the sync) never sees half a file.
    public static func writeSettings(_ data: Data, to path: String) throws {
        let target = URL(fileURLWithPath: path).resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: target, options: .atomic)
    }
}
