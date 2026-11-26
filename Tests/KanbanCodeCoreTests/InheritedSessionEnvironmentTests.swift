import Foundation
import Testing
@testable import KanbanCodeCore

@Suite("Environment inherited from an agent session")
struct InheritedSessionEnvironmentTests {
    @Test("An app launched from a rush session's shell drops what that session set")
    func dropsSessionMarkers() {
        let env = [
            "RUSH_SESSION": "8c76706f",
            "CLAUDECODE": "1",
            "CLAUDE_CODE_SESSION_ID": "8c76706f-1c00",
            "CLAUDE_PID": "2024",
            "KANBAN_CARD_ID": "card_x",
            "TMPDIR": "/Users/me/.config/rush/sessions/8c76706f/tmp",
            "HOME": "/Users/me",
            "PATH": "/usr/bin",
            "CLAUDE_CODE_ENABLE_TELEMETRY": "1",
        ]
        #expect(InheritedSessionEnvironment.inherited(in: env) == [
            "CLAUDECODE", "CLAUDE_CODE_SESSION_ID", "CLAUDE_PID", "KANBAN_CARD_ID", "RUSH_SESSION", "TMPDIR",
        ])
    }

    @Test("A TMPDIR of the user's own stays")
    func keepsOwnTmpdir() {
        #expect(InheritedSessionEnvironment.inherited(in: ["TMPDIR": "/var/folders/ab/T/", "HOME": "/Users/me"]).isEmpty)
    }

    @Test("A tmux server started from an agent's shell stops passing that agent on to new panes")
    func tmuxServerDropsInheritedVariables() async throws {
        guard let tmux = ShellCommand.findExecutable("tmux") else { return }
        let socket = "kanban-inherited-\(UUID().uuidString.prefix(8))"
        let out = FileManager.default.temporaryDirectory.appendingPathComponent("\(socket).env").path
        // ShellCommand rather than Process: on Linux, Foundation's
        // waitUntilExit can miss the child's exit and hang the whole run.
        func run(_ args: [String], env: [String: String] = ProcessInfo.processInfo.environment) async throws {
            _ = try await ShellCommand.run(tmux, arguments: ["-L", socket, "-f", "/dev/null"] + args, environment: env, timeout: 20)
        }
        func cleanUp() async {
            try? await run(["kill-server"])
            try? FileManager.default.removeItem(atPath: out)
        }
        var agent = ProcessInfo.processInfo.environment
        agent["KANBAN_CARD_ID"] = "card_agent"
        agent["CLAUDE_CODE_SESSION_ID"] = "agent-session"
        agent["TMPDIR"] = "/Users/me/.config/rush/sessions/8c76706f/tmp"
        let env: String
        do {
            try await run(["new-session", "-d", "-s", "first"], env: agent)
            try await run(InheritedSessionEnvironment.tmuxUnsetArguments(serverTMPDIR: agent["TMPDIR"]))
            try await run(["new-session", "-d", "-s", "second", "env > '\(out)'; sleep 5"])
            for _ in 0..<50 where (try? String(contentsOfFile: out, encoding: .utf8))?.isEmpty ?? true {
                try await Task.sleep(for: .milliseconds(100))
            }
            env = try String(contentsOfFile: out, encoding: .utf8)
        } catch {
            await cleanUp()
            throw error
        }
        await cleanUp()
        #expect(env.contains("PATH="))
        #expect(!env.contains("KANBAN_CARD_ID="))
        #expect(!env.contains("CLAUDE_CODE_SESSION_ID="))
        #expect(!env.contains("/.config/rush/sessions/"))
    }

    @Test("an Anthropic API key in the launching shell is dropped, so sessions bill the signed-in account")
    func anthropicKeyIsDropped() {
        let env = ["ANTHROPIC_API_KEY": "sk-ant-api-x", "ANTHROPIC_AUTH_TOKEN": "t", "ANTHROPIC_BASE_URL": "https://example.invalid", "HOME": "/Users/x"]
        #expect(InheritedSessionEnvironment.inherited(in: env) == ["ANTHROPIC_API_KEY", "ANTHROPIC_AUTH_TOKEN", "ANTHROPIC_BASE_URL"])
    }
}
