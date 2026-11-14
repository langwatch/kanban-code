import Foundation

/// A machine reached over ssh that runs cards the way a boxd machine does.
/// It is always on and shared by every card sent to it: the app never
/// creates, stops or removes it.
public struct SshMachine: Codable, Sendable, Equatable, Hashable, Identifiable {
    /// Stable identifier for SwiftUI view identity across edits.
    public let id: UUID
    /// Name shown in the app and stored on the cards that run there.
    public var name: String
    /// What `ssh` connects to: `user@host`, or a host alias of `~/.ssh/config`.
    public var target: String
    /// Folder the repositories are checked out in. `~` is the home directory
    /// on the machine.
    public var repoRoot: String

    public static let defaultRepoRoot = "~/Projects"

    public init(id: UUID = UUID(), name: String, target: String, repoRoot: String = SshMachine.defaultRepoRoot) {
        self.id = id
        self.name = name
        self.target = target
        self.repoRoot = repoRoot
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = UUID()
        name = (try? c.decodeIfPresent(String.self, forKey: .name)) ?? ""
        target = (try? c.decodeIfPresent(String.self, forKey: .target)) ?? ""
        repoRoot = (try? c.decodeIfPresent(String.self, forKey: .repoRoot)) ?? Self.defaultRepoRoot
    }

    private enum CodingKeys: String, CodingKey {
        case name, target, repoRoot
    }

    // `id` is runtime SwiftUI identity only; value equality, hashing, and
    // persisted JSON depend strictly on the machine's configuration fields.
    public static func == (lhs: SshMachine, rhs: SshMachine) -> Bool {
        lhs.name == rhs.name && lhs.target == rhs.target && lhs.repoRoot == rhs.repoRoot
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(name)
        hasher.combine(target)
        hasher.combine(repoRoot)
    }

    /// Folder template of the checkouts, in the syntax of `BoxdSettings`.
    public var folderTemplate: String {
        var root = repoRoot.trimmingCharacters(in: .whitespaces)
        while root.count > 1, root.hasSuffix("/") { root.removeLast() }
        if root.isEmpty { root = "~" }
        return "\(root)/${repo_name}"
    }

    /// Home directory guessed from the user of the target, for the time
    /// before the machine answered: `/root` for root, `/home/<user>` else.
    public var assumedHome: String {
        guard let at = target.firstIndex(of: "@") else { return "/root" }
        let user = String(target[..<at])
        return user == "root" ? "/root" : "/home/\(user)"
    }

    /// A machine the settings can use: both fields filled in.
    public var isComplete: Bool {
        !name.trimmingCharacters(in: .whitespaces).isEmpty && !target.trimmingCharacters(in: .whitespaces).isEmpty
    }
}

/// What differs on a machine that is not a boxd machine.
public struct RemoteHostProfile: Sendable, Equatable {
    /// Home directory of the user on the machine.
    public let remoteHome: String
    /// Folder template of the checkouts on the machine.
    public let folderTemplate: String
    /// The node that runs the kanban CLI on the machine.
    public let nodePath: String

    public init(remoteHome: String, folderTemplate: String, nodePath: String) {
        self.remoteHome = remoteHome
        self.folderTemplate = folderTemplate
        self.nodePath = nodePath
    }
}

/// `BoxdPort` over plain ssh, for machines that are always on.
///
/// Machine control is a reachability check: `getMachine` answers `running`
/// when the machine answers over ssh and throws otherwise, and the start,
/// stop and remove calls do nothing. Commands run with `ssh <target> --`,
/// uploads stream a file into `cat` on the machine, and the bridge is one
/// long-lived `ssh -T <target> -- node kanban.js remote-agent`.
public final class SshHostPort: BoxdPort, @unchecked Sendable {
    private static let subsystem = "ssh-host"

    private let machinesProvider: @Sendable () async -> [SshMachine]
    private let sshPath: String
    private let lock = NSLock()
    /// What each machine answered on its last check: home and node.
    private var probes: [String: Probe] = [:]

    struct Probe: Equatable {
        let home: String
        let nodePath: String
    }

    private func probe(of name: String) -> Probe? {
        lock.lock(); defer { lock.unlock() }
        return probes[name]
    }

    private func record(_ probe: Probe, for name: String) {
        lock.lock(); defer { lock.unlock() }
        probes[name] = probe
    }

    public init(sshPath: String = "/usr/bin/ssh", machines: @escaping @Sendable () async -> [SshMachine]) {
        self.sshPath = sshPath
        self.machinesProvider = machines
    }

    /// Options of every ssh call: never ask for a password, give up on a
    /// machine that does not answer, and notice a connection that died.
    public static let options = [
        "-o", "BatchMode=yes",
        "-o", "ConnectTimeout=10",
        "-o", "ServerAliveInterval=15",
        "-o", "ServerAliveCountMax=4",
    ]

