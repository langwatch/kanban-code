import Testing
import Foundation
@testable import KanbanCodeCore

@Suite("HookManager")
struct HookManagerTests {
    func makeTempDir() throws -> String {
        let dir = NSTemporaryDirectory() + "kanban-code-hooks-test-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        return dir
    }

    func cleanup(_ dir: String) {
        try? FileManager.default.removeItem(atPath: dir)
    }

    @Test("Install hooks into empty settings")
    func installEmpty() throws {
        let dir = try makeTempDir()
        defer { cleanup(dir) }

        let settingsPath = (dir as NSString).appendingPathComponent("settings.json")
        let scriptPath = (dir as NSString).appendingPathComponent(".kanban-code/hook.sh")
        try "{}".write(toFile: settingsPath, atomically: true, encoding: .utf8)

        try HookManager.install(claudeSettingsPath: settingsPath, hookScriptPath: scriptPath)

        let installed = HookManager.isInstalled(claudeSettingsPath: settingsPath)
        #expect(installed)

        // Verify all hook events are present
        let data = try Data(contentsOf: URL(fileURLWithPath: settingsPath))
        let root = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        let hooks = root["hooks"] as! [String: Any]
        #expect(hooks["Stop"] != nil)
        #expect(hooks["Notification"] != nil)
        #expect(hooks["UserPromptSubmit"] != nil)
        #expect(hooks["SessionStart"] != nil)
        #expect(hooks["SessionEnd"] != nil)

        // Verify nested format: [{matcher: "", hooks: [{type, command}]}]
        let stopGroups = hooks["Stop"] as! [[String: Any]]
        #expect(stopGroups.count == 1)
        let entries = stopGroups[0]["hooks"] as! [[String: Any]]
        #expect(entries.count == 1)
        #expect((entries[0]["command"] as! String).contains(".kanban-code/hook.sh"))

        // Verify hook script was deployed
        #expect(FileManager.default.fileExists(atPath: scriptPath))
        #expect(FileManager.default.isExecutableFile(atPath: scriptPath))
    }

    @Test("Install preserves existing hooks in nested format")
    func installPreservesExisting() throws {
        let dir = try makeTempDir()
        defer { cleanup(dir) }

        let settingsPath = (dir as NSString).appendingPathComponent("settings.json")
        let scriptPath = (dir as NSString).appendingPathComponent(".kanban-code/hook.sh")
        let existing = """
        {
            "hooks": {
                "Stop": [
                    {
                        "matcher": "",
                        "hooks": [
                            {"type": "command", "command": "/usr/local/bin/other-hook.sh"}
                        ]
                    }
                ]
            }
        }
        """
        try existing.write(toFile: settingsPath, atomically: true, encoding: .utf8)

        try HookManager.install(claudeSettingsPath: settingsPath, hookScriptPath: scriptPath)

        let data = try Data(contentsOf: URL(fileURLWithPath: settingsPath))
        let root = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        let hooks = root["hooks"] as! [String: Any]
        let stopGroups = hooks["Stop"] as! [[String: Any]]

        // Should have one group with both hooks
        #expect(stopGroups.count == 1)
        let entries = stopGroups[0]["hooks"] as! [[String: Any]]
        #expect(entries.count == 2)
    }

    @Test("Install is idempotent")
    func installIdempotent() throws {
        let dir = try makeTempDir()
        defer { cleanup(dir) }

        let settingsPath = (dir as NSString).appendingPathComponent("settings.json")
        let scriptPath = (dir as NSString).appendingPathComponent(".kanban-code/hook.sh")
        try "{}".write(toFile: settingsPath, atomically: true, encoding: .utf8)

        try HookManager.install(claudeSettingsPath: settingsPath, hookScriptPath: scriptPath)
        try HookManager.install(claudeSettingsPath: settingsPath, hookScriptPath: scriptPath)

        let data = try Data(contentsOf: URL(fileURLWithPath: settingsPath))
        let root = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        let hooks = root["hooks"] as! [String: Any]
        let stopGroups = hooks["Stop"] as! [[String: Any]]
        let entries = stopGroups[0]["hooks"] as! [[String: Any]]

        // Should NOT have duplicates
        #expect(entries.count == 1)
    }

