import Foundation

/// One agtop host as `agtop session info|list|start --json` prints it.
public struct AgtopSessionInfo: Decodable, Sendable, Equatable {
    public let id: String
    public let sessionId: String
    public let cwd: String
    public let name: String?
    public let state: String
    public let alive: Bool
    /// Messages waiting for the turn to end, oldest first; the host sends
    /// them when it ends.
    public let queue: [String]

    public init(id: String, sessionId: String, cwd: String, name: String? = nil, state: String, alive: Bool,
                queue: [String] = []) {
        self.id = id
        self.sessionId = sessionId
        self.cwd = cwd
        self.name = name
        self.state = state
        self.alive = alive
        self.queue = queue
    }

    enum CodingKeys: String, CodingKey { case id, sessionId, cwd, name, state, alive, queue }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        sessionId = try c.decodeIfPresent(String.self, forKey: .sessionId) ?? ""
        cwd = try c.decodeIfPresent(String.self, forKey: .cwd) ?? ""
        name = try c.decodeIfPresent(String.self, forKey: .name)
        state = try c.decodeIfPresent(String.self, forKey: .state) ?? "stopped"
        alive = try c.decodeIfPresent(Bool.self, forKey: .alive) ?? false
        queue = try c.decodeIfPresent([String].self, forKey: .queue) ?? []
    }

    /// Claude is running a turn or waiting on a permission answer.
    public var isBusy: Bool { alive && (state == "working" || state == "blocked" || state == "starting") }
}

/// What `agtop session start` needs to run a card's Claude session.
public struct AgtopStartRequest: Sendable, Equatable {
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

public struct AgtopCommandFailed: Error, LocalizedError {
    public let arguments: [String]
    public let message: String

    public var errorDescription: String? { "agtop \(arguments.first ?? "") failed: \(message)" }
}

/// Drives agtop hosts through the `agtop session` CLI.
public final class AgtopCliAdapter: @unchecked Sendable {
    /// Path of the agtop binary, or nil to look it up on every call.
    private let executable: String?
    private let scratchDirectory: String

    public init(executable: String? = nil, scratchDirectory: String? = nil) {
        self.executable = executable
        self.scratchDirectory = scratchDirectory
            ?? (NSHomeDirectory() as NSString).appendingPathComponent(".kanban-code/tmp/agtop")
    }

    public static func findExecutable() -> String? {
        ShellCommand.findExecutable("agtop")
    }

    public var isAvailable: Bool {
        resolvedExecutable().map(FileManager.default.isExecutableFile(atPath:)) ?? false
    }

    private func resolvedExecutable() -> String? {
        executable ?? Self.findExecutable()
    }

    /// Arguments for `agtop session start`, the prompt already written to
    /// `promptFile`.
    public static func startArguments(_ request: AgtopStartRequest, promptFile: String?) -> [String] {
        var args = ["session", "start", "--cwd", request.cwd, "--session-id", request.sessionId]
        if request.resume { args.append("--resume") }
        if let name = request.name, !name.isEmpty { args += ["--name", name] }
        if let promptFile { args += ["--prompt-file", promptFile] }
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
    public func start(_ request: AgtopStartRequest) async throws -> AgtopSessionInfo {
        var promptFile: String?
        if let prompt = request.prompt, !prompt.isEmpty {
            promptFile = try writeScratch(prompt)
        }
        defer { if let promptFile { try? FileManager.default.removeItem(atPath: promptFile) } }
        let result = try await run(Self.startArguments(request, promptFile: promptFile), timeout: 60)
        return try JSONDecoder().decode(AgtopSessionInfo.self, from: Data(result.utf8))
    }

    /// Sends a message. A busy session queues it; `now` delivers it mid-turn,
    /// for Claude to read at its next step. Images always go at once. A
    /// stopped host is started again with `--resume`.
    public func send(id: String, text: String, imagePaths: [String] = [], now: Bool = false) async throws {
        let file = try writeScratch(text)
        defer { try? FileManager.default.removeItem(atPath: file) }
        guard let bin = resolvedExecutable() else { throw Self.notInstalled }
        var args = ["session", "send", id]
        if now { args.append("--now") }
        for path in imagePaths { args += ["--image", path] }
        let command = ([bin] + args).map(Self.shellQuote).joined(separator: " ") + " < " + Self.shellQuote(file)
        let result = try await ShellCommand.run("/bin/sh", arguments: ["-c", command], timeout: 60)
        guard result.succeeded else {
            throw AgtopCommandFailed(arguments: args, message: Self.errorMessage(result))
        }
    }

    /// Sends the queued message at `index` now. `was` is its text as last
    /// read, so the host still finds it if the queue moved.
    public func sendQueued(id: String, index: Int, was: String) async throws {
        _ = try await run(["session", "queue", id, "send", String(index), "--was", was], timeout: 30)
    }

    /// Drops the queued message at `index` (see `sendQueued`).
    public func removeQueued(id: String, index: Int, was: String) async throws {
        _ = try await run(["session", "queue", id, "remove", String(index), "--was", was], timeout: 30)
    }

    public func interrupt(id: String) async throws {
        _ = try await run(["session", "interrupt", id], timeout: 15)
    }

    public func stop(id: String) async throws {
        _ = try await run(["session", "stop", id], timeout: 30)
    }

    /// The host, or nil when agtop has no session with that id.
    public func info(id: String) async throws -> AgtopSessionInfo? {
        guard let bin = resolvedExecutable() else { throw Self.notInstalled }
        let result = try await ShellCommand.run(bin, arguments: ["session", "info", id, "--json"], timeout: 15)
        if !result.succeeded {
            if result.stdout.contains("not found") || result.stderr.contains("not found") { return nil }
            throw AgtopCommandFailed(arguments: ["info", id], message: Self.errorMessage(result))
        }
        return try JSONDecoder().decode(AgtopSessionInfo.self, from: Data(result.stdout.utf8))
    }

    /// Every host agtop knows, stopped ones included.
    public func list() async throws -> [AgtopSessionInfo] {
        let out = try await run(["session", "list", "--json"], timeout: 15)
        let trimmed = out.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty || trimmed == "null" { return [] }
        return try JSONDecoder().decode([AgtopSessionInfo].self, from: Data(trimmed.utf8))
    }

    // MARK: - Helpers

    public static let notInstalled = AgtopCommandFailed(
        arguments: [],
        message: "agtop is not installed (go install github.com/0xdeafcafe/agtop/cmd/agtop@latest)"
    )

    private func run(_ args: [String], timeout: TimeInterval) async throws -> String {
        guard let bin = resolvedExecutable() else { throw Self.notInstalled }
        let result = try await ShellCommand.run(bin, arguments: args, timeout: timeout)
        guard result.succeeded else {
            throw AgtopCommandFailed(arguments: Array(args.dropFirst()), message: Self.errorMessage(result))
        }
        return result.stdout
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