    public func machine(named name: String) async -> SshMachine? {
        await machinesProvider().first { $0.name == name && $0.isComplete }
    }

    private func requireMachine(_ name: String) async throws -> SshMachine {
        guard let machine = await machine(named: name) else {
            throw BoxdError.commandFailed(command: "ssh \(name)", exitCode: 255, message: "Machine \(name) not found in the settings")
        }
        return machine
    }

    // MARK: - Profile

    /// Home and node of a machine, from its last check, or from the target
    /// when it has not answered yet.
    public func profile(for name: String) async -> RemoteHostProfile? {
        guard let machine = await machine(named: name) else { return nil }
        let probe = probe(of: name)
        return RemoteHostProfile(
            remoteHome: probe?.home ?? machine.assumedHome,
            folderTemplate: machine.folderTemplate,
            nodePath: probe?.nodePath ?? "node")
    }

    /// Script of the reachability check: prints the home directory and the
    /// path of node, one per line.
    static let probeScript = "printf '%s\\n%s\\n' \"$HOME\" \"$(command -v node || echo node)\""

    static func parseProbe(_ output: String) -> Probe? {
        let lines = output.split(separator: "\n", omittingEmptySubsequences: false).map {
            $0.trimmingCharacters(in: .whitespaces)
        }
        guard let home = lines.first, home.hasPrefix("/") else { return nil }
        let node = lines.count > 1 && !lines[1].isEmpty ? lines[1] : "node"
        return Probe(home: home, nodePath: node)
    }

    // MARK: - BoxdPort

    public func createMachine(name: String, snapshot: String?, autoSuspendSeconds: Int?) async throws -> BoxdMachine {
        throw BoxdError.commandFailed(command: "ssh \(name)", exitCode: 255, message: "\(name) is an ssh machine, it is not created by the app")
    }

    public func getMachine(name: String) async throws -> BoxdMachine {
        let machine = try await requireMachine(name)
        let result = try await run(machine, command: Self.probeScript, timeout: 20)
        if let probe = Self.parseProbe(result.stdout) {
            record(probe, for: name)
        }
        return BoxdMachine(name: name, status: .running)
    }

    public func listMachines() async throws -> [BoxdMachine] { [] }
    public func resume(name: String) async throws {}
    public func wake(name: String) async throws {}
    public func start(name: String) async throws {}
    public func stop(name: String) async throws {}
    public func remove(name: String) async throws {}

    public func saveSnapshot(machine: String, name: String) async throws {
        throw BoxdError.commandFailed(command: "ssh \(machine)", exitCode: 1, message: "ssh machines have no snapshots")
    }

    public func listSnapshots() async throws -> [BoxdSnapshot] { [] }

    public func exec(name: String, command: String, timeout: TimeInterval) async throws -> ShellCommand.Result {
        let machine = try await requireMachine(name)
        return try await ShellCommand.run(
            sshPath, arguments: Self.options + [machine.target, "--", command], timeout: timeout)
    }

    /// Streams the bytes into `cat` on the machine, under a unique name that
    /// is moved into place once complete, so two uploads to one target never
    /// leave a mix of both.
    public func upload(name: String, remotePath: String, data: Data, onEvent: @escaping @Sendable (BoxdUploadEvent) -> Void) async throws {
        let machine = try await requireMachine(name)
        let local = (NSTemporaryDirectory() as NSString).appendingPathComponent("kanban-ssh-upload-\(UUID().uuidString)")
        try data.write(to: URL(fileURLWithPath: local))
        defer { try? FileManager.default.removeItem(atPath: local) }
        let remote = Self.uploadCommand(remotePath: remotePath, suffix: String(UUID().uuidString.prefix(8)))
        let ssh = ([sshPath] + Self.options + [machine.target, "--", remote]).map(Self.shellEscape).joined(separator: " ")
        KanbanCodeLog.info(Self.subsystem, "Uploading \(data.count) bytes to \(name):\(remotePath)")
        let result = try await ShellCommand.run("/bin/sh", arguments: ["-c", "\(ssh) < \"$1\"", "sh", local], timeout: 600)
        guard result.succeeded else { throw Self.failure("ssh \(machine.target) upload", result) }
        onEvent(.progress(sent: data.count, total: data.count))
    }

    /// The command on the machine that receives an upload on stdin.
    static func uploadCommand(remotePath: String, suffix: String) -> String {
        let target = shellEscape(remotePath)
        let incoming = shellEscape("\(remotePath).incoming-\(suffix)")
        let directory = shellEscape((remotePath as NSString).deletingLastPathComponent)
        return "mkdir -p \(directory) && cat > \(incoming) && mv -f \(incoming) \(target) || { rm -f \(incoming); exit 1; }"
    }