    @Test("Uninstall removes only kanban hooks")
    func uninstall() throws {
        let dir = try makeTempDir()
        defer { cleanup(dir) }

        let settingsPath = (dir as NSString).appendingPathComponent("settings.json")
        let existing = """
        {
            "hooks": {
                "Stop": [
                    {
                        "matcher": "",
                        "hooks": [
                            {"type": "command", "command": "/usr/local/bin/other-hook.sh"},
                            {"type": "command", "command": "/home/user/.kanban-code/hook.sh"}
                        ]
                    }
                ]
            }
        }
        """
        try existing.write(toFile: settingsPath, atomically: true, encoding: .utf8)

        try HookManager.uninstall(claudeSettingsPath: settingsPath)

        let data = try Data(contentsOf: URL(fileURLWithPath: settingsPath))
        let root = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        let hooks = root["hooks"] as! [String: Any]
        let stopGroups = hooks["Stop"] as! [[String: Any]]
        let entries = stopGroups[0]["hooks"] as! [[String: Any]]

        #expect(entries.count == 1)
        #expect((entries[0]["command"] as! String).contains("other-hook"))
    }

    @Test("isInstalled returns false for missing hooks")
    func notInstalled() {
        let installed = HookManager.isInstalled(claudeSettingsPath: "/nonexistent/path")
        #expect(!installed)
    }

    @Test("Install creates settings file if missing")
    func installCreatesFile() throws {
        let dir = try makeTempDir()
        defer { cleanup(dir) }

        let settingsPath = (dir as NSString).appendingPathComponent("subdir/settings.json")
        let scriptPath = (dir as NSString).appendingPathComponent(".kanban-code/hook.sh")
        try HookManager.install(claudeSettingsPath: settingsPath, hookScriptPath: scriptPath)

        #expect(FileManager.default.fileExists(atPath: settingsPath))
        let installed = HookManager.isInstalled(claudeSettingsPath: settingsPath)
        #expect(installed)
    }

    @Test("Install deploys executable hook script")
    func installDeploysScript() throws {
        let dir = try makeTempDir()
        defer { cleanup(dir) }

        let settingsPath = (dir as NSString).appendingPathComponent("settings.json")
        let scriptPath = (dir as NSString).appendingPathComponent(".kanban-code/hook.sh")
        try "{}".write(toFile: settingsPath, atomically: true, encoding: .utf8)

        try HookManager.install(claudeSettingsPath: settingsPath, hookScriptPath: scriptPath)

        // Script should exist and be executable
        #expect(FileManager.default.fileExists(atPath: scriptPath))
        #expect(FileManager.default.isExecutableFile(atPath: scriptPath))

        // Script should contain the shebang and event writing logic
        let content = try String(contentsOfFile: scriptPath, encoding: .utf8)
        #expect(content.contains("#!/usr/bin/env bash"))
        #expect(content.contains("hook-events.jsonl"))
        #expect(content.contains("session_id"))
    }

    // MARK: - Multi-Assistant Support

    @Test("Install for Gemini uses correct event names")
    func installGemini() throws {
        let dir = try makeTempDir()
        defer { cleanup(dir) }

        let settingsPath = (dir as NSString).appendingPathComponent("settings.json")
        let scriptPath = (dir as NSString).appendingPathComponent(".kanban-code/hook.sh")
        try "{}".write(toFile: settingsPath, atomically: true, encoding: .utf8)

        try HookManager.install(for: .gemini, settingsPath: settingsPath, hookScriptPath: scriptPath)

        let installed = HookManager.isInstalled(for: .gemini, settingsPath: settingsPath)
        #expect(installed)

        let data = try Data(contentsOf: URL(fileURLWithPath: settingsPath))
        let root = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        let hooks = root["hooks"] as! [String: Any]

        // Gemini uses different event names
        #expect(hooks["AfterAgent"] != nil)
        #expect(hooks["BeforeAgent"] != nil)
        #expect(hooks["Notification"] != nil)
        #expect(hooks["SessionStart"] != nil)
        #expect(hooks["SessionEnd"] != nil)

        // Should NOT have Claude-specific events
        #expect(hooks["Stop"] == nil)
        #expect(hooks["UserPromptSubmit"] == nil)
    }

