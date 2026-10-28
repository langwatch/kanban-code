import Foundation

/// One rush host as `rush session info|list|start --json` prints it.
public struct RushSessionInfo: Decodable, Sendable, Equatable {
    public let id: String
    public let sessionId: String
    public let cwd: String
    public let name: String?
    public let state: String
    public let alive: Bool
    /// rush ended the host between turns (it rests a few seconds after a
    /// turn ends). The session is still open: a message wakes it.
    public var sleeping: Bool
    /// Messages waiting for the turn to end, oldest first; the host sends
    /// them when it ends.
    public let queue: [String]
    /// The host process and the assistant it runs, for telling which
    /// session a process belongs to.
    public var hostPid: Int?
    public var claudePid: Int?
    /// `--meta` pairs given at start, e.g. `kanban_card`.
    public var meta: [String: String]?
    /// What a blocked session waits on, as rush words it: "asks: <question>"
    /// for a question, "<Tool> <argument>" for a permission.
    public var needs: String?
    /// The model the hosted assistant runs, such as `claude-opus-5-5[1m]`.
    public var model: String?

    public init(id: String, sessionId: String, cwd: String, name: String? = nil, state: String, alive: Bool,
                queue: [String] = []) {
        self.id = id
        self.sessionId = sessionId
        self.cwd = cwd
        self.name = name
        self.state = state
        self.alive = alive
        self.sleeping = false
        self.queue = queue
    }

    enum CodingKeys: String, CodingKey { case id, sessionId, cwd, name, state, alive, sleeping, queue, hostPid, claudePid, meta, needs, model }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        sessionId = try c.decodeIfPresent(String.self, forKey: .sessionId) ?? ""
        cwd = try c.decodeIfPresent(String.self, forKey: .cwd) ?? ""
        name = try c.decodeIfPresent(String.self, forKey: .name)
        state = try c.decodeIfPresent(String.self, forKey: .state) ?? "stopped"
        alive = try c.decodeIfPresent(Bool.self, forKey: .alive) ?? false
        sleeping = (try? c.decodeIfPresent(Bool.self, forKey: .sleeping)) ?? false
        queue = try c.decodeIfPresent([String].self, forKey: .queue) ?? []
        hostPid = try? c.decodeIfPresent(Int.self, forKey: .hostPid)
        claudePid = try? c.decodeIfPresent(Int.self, forKey: .claudePid)
        meta = try? c.decodeIfPresent([String: String].self, forKey: .meta)
        needs = try? c.decodeIfPresent(String.self, forKey: .needs)
        model = try? c.decodeIfPresent(String.self, forKey: .model)
    }

    /// The session is open on its card: its host runs, or rush put it to
    /// sleep between turns. A stopped one is not.
    public var isOpen: Bool { alive || sleeping && state != "stopped" }

    /// What the session waits on, while it is blocked.
    public var blockedOn: String? { alive && state == "blocked" ? needs : nil }

    /// Claude is running a turn or waiting on a permission answer.
    public var isBusy: Bool { alive && (state == "working" || state == "blocked" || state == "starting") }
}

/// What `rush session start` needs to run a card's Claude session.
public struct RushStartRequest: Sendable, Equatable {
    public var cwd: String
    public var sessionId: String
    public var resume: Bool
    public var name: String?
    public var prompt: String?
    public var imagePaths: [String]
    public var env: [String: String]
    public var model: String?
    public var permissionMode: String?
    /// Runs in place of `claude`.
    public var binary: String?
    public var meta: [String: String]

    public init(
        cwd: String,
        sessionId: String,
        resume: Bool,
        name: String? = nil,
        prompt: String? = nil,
        imagePaths: [String] = [],
        env: [String: String] = [:],
        model: String? = nil,
        permissionMode: String? = nil,
        binary: String? = nil,
        meta: [String: String] = [:]
    ) {
        self.cwd = cwd
        self.sessionId = sessionId
        self.resume = resume
        self.name = name
        self.prompt = prompt
        self.imagePaths = imagePaths
        self.env = env
        self.model = model
        self.permissionMode = permissionMode
        self.binary = binary
        self.meta = meta
    }
}

public struct RushCommandFailed: Error, LocalizedError {
    public let arguments: [String]
    public let message: String

