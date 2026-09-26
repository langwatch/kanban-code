import Testing
import Foundation
@testable import KanbanCodeCore

@Suite("agtop runtime")
struct AgtopTests {
    /// A stand-in `agtop` that logs each call (argv, then stdin) and answers
    /// like the real one.
    struct FakeAgtop {
        let dir: String
        var path: String { "\(dir)/agtop" }
        var logPath: String { "\(dir)/calls.log" }

        init() throws {
            dir = NSTemporaryDirectory() + "kanban-agtop-test-\(UUID().uuidString)"
            try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
            let script = """
            #!/bin/sh
            echo "ARGS $*" >> '\(dir)/calls.log'
            case "$2" in
              send) echo "STDIN $(cat)" >> '\(dir)/calls.log' ;;
              start) echo '{"id":"0a1b2c3d","sessionId":"0a1b2c3d-1111-2222-3333-444455556666","cwd":"/repo","state":"starting","hostPid":42,"alive":true}' ;;
              info)
                if [ "$3" = "0a1b2c3d" ]; then
                  echo '{"id":"0a1b2c3d","sessionId":"0a1b2c3d-1111","cwd":"/repo","state":"working","alive":true}'
                else
                  echo '{"error":"not found"}'; exit 1
                fi ;;
              list) echo '[{"id":"0a1b2c3d","sessionId":"s1","cwd":"/repo","state":"working","alive":true,"queue":["later","and this"]},{"id":"99999999","sessionId":"s2","cwd":"/old","state":"stopped","alive":false}]' ;;
            esac
            """
            try script.write(toFile: path, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path)
        }

        func calls() -> String { (try? String(contentsOfFile: logPath, encoding: .utf8)) ?? "" }

        func cleanup() { try? FileManager.default.removeItem(atPath: dir) }

        func adapter() -> AgtopCliAdapter {
            AgtopCliAdapter(executable: path, scratchDirectory: "\(dir)/scratch")
        }
    }

    // MARK: - Session names

    @Test("The session name carries the agtop id of the Claude session")
    func sessionName() {
        let sid = "0a1b2c3d-1111-2222-3333-444455556666"
        #expect(AgtopSessionName.agtopId(sessionId: sid) == "0a1b2c3d")
        #expect(AgtopSessionName.name(sessionId: sid) == "agtop-0a1b2c3d")
        #expect(AgtopSessionName.agtopId(fromName: "agtop-0a1b2c3d") == "0a1b2c3d")
    }

    @Test("Extra shells and tmux sessions are not agtop sessions")
    func notAgtop() {
        #expect(!AgtopSessionName.isAgtop("agtop-0a1b2c3d-sh1"))
        #expect(!AgtopSessionName.isAgtop("claude-0a1b2c3d"))
        #expect(!AgtopSessionName.isAgtop("agtop-0A1B2C3D"))
        #expect(!AgtopSessionName.isAgtop("agtop-0a1b"))
    }

    // MARK: - Settings

    @Test("Settings keep the runtime of Claude, and default to tmux")
    func settingsRuntime() throws {
        let json = #"{"assistantRuntimes":{"claude":"agtop","gemini":"agtop","codex":"bogus"}}"#
        let settings = try JSONDecoder().decode(Settings.self, from: Data(json.utf8))
        #expect(settings.runtime(for: .claude) == .agtop)
        #expect(settings.runtime(for: .gemini) == .tmux)
        #expect(settings.runtime(for: .codex) == .tmux)
        #expect(Settings().runtime(for: .claude) == .tmux)

        let encoded = try JSONEncoder().encode(settings)
        let decoded = try JSONDecoder().decode(Settings.self, from: encoded)
        #expect(decoded.runtime(for: .claude) == .agtop)
    }

    // MARK: - Launch planning

    @Test("A card set to agtop runs on agtop only when agtop can run it")
    func choose() {
        func choice(_ assistant: CodingAssistant = .claude, runtime: SessionRuntime = .agtop, remote: Bool = false,
                    override: String? = nil, installed: Bool = true) -> AgtopLaunchPlanner.Choice {
            AgtopLaunchPlanner.choose(assistant: assistant, runtime: runtime, remote: remote,
                                      commandOverride: override, agtopInstalled: installed)
        }
        #expect(choice() == .agtop)
        #expect(choice(runtime: .tmux) == .tmux)
        #expect(choice(.codex) == .fallback(.notClaude))
        #expect(choice(remote: true) == .fallback(.remote))
        #expect(choice(override: "claude --foo") == .fallback(.commandOverride))
        #expect(choice(override: "  ") == .agtop)
        #expect(choice(installed: false) == .fallback(.notInstalled))
    }

    @Test("A command template or a service launcher becomes the binary agtop runs")
    func wrapperCommand() {
        #expect(AgtopLaunchPlanner.wrapperCommand(template: nil, service: nil) == nil)
        #expect(AgtopLaunchPlanner.wrapperCommand(template: "${cli_command}", service: nil) == nil)
        #expect(AgtopLaunchPlanner.wrapperCommand(template: "langwatch ${cli_command}", service: nil) == "langwatch claude")
        let service = APIService(name: "Ollama", assistant: .claude, launcherPrefix: "ollama launch")
        #expect(AgtopLaunchPlanner.wrapperCommand(template: nil, service: service) == "ollama launch claude --")
        #expect(AgtopLaunchPlanner.wrapperScript(command: "langwatch claude") == "#!/bin/sh\nexec langwatch claude \"$@\"\n")
    }

