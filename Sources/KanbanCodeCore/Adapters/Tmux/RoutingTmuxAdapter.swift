import Foundation

/// Sends each tmux command to the server that owns the session: the local
/// tmux for local cards, the bridge of a boxd machine for remote cards, and
/// the agtop host for sessions named `agtop-<id>` (see `AgtopSessionName`).
///
/// Session names are looked up in a `RemoteSessionRegistry`. A name the
/// registry does not know is local. A name on a machine that is not
/// connected throws `RemoteMachineUnavailable`, so a paused machine never
/// falls through to the local tmux server.
public final class RoutingTmuxAdapter: TmuxManagerPort, @unchecked Sendable {
    public let local: TmuxAdapter
    public let registry: RemoteSessionRegistry
    public let agtop: AgtopCliAdapter

    public init(
        local: TmuxAdapter = TmuxAdapter(),
        registry: RemoteSessionRegistry = RemoteSessionRegistry(),
        agtop: AgtopCliAdapter = AgtopCliAdapter()
    ) {
        self.local = local
        self.registry = registry
        self.agtop = agtop
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

    public func isRemote(_ sessionName: String) -> Bool {
        registry.machine(forSession: sessionName) != nil
    }

    // MARK: - TmuxManagerPort

    /// Local sessions, live agtop hosts, plus the sessions of every
    /// registered machine. A connected machine is listed live; the others
    /// keep their last list.
    public func listSessions() async throws -> [TmuxSession] {
        var result = try await local.listSessions()
        if agtop.isAvailable, let hosts = try? await agtop.list() {
            for host in hosts where host.alive {
                result.append(TmuxSession(name: AgtopSessionName.name(agtopId: host.id), path: host.cwd, agtopQueue: host.queue))
            }
        }
        var seen = Set(result.map(\.name))
        for machine in registry.machineNames {
            let sessions: [TmuxSession]
            if let remote = registry.tmux(for: machine), registry.state(of: machine)?.isConnected == true,
               let live = try? await remote.listSessions() {
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
        if AgtopSessionName.isAgtop(name) {
            throw AgtopCommandFailed(arguments: ["start"], message: "agtop sessions start with AgtopCliAdapter.start")
        }
        try await adapter(for: name).createSession(name: name, path: path, command: command)
    }

    public func killSession(name: String) async throws {
        if let id = AgtopSessionName.agtopId(fromName: name) { return try await agtop.stop(id: id) }
        let target = try adapter(for: name)
        try await target.killSession(name: name)
        registry.unassign(sessionName: name)
    }

    public func sendInterrupt(sessionName: String) async throws {
        if let id = AgtopSessionName.agtopId(fromName: sessionName) { return try await agtop.interrupt(id: id) }
        try await adapter(for: sessionName).sendInterrupt(sessionName: sessionName)
    }

    public func sendEscape(sessionName: String) async throws {
        if let id = AgtopSessionName.agtopId(fromName: sessionName) { return try await agtop.interrupt(id: id) }
        try await adapter(for: sessionName).sendEscape(sessionName: sessionName)
    }

    public func findSessionForWorktree(sessions: [TmuxSession], worktreePath: String, branch: String?) -> TmuxSession? {
        local.findSessionForWorktree(sessions: sessions, worktreePath: worktreePath, branch: branch)
    }

    public func sendPrompt(to sessionName: String, text: String) async throws {
        if let id = AgtopSessionName.agtopId(fromName: sessionName) { return try await agtop.send(id: id, text: text) }
        try await adapter(for: sessionName).sendPrompt(to: sessionName, text: text)
    }

    public func pastePrompt(to sessionName: String, text: String) async throws {
        if let id = AgtopSessionName.agtopId(fromName: sessionName) { return try await agtop.send(id: id, text: text) }
        try await adapter(for: sessionName).pastePrompt(to: sessionName, text: text)
    }

    public func pastePrompt(to sessionName: String, text: String, abortIf: PromptAbortCheck?) async throws {
        if let id = AgtopSessionName.agtopId(fromName: sessionName) { return try await agtop.send(id: id, text: text) }
        try await adapter(for: sessionName).pastePrompt(to: sessionName, text: text, abortIf: abortIf)
    }

    public func interruptPrompt(to sessionName: String, text: String) async throws {
        if let id = AgtopSessionName.agtopId(fromName: sessionName) {
            return try await agtop.send(id: id, text: text, now: true)
        }
        try await adapter(for: sessionName).interruptPrompt(to: sessionName, text: text)
    }

    public func interruptPrompt(to sessionName: String, text: String, abortIf: PromptAbortCheck?) async throws {
        if let id = AgtopSessionName.agtopId(fromName: sessionName) {
            return try await agtop.send(id: id, text: text, now: true)
        }
        try await adapter(for: sessionName).interruptPrompt(to: sessionName, text: text, abortIf: abortIf)
    }

    @discardableResult
    public func clearComposer(sessionName: String) async throws -> Bool {
        if AgtopSessionName.isAgtop(sessionName) { return false }
        return try await adapter(for: sessionName).clearComposer(sessionName: sessionName)
    }

    /// agtop has no composer to type into from outside, so pasted text is
    /// sent as a message.
    public func pasteText(to sessionName: String, text: String) async throws {
        if let id = AgtopSessionName.agtopId(fromName: sessionName) { return try await agtop.send(id: id, text: text) }
        try await adapter(for: sessionName).pasteText(to: sessionName, text: text)
    }

    public func submitPrompt(to sessionName: String) async throws {
        if AgtopSessionName.isAgtop(sessionName) { return }
        try await adapter(for: sessionName).submitPrompt(to: sessionName)
    }

    /// Empty for agtop sessions: callers that read the pane have agtop
    /// branches that ask the host instead.
    public func capturePane(sessionName: String) async throws -> String {
        if AgtopSessionName.isAgtop(sessionName) { return "" }
        return try await adapter(for: sessionName).capturePane(sessionName: sessionName)
    }

    public func sendBracketedPaste(to sessionName: String) async throws {
        if AgtopSessionName.isAgtop(sessionName) { return }
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