    public var errorDescription: String? { "rush \(arguments.first ?? "") failed: \(message)" }

    /// Whether a `queue send` or `queue remove` failed because the message
    /// was no longer in the queue: rush sent it when the turn ended, or
    /// another client moved it. The host says "that message has already
    /// been sent"; the CLI, which reads the queue first, says "no such
    /// message in the queue".
    public var messageLeftQueue: Bool {
        message.contains("already been sent") || message.contains("no such message in the queue")
    }
}

/// Drives rush hosts through the `rush session` CLI, on this machine or,
/// through a bridge, on a machine that runs cards for this one.
public final class RushCliAdapter: @unchecked Sendable {
    /// Path of the rush binary, or nil to look it up on every call.
    private let executable: String?
    private let scratchDirectory: String
    /// The machine the hosts run on, nil for this one.
    private let remote: (any RemoteCommandRunner)?

    public init(executable: String? = nil, scratchDirectory: String? = nil) {
        self.executable = executable
        self.scratchDirectory = scratchDirectory
            ?? (NSHomeDirectory() as NSString).appendingPathComponent(".kanban-code/tmp/rush")
        self.remote = nil
    }

    /// rush on another machine: every command goes through `runner`, and
    /// image files of this machine are copied into `scratchDirectory` there
    /// before rush gets their paths.
    public init(remote runner: any RemoteCommandRunner, executable: String, scratchDirectory: String) {
        self.executable = executable
        self.scratchDirectory = scratchDirectory
        self.remote = runner
    }

    public var isRemote: Bool { remote != nil }

    /// rush, or agtop, the name it had before it was renamed, for a machine
    /// that has only the older build.
    public static func findExecutable() -> String? {
        ShellCommand.findExecutable("rush") ?? ShellCommand.findExecutable("agtop")
    }

    /// Whether `executable` is rush rather than an agtop build from before
    /// the rename. The two differ in a few commands: rush opens one session
    /// alone without `--solo`, names the agent to start, and edits a queue
    /// with `rush queue` instead of `agtop session queue`.
    public static func isRush(_ executable: String) -> Bool {
        (executable as NSString).lastPathComponent.hasPrefix("rush")
    }

    /// The command that shows session `id` alone, full width.
    public static func openArguments(executable: String, id: String) -> [String] {
        isRush(executable) ? [executable, "open", id] : [executable, "open", id, "--solo"]
    }

    /// `openArguments` with the binary this machine has.
    public static func openCommand(id: String) -> [String] {
        openArguments(executable: findExecutable() ?? "rush", id: id)
    }

    /// Turns off copying a selection as a drag ends, for rush and for agtop:
    /// the card's terminal copies with cmd+c.
    public static let copyOnSelectOff = "RUSH_COPY_ON_SELECT=0 AGTOP_COPY_ON_SELECT=0"

    /// Shell for another machine that shows session `id` alone, with rush
    /// when the machine has it and agtop otherwise.
    public static func remoteOpenScript(id: String) -> String {
        let quoted = shellQuote(id)
        return "if command -v rush >/dev/null 2>&1; then exec rush open \(quoted); "
            + "else exec agtop open \(quoted) --solo; fi"
    }

    /// Arguments that send now (`send`) or drop (`remove`) the queued
    /// message at `index`, for the binary at `executable`.
    public static func queueArguments(executable: String, action: String, id: String, index: Int, was: String) -> [String] {
        isRush(executable)
            ? ["queue", action, id, String(index), "--was", was]
            : ["session", "queue", id, action, String(index), "--was", was]
    }

    public var isAvailable: Bool {
        if remote != nil { return true }
        return resolvedExecutable().map(FileManager.default.isExecutableFile(atPath:)) ?? false
    }

    private func resolvedExecutable() -> String? {
        executable ?? Self.findExecutable()
    }

