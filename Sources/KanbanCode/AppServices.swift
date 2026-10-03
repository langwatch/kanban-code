import Foundation
import KanbanCodeCore
import KanbanCodeRemoteKit

/// Process-wide handles to the adapters the app builds once in
/// `ContentView.init`. Views that are far from the composition root (the
/// embedded terminal, the app delegate, chat views) reach tmux and the boxd
/// supervisor through here instead of building their own adapters.
enum AppServices {
    /// Answers an attention request from this Mac, with what its vault key
    /// unlocked for the approval; the problem as text when it was not taken.
    nonisolated(unsafe) static var resolveAttention: (@Sendable (String, String, VaultUnsealed?) async -> String?)?
    /// Answers the question or plan a card waits on from the chat; false
    /// when it waits on none.
    nonisolated(unsafe) static var answerCard: (@Sendable (String, String) async -> Bool)?
    /// Boxd machines of the org and whether the boxd CLI answers, as the
    /// launch dialogs last read them; launches from the remote API use them.
    @MainActor static var boxdMachineNames: [String] = []
    @MainActor static var boxdAvailable = true

    nonisolated(unsafe) static var tmux = RoutingTmuxAdapter()
    nonisolated(unsafe) static var remoteRegistry: RemoteSessionRegistry?
    nonisolated(unsafe) static var boxdSupervisor: BoxdMachineSupervisor?

    /// Card menu handlers for the boxd machine of a card, set by the
    /// composition root so menus far from the store can reach the reducer.
    nonisolated(unsafe) static var pauseMachine: (@MainActor (String) -> Void)?
    nonisolated(unsafe) static var destroyMachine: (@MainActor (String) -> Void)?

    /// The command a remote viewer runs for a session, the same way the
    /// card's own terminal decides it: an attach on its machine, rush's own
    /// UI for rush, a tmux attach otherwise.
    @MainActor
    static func terminalCommand(forSession sessionName: String) -> [String] {
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        if let machine = machine(forSession: sessionName),
           let rushId = RushSessionName.rushId(fromName: sessionName),
           let target = sshTargets[machine] {
            let script = TerminalCache.remoteRushScript(
                target: target, id: rushId, readyMarker: remoteReadyMarkerPath(for: sessionName))
            return [shell, "-l", "-c", script]
        }
        if let machine = machine(forSession: sessionName) {
            let script = TerminalCache.remoteAttachScript(
                boxd: boxdPath,
                machine: machine,
                session: sessionName,
                readyMarker: remoteReadyMarkerPath(for: sessionName),
                sshTargets: sshTargets
            )
            return [shell, "-l", "-c", script]
        }
        if let rushId = RushSessionName.rushId(fromName: sessionName) {
            return RushCliAdapter.openCommand(id: rushId)
        }
        return [shell, "-l", "-c", TerminalCache.attachScript(tmux: TerminalCache.tmuxPath, session: sessionName)]
    }

    // MARK: - Cards other masters run

    /// Continues a card on this Mac ("mac"), a peer master or a machine.
    @MainActor
    static func moveCard(_ cardId: String, to target: String) {
        let composition = AppComposition.shared
        Task { @MainActor in
            do {
                try await composition.engine.moveCard(cardId, to: target)
            } catch {
                composition.store.dispatch(.setError("Move failed: \(error.localizedDescription)"))
            }
        }
    }

    /// The card another master owns that has `sessionName` as a terminal:
    /// its owner's machine id and the card id.
    @MainActor
    static func peerCard(forSession sessionName: String) -> (machineId: String, cardId: String)? {
        let state = AppComposition.shared.store.state
        let local = state.localMachineId
        guard !local.isEmpty else { return nil }
        for link in state.links.values {
            guard let owner = link.ownerMachine, owner != local,
                  link.tmuxLink?.allSessionNames.contains(sessionName) == true else { continue }
            return (owner, link.id)
        }
        return nil
    }

    /// Whether the terminal `sessionName` must wait before it starts: its
    /// card names an owner, and this Mac does not know yet whether that is
    /// itself or which peer it is (the identity and peer statuses load after
    /// the board). Started early, the terminal would look for the session
    /// on this Mac.
    @MainActor
    static func terminalWaitsForOwner(_ sessionName: String) -> Bool {
        let state = AppComposition.shared.store.state
        guard let link = state.links.values.first(where: { $0.tmuxLink?.allSessionNames.contains(sessionName) == true }),
              let owner = link.ownerMachine else { return false }
        if state.localMachineId.isEmpty { return true }
        if owner == state.localMachineId { return false }
        return !state.peerStatuses.values.contains { $0.machine?.id == owner }
    }