    @Test("isInstalled for Gemini checks Gemini event names")
    func isInstalledGemini() throws {
        let dir = try makeTempDir()
        defer { cleanup(dir) }

        let settingsPath = (dir as NSString).appendingPathComponent("settings.json")
        let scriptPath = (dir as NSString).appendingPathComponent(".kanban-code/hook.sh")
        try "{}".write(toFile: settingsPath, atomically: true, encoding: .utf8)

        // Install Claude hooks
        try HookManager.install(for: .claude, settingsPath: settingsPath, hookScriptPath: scriptPath)

        // Claude hooks installed but Gemini hooks are not
        #expect(HookManager.isInstalled(for: .claude, settingsPath: settingsPath))
        #expect(!HookManager.isInstalled(for: .gemini, settingsPath: settingsPath))
    }

    @Test("Uninstall for Gemini removes hooks from its own settings file")
    func uninstallGemini() throws {
        let dir = try makeTempDir()
        defer { cleanup(dir) }

        // Claude and Gemini use separate settings files in practice
        let claudeSettings = (dir as NSString).appendingPathComponent("claude-settings.json")
        let geminiSettings = (dir as NSString).appendingPathComponent("gemini-settings.json")
        let scriptPath = (dir as NSString).appendingPathComponent(".kanban-code/hook.sh")
        try "{}".write(toFile: claudeSettings, atomically: true, encoding: .utf8)
        try "{}".write(toFile: geminiSettings, atomically: true, encoding: .utf8)

        try HookManager.install(for: .claude, settingsPath: claudeSettings, hookScriptPath: scriptPath)
        try HookManager.install(for: .gemini, settingsPath: geminiSettings, hookScriptPath: scriptPath)

        #expect(HookManager.isInstalled(for: .claude, settingsPath: claudeSettings))
        #expect(HookManager.isInstalled(for: .gemini, settingsPath: geminiSettings))

        // Uninstall Gemini
        try HookManager.uninstall(for: .gemini, settingsPath: geminiSettings)

        // Claude unaffected, Gemini removed
        #expect(HookManager.isInstalled(for: .claude, settingsPath: claudeSettings))
        #expect(!HookManager.isInstalled(for: .gemini, settingsPath: geminiSettings))
    }

    @Test("normalizeEventName maps Gemini events to canonical names")
    func normalizeEventName() {
        #expect(HookManager.normalizeEventName("AfterAgent") == "Stop")
        #expect(HookManager.normalizeEventName("BeforeAgent") == "UserPromptSubmit")
        #expect(HookManager.normalizeEventName("SessionStart") == "SessionStart")
        #expect(HookManager.normalizeEventName("SessionEnd") == "SessionEnd")
        #expect(HookManager.normalizeEventName("Notification") == "Notification")
        #expect(HookManager.normalizeEventName("Stop") == "Stop")
    }

    @Test("requiredHooks returns correct events per assistant")
    func requiredHooksPerAssistant() {
        let claude = HookManager.requiredHooks(for: .claude)
        #expect(claude.contains("Stop"))
        #expect(claude.contains("UserPromptSubmit"))
        #expect(!claude.contains("AfterAgent"))

        let gemini = HookManager.requiredHooks(for: .gemini)
        #expect(gemini.contains("AfterAgent"))
        #expect(gemini.contains("BeforeAgent"))
        #expect(!gemini.contains("Stop"))
        #expect(!gemini.contains("UserPromptSubmit"))
    }
}