    /// Arguments for `rush session start`, the prompt already written to
    /// `promptFile` (`-` for stdin).
    /// rush runs other agents too, so it is told the agent is Claude Code.
    /// `human` marks the first prompt as typed by the human, for a rush
    /// that keeps that record.
    public static func startArguments(_ request: RushStartRequest, promptFile: String?, rush: Bool = false,
                                      human: Bool = false) -> [String] {
        var args = ["session", "start", "--cwd", request.cwd, "--session-id", request.sessionId]
        if rush { args += ["--agent", "claude"] }
        if request.resume { args.append("--resume") }
        if let name = request.name, !name.isEmpty { args += ["--name", name] }
        if let promptFile {
            args += ["--prompt-file", promptFile]
            if human { args.append("--human") }
        }
        for path in request.imagePaths { args += ["--image", path] }
        for key in request.env.keys.sorted() { args += ["--env", "\(key)=\(request.env[key]!)"] }
        if let model = request.model, !model.isEmpty { args += ["--model", model] }
        if let mode = request.permissionMode, !mode.isEmpty { args += ["--permission-mode", mode] }
        if let binary = request.binary, !binary.isEmpty { args += ["--binary", binary] }
        for key in request.meta.keys.sorted() { args += ["--meta", "\(key)=\(request.meta[key]!)"] }
        args.append("--json")
        return args
    }

    @discardableResult
    public func start(_ request: RushStartRequest, human: Bool = false) async throws -> RushSessionInfo {
        var request = request
        if case .projectRoot(let root) = await ensureDirectory(request.cwd) {
            // The conversation goes on in the project root rather than not at all.
            request.cwd = root
        }
        request.imagePaths = try await machinePaths(of: request.imagePaths)
        let prompt = request.prompt.flatMap { $0.isEmpty ? nil : $0 }
        let marksHuman = human && prompt != nil ? await supportsHumanRecord() : false
        let args = Self.startArguments(
            request, promptFile: prompt == nil ? nil : "-", rush: resolvedExecutable().map(Self.isRush) ?? false,
            human: marksHuman)
        let result = try await exec(args, stdin: prompt, timeout: 60)
        guard result.succeeded else {
            let message = Self.errorMessage(result)
            throw RushCommandFailed(
                arguments: Array(args.dropFirst()),
                message: SessionDirectory.isMissingCwdError(message)
                    ? SessionDirectory.missingMessage(request.cwd, outcome: .missing) : message)
        }
        return try JSONDecoder().decode(RushSessionInfo.self, from: Data(result.stdout.utf8))
    }

    /// Sends a message. A busy session queues it; `now` delivers it mid-turn,
    /// for Claude to read at its next step. Images always go at once. A
    /// stopped host is started again with `--resume`.
    /// `human` marks a message the human typed and sent himself, for a rush
    /// that keeps that record (`--human`); an older rush sends it unmarked.
    public func send(id: String, text: String, imagePaths: [String] = [], now: Bool = false, human: Bool = false) async throws {
        var args = ["session", "send", id]
        if now { args.append("--now") }
        if human, await supportsHumanRecord() { args.append("--human") }
        for path in try await machinePaths(of: imagePaths) { args += ["--image", path] }
        var result = try await exec(args, stdin: text, timeout: 60)
        // A stopped host starts again in its cwd; a worktree deleted under it
        // is added again from its branch, then the message goes once more.
        if !result.succeeded, SessionDirectory.isMissingCwdError(Self.errorMessage(result)),
           let cwd = (try? await info(id: id))?.cwd, !cwd.isEmpty {
            let outcome = await ensureDirectory(cwd)
            guard case .restored = outcome else {
                throw RushCommandFailed(arguments: args, message: SessionDirectory.missingMessage(cwd, outcome: outcome))
            }
            result = try await exec(args, stdin: text, timeout: 60)
        }
        guard result.succeeded else {
            throw RushCommandFailed(arguments: args, message: Self.errorMessage(result))
        }
    }

    /// Makes sure `dir` is there on the machine the hosts run on, adding a
    /// deleted worktree again from its branch (see `SessionDirectory`).
    public func ensureDirectory(_ dir: String, branch: String? = nil) async -> SessionDirectory.Outcome {
        guard !dir.isEmpty else { return .present }
        guard let remote else { return await SessionDirectory.ensureLocal(dir: dir, branch: branch) }
        let script = SessionDirectory.ensureScript(dir: dir, branch: branch)
        // A machine that did not answer is left to rush, which says why.
        guard let result = try? await remote.exec(["/bin/sh", "-c", script], stdin: nil, cwd: nil, timeout: 120),
              result.succeeded else {
            return .present
        }
        let outcome = SessionDirectory.parse(result.stdout)
        SessionDirectory.log(dir: dir, outcome: outcome)
        return outcome
    }