    /// The shell script a terminal of a card another master owns runs: the
    /// kanban CLI bridges it to the owner's terminal socket, with the
    /// terminal token this Mac holds for that peer, and reconnects when the
    /// link drops.
    @MainActor
    static func peerAttachScript(machineId: String, cardId: String, session: String) -> String? {
        let settings = FileManager.default.contents(atPath: NSHomeDirectory() + "/.kanban-code/settings.json")
            .flatMap { try? JSONDecoder().decode(Settings.self, from: $0) }
        let state = AppComposition.shared.store.state
        let peerId = state.peerStatuses.values.first { $0.machine?.id == machineId }?.peerId
        guard let peer = settings?.peers.first(where: { $0.id == peerId }) else { return nil }
        let quote = { (value: String) in "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'" }
        let cli = cliBundlePath.map { "\($0)/dist/kanban.js" }
            ?? (NSHomeDirectory() + "/Projects/kanban/cli/dist/kanban.js")
        let node = findNode() ?? "node"
        let attach = "KANBAN_REMOTE_URL=\(quote(peer.url)) KANBAN_REMOTE_TOKEN=\(quote(peer.terminalToken ?? peer.token)) "
            + "\(quote(node)) \(quote(cli)) remote attach \(quote(cardId)) --session \(quote(session))"
        return "while :; do \(attach) && break; sleep 2; done; echo 'Session ended.'"
    }

