import Testing
import Foundation
@testable import KanbanCodeCore

@Suite("rush runtime")
struct RushTests {
    /// A stand-in `rush` (by default its older build, `agtop`) that logs
    /// each call (argv, then stdin) and answers like the real one.
    struct FakeRush {
        let dir: String
        let name: String
        var path: String { "\(dir)/\(name)" }
        var logPath: String { "\(dir)/calls.log" }

        init(name: String = "agtop") throws {
            self.name = name
            dir = NSTemporaryDirectory() + "kanban-rush-test-\(UUID().uuidString)"
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
              list) echo '[{"id":"0a1b2c3d","sessionId":"s1","cwd":"/repo","state":"working","alive":true,"queue":["later","and this"],"meta":{"kanban_session":"rush-0a1b2c3d"}},{"id":"99999999","sessionId":"s2","cwd":"/old","state":"stopped","alive":false},{"id":"5133e9c0","sessionId":"s3","cwd":"/rested","state":"idle","alive":false,"sleeping":true}]' ;;
            esac
            """
            try script.write(toFile: path, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path)
        }

        func calls() -> String { (try? String(contentsOfFile: logPath, encoding: .utf8)) ?? "" }

        func cleanup() { try? FileManager.default.removeItem(atPath: dir) }

        func adapter() -> RushCliAdapter {
            RushCliAdapter(executable: path, scratchDirectory: "\(dir)/scratch")
        }
    }

    // MARK: - Session names

    @Test("The session name carries the rush id of the Claude session")
    func sessionName() {
        let sid = "0a1b2c3d-1111-2222-3333-444455556666"
        #expect(RushSessionName.rushId(sessionId: sid) == "0a1b2c3d")
        #expect(RushSessionName.name(sessionId: sid) == "rush-0a1b2c3d")
        #expect(RushSessionName.rushId(fromName: "rush-0a1b2c3d") == "0a1b2c3d")
    }

    @Test("A host started before the rename keeps its agtop name")
    func legacySessionName() throws {
        #expect(RushSessionName.rushId(fromName: "agtop-0a1b2c3d") == "0a1b2c3d")
        #expect(RushSessionName.isRush("agtop-0a1b2c3d"))
        #expect(!RushSessionName.isRush("agtop-0a1b2c3d-sh1"))
        #expect(RushSessionName.names(rushId: "0a1b2c3d") == ["rush-0a1b2c3d", "agtop-0a1b2c3d"])

        func host(_ meta: String) throws -> RushSessionInfo {
            try JSONDecoder().decode(RushSessionInfo.self, from: Data(#"{"id":"0a1b2c3d"\#(meta)}"#.utf8))
        }
        #expect(RushSessionName.name(for: try host(#","meta":{"kanban_session":"rush-0a1b2c3d"}"#)) == "rush-0a1b2c3d")
        #expect(RushSessionName.name(for: try host(#","meta":{"kanban_card":"card_1"}"#)) == "agtop-0a1b2c3d")
        #expect(RushSessionName.name(for: try host("")) == "agtop-0a1b2c3d")
        // A meta name for another host is not this one's.
        #expect(RushSessionName.name(for: try host(#","meta":{"kanban_session":"rush-99999999"}"#)) == "agtop-0a1b2c3d")
    }

    @Test("Extra shells and tmux sessions are not rush sessions")
    func notRush() {
        #expect(!RushSessionName.isRush("rush-0a1b2c3d-sh1"))
        #expect(!RushSessionName.isRush("claude-0a1b2c3d"))
        #expect(!RushSessionName.isRush("rush-0A1B2C3D"))
        #expect(!RushSessionName.isRush("rush-0a1b"))
    }

    // MARK: - Settings

    @Test("Settings keep the runtime of Claude, and default to tmux")
    func settingsRuntime() throws {
        let json = #"{"assistantRuntimes":{"claude":"rush","gemini":"rush","codex":"bogus"}}"#
        let settings = try JSONDecoder().decode(Settings.self, from: Data(json.utf8))
        #expect(settings.runtime(for: .claude) == .rush)
        #expect(settings.runtime(for: .gemini) == .tmux)
        #expect(settings.runtime(for: .codex) == .tmux)
        #expect(Settings().runtime(for: .claude) == .tmux)

        let encoded = try JSONEncoder().encode(settings)
        let decoded = try JSONDecoder().decode(Settings.self, from: encoded)
        #expect(decoded.runtime(for: .claude) == .rush)
    }

    @Test("The rush runtime is stored as agtop and read under either name")
    func runtimeStoredName() throws {
        let json = #"{"assistantRuntimes":{"claude":"agtop"}}"#
        let settings = try JSONDecoder().decode(Settings.self, from: Data(json.utf8))
        #expect(settings.runtime(for: .claude) == .rush)
        let encoded = String(decoding: try JSONEncoder().encode(settings), as: UTF8.self)
        #expect(encoded.contains(#""claude":"agtop""#))

        #expect(try JSONDecoder().decode([SessionRuntime].self, from: Data(#"["agtop","rush","tmux"]"#.utf8)) == [.rush, .rush, .tmux])
        #expect(String(decoding: try JSONEncoder().encode([SessionRuntime.rush]), as: UTF8.self) == #"["agtop"]"#)
        #expect(throws: DecodingError.self) { try JSONDecoder().decode([SessionRuntime].self, from: Data(#"["bogus"]"#.utf8)) }
    }

    // MARK: - Launch planning

    @Test("A card set to rush runs on rush only when rush can run it")
    func choose() {
        func choice(_ assistant: CodingAssistant = .claude, runtime: SessionRuntime = .rush, remote: Bool = false,
                    override: String? = nil, installed: Bool = true) -> RushLaunchPlanner.Choice {
            RushLaunchPlanner.choose(assistant: assistant, runtime: runtime, remote: remote,
                                      commandOverride: override, rushInstalled: installed)
        }
        #expect(choice() == .rush)
        #expect(choice(runtime: .tmux) == .tmux)
        #expect(choice(.codex) == .fallback(.notClaude))
        #expect(choice(remote: true) == .fallback(.remote))
        #expect(choice(override: "claude --foo") == .fallback(.commandOverride))
        #expect(choice(override: "  ") == .rush)
        #expect(choice(installed: false) == .fallback(.notInstalled))
    }

    @Test("A command template or a service launcher becomes the binary rush runs")
    func wrapperCommand() {
        #expect(RushLaunchPlanner.wrapperCommand(template: nil, service: nil) == nil)
        #expect(RushLaunchPlanner.wrapperCommand(template: "${cli_command}", service: nil) == nil)
        #expect(RushLaunchPlanner.wrapperCommand(template: "langwatch ${cli_command}", service: nil) == "langwatch claude")
        let service = APIService(name: "Ollama", assistant: .claude, launcherPrefix: "ollama launch")
        #expect(RushLaunchPlanner.wrapperCommand(template: nil, service: service) == "ollama launch claude --")
        #expect(RushLaunchPlanner.wrapperScript(command: "langwatch claude") == "#!/bin/sh\nexec langwatch claude \"$@\"\n")
    }

    @Test("The start request carries the card id and the permission mode")
    func request() {
        let request = RushLaunchPlanner.request(
            cardId: "card_1", cwd: "/repo", sessionId: "sid", resume: false, name: "Fix it",
            prompt: "hi", imagePaths: [], extraEnv: ["ANTHROPIC_BASE_URL": "http://x"],
            skipPermissions: true, model: "opus", binary: nil
        )
        #expect(request.env == ["ANTHROPIC_BASE_URL": "http://x", "KANBAN_CARD_ID": "card_1"])
        #expect(request.permissionMode == "bypassPermissions")
        #expect(request.meta == ["kanban_card": "card_1", "kanban_session": "rush-sid"])
        let args = RushCliAdapter.startArguments(request, promptFile: "/p.txt")
        #expect(args == [
            "session", "start", "--cwd", "/repo", "--session-id", "sid", "--name", "Fix it",
            "--prompt-file", "/p.txt",
            "--env", "ANTHROPIC_BASE_URL=http://x", "--env", "KANBAN_CARD_ID=card_1",
            "--model", "opus", "--permission-mode", "bypassPermissions",
            "--meta", "kanban_card=card_1", "--meta", "kanban_session=rush-sid", "--json",
        ])
    }

    @Test("rush gets the absolute path of claude, so a host restarted with a bare PATH finds it")
    func claudeBinary() {
        let found: (String) -> String? = { $0 == "claude" ? "/Users/me/.nvm/versions/node/v22/bin/claude" : nil }
        #expect(RushLaunchPlanner.binary(wrapper: nil, remote: false, findExecutable: found)
            == "/Users/me/.nvm/versions/node/v22/bin/claude")
        // A wrapper script runs in its place.
        #expect(RushLaunchPlanner.binary(wrapper: "/w/card-claude.sh", remote: false, findExecutable: found) == "/w/card-claude.sh")
        // A path of this machine means nothing on another one.
        #expect(RushLaunchPlanner.binary(wrapper: nil, remote: true, findExecutable: found) == nil)
        // Not found: rush looks claude up itself.
        #expect(RushLaunchPlanner.binary(wrapper: nil, remote: false, findExecutable: { _ in nil }) == nil)

        let request = RushLaunchPlanner.request(
            cardId: "card_1", cwd: "/repo", sessionId: "sid", resume: false, name: nil, prompt: nil, imagePaths: [],
            extraEnv: [:], skipPermissions: false, model: nil,
            binary: RushLaunchPlanner.binary(wrapper: nil, remote: false, findExecutable: found))
        let args = RushCliAdapter.startArguments(request, promptFile: nil, rush: true)
        #expect(args.contains("--binary") && args.contains("/Users/me/.nvm/versions/node/v22/bin/claude"))
    }

    // MARK: - CLI adapter

    @Test("start runs rush session start and reads the host back")
    func start() async throws {
        let fake = try FakeRush()
        defer { fake.cleanup() }
        let info = try await fake.adapter().start(RushStartRequest(
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
        let fake = try FakeRush()
        defer { fake.cleanup() }
        try await fake.adapter().send(id: "0a1b2c3d", text: "it's \"quoted\" $HOME", imagePaths: ["/a b.png"], now: true)
        let calls = fake.calls()
        #expect(calls.contains("ARGS session send 0a1b2c3d --now --image /a b.png"))
        #expect(calls.contains("STDIN it's \"quoted\" $HOME"))
    }

    @Test("info reads a host, and nil for an unknown id")
    func info() async throws {
        let fake = try FakeRush()
        defer { fake.cleanup() }
        let adapter = fake.adapter()
        let info = try await adapter.info(id: "0a1b2c3d")
        #expect(info?.isBusy == true)
        #expect(try await adapter.info(id: "ffffffff") == nil)
    }

    @Test("The router sends rush names to rush and lists running and sleeping hosts")
    func routing() async throws {
        let fake = try FakeRush()
        defer { fake.cleanup() }
        let router = RoutingTmuxAdapter(rush: fake.adapter())
        try await router.pastePrompt(to: "rush-0a1b2c3d", text: "hello", abortIf: nil)
        try await router.sendEscape(sessionName: "rush-0a1b2c3d")
        try await router.killSession(name: "rush-0a1b2c3d")
        #expect(try await router.capturePane(sessionName: "rush-0a1b2c3d") == "")
        #expect(try await router.clearComposer(sessionName: "rush-0a1b2c3d") == false)
        let calls = fake.calls()
        #expect(calls.contains("ARGS session send 0a1b2c3d\nSTDIN hello"))
        #expect(calls.contains("ARGS session interrupt 0a1b2c3d"))
        #expect(calls.contains("ARGS session stop 0a1b2c3d"))

        let sessions = try await router.listSessions()
        let names = sessions.map(\.name)
        #expect(names.contains("rush-0a1b2c3d"))
        #expect(!names.contains("rush-99999999"))
        // rush rests a host seconds after its turn: the card keeps it. A
        // host without the name in its meta was started under the old name.
        #expect(names.contains("agtop-5133e9c0"))
        #expect(sessions.first { $0.name == "rush-0a1b2c3d" }?.rushQueue == ["later", "and this"])
        #expect(BoardStore.rushQueues(in: sessions) == ["rush-0a1b2c3d": ["later", "and this"]])
    }

    @Test("A queued message is sent now or removed by its place and text")
    func queueCommands() async throws {
        let fake = try FakeRush()
        defer { fake.cleanup() }
        let adapter = fake.adapter()
        try await adapter.sendQueued(id: "0a1b2c3d", index: 1, was: "and this")
        try await adapter.removeQueued(id: "0a1b2c3d", index: 0, was: "later")
        let calls = fake.calls()
        #expect(calls.contains("ARGS session queue 0a1b2c3d send 1 --was and this"))
        #expect(calls.contains("ARGS session queue 0a1b2c3d remove 0 --was later"))
        #expect(try await adapter.list().first?.queue == ["later", "and this"])
    }

    @Test("rush sends now or removes a queued message with rush queue")
    func rushQueueCommands() async throws {
        let fake = try FakeRush(name: "rush")
        defer { fake.cleanup() }
        let adapter = fake.adapter()
        try await adapter.sendQueued(id: "0a1b2c3d", index: 1, was: "and this")
        try await adapter.removeQueued(id: "0a1b2c3d", index: 0, was: "later")
        let calls = fake.calls()
        #expect(calls.contains("ARGS queue send 0a1b2c3d 1 --was and this"))
        #expect(calls.contains("ARGS queue remove 0a1b2c3d 0 --was later"))
    }

    @Test("rush is told the agent is Claude Code, agtop is not")
    func rushStartNamesTheAgent() async throws {
        let rush = try FakeRush(name: "rush")
        defer { rush.cleanup() }
        _ = try await rush.adapter().start(RushStartRequest(cwd: "/repo", sessionId: "0a1b2c3d-1111-2222-3333-444455556666", resume: false))
        #expect(rush.calls().contains("ARGS session start --cwd /repo --session-id 0a1b2c3d-1111-2222-3333-444455556666 --agent claude --json"))
        let agtop = try FakeRush(name: "agtop")
        defer { agtop.cleanup() }
        _ = try await agtop.adapter().start(RushStartRequest(cwd: "/repo", sessionId: "0a1b2c3d-1111-2222-3333-444455556666", resume: false))
        #expect(agtop.calls().contains("ARGS session start --cwd /repo --session-id 0a1b2c3d-1111-2222-3333-444455556666 --json"))
    }

    @Test("rush opens one session without --solo, agtop with it")
    func openArguments() {
        #expect(RushCliAdapter.openArguments(executable: "/Users/me/go/bin/rush", id: "0a1b2c3d")
            == ["/Users/me/go/bin/rush", "open", "0a1b2c3d"])
        #expect(RushCliAdapter.openArguments(executable: "/Users/me/go/bin/agtop", id: "0a1b2c3d")
            == ["/Users/me/go/bin/agtop", "open", "0a1b2c3d", "--solo"])
        #expect(RushCliAdapter.remoteOpenScript(id: "0a1b2c3d")
            == "if command -v rush >/dev/null 2>&1; then exec rush open '0a1b2c3d'; else exec agtop open '0a1b2c3d' --solo; fi")
    }

    @Test("Versions compare by build, not by the day each machine prints")
    func versionBuild() {
        #expect(RushCliAdapter.build(ofVersion: "rush b06e734 (Sep 30)") == RushCliAdapter.build(ofVersion: "rush b06e734 (Sep 29)"))
        #expect(RushCliAdapter.build(ofVersion: "rush b06e734 (Sep 30)") != RushCliAdapter.build(ofVersion: "agtop 31c008a (Sep 28)"))
    }

    // MARK: - rush on a machine

    @Test("rush on a machine runs through the bridge, with the prompt on stdin and the images copied over")
    func remoteAdapter() async throws {
        let runner = FakeRemoteCommandRunner()
        runner.script(["/usr/local/bin/rush", "session", "info", "0a1b2c3d", "--json"], ShellCommand.Result(
            exitCode: 0, stdout: #"{"id":"0a1b2c3d","sessionId":"s","cwd":"/root/repo","state":"idle","alive":true}"#, stderr: ""))
        runner.setFallback(ShellCommand.Result(
            exitCode: 0, stdout: #"{"id":"0a1b2c3d","sessionId":"s","cwd":"/root/repo","state":"starting","alive":true}"#, stderr: ""))
        let rush = RushCliAdapter(remote: runner, executable: "/usr/local/bin/rush", scratchDirectory: "/root/.kanban-code/tmp/rush")
        #expect(rush.isAvailable)

        let image = NSTemporaryDirectory() + "kanban-rush-image-\(UUID().uuidString).png"
        try Data([1, 2, 3]).write(to: URL(fileURLWithPath: image))
        defer { try? FileManager.default.removeItem(atPath: image) }

        _ = try await rush.start(RushStartRequest(
            cwd: "/root/repo", sessionId: "0a1b2c3d-1111-2222-3333-444455556666", resume: true,
            prompt: "go on", imagePaths: [image]))
        // The worktree check runs first on the machine, then the start.
        #expect(runner.execCalls.first?.prefix(2) == ["/bin/sh", "-c"])
        let startIndex = try #require(runner.execCalls.firstIndex { $0.prefix(3) == ["/usr/local/bin/rush", "session", "start"] })
        let start = runner.execCalls[startIndex]
        #expect(start.contains("--prompt-file") && start[start.firstIndex(of: "--prompt-file")! + 1] == "-")
        #expect(runner.execStdins[startIndex] == "go on")
        let copied = try #require(runner.files.keys.first)
        #expect(copied.hasPrefix("/root/.kanban-code/tmp/rush/") && copied.hasSuffix("/1.png"))
        #expect(start[start.firstIndex(of: "--image")! + 1] == copied)

        try await rush.send(id: "0a1b2c3d", text: "hello", imagePaths: ["/root/already-there.png"])
        #expect(runner.execCalls.last == ["/usr/local/bin/rush", "session", "send", "0a1b2c3d", "--image", "/root/already-there.png"])
        #expect(runner.execStdins.last == "hello")
        #expect(try await rush.info(id: "0a1b2c3d")?.alive == true)
    }

    @Test("A rush name on a machine routes to that machine's rush, and only its own hosts are listed")
    func remoteRouting() async throws {
        let runner = FakeRemoteCommandRunner()
        runner.script(["/usr/local/bin/rush", "session", "list", "--json"], ShellCommand.Result(exitCode: 0, stdout: """
            [{"id":"0a1b2c3d","sessionId":"s1","cwd":"/root/repo","state":"working","alive":true,"queue":["next"],"meta":{"kanban_session":"rush-0a1b2c3d"}},
             {"id":"feedbeef","sessionId":"s2","cwd":"/root/other","state":"idle","alive":true,"meta":{"kanban_session":"rush-feedbeef"}}]
            """, stderr: ""))
        let registry = RemoteSessionRegistry()
        let router = RoutingTmuxAdapter(
            local: TmuxAdapter(transport: FakeTmuxTransport(label: "local")),
            registry: registry,
            rush: RushCliAdapter(executable: "/nonexistent/rush"))
        registry.assign(sessionName: "rush-0a1b2c3d", to: "box")
        registry.setMachine("box", state: .connected, tmux: TmuxAdapter(transport: FakeTmuxTransport(label: "box")))
        registry.setRush(RushCliAdapter(remote: runner, executable: "/usr/local/bin/rush", scratchDirectory: "/tmp/a"), on: "box")

        try await router.sendPrompt(to: "rush-0a1b2c3d", text: "hi")
        #expect(runner.execCalls.last == ["/usr/local/bin/rush", "session", "send", "0a1b2c3d"])

        let sessions = try await router.listSessions()
        #expect(sessions.contains { $0.name == "rush-0a1b2c3d" && $0.rushQueue == ["next"] })
        // Another master's host on the same machine is not this one's.
        #expect(!sessions.contains { $0.name == "rush-feedbeef" })

        try await router.killSession(name: "rush-0a1b2c3d")
        #expect(runner.execCalls.last == ["/usr/local/bin/rush", "session", "stop", "0a1b2c3d"])
        #expect(registry.machine(forSession: "rush-0a1b2c3d") == nil)

        // A machine that is not connected refuses instead of falling back here.
        registry.assign(sessionName: "rush-0a1b2c3d", to: "box")
        registry.disconnectMachine("box", state: .unreachable)
        #expect(throws: RemoteMachineUnavailable.self) { try router.rush(forSession: "rush-0a1b2c3d") }
    }
}
