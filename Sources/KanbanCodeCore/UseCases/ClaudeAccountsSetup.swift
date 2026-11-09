import Foundation

/// What a Claude config folder needs from Kanban Code: its hooks (the board
/// follows sessions by them), the vault and permission hooks, the status
/// line and the kanban-code skill. Run at start and whenever the folders
/// change (an account added in Settings), so a new account works without a
/// restart.
public enum ClaudeAccountsSetup {
    /// `installingHooks`: install the hooks into every folder that lacks
    /// them (the headless server, which always runs with hooks). Otherwise
    /// only where the user already opted in once (`addMissingHooks`).
    public static func refresh(installingHooks: Bool = false) {
        let paths = HookManager.claudeSettingsPaths().filter {
            FileManager.default.fileExists(atPath: ($0 as NSString).deletingLastPathComponent)
        }
        if installingHooks {
            for path in paths where !HookManager.isInstalled(for: .claude, settingsPath: path) {
                guard HookManager.isRewritable(path) else { continue }
                do {
                    try HookManager.install(for: .claude, settingsPath: path)
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
        ChatBootstrap.ensureSkillSymlink()
    }
}
