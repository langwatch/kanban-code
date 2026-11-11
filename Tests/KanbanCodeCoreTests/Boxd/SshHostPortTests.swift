import Foundation
import Testing
@testable import KanbanCodeCore

private func withLock<T>(_ lock: NSLock, _ body: () -> T) -> T {
    lock.lock()
    defer { lock.unlock() }
    return body()
}

/// A bridge channel whose machine answers at once: `hello` when it opens,
/// exit 0 to every `exec`, `pong` to every `ping`.
final class AnsweringBridgeChannel: BridgeChannel, @unchecked Sendable {
    let lines: AsyncStream<String>
    private let continuation: AsyncStream<String>.Continuation
    private let lock = NSLock()
    private var _execs: [[String]] = []
    private let home: String

    init(home: String) {
        self.home = home
        let (stream, continuation) = AsyncStream<String>.makeStream(bufferingPolicy: .unbounded)
        self.lines = stream
        self.continuation = continuation
        feed(["type": "hello", "agentVersion": "test", "home": home, "vm": "box"])
    }

    var execs: [[String]] { withLock(lock) { _execs } }

    private func feed(_ object: [String: Any]) {
        let data = try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        continuation.yield(String(data: data, encoding: .utf8)!)
    }

    func send(line: String) throws {
        guard let object = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any] else { return }
        switch object["type"] as? String {
        case "exec":
            let argv = object["argv"] as? [String] ?? []
            withLock(lock) { _execs.append(argv) }
            feed(["type": "exec-result", "id": object["id"] as? String ?? "", "stdout": "", "stderr": "", "code": 0])
        case "ping":
            feed(["type": "pong"])
        default:
            break
        }
    }

    func close() { continuation.finish() }
    func terminationReason() async -> String { "exit 0" }
}

/// A port for an always-on machine: the calls of `FakeBoxdPort`, a host
/// profile, and a bridge that answers.
final class FakeHostPort: BoxdPort, @unchecked Sendable {
    let calls = FakeBoxdPort()
    let hostName: String
    let home: String
    private let lock = NSLock()
    private var _channels: [AnsweringBridgeChannel] = []

    init(hostName: String = "box", home: String = "/root") {
        self.hostName = hostName
        self.home = home
    }

    var channels: [AnsweringBridgeChannel] { withLock(lock) { _channels } }

    func createMachine(name: String, snapshot: String?, autoSuspendSeconds: Int?) async throws -> BoxdMachine {
        try await calls.createMachine(name: name, snapshot: snapshot, autoSuspendSeconds: autoSuspendSeconds)
    }
    func getMachine(name: String) async throws -> BoxdMachine { try await calls.getMachine(name: name) }
    func listMachines() async throws -> [BoxdMachine] { try await calls.listMachines() }
    func resume(name: String) async throws { try await calls.resume(name: name) }
    func wake(name: String) async throws { try await calls.wake(name: name) }
    func start(name: String) async throws { try await calls.start(name: name) }
    func stop(name: String) async throws { try await calls.stop(name: name) }
    func remove(name: String) async throws { try await calls.remove(name: name) }
    func saveSnapshot(machine: String, name: String) async throws { try await calls.saveSnapshot(machine: machine, name: name) }
    func listSnapshots() async throws -> [BoxdSnapshot] { try await calls.listSnapshots() }
    func exec(name: String, command: String, timeout: TimeInterval) async throws -> ShellCommand.Result {
        try await calls.exec(name: name, command: command, timeout: timeout)
    }
    func upload(name: String, remotePath: String, data: Data, onEvent: @escaping @Sendable (BoxdUploadEvent) -> Void) async throws {
        try await calls.upload(name: name, remotePath: remotePath, data: data, onEvent: onEvent)
    }
    func isAvailable() async -> Bool { true }

    func hostProfile(name: String) async -> RemoteHostProfile? {
        name == hostName ? RemoteHostProfile(remoteHome: home, folderTemplate: "~/Projects/${repo_name}", nodePath: "/usr/bin/node") : nil
    }

