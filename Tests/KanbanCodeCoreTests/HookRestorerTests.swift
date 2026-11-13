import Testing
import Foundation
@testable import KanbanCodeCore

@Suite("HookRestorer")
struct HookRestorerTests {
    private func tempDir() throws -> String {
        let dir = NSTemporaryDirectory() + "hook-restorer-\(UUID().uuidString.prefix(8))"
        try FileManager.default.createDirectory(atPath: dir + "/.claude", withIntermediateDirectories: true)
        return dir
    }

    private func read(_ path: String) throws -> [String: Any] {
        try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: path))) as! [String: Any]
    }

    private func commands(_ root: [String: Any], _ event: String) -> [String] {
        let groups = (root["hooks"] as? [String: Any])?[event] as? [[String: Any]] ?? []
        return groups.flatMap { ($0["hooks"] as? [[String: Any]] ?? []).compactMap { $0["command"] as? String } }
    }

    /// The settings another program wrote over the installed ones.
    private let overwritten = #"""
    {"env":{"A":"1"},"model":"opus","hooks":{"SessionStart":[{"matcher":"","hooks":[{"type":"command","command":"./scripts/session-log.sh"}]}]}}
    """#

    @Test func restoresTheMissingEntriesAndKeepsTheRest() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let home = dir + "/.kanban-code", settings = dir + "/.claude/settings.json"
        try "{}".write(toFile: settings, atomically: true, encoding: .utf8)
        try HookManager.install(for: .claude, settingsPath: settings, hookScriptPath: home + "/hook.sh")
        #expect(HookRestorer.recordedOptIn(for: .claude, kanbanHome: home) == true)

        try overwritten.write(toFile: settings, atomically: true, encoding: .utf8)
        let restored = HookRestorer.restoreMissing(for: .claude, settingsPath: settings, kanbanHome: home)

        #expect(Set(restored) == Set(HookManager.requiredHooks(for: .claude) + [
            "PreToolUse vault hook", "PermissionRequest permission hook", "statusLine",
        ]))
        #expect(HookManager.isInstalled(for: .claude, settingsPath: settings))
        let root = try read(settings)
        #expect(root["model"] as? String == "opus")
        #expect((root["env"] as? [String: String]) == ["A": "1"])
        #expect(commands(root, "SessionStart") == ["./scripts/session-log.sh", home + "/hook.sh"])
        #expect(commands(root, "PreToolUse") == [home + "/vault-hook.sh"])
        #expect(commands(root, "PermissionRequest") == [home + "/permission-hook.sh"])
        #expect((root["statusLine"] as? [String: Any])?["command"] as? String == home + "/statusline.sh")
        for script in ["hook.sh", "vault-hook.sh", "permission-hook.sh", "statusline.sh"] {
            #expect(FileManager.default.isExecutableFile(atPath: home + "/" + script))
        }
    }

    @Test func addsOnlyWhatIsMissingAndLeavesAUserStatusLine() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let home = dir + "/.kanban-code", settings = dir + "/.claude/settings.json"
        HookRestorer.setOptedIn(true, for: .claude, kanbanHome: home)
        try #"""
        {"statusLine":{"type":"command","command":"mine.sh"},"hooks":{
          "Stop":[{"matcher":"","hooks":[{"type":"command","command":"/Users/x/.kanban-code/hook.sh"}]}],
          "PreToolUse":[{"matcher":"Bash","hooks":[{"type":"command","command":"/Users/x/.kanban-code/vault-hook.sh"}]},
                        {"matcher":"Edit","hooks":[{"type":"command","command":"lint.sh"}]}]}}
        """#.write(toFile: settings, atomically: true, encoding: .utf8)

        let restored = HookRestorer.restoreMissing(for: .claude, settingsPath: settings, kanbanHome: home)

        #expect(!restored.contains("Stop") && !restored.contains("PreToolUse vault hook") && !restored.contains("statusLine"))
        #expect(restored.contains("Notification") && restored.contains("PermissionRequest permission hook"))
        let root = try read(settings)
        #expect(commands(root, "Stop") == ["/Users/x/.kanban-code/hook.sh"])
        #expect(commands(root, "PreToolUse") == ["/Users/x/.kanban-code/vault-hook.sh", "lint.sh"])
        #expect((root["statusLine"] as? [String: Any])?["command"] as? String == "mine.sh")
    }

    @Test func writesNothingWhenNothingIsMissing() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let home = dir + "/.kanban-code", settings = dir + "/.claude/settings.json"
        try overwritten.write(toFile: settings, atomically: true, encoding: .utf8)
        HookRestorer.setOptedIn(true, for: .claude, kanbanHome: home)
        #expect(!HookRestorer.restoreMissing(for: .claude, settingsPath: settings, kanbanHome: home).isEmpty)

        let before = try Data(contentsOf: URL(fileURLWithPath: settings))
        let modified = try FileManager.default.attributesOfItem(atPath: settings)[.modificationDate] as? Date
        let inode = try FileManager.default.attributesOfItem(atPath: settings)[.systemFileNumber] as? Int
        #expect(HookRestorer.restoreMissing(for: .claude, settingsPath: settings, kanbanHome: home).isEmpty)
        #expect(try Data(contentsOf: URL(fileURLWithPath: settings)) == before)
        #expect(try FileManager.default.attributesOfItem(atPath: settings)[.modificationDate] as? Date == modified)
        #expect(try FileManager.default.attributesOfItem(atPath: settings)[.systemFileNumber] as? Int == inode)
    }

    @Test func uninstallStopsTheRestore() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let home = dir + "/.kanban-code", settings = dir + "/.claude/settings.json"
        try HookManager.install(for: .claude, settingsPath: settings, hookScriptPath: home + "/hook.sh")
        try HookManager.uninstall(for: .claude, settingsPath: settings, kanbanHome: home)
        #expect(HookRestorer.recordedOptIn(for: .claude, kanbanHome: home) == false)
        #expect(!HookManager.isInstalled(for: .claude, settingsPath: settings))

        let before = try String(contentsOfFile: settings, encoding: .utf8)
        #expect(HookRestorer.restoreMissing(for: .claude, settingsPath: settings, kanbanHome: home).isEmpty)
        #expect(try String(contentsOfFile: settings, encoding: .utf8) == before)
    }

    @Test func aMachineThatNeverInstalledIsLeftAlone() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let home = dir + "/.kanban-code", settings = dir + "/.claude/settings.json"
        try overwritten.write(toFile: settings, atomically: true, encoding: .utf8)
        #expect(HookRestorer.restoreMissing(for: .claude, settingsPath: settings, kanbanHome: home).isEmpty)
        #expect(HookRestorer.recordedOptIn(for: .claude, kanbanHome: home) == nil)
        #expect(try String(contentsOfFile: settings, encoding: .utf8) == overwritten)
    }

    @Test func aDeployedHookScriptCountsAsAnEarlierInstall() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let home = dir + "/.kanban-code", settings = dir + "/.claude/settings.json"
        try HookManager.deployHookScript(to: home + "/hook.sh")
        try overwritten.write(toFile: settings, atomically: true, encoding: .utf8)
        #expect(!HookRestorer.restoreMissing(for: .claude, settingsPath: settings, kanbanHome: home).isEmpty)
        #expect(HookRestorer.recordedOptIn(for: .claude, kanbanHome: home) == true)
        #expect(HookManager.isInstalled(for: .claude, settingsPath: settings))
    }

    @Test func leavesAFileThatDoesNotParse() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let home = dir + "/.kanban-code", settings = dir + "/.claude/settings.json"
        HookRestorer.setOptedIn(true, for: .claude, kanbanHome: home)
        try #"{"hooks": {"#.write(toFile: settings, atomically: true, encoding: .utf8)
        #expect(HookRestorer.restoreMissing(for: .claude, settingsPath: settings, kanbanHome: home).isEmpty)
        #expect(try String(contentsOfFile: settings, encoding: .utf8) == #"{"hooks": {"#)
        #expect(throws: HookManagerError.self) {
            try HookManager.install(for: .claude, settingsPath: settings, hookScriptPath: home + "/hook.sh")
        }
    }

    @Test func restoresThroughASymlinkedSettingsFile() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let home = dir + "/.kanban-code", real = dir + "/real-settings.json", link = dir + "/.claude/settings.json"
        try overwritten.write(toFile: real, atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: real)
        HookRestorer.setOptedIn(true, for: .claude, kanbanHome: home)
        #expect(!HookRestorer.restoreMissing(for: .claude, settingsPath: link, kanbanHome: home).isEmpty)
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: link) == real)
        #expect(HookManager.isInstalled(for: .claude, settingsPath: real))
    }
}
