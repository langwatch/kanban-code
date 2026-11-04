import Foundation

/// Sends each tmux command to the server that owns the session: the local
/// tmux for local cards, the bridge of a boxd machine for remote cards, and
/// the rush host for sessions named `rush-<id>` (see `RushSessionName`).
///
/// Session names are looked up in a `RemoteSessionRegistry`. A name the
/// registry does not know is local. A name on a machine that is not
/// connected throws `RemoteMachineUnavailable`, so a paused machine never
/// falls through to the local tmux server.
public final class RoutingTmuxAdapter: TmuxManagerPort, @unchecked Sendable {
    public let local: TmuxAdapter
    public let registry: RemoteSessionRegistry
    public let rush: RushCliAdapter

    public init(
        local: TmuxAdapter = TmuxAdapter(),
        registry: RemoteSessionRegistry = RemoteSessionRegistry(),
        rush: RushCliAdapter = RushCliAdapter()
    ) {
        self.local = local
        self.registry = registry
        self.rush = rush
    }

    /// The adapter that owns `sessionName`: the local one, or the bridge
    /// adapter of its machine.
    public func adapter(for sessionName: String) throws -> TmuxAdapter {
        guard let machine = registry.machine(forSession: sessionName) else { return local }
        guard let remote = registry.tmux(for: machine), registry.state(of: machine)?.isConnected == true else {
            throw RemoteMachineUnavailable(
                machineName: machine,
                state: registry.state(of: machine) ?? .unreachable
            )
        }
        return remote
    }

    /// The rush that hosts a `rush-<id>` (or `agtop-<id>`) session: the one of its machine
    /// when the registry maps the name to one, the local one otherwise.
    public func rush(forSession sessionName: String) throws -> RushCliAdapter {
        guard let machine = registry.machine(forSession: sessionName) else { return rush }
        guard registry.state(of: machine)?.isConnected == true, let remote = registry.rush(for: machine) else {
            throw RemoteMachineUnavailable(
                machineName: machine,
                state: registry.state(of: machine) ?? .unreachable
            )
        }
        return remote
    }

    public func isRemote(_ sessionName: String) -> Bool {
        registry.machine(forSession: sessionName) != nil
    }

    // MARK: - TmuxManagerPort

    /// Local sessions, open rush hosts (running, or asleep between
    /// turns), plus the sessions of every registered machine. A connected
    /// machine is listed live; the others keep their last list.
    public func listSessions() async throws -> [TmuxSession] {
        var result = try await local.listSessions()
        if rush.isAvailable, let hosts = try? await rush.list() {
            for host in hosts where host.isOpen {
                result.append(TmuxSession(name: RushSessionName.name(for: host), path: host.cwd, rushQueue: host.queue, rushNeeds: host.blockedOn, rushLimit: host.usageLimit()))
            }
        }
        var seen = Set(result.map(\.name))
        for machine in registry.machineNames {
            let sessions: [TmuxSession]
            if let remote = registry.tmux(for: machine), registry.state(of: machine)?.isConnected == true,
               var live = try? await remote.listSessions() {
                // Only the hosts this master started there: another master
                // on the same machine runs its own.
                if let remoteRush = registry.rush(for: machine), let hosts = try? await remoteRush.list() {
                    let ours = registry.sessionNames(on: machine)
                    for host in hosts where host.isOpen {
                        let name = RushSessionName.name(for: host)
                        if ours.contains(name) {
                            live.append(TmuxSession(name: name, path: host.cwd, rushQueue: host.queue, rushNeeds: host.blockedOn, rushLimit: host.usageLimit()))
                        }
                    }
                }
                registry.recordSessions(live, on: machine)
                sessions = live
            } else {
                sessions = registry.knownSessions(on: machine)
            }
            for session in sessions where !seen.contains(session.name) {
                seen.insert(session.name)
                result.append(session)
            }
        }
        return result
    }

    public func createSession(name: String, path: String, command: String?) async throws {
        try await createSession(name: name, path: path, command: command, environment: [:])
    }

    public func createSession(name: String, path: String, command: String?, environment: [String: String]) async throws {
        if RushSessionName.isRush(name) {
            throw RushCommandFailed(arguments: ["start"], message: "rush sessions start with RushCliAdapter.start")
        }
        try await adapter(for: name).createSession(name: name, path: path, command: command, environment: environment)
    }