    func bridgeChannel(name: String, remoteHome: String) async throws -> any BridgeChannel {
        let channel = AnsweringBridgeChannel(home: home)
        withLock(lock) { _channels.append(channel) }
        return channel
    }
}

@Suite("Ssh machines")
struct SshHostPortTests {

    // MARK: - Settings

    @Test("An ssh machine checks out repositories under its folder, and its home follows the user")
    func machineDefaults() {
        let root = SshMachine(name: "box", target: "root@10.0.0.1")
        #expect(root.folderTemplate == "~/Projects/${repo_name}")
        #expect(root.assumedHome == "/root")
        #expect(SshMachine(name: "b", target: "dev@host", repoRoot: "/srv/code/").folderTemplate == "/srv/code/${repo_name}")
        #expect(SshMachine(name: "b", target: "dev@host").assumedHome == "/home/dev")
        #expect(SshMachine(name: "b", target: "alias", repoRoot: "  ").folderTemplate == "~/${repo_name}")
        #expect(!SshMachine(name: "b", target: " ").isComplete)
    }

    @Test("Settings written before ssh machines existed read with none, and a list survives a round trip")
    func settingsRoundTrip() throws {
        let old = try JSONDecoder().decode(BoxdSettings.self, from: Data(#"{"snapshotName":"s"}"#.utf8))
        #expect(old.sshMachines.isEmpty)

        let settings = BoxdSettings(sshMachines: [SshMachine(name: "box", target: "root@h", repoRoot: "~/code")])
        let encoded = try JSONEncoder().encode(settings)
        #expect(!(String(data: encoded, encoding: .utf8) ?? "").contains(#""id""#))
        let decoded = try JSONDecoder().decode(BoxdSettings.self, from: encoded)
        #expect(decoded.sshMachines == settings.sshMachines)
        #expect(decoded.sshMachines[0].id != settings.sshMachines[0].id)
        #expect(Set([decoded.sshMachines[0], settings.sshMachines[0]]).count == 1)
        #expect(decoded.sshMachine(named: "box")?.target == "root@h")
        #expect(decoded.sshMachine(named: "other") == nil)

        let partial = try JSONDecoder().decode(SshMachine.self, from: Data(#"{"name":"box","target":"root@h"}"#.utf8))
        #expect(partial.repoRoot == SshMachine.defaultRepoRoot)
        #expect(!partial.id.uuidString.isEmpty)

        // Two separately created machines with the same fields compare equal despite distinct runtime ids
        let otherCopy = SshMachine(name: "box", target: "root@h")
        #expect(partial == otherCopy)
        #expect(partial.id != otherCopy.id)

        // Changing name preserves the stable id
        var mutableMachine = partial
        let originalId = mutableMachine.id
        mutableMachine.name = "renamed-box"
        #expect(mutableMachine.id == originalId)
        #expect(mutableMachine.name == "renamed-box")
    }

    // MARK: - Commands

    @Test("The reachability check reads home and node from the machine")
    func parseProbe() {
        #expect(SshHostPort.parseProbe("/root\n/usr/bin/node\n") == SshHostPort.Probe(home: "/root", nodePath: "/usr/bin/node"))
        #expect(SshHostPort.parseProbe("/home/dev\n\n") == SshHostPort.Probe(home: "/home/dev", nodePath: "node"))
        #expect(SshHostPort.parseProbe("Welcome!\n") == nil)
    }

    @Test("An upload lands on its own name and is moved into place")
    func uploadCommand() {
        let command = SshHostPort.uploadCommand(remotePath: "/root/.kanban-code/x y.jsonl", suffix: "ab12")
        #expect(command == "mkdir -p '/root/.kanban-code' && cat > '/root/.kanban-code/x y.jsonl.incoming-ab12' && mv -f '/root/.kanban-code/x y.jsonl.incoming-ab12' '/root/.kanban-code/x y.jsonl' || { rm -f '/root/.kanban-code/x y.jsonl.incoming-ab12'; exit 1; }")
    }

    @Test("The bridge runs the agent with the node of the machine, without a tty")
    func bridgeArguments() {
        let arguments = SshHostPort.bridgeArguments(target: "root@h", nodePath: "/usr/bin/node", remoteHome: "/root")
        #expect(arguments.suffix(4) == ["-T", "root@h", "--", "'/usr/bin/node' '/root/.kanban-code/cli/dist/kanban.js' 'remote-agent'"])
        #expect(arguments.contains("BatchMode=yes"))
    }

    // MARK: - Router

    @Test("The router sends ssh machines to ssh and everything else to boxd")
    func routing() async throws {
        let boxd = FakeBoxdPort()
        let ssh = SshHostPort(sshPath: "/usr/bin/false", machines: { [SshMachine(name: "box", target: "root@h")] })
        let router = MachinePortRouter(boxd: boxd, ssh: ssh)

        _ = try await router.getMachine(name: "kanban-repo-1")
        #expect(boxd.callNames("getMachine") == ["kanban-repo-1"])
        await #expect(throws: BoxdError.self) { _ = try await router.getMachine(name: "box") }
        #expect(boxd.callNames("getMachine") == ["kanban-repo-1"])

        try await router.stop(name: "box")
        try await router.remove(name: "box")
        #expect(boxd.callNames("stop").isEmpty && boxd.callNames("remove").isEmpty)

        #expect(await router.hostProfile(name: "box") == RemoteHostProfile(remoteHome: "/root", folderTemplate: "~/Projects/${repo_name}", nodePath: "node"))
        #expect(await router.hostProfile(name: "kanban-repo-1") == nil)
        _ = try await router.listMachines()
        #expect(boxd.callNames("listMachines").count == 1)
    }

    // MARK: - Supervisor

    private func makeSupervisor(port: any BoxdPort, registry: RemoteSessionRegistry, cliBundle: String? = nil, home: String) -> BoxdMachineSupervisor {
        BoxdMachineSupervisor(
            boxd: port,
            registry: registry,
            settingsProvider: { BoxdSettings(initCommand: "true", copyGlobs: []) },
            cliBundlePath: cliBundle,
            appVersion: "1.0.0-test",
            localHome: home,
            localKanbanHome: home + "/.kanban-code",
            loginStore: FakeLoginStore(),
            now: { Date(timeIntervalSince1970: 1_700_000_000) }
        )
    }

    private func temporaryHome() -> String {
        let home = NSTemporaryDirectory() + "ssh-host-\(UUID().uuidString)"
        try? FileManager.default.createDirectory(atPath: home, withIntermediateDirectories: true)
        return home
    }

    /// A folder that looks like the CLI bundle of the app.
    private func cliBundle(in home: String) throws -> String {
        let bundle = "\(home)/cli"
        try FileManager.default.createDirectory(atPath: "\(bundle)/dist", withIntermediateDirectories: true)
        try Data("console.log(1)".utf8).write(to: URL(fileURLWithPath: "\(bundle)/dist/kanban.js"))
        return bundle
    }

    @Test("An ssh machine is never stopped, removed or paused for inactivity")
    func hostIsNeverStopped() async throws {
        let port = FakeHostPort()
        let registry = RemoteSessionRegistry()
        registry.setMachine("box", state: .connected)
        registry.assign(sessionName: "claude-aaaa", to: "box")
        let supervisor = makeSupervisor(port: port, registry: registry, home: temporaryHome())

        #expect(await supervisor.isHost("box"))
        #expect(await !supervisor.isHost("kanban-repo-1"))
        await supervisor.stop(machineName: "box", reason: .inactivity)
        try await supervisor.destroy(machineName: "box")
        await supervisor.stopAll(reason: .appQuit)
        await supervisor.checkInactivity()

        #expect(port.calls.callNames("stop").isEmpty)
        #expect(port.calls.callNames("remove").isEmpty)
        #expect(registry.state(of: "box") == .connected)
        #expect(registry.machine(forSession: "claude-aaaa") == "box")
    }

    @Test("A card leaving an ssh machine kills its session there and keeps the machine")
    func leaveHost() async throws {
        let home = temporaryHome()
        let port = FakeHostPort()
        let registry = RemoteSessionRegistry()
        let supervisor = makeSupervisor(port: port, registry: registry, cliBundle: try cliBundle(in: home), home: home)
        let project = "\(home)/Projects/app"
        try FileManager.default.createDirectory(atPath: project, withIntermediateDirectories: true)

        let preparation = try await supervisor.prepare(
            cardId: "card-1", localProjectPath: project, existingMachine: "box",
            worktreeName: nil, existingWorktree: nil, sessionNames: ["claude-aaaa"])
        #expect(preparation.remoteProjectPath == "/root/Projects/app")
        #expect(preparation.remoteHome == "/root")
        #expect(registry.machine(forSession: "claude-aaaa") == "box")
        // No watchdog on an always-on machine, and node comes from the profile.
        #expect(!port.calls.callNames("exec").contains { $0.contains("watchdog") })
        #expect(port.calls.callNames("exec").contains { $0.contains("exec /usr/bin/node /root/.kanban-code/cli/dist/kanban.js") })
        #expect(port.calls.callNames("createMachine").isEmpty)

        await supervisor.leave(machineName: "box", sessionNames: ["claude-aaaa"], localTranscript: nil, remoteCwd: nil)
        let channel = try #require(port.channels.first)
        #expect(channel.execs.contains(["tmux", "kill-session", "-t", "claude-aaaa"]))
        #expect(registry.machine(forSession: "claude-aaaa") == nil)
        #expect(port.calls.callNames("stop").isEmpty)
        #expect(await supervisor.isConnected("box"))
    }

    @Test("A session of root is marked as sandboxed, so Claude accepts skipping permissions")
    func rootSandbox() {
        #expect(BoxdMachineSupervisor.sessionEnvironment(cardId: "c", remoteHome: "/root")["IS_SANDBOX"] == "1")
        #expect(BoxdMachineSupervisor.sessionEnvironment(cardId: "c", remoteHome: "/home/boxd")["IS_SANDBOX"] == nil)
    }

    @Test("A boxd machine the card leaves is stopped, as before")
    func leaveBoxd() async {
        let boxd = FakeBoxdPort()
        let registry = RemoteSessionRegistry()
        registry.setMachine("kanban-repo-1", state: .connected)
        registry.assign(sessionName: "claude-aaaa", to: "kanban-repo-1")
        let supervisor = makeSupervisor(port: boxd, registry: registry, home: temporaryHome())

        await supervisor.leave(machineName: "kanban-repo-1", sessionNames: ["claude-aaaa"], localTranscript: nil, remoteCwd: nil)
        #expect(boxd.callNames("stop") == ["kanban-repo-1"])
        #expect(registry.machine(forSession: "claude-aaaa") == nil)
    }

    @Test("One ssh machine maps the checkouts of every project that runs on it")
    func sharedHostMapsEveryProject() async throws {
        let home = temporaryHome()
        let port = FakeHostPort()
        let supervisor = makeSupervisor(port: port, registry: RemoteSessionRegistry(), cliBundle: try cliBundle(in: home), home: home)
        let first = "\(home)/Projects/app"
        let second = "\(home)/Code/site"
        for path in [first, second] {
            try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
        }

        _ = try await supervisor.prepare(
            cardId: "card-1", localProjectPath: first, existingMachine: "box",
            worktreeName: nil, existingWorktree: nil, sessionNames: ["claude-aaaa"])
        _ = try await supervisor.prepare(
            cardId: "card-2", localProjectPath: second, existingMachine: "box",
            worktreeName: nil, existingWorktree: nil, sessionNames: ["claude-bbbb"])

        #expect(port.channels.count == 1)
        let rewriter = try #require(await supervisor.mirror(for: "box")?.rewriter)
        #expect(rewriter.mapPath("/root/Projects/app/README.md") == "\(first)/README.md")
        #expect(rewriter.mapPath("/root/Projects/site/index.html") == "\(second)/index.html")
        #expect(rewriter.mapPath("/root/.kanban-code/context/x.json") == "\(home)/.kanban-code/context/x.json")
    }
}