    /// Settles what the session waits on: `text` answers its question, a
    /// tool call waiting for permission is allowed, and `deny` declines
    /// either (`text` then goes to the agent as the reason). `request` is
    /// the tool call id the answer is meant for. Returns false when the
    /// binary has no `session answer` command (agtop, older rush).
    @discardableResult
    public func answer(id: String, text: String, deny: Bool = false, request: String? = nil) async throws -> Bool {
        var args = ["session", "answer", id]
        if deny { args.append("--deny") }
        if let request, !request.isEmpty { args += ["--request", request] }
        let result = try await exec(args, stdin: text, timeout: 30)
        if result.succeeded { return true }
        let message = Self.errorMessage(result)
        if message.contains("unknown session command") { return false }
        throw RushCommandFailed(arguments: args, message: message)
    }

    // MARK: - The human's messages

    private static let humanSupport = HumanSupportCache()

    /// Whether this rush has `session send --human` and `session human`.
    /// Read from its help text, and read again every few minutes, since
    /// rush is updated while the app runs.
    public func supportsHumanRecord() async -> Bool {
        guard let bin = resolvedExecutable() else { return false }
        let key = remote == nil ? bin : "\(bin)|remote:\(ObjectIdentifier(remote! as AnyObject).hashValue)"
        if let known = Self.humanSupport.value(key) { return known }
        guard let result = try? await exec(["session", "--help"], stdin: nil, timeout: 15) else { return false }
        let supported = Self.helpListsHumanRecord(result.stdout + "\n" + result.stderr)
        Self.humanSupport.set(key, supported)
        return supported
    }

    static func helpListsHumanRecord(_ help: String) -> Bool {
        help.contains("--human") && help.contains("session human")
    }

    /// The messages of the session the human typed himself, newest last, as
    /// `rush session human <id> --json` prints them. Nil when this rush
    /// keeps no such record.
    public func humanMessages(id: String) async -> [RushHumanMessage]? {
        guard await supportsHumanRecord(),
              let result = try? await exec(["session", "human", id, "--json"], stdin: nil, timeout: 20),
              result.succeeded else { return nil }
        return Self.parseHumanMessages(result.stdout)
    }

    static func parseHumanMessages(_ output: String) -> [RushHumanMessage]? {
        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty || trimmed == "null" { return [] }
        return try? JSONDecoder().decode([RushHumanMessage].self, from: Data(trimmed.utf8))
    }

    /// Sends the queued message at `index` now. `was` is its text as last
    /// read, so the host still finds it if the queue moved.
    public func sendQueued(id: String, index: Int, was: String) async throws {
        _ = try await run(try queueArguments("send", id: id, index: index, was: was), timeout: 30)
    }

    /// Drops the queued message at `index` (see `sendQueued`).
    public func removeQueued(id: String, index: Int, was: String) async throws {
        _ = try await run(try queueArguments("remove", id: id, index: index, was: was), timeout: 30)
    }

    private func queueArguments(_ action: String, id: String, index: Int, was: String) throws -> [String] {
        guard let bin = resolvedExecutable() else { throw Self.notInstalled }
        return Self.queueArguments(executable: bin, action: action, id: id, index: index, was: was)
    }

    public func interrupt(id: String) async throws {
        _ = try await run(["session", "interrupt", id], timeout: 15)
    }

    public func stop(id: String) async throws {
        _ = try await run(["session", "stop", id], timeout: 30)
    }

    /// The host, or nil when rush has no session with that id.
    public func info(id: String) async throws -> RushSessionInfo? {
        let result = try await exec(["session", "info", id, "--json"], stdin: nil, timeout: 15)
        if !result.succeeded {
            if result.stdout.contains("not found") || result.stderr.contains("not found") { return nil }
            throw RushCommandFailed(arguments: ["info", id], message: Self.errorMessage(result))
        }
        return try JSONDecoder().decode(RushSessionInfo.self, from: Data(result.stdout.utf8))
    }

    /// Every host rush knows, stopped ones included.
    public func list() async throws -> [RushSessionInfo] {
        let out = try await run(["session", "list", "--json"], timeout: 15)
        let trimmed = out.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty || trimmed == "null" { return [] }
        return try JSONDecoder().decode([RushSessionInfo].self, from: Data(trimmed.utf8))
    }