    /// The command a remote viewer of this Mac runs for a terminal of a
    /// card another master owns.
    @MainActor
    static func peerTerminalCommand(machineId: String, cardId: String, session: String) -> [String]? {
        guard let script = peerAttachScript(machineId: machineId, cardId: cardId, session: session) else { return nil }
        return [ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh", "-l", "-c", script]
    }

    static var boxdPath: String {
        ShellCommand.findExecutable("boxd") ?? "boxd"
    }

    /// Ssh machines of the settings, machine name to ssh target, for the
    /// terminals that attach to sessions on them.
    static var sshTargets: [String: String] {
        let path = NSHomeDirectory() + "/.kanban-code/settings.json"
        let settings = FileManager.default.contents(atPath: path).flatMap { try? JSONDecoder().decode(Settings.self, from: $0) }
        let machines = settings?.boxd?.sshMachines ?? []
        var targets: [String: String] = [:]
        for machine in machines where machine.isComplete { targets[machine.name] = machine.target }
        return targets
    }

    // MARK: - Remote session readiness

    /// Directory of the marker files that tell the embedded terminal a remote
    /// tmux session exists. The terminal opens as soon as a launch starts,
    /// long before the machine is ready, so it waits for the marker instead
    /// of retrying `tmux attach` against a session that is not there yet.
    static var remoteReadyDirectory: String {
        NSHomeDirectory() + "/.kanban-code/remote-ready"
    }

    static func remoteReadyMarkerPath(for sessionName: String) -> String {
        remoteReadyDirectory + "/" + sessionName
    }

    /// Sessions a launch in flight will create on a machine. The terminal
    /// consults this before the session registry knows the machine, which
    /// happens only once the launch has reached the machine.
    nonisolated(unsafe) private static var expectedRemoteSessions: Set<String> = []
    private static let expectedLock = NSLock()

    /// Writes the marker; its content is the machine name, so a terminal that
    /// started before the machine was known can still attach.
    static func markRemoteSessionReady(_ sessionName: String, machine: String? = nil) {
        try? FileManager.default.createDirectory(atPath: remoteReadyDirectory, withIntermediateDirectories: true)
        FileManager.default.createFile(
            atPath: remoteReadyMarkerPath(for: sessionName),
            contents: (machine ?? "").data(using: .utf8)
        )
        try? FileManager.default.removeItem(atPath: remoteReadyMarkerPath(for: sessionName) + BoxdMachineSupervisor.pausedMarkerSuffix)
        expectedLock.lock(); defer { expectedLock.unlock() }
        expectedRemoteSessions.remove(sessionName)
    }

    static func clearRemoteSessionReady(_ sessionName: String) {
        try? FileManager.default.removeItem(atPath: remoteReadyMarkerPath(for: sessionName))
        try? FileManager.default.removeItem(atPath: remoteReadyMarkerPath(for: sessionName) + BoxdMachineSupervisor.pausedMarkerSuffix)
        expectedLock.lock(); defer { expectedLock.unlock() }
        expectedRemoteSessions.remove(sessionName)
    }

    static func expectRemoteSession(_ sessionName: String) {
        expectedLock.lock(); defer { expectedLock.unlock() }
        expectedRemoteSessions.insert(sessionName)
    }

    static func isRemoteSessionExpected(_ sessionName: String) -> Bool {
        expectedLock.lock(); defer { expectedLock.unlock() }
        return expectedRemoteSessions.contains(sessionName)
    }

    /// True when at least one boxd machine has an open bridge.
    static var hasConnectedMachines: Bool {
        remoteRegistry?.states.values.contains { $0.isConnected } ?? false
    }

    /// Machine that hosts a tmux session, when it is remote.
    static func machine(forSession sessionName: String) -> String? {
        remoteRegistry?.machine(forSession: sessionName)
    }

    /// Machines with a resume in flight, so a second click does not start a
    /// second one, or print the line twice.
    nonisolated(unsafe) private static var resumingMachines: Set<String> = []
    private static let resumingLock = NSLock()

    /// Takes a machine the app holds as paused or stopped out of that state,
    /// because a person asked for it from the resume bar of a card. Returns
    /// once the bridge is connected: true when it is, false when the machine
    /// did not come back or another resume of it is still running. A
    /// connected machine returns true at once. The terminals of the machine
    /// say what is happening while it comes back.
    static func resumeMachine(_ machineName: String) async -> Bool {
        let state = remoteRegistry?.state(of: machineName)
        if state?.isConnected == true { return true }
        guard state != .connecting, let supervisor = boxdSupervisor else { return false }
        guard markResuming(machineName) else { return false }
        defer { clearResuming(machineName) }
        let sessions = remoteRegistry?.sessionNames(on: machineName) ?? []
        await MainActor.run {
            TerminalCache.shared.showNotice("Resuming machine \(machineName)…", sessions: sessions)
        }
        let resumed = await supervisor.resume(machineName: machineName)
        if !resumed {
            await MainActor.run {
                TerminalCache.shared.showNotice("Machine \(machineName) did not come back.", sessions: sessions)
            }
        }
        return resumed
    }

    /// True when this call is the one that starts the resume.
    private static func markResuming(_ machineName: String) -> Bool {
        resumingLock.lock(); defer { resumingLock.unlock() }
        return resumingMachines.insert(machineName).inserted
    }

    private static func clearResuming(_ machineName: String) {
        resumingLock.lock(); defer { resumingLock.unlock() }
        resumingMachines.remove(machineName)
    }

    /// Runs the bundled kanban CLI on the Mac for a command proxied from a
    /// machine. `KANBAN_CARD_ID` names the card the command came from.
    static func runProxiedCommand(_ invocation: BoxdProxyInvocation) async -> ShellCommand.Result {
        guard let resourceURL = Bundle.main.resourceURL else {
            return ShellCommand.Result(exitCode: 1, stdout: "", stderr: "kanban CLI bundle not found")
        }
        let cliJS = resourceURL.appendingPathComponent("cli/dist/kanban.js").path
        guard let node = findNode() else {
            return ShellCommand.Result(exitCode: 1, stdout: "", stderr: "node not found on this Mac")
        }
        var argv = invocation.request.argv
        // Image arguments were rewritten on the machine to the proxy image
        // directory; the supervisor wrote them there before this call.
        if !invocation.imagePaths.isEmpty {
            let byName = Dictionary(uniqueKeysWithValues: invocation.imagePaths.map { (($0 as NSString).lastPathComponent, $0) })
            argv = argv.map { argument in
                let name = (argument as NSString).lastPathComponent
                if argument.contains("/images/proxy/"), let local = byName[name] { return local }
                return argument
            }
        }
        var environment = ShellCommand.loginEnvironment
        environment["KANBAN_REMOTE_PROXY"] = nil
        environment["TMUX"] = nil
        environment["TMUX_PANE"] = nil
        if let cardId = invocation.cardId { environment["KANBAN_CARD_ID"] = cardId }
        do {
            return try await ShellCommand.run(
                node,
                arguments: [cliJS] + argv,
                currentDirectory: invocation.cwd.flatMap { FileManager.default.fileExists(atPath: $0) ? $0 : nil },
                stdin: invocation.request.stdin,
                environment: environment,
                timeout: 110
            )
        } catch {
            return ShellCommand.Result(exitCode: 1, stdout: "", stderr: error.localizedDescription)
        }
    }

    static func findNode() -> String? {
        let candidates = ["/usr/local/bin/node", "/opt/homebrew/bin/node", "/usr/bin/node"]
        for candidate in candidates where FileManager.default.isExecutableFile(atPath: candidate) {
            return candidate
        }
        return ShellCommand.findExecutable("node")
    }

    static var appVersion: String {
        (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "dev"
    }

    static var cliBundlePath: String? {
        guard let resourceURL = Bundle.main.resourceURL else { return nil }
        let path = resourceURL.appendingPathComponent("cli").path
        return FileManager.default.fileExists(atPath: "\(path)/dist/kanban.js") ? path : nil
    }
}
