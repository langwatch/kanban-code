import Foundation

/// What a Claude config folder needs from Kanban Code: its hooks (the board
/// follows sessions by them), the vault and permission hooks, the status
/// line and the kanban-code skill. Run at start and whenever the folders
/// change (an account added in Settings), so a new account works without a
/// restart.
public enum ClaudeAccountsSetup {
    /// One run at a time: two would read and write the same settings files.
    private static let lock = NSLock()

    /// `installingHooks`: install the hooks into every folder that lacks
    /// them (the headless server, which always runs with hooks). Otherwise
    /// only where the user already opted in once (`addMissingHooks`).
    /// Folders other than `~/.claude` keep a status line of their own.
    /// Runs `body`, which writes Claude settings files, one at a time with
    /// `refresh` and every other caller.
    public static func serialized<T>(_ body: () throws -> T) rethrows -> T {
        try lock.withLock(body)
    }

    public static func refresh(installingHooks: Bool = false) {
        lock.lock()
        defer { lock.unlock() }
        let layout = ClaudeConfigDirectories.current
        let paths = HookManager.claudeSettingsPaths(layout: layout).filter {
            FileManager.default.fileExists(atPath: ($0 as NSString).deletingLastPathComponent)
        }
        if installingHooks {
            for path in paths where !HookManager.isInstalled(for: .claude, settingsPath: path) {
                guard HookManager.isRewritable(path) else { continue }
                do {
                    try HookManager.install(
                        for: .claude, settingsPaths: [path],
                        replacingOwnStatusLine: path == layout.standard + "/settings.json")
                    KanbanCodeLog.info("hooks", "installed Claude Code hooks in \(path)")
                } catch {
                    KanbanCodeLog.warn("hooks", "could not install Claude Code hooks in \(path): \(error)")
                }
            }
        } else if HookManager.addMissingHooks(for: .claude) {
            KanbanCodeLog.info("hooks", "added missing Claude Code hooks")
        }
        VaultHook.installWhereHooked()
        PermissionHook.installWhereHooked()
        ChatBootstrap.ensureSkillSymlink(layout: layout)
    }
}