    /// `rush --version`, such as `rush b06e734 (Sep 30)`.
    public func version() async -> String? {
        guard let result = try? await exec(["--version"], stdin: nil, timeout: 15), result.succeeded else { return nil }
        let line = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        return line.isEmpty ? nil : line
    }

    /// The build a `--version` line names, without the date after it, which
    /// is the local day of the machine that answered: `rush b06e734 (Sep 30)`
    /// and `rush b06e734 (Sep 29)` are the same build.
    public static func build(ofVersion version: String) -> String {
        version.split(separator: " ").prefix(2).joined(separator: " ")
    }

    // MARK: - Helpers

    public static let notInstalled = RushCommandFailed(
        arguments: [],
        message: "rush is not installed (go install github.com/0xdeafcafe/rush/cmd/rush@latest)"
    )

    private func run(_ args: [String], timeout: TimeInterval) async throws -> String {
        let result = try await exec(args, stdin: nil, timeout: timeout)
        guard result.succeeded else {
            throw RushCommandFailed(arguments: Array(args.dropFirst()), message: Self.errorMessage(result))
        }
        return result.stdout
    }

    /// Runs rush with `args`, here or on the machine. Text for stdin goes
    /// through a scratch file here, so a long prompt never fills a pipe.
    private func exec(_ args: [String], stdin: String?, timeout: TimeInterval) async throws -> ShellCommand.Result {
        guard let bin = resolvedExecutable() else { throw Self.notInstalled }
        if let remote {
            return try await remote.exec([bin] + args, stdin: stdin, cwd: nil, timeout: timeout)
        }
        guard let stdin else {
            return try await ShellCommand.run(bin, arguments: args, timeout: timeout)
        }
        let file = try writeScratch(stdin)
        defer { try? FileManager.default.removeItem(atPath: file) }
        let command = ([bin] + args).map(Self.shellQuote).joined(separator: " ") + " < " + Self.shellQuote(file)
        return try await ShellCommand.run("/bin/sh", arguments: ["-c", command], timeout: timeout)
    }

    /// Paths rush can open: the same paths here, and on a machine a copy of
    /// each file of this machine (a path that is not a file here is taken
    /// as one on the machine already).
    private func machinePaths(of paths: [String]) async throws -> [String] {
        guard let remote, !paths.isEmpty else { return paths }
        let folder = "\(scratchDirectory)/\(UUID().uuidString.lowercased().prefix(8))"
        var result: [String] = []
        for (index, path) in paths.enumerated() {
            guard let data = FileManager.default.contents(atPath: path) else {
                result.append(path)
                continue
            }
            let ext = (path as NSString).pathExtension
            let target = "\(folder)/\(index + 1).\(ext.isEmpty ? "png" : ext)"
            try await remote.put(path: target, data: data, mode: nil)
            result.append(target)
        }
        return result
    }

    private func writeScratch(_ text: String) throws -> String {
        try FileManager.default.createDirectory(atPath: scratchDirectory, withIntermediateDirectories: true)
        let path = (scratchDirectory as NSString).appendingPathComponent("\(UUID().uuidString).txt")
        try text.write(toFile: path, atomically: true, encoding: .utf8)
        return path
    }

    private static func errorMessage(_ result: ShellCommand.Result) -> String {
        let text = [result.stderr, result.stdout]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty } ?? "exit \(result.exitCode)"
        if let data = text.data(using: .utf8),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let error = obj["error"] as? String {
            return error
        }
        return text
    }

    static func shellQuote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

/// What `supportsHumanRecord` last found, by rush binary.
private final class HumanSupportCache: @unchecked Sendable {
    private let lock = NSLock()
    private var known: [String: (supported: Bool, at: Date)] = [:]
    private let lifetime: TimeInterval = 300

    func value(_ key: String) -> Bool? {
        lock.withLock {
            guard let entry = known[key], Date.now.timeIntervalSince(entry.at) < lifetime else { return nil }
            return entry.supported
        }
    }

    func set(_ key: String, _ supported: Bool) {
        lock.withLock { known[key] = (supported, .now) }
    }
}