    public func isAvailable() async -> Bool {
        FileManager.default.isExecutableFile(atPath: sshPath)
    }

    public func hostProfile(name: String) async -> RemoteHostProfile? {
        await profile(for: name)
    }

    public func bridgeChannel(name: String, remoteHome: String) async throws -> any BridgeChannel {
        let machine = try await requireMachine(name)
        let node = await profile(for: name)?.nodePath ?? "node"
        return try ProcessBridgeChannel(
            executable: sshPath,
            arguments: Self.bridgeArguments(target: machine.target, nodePath: node, remoteHome: remoteHome),
            environment: ShellCommand.loginEnvironment)
    }

    static func bridgeArguments(target: String, nodePath: String, remoteHome: String) -> [String] {
        let command = [nodePath, "\(remoteHome)/.kanban-code/cli/dist/kanban.js", "remote-agent"]
            .map(shellEscape).joined(separator: " ")
        return options + ["-T", target, "--", command]
    }

    // MARK: - Reachability

    /// Whether a target answers over ssh within a few seconds.
    public static func isReachable(target: String, sshPath: String = "/usr/bin/ssh", timeoutSeconds: Int = 5) async -> Bool {
        let arguments = ["-o", "BatchMode=yes", "-o", "ConnectTimeout=\(timeoutSeconds)", target, "--", "true"]
        let result = try? await ShellCommand.run(sshPath, arguments: arguments, timeout: TimeInterval(timeoutSeconds + 5))
        return result?.succeeded == true
    }

    // MARK: - Private

    private func run(_ machine: SshMachine, command: String, timeout: TimeInterval) async throws -> ShellCommand.Result {
        let result = try await ShellCommand.run(
            sshPath, arguments: Self.options + [machine.target, "--", command], timeout: timeout)
        guard result.succeeded else { throw Self.failure("ssh \(machine.target)", result) }
        return result
    }

    private static func failure(_ command: String, _ result: ShellCommand.Result) -> BoxdError {
        KanbanCodeLog.warn(subsystem, "\(command) exited \(result.exitCode): \(result.stderr)")
        return BoxdError.commandFailed(
            command: command, exitCode: result.exitCode,
            message: result.stderr.isEmpty ? result.stdout : result.stderr)
    }

    static func shellEscape(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

/// The port of the supervisor: ssh machines by name, boxd for the rest.
public final class MachinePortRouter: BoxdPort, @unchecked Sendable {
    public let boxd: any BoxdPort
    public let ssh: SshHostPort

    public init(boxd: any BoxdPort, ssh: SshHostPort) {
        self.boxd = boxd
        self.ssh = ssh
    }

    private func port(for name: String) async -> any BoxdPort {
        await ssh.machine(named: name) != nil ? ssh : boxd
    }

    public func createMachine(name: String, snapshot: String?, autoSuspendSeconds: Int?) async throws -> BoxdMachine {
        try await port(for: name).createMachine(name: name, snapshot: snapshot, autoSuspendSeconds: autoSuspendSeconds)
    }

    public func getMachine(name: String) async throws -> BoxdMachine {
        try await port(for: name).getMachine(name: name)
    }

    /// The boxd machines only: an ssh machine is never swept or followed.
    public func listMachines() async throws -> [BoxdMachine] {
        try await boxd.listMachines()
    }

    public func resume(name: String) async throws { try await port(for: name).resume(name: name) }
    public func wake(name: String) async throws { try await port(for: name).wake(name: name) }
    public func start(name: String) async throws { try await port(for: name).start(name: name) }
    public func stop(name: String) async throws { try await port(for: name).stop(name: name) }
    public func remove(name: String) async throws { try await port(for: name).remove(name: name) }

    public func saveSnapshot(machine: String, name: String) async throws {
        try await port(for: machine).saveSnapshot(machine: machine, name: name)
    }

    public func listSnapshots() async throws -> [BoxdSnapshot] {
        try await boxd.listSnapshots()
    }

    public func exec(name: String, command: String, timeout: TimeInterval) async throws -> ShellCommand.Result {
        try await port(for: name).exec(name: name, command: command, timeout: timeout)
    }

    public func upload(name: String, remotePath: String, data: Data, onEvent: @escaping @Sendable (BoxdUploadEvent) -> Void) async throws {
        try await port(for: name).upload(name: name, remotePath: remotePath, data: data, onEvent: onEvent)
    }

    public func isAvailable() async -> Bool {
        await boxd.isAvailable()
    }

    public func hostProfile(name: String) async -> RemoteHostProfile? {
        await ssh.profile(for: name)
    }

    public func bridgeChannel(name: String, remoteHome: String) async throws -> any BridgeChannel {
        try await port(for: name).bridgeChannel(name: name, remoteHome: remoteHome)
    }
}