    public func killSession(name: String) async throws {
        if let id = RushSessionName.rushId(fromName: name) {
            try await rush(forSession: name).stop(id: id)
            registry.unassign(sessionName: name)
            return
        }
        let target = try adapter(for: name)
        try await target.killSession(name: name)
        registry.unassign(sessionName: name)
    }

    public func sendInterrupt(sessionName: String) async throws {
        if let id = RushSessionName.rushId(fromName: sessionName) { return try await rush(forSession: sessionName).interrupt(id: id) }
        try await adapter(for: sessionName).sendInterrupt(sessionName: sessionName)
    }

    public func sendEscape(sessionName: String) async throws {
        if let id = RushSessionName.rushId(fromName: sessionName) { return try await rush(forSession: sessionName).interrupt(id: id) }
        try await adapter(for: sessionName).sendEscape(sessionName: sessionName)
    }

    public func findSessionForWorktree(sessions: [TmuxSession], worktreePath: String, branch: String?) -> TmuxSession? {
        local.findSessionForWorktree(sessions: sessions, worktreePath: worktreePath, branch: branch)
    }

    public func sendPrompt(to sessionName: String, text: String) async throws {
        if let id = RushSessionName.rushId(fromName: sessionName) { return try await rush(forSession: sessionName).send(id: id, text: text) }
        try await adapter(for: sessionName).sendPrompt(to: sessionName, text: text)
    }

    public func pastePrompt(to sessionName: String, text: String) async throws {
        if let id = RushSessionName.rushId(fromName: sessionName) { return try await rush(forSession: sessionName).send(id: id, text: text) }
        try await adapter(for: sessionName).pastePrompt(to: sessionName, text: text)
    }

    public func pastePrompt(to sessionName: String, text: String, abortIf: PromptAbortCheck?) async throws {
        if let id = RushSessionName.rushId(fromName: sessionName) { return try await rush(forSession: sessionName).send(id: id, text: text) }
        try await adapter(for: sessionName).pastePrompt(to: sessionName, text: text, abortIf: abortIf)
    }

    public func interruptPrompt(to sessionName: String, text: String) async throws {
        if let id = RushSessionName.rushId(fromName: sessionName) {
            return try await rush(forSession: sessionName).send(id: id, text: text, now: true)
        }
        try await adapter(for: sessionName).interruptPrompt(to: sessionName, text: text)
    }

    public func interruptPrompt(to sessionName: String, text: String, abortIf: PromptAbortCheck?) async throws {
        if let id = RushSessionName.rushId(fromName: sessionName) {
            return try await rush(forSession: sessionName).send(id: id, text: text, now: true)
        }
        try await adapter(for: sessionName).interruptPrompt(to: sessionName, text: text, abortIf: abortIf)
    }

    @discardableResult
    public func clearComposer(sessionName: String) async throws -> Bool {
        if RushSessionName.isRush(sessionName) { return false }
        return try await adapter(for: sessionName).clearComposer(sessionName: sessionName)
    }

    /// rush has no composer to type into from outside, so pasted text is
    /// sent as a message.
    public func pasteText(to sessionName: String, text: String) async throws {
        if let id = RushSessionName.rushId(fromName: sessionName) { return try await rush(forSession: sessionName).send(id: id, text: text) }
        try await adapter(for: sessionName).pasteText(to: sessionName, text: text)
    }

    public func submitPrompt(to sessionName: String) async throws {
        if RushSessionName.isRush(sessionName) { return }
        try await adapter(for: sessionName).submitPrompt(to: sessionName)
    }

    /// Empty for rush sessions: callers that read the pane have rush
    /// branches that ask the host instead.
    public func capturePane(sessionName: String) async throws -> String {
        if RushSessionName.isRush(sessionName) { return "" }
        return try await adapter(for: sessionName).capturePane(sessionName: sessionName)
    }

    public func sendBracketedPaste(to sessionName: String) async throws {
        if RushSessionName.isRush(sessionName) { return }
        try await adapter(for: sessionName).sendBracketedPaste(to: sessionName)
    }

    public func isAvailable() async -> Bool {
        await local.isAvailable()
    }
}

/// Thrown when a tmux command targets a session on a machine that is paused,
/// unreachable or destroyed.
public struct RemoteMachineUnavailable: Error, LocalizedError, Equatable {
    public let machineName: String
    public let state: RemoteMachineState

    public init(machineName: String, state: RemoteMachineState) {
        self.machineName = machineName
        self.state = state
    }

    public var errorDescription: String? {
        "Machine \(machineName) is \(state.label.lowercased())"
    }
}