    @Test("The start request carries the card id and the permission mode")
    func request() {
        let request = AgtopLaunchPlanner.request(
            cardId: "card_1", cwd: "/repo", sessionId: "sid", resume: false, name: "Fix it",
            prompt: "hi", imagePaths: [], extraEnv: ["ANTHROPIC_BASE_URL": "http://x"],
            skipPermissions: true, model: "opus", binary: nil
        )
        #expect(request.env == ["ANTHROPIC_BASE_URL": "http://x", "KANBAN_CARD_ID": "card_1"])
        #expect(request.permissionMode == "bypassPermissions")
        #expect(request.meta == ["kanban_card": "card_1"])
        let args = AgtopCliAdapter.startArguments(request, promptFile: "/p.txt")
        #expect(args == [
            "session", "start", "--cwd", "/repo", "--session-id", "sid", "--name", "Fix it",
            "--prompt-file", "/p.txt",
            "--env", "ANTHROPIC_BASE_URL=http://x", "--env", "KANBAN_CARD_ID=card_1",
            "--model", "opus", "--permission-mode", "bypassPermissions",
            "--meta", "kanban_card=card_1", "--json",
        ])
    }

    // MARK: - CLI adapter

    @Test("start runs agtop session start and reads the host back")
    func start() async throws {
        let fake = try FakeAgtop()
        defer { fake.cleanup() }
        let info = try await fake.adapter().start(AgtopStartRequest(
            cwd: "/repo", sessionId: "0a1b2c3d-1111-2222-3333-444455556666", resume: true,
            prompt: "do the thing", imagePaths: ["/img.png"]
        ))
        #expect(info.id == "0a1b2c3d")
        #expect(info.alive)
        let calls = fake.calls()
        #expect(calls.contains("session start --cwd /repo --session-id 0a1b2c3d-1111-2222-3333-444455556666 --resume --prompt-file"))
        #expect(calls.contains("--image /img.png --json"))
    }

    @Test("send passes the text on stdin, whatever it holds")
    func send() async throws {
        let fake = try FakeAgtop()
        defer { fake.cleanup() }
        try await fake.adapter().send(id: "0a1b2c3d", text: "it's \"quoted\" $HOME", imagePaths: ["/a b.png"], now: true)
        let calls = fake.calls()
        #expect(calls.contains("ARGS session send 0a1b2c3d --now --image /a b.png"))
        #expect(calls.contains("STDIN it's \"quoted\" $HOME"))
    }

    @Test("info reads a host, and nil for an unknown id")
    func info() async throws {
        let fake = try FakeAgtop()
        defer { fake.cleanup() }
        let adapter = fake.adapter()
        let info = try await adapter.info(id: "0a1b2c3d")
        #expect(info?.isBusy == true)
        #expect(try await adapter.info(id: "ffffffff") == nil)
    }

    @Test("The router sends agtop names to agtop and lists live hosts")
    func routing() async throws {
        let fake = try FakeAgtop()
        defer { fake.cleanup() }
        let router = RoutingTmuxAdapter(agtop: fake.adapter())
        try await router.pastePrompt(to: "agtop-0a1b2c3d", text: "hello", abortIf: nil)
        try await router.sendEscape(sessionName: "agtop-0a1b2c3d")
        try await router.killSession(name: "agtop-0a1b2c3d")
        #expect(try await router.capturePane(sessionName: "agtop-0a1b2c3d") == "")
        #expect(try await router.clearComposer(sessionName: "agtop-0a1b2c3d") == false)
        let calls = fake.calls()
        #expect(calls.contains("ARGS session send 0a1b2c3d\nSTDIN hello"))
        #expect(calls.contains("ARGS session interrupt 0a1b2c3d"))
        #expect(calls.contains("ARGS session stop 0a1b2c3d"))

        let sessions = try await router.listSessions()
        let names = sessions.map(\.name)
        #expect(names.contains("agtop-0a1b2c3d"))
        #expect(!names.contains("agtop-99999999"))
        #expect(sessions.first { $0.name == "agtop-0a1b2c3d" }?.agtopQueue == ["later", "and this"])
        #expect(BoardStore.agtopQueues(in: sessions) == ["agtop-0a1b2c3d": ["later", "and this"]])
    }

    @Test("A queued message is sent now or removed by its place and text")
    func queueCommands() async throws {
        let fake = try FakeAgtop()
        defer { fake.cleanup() }
        let adapter = fake.adapter()
        try await adapter.sendQueued(id: "0a1b2c3d", index: 1, was: "and this")
        try await adapter.removeQueued(id: "0a1b2c3d", index: 0, was: "later")
        let calls = fake.calls()
        #expect(calls.contains("ARGS session queue 0a1b2c3d send 1 --was and this"))
        #expect(calls.contains("ARGS session queue 0a1b2c3d remove 0 --was later"))
        #expect(try await adapter.list().first?.queue == ["later", "and this"])
    }
}
