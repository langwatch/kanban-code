import Testing
import Foundation
@testable import KanbanCodeCore

@Suite("PermissionHook")
struct PermissionHookTests {
    private func tempDir() throws -> String {
        let dir = NSTemporaryDirectory() + "permission-hook-\(UUID().uuidString.prefix(8))"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Runs the deployed script on a payload and returns its stdout.
    private func run(_ script: String, payload: String) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: script)
        let input = Pipe(), output = Pipe()
        process.standardInput = input
        process.standardOutput = output
        try process.run()
        input.fileHandleForWriting.write(Data(payload.utf8))
        try input.fileHandleForWriting.close()
        process.waitUntilExit()
        #expect(process.terminationStatus == 0)
        return String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    }

    @Test func installsOnceAndKeepsTheRestOfTheSettings() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let settings = dir + "/settings.json"
        try #"{"hooks":{"Stop":[{"matcher":"","hooks":[{"type":"command","command":"x"}]}]},"model":"m"}"#
            .write(toFile: settings, atomically: true, encoding: .utf8)
        let script = dir + "/.kanban-code/permission-hook.sh"
        #expect(try PermissionHook.install(settingsPath: settings, scriptPath: script))
        #expect(try !PermissionHook.install(settingsPath: settings, scriptPath: script))
        let root = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: settings))) as! [String: Any]
        let hooks = root["hooks"] as! [String: Any]
        let groups = hooks["PermissionRequest"] as! [[String: Any]]
        #expect(groups.count == 1)
        #expect(groups[0]["matcher"] as? String == "")
        #expect((groups[0]["hooks"] as! [[String: Any]])[0]["command"] as? String == script)
        #expect(hooks["Stop"] != nil && root["model"] as? String == "m")
    }

    @Test func installsThroughASymlinkedSettingsFile() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let real = dir + "/settings.json"
        try "{}".write(toFile: real, atomically: true, encoding: .utf8)
        let link = dir + "/account-settings.json"
        try FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: real)
        #expect(try PermissionHook.install(settingsPath: link, scriptPath: dir + "/.kanban-code/permission-hook.sh"))
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: link) == real)
        #expect(try String(contentsOfFile: real, encoding: .utf8).contains("permission-hook.sh"))
    }

    @Test func allowsAToolAndLetsQuestionsPlansAndPlanModeThrough() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let script = dir + "/.kanban-code/permission-hook.sh"
        try PermissionHook.install(settingsPath: dir + "/settings.json", scriptPath: script)

        let bash = try run(script, payload: #"{"hook_event_name":"PermissionRequest","permission_mode":"bypassPermissions","tool_name":"Bash","tool_input":{"command":"cd a && rm -rf ../../x/*"}}"#)
        let decision = try JSONSerialization.jsonObject(with: Data(bash.utf8)) as! [String: Any]
        let specific = decision["hookSpecificOutput"] as! [String: Any]
        #expect(specific["hookEventName"] as? String == "PermissionRequest")
        #expect((specific["decision"] as! [String: Any])["behavior"] as? String == "allow")

        // A command that only mentions the question tool is still a command.
        let mention = try run(script, payload: #"{"permission_mode":"default","tool_name":"Bash","tool_input":{"command":"echo AskUserQuestion"}}"#)
        #expect(mention.contains("allow"))

        for payload in [
            #"{"permission_mode":"default","tool_name":"AskUserQuestion","tool_input":{}}"#,
            #"{"permission_mode":"default","tool_name":"ExitPlanMode","tool_input":{}}"#,
            #"{"permission_mode":"plan","tool_name":"Bash","tool_input":{"command":"rm x"}}"#,
        ] {
            #expect(try run(script, payload: payload).isEmpty)
        }
    }
}
