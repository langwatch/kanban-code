import Foundation
import Testing

@testable import KanbanCodeCore

/// Every rush host of a card carries a session token the vault knows, and a
/// resume of a rush card whose host does not run starts it.
@Suite("rush session tokens")
@MainActor
struct RushTokenTests {
    /// A stand-in `rush` that logs each call and answers `list` and `info`
    /// from `hosts.json` (a JSON array of hosts).
    private struct FakeRush {
        let dir = NSTemporaryDirectory() + "kanban-rush-token-\(UUID().uuidString)"
        var path: String { "\(dir)/rush" }

        init() throws {
            try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
            let script = """
            #!/bin/sh
            echo "ARGS $*" >> '\(dir)/calls.log'
            case "$2" in
              list) cat '\(dir)/hosts.json' ;;
              info) python3 -c 'import json,sys; h=[x for x in json.load(open(sys.argv[1])) if x["id"]==sys.argv[2]]; print(json.dumps(h[0])) if h else (print("{\\"error\\":\\"not found\\"}"), sys.exit(1))' '\(dir)/hosts.json' "$3" ;;
              start) echo '{"id":"7e57ab1e","sessionId":"7e57ab1e-0000-4000-8000-000000000001","cwd":"/repo","state":"starting","alive":true}' ;;
            esac
            """
            try script.write(toFile: path, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path)
            try setHost(alive: true, sleeping: false, claudePid: 4242)
        }

        func setHost(alive: Bool, sleeping: Bool, claudePid: Int?, state: String = "idle", queue: [String] = []) throws {
            var host: [String: Any] = [
                "id": "7e57ab1e", "sessionId": "7e57ab1e-0000-4000-8000-000000000001", "cwd": "/repo",
                "state": state, "alive": alive, "sleeping": sleeping, "queue": queue,
                "meta": ["kanban_session": "rush-7e57ab1e"],
            ]
            if let claudePid { host["claudePid"] = claudePid }
            try JSONSerialization.data(withJSONObject: [host]).write(to: URL(fileURLWithPath: "\(dir)/hosts.json"))
        }

        func calls() -> [String] {
            ((try? String(contentsOfFile: "\(dir)/calls.log", encoding: .utf8)) ?? "")
                .split(separator: "\n").map(String.init)
        }

        func starts() -> [String] { calls().filter { $0.hasPrefix("ARGS session start") } }

        func adapter() -> RushCliAdapter { RushCliAdapter(executable: path, scratchDirectory: "\(dir)/scratch") }
        func cleanup() { try? FileManager.default.removeItem(atPath: dir) }
    }

    private static let cardId = "card_rushtoken"
    private static let sessionId = "7e57ab1e-0000-4000-8000-000000000001"

    private func makeEngine(rush: FakeRush) async throws -> (MasterEngine, VaultCardTokens, String) {
        let dir = NSTemporaryDirectory() + "kanban-rush-token-store-\(UUID().uuidString)"
        let local = TmuxAdapter(transport: FakeTmuxTransport(label: "local"))
        let store = BoardStore(
            effectHandler: EffectHandler(
                coordinationStore: CoordinationStore(basePath: dir),
                tmuxAdapter: local,
                queuedPromptJournal: QueuedPromptJournal(basePath: dir)
            ),
            discovery: ClaudeCodeSessionDiscovery(),
            coordinationStore: CoordinationStore(basePath: dir)
        )
        let settingsStore = SettingsStore(basePath: dir)
        try await settingsStore.write(try JSONDecoder().decode(Settings.self, from: Data(#"{"assistantRuntimes":{"claude":"rush"}}"#.utf8)))
        let engine = MasterEngine(
            store: store,
            settingsStore: settingsStore,
            launcher: LaunchSession(tmux: local),
            tmux: RoutingTmuxAdapter(local: local, rush: rush.adapter()),
            registry: CodingAssistantRegistry()
        )
        let tokens = VaultCardTokens(directory: dir)
        engine.cardSessionEnvironment = { cardId in
            ["KANBAN_CARD_ID": cardId, VaultCardTokens.environmentName: await tokens.issue(cardId: cardId)]
        }
        engine.cardTokenOwner = { token in await tokens.issuedCard(of: token) }
        store.dispatch(.createManualTask(Link(
            id: Self.cardId, name: "Rush card", projectPath: rush.dir, column: .inProgress,
            sessionLink: SessionLink(sessionId: Self.sessionId), tmuxLink: TmuxLink(sessionName: "rush-7e57ab1e")
        )))
        store.dispatch(.tmuxLivenessScanned(live: ["rush-7e57ab1e"]))
        return (engine, tokens, dir)
    }

    private static func token(in startCall: String) -> String? {
        startCall.split(separator: " ").first { $0.hasPrefix("KANBAN_CARD_TOKEN=") }
            .map { String($0.dropFirst("KANBAN_CARD_TOKEN=".count)) }
    }

    // MARK: - The keeper

    private func host(alive: Bool, sleeping: Bool = false, claudePid: Int? = nil, state: String = "idle",
                      queue: [String] = []) -> RushSessionInfo {
        var info = RushSessionInfo(id: "7e57ab1e", sessionId: Self.sessionId, cwd: "/repo", state: state, alive: alive, queue: queue)
        info.sleeping = sleeping
        info.claudePid = claudePid
        return info
    }

    @Test("a host is restarted for its token only while it rests, never mid-turn, with a queue, or stopped")
    func refreshOnlyWhileResting() {
        #expect(RushTokenKeeper.refresh(of: host(alive: false, sleeping: true)) == .start)
        #expect(RushTokenKeeper.refresh(of: host(alive: true)) == .stopThenStart)
        #expect(RushTokenKeeper.refresh(of: host(alive: true, claudePid: 7)) == nil)
        #expect(RushTokenKeeper.refresh(of: host(alive: true, state: "working")) == nil)
        #expect(RushTokenKeeper.refresh(of: host(alive: true, state: "blocked")) == nil)
        #expect(RushTokenKeeper.refresh(of: host(alive: false, sleeping: true, queue: ["next"])) == nil)
        #expect(RushTokenKeeper.refresh(of: host(alive: false, state: "stopped")) == nil)
    }

    @Test("a host seen without the card's token is restarted once it rests, then not again for a while")
    func keeperSchedule() {
        var keeper = RushTokenKeeper()
        let start = Date(timeIntervalSince1970: 1_000_000)
        // Seen with the card's token: nothing to do.
        keeper.observe(hostId: "7e57ab1e", cardId: "card_a", tokenCard: "card_a")
        #expect(keeper.due([host(alive: false, sleeping: true)], now: start).isEmpty)

        // Seen with another card's token, or none: due once it rests.
        keeper.observe(hostId: "7e57ab1e", cardId: "card_a", tokenCard: "card_b")
        #expect(keeper.due([host(alive: true, claudePid: 7, state: "working")], now: start).isEmpty)
        #expect(keeper.missing == ["7e57ab1e"])
        #expect(keeper.due([host(alive: false, sleeping: true)], now: start).map(\.refresh) == [.start])
        #expect(keeper.missing.isEmpty)

        // Still without one after the restart: not again before retryAfter,
        // and never more than maxRefreshes times.
        keeper.observe(hostId: "7e57ab1e", cardId: "card_a", tokenCard: nil)
        #expect(keeper.due([host(alive: false, sleeping: true)], now: start.addingTimeInterval(60)).isEmpty)
        var now = start
        var restarts = 1
        for _ in 0..<5 {
            now = now.addingTimeInterval(RushTokenKeeper.retryAfter + 1)
            keeper.observe(hostId: "7e57ab1e", cardId: "card_a", tokenCard: nil)
            restarts += keeper.due([host(alive: false, sleeping: true)], now: now).count
        }
        #expect(restarts == RushTokenKeeper.maxRefreshes)

        // A host rush no longer lists is forgotten.
        keeper.observe(hostId: "7e57ab1e", cardId: "card_a", tokenCard: nil)
        #expect(keeper.due([], now: now).isEmpty)
        #expect(keeper.missing.isEmpty)
    }

    @Test("a process environment is read from /proc and from ps eww")
    func environmentParsing() {
        let proc = "PATH=/usr/bin\0KANBAN_CARD_ID=card_a\0KANBAN_CARD_TOKEN=kct_abc\0"
        #expect(ProcessEnvironment.parseEnviron(proc, name: "KANBAN_CARD_TOKEN") == .value("kct_abc"))
        #expect(ProcessEnvironment.parseEnviron("PATH=/usr/bin\0", name: "KANBAN_CARD_TOKEN") == .absent)
        #expect(ProcessEnvironment.parseEnviron("", name: "KANBAN_CARD_TOKEN") == .unreadable)

        let ps = "claude --resume abc PATH=/usr/bin HOME=/Users/a KANBAN_CARD_ID=card_a KANBAN_CARD_TOKEN=kct_abc\n"
        #expect(ProcessEnvironment.parsePsEnvironment(ps, name: "KANBAN_CARD_TOKEN") == .value("kct_abc"))
        #expect(ProcessEnvironment.parsePsEnvironment("claude PATH=/usr/bin HOME=/a\n", name: "KANBAN_CARD_TOKEN") == .absent)
        // Another user's process: ps prints the command alone.
        #expect(ProcessEnvironment.parsePsEnvironment("claude --resume abc\n", name: "KANBAN_CARD_TOKEN") == .unreadable)
    }

    @Test("this process's own environment reads back")
    func environmentOfThisProcess() async {
        // ps separates the words with spaces: a token has none, HOME neither.
        let reading = await ProcessEnvironment.read("HOME", pid: Int(getpid()))
        #expect(reading == .value(ProcessInfo.processInfo.environment["HOME"] ?? ""))
        #expect(await ProcessEnvironment.read("KANBAN_TEST_NO_SUCH_VARIABLE", pid: Int(getpid())) == .absent)
    }

    @Test("the vault names the card a token was issued for, without dropping any")
    func issuedCard() async {
        let tokens = VaultCardTokens(directory: NSTemporaryDirectory() + "kanban-card-tokens-\(UUID().uuidString)")
        let token = await tokens.issue(cardId: "card_a")
        #expect(await tokens.issuedCard(of: token) == "card_a")
        #expect(await tokens.issuedCard(of: "kct_unknown") == nil)
        #expect(await tokens.count == 1)
    }

    // MARK: - The master

    @Test("a card's host that ran without a token is started again with one once it rests")
    func monitorRestartsHostWithoutToken() async throws {
        let rush = try FakeRush()
        defer { rush.cleanup() }
        let (engine, tokens, _) = try await makeEngine(rush: rush)

        // Running a turn without a token: seen, left alone.
        try rush.setHost(alive: true, sleeping: false, claudePid: 4242, state: "working")
        await engine.checkRushTokens(readToken: { _ in .absent })
        #expect(rush.starts().isEmpty)

        // Resting: started again with --resume and a token the vault knows.
        try rush.setHost(alive: false, sleeping: true, claudePid: nil)
        await engine.checkRushTokens(readToken: { _ in .absent })
        let start = try #require(rush.starts().first)
        #expect(start.contains("--session-id \(Self.sessionId)"))
        #expect(start.contains("--resume"))
        #expect(start.contains("KANBAN_CARD_ID=\(Self.cardId)"))
        let token = try #require(Self.token(in: start))
        #expect(await tokens.issuedCard(of: token) == Self.cardId)
        #expect(!rush.calls().contains { $0.hasPrefix("ARGS session stop") })

        // Running again with that token: nothing more.
        try rush.setHost(alive: true, sleeping: false, claudePid: 4242, state: "working")
        await engine.checkRushTokens(readToken: { _ in .value(token) })
        try rush.setHost(alive: false, sleeping: true, claudePid: nil)
        await engine.checkRushTokens(readToken: { _ in .value(token) })
        #expect(rush.starts().count == 1)
    }

    @Test("a host with the card's token, or whose environment cannot be read, is left alone")
    func monitorLeavesValidHosts() async throws {
        let rush = try FakeRush()
        defer { rush.cleanup() }
        let (engine, tokens, _) = try await makeEngine(rush: rush)
        let token = await tokens.issue(cardId: Self.cardId)
        let other = await tokens.issue(cardId: "card_other")

        try rush.setHost(alive: true, sleeping: false, claudePid: 4242, state: "working")
        await engine.checkRushTokens(readToken: { _ in .value(token) })
        await engine.checkRushTokens(readToken: { _ in .unreadable })
        try rush.setHost(alive: false, sleeping: true, claudePid: nil)
        await engine.checkRushTokens(readToken: { _ in .unreadable })
        #expect(rush.starts().isEmpty)

        // Another card's token is not this card's.
        try rush.setHost(alive: true, sleeping: false, claudePid: 4242, state: "working")
        await engine.checkRushTokens(readToken: { _ in .value(other) })
        try rush.setHost(alive: false, sleeping: true, claudePid: nil)
        await engine.checkRushTokens(readToken: { _ in .absent })
        #expect(rush.starts().count == 1)
    }

    @Test("an older host that stays up with its assistant resting is stopped, then started with a token")
    func monitorStopsOlderHost() async throws {
        let rush = try FakeRush()
        defer { rush.cleanup() }
        let (engine, _, _) = try await makeEngine(rush: rush)
        try rush.setHost(alive: true, sleeping: false, claudePid: 4242, state: "idle")
        await engine.checkRushTokens(readToken: { _ in .absent })
        #expect(rush.starts().isEmpty, "its assistant still runs")
        try rush.setHost(alive: true, sleeping: false, claudePid: nil, state: "idle")
        await engine.checkRushTokens(readToken: { _ in .absent })
        let calls = rush.calls()
        let stop = try #require(calls.firstIndex { $0.hasPrefix("ARGS session stop 7e57ab1e") })
        let start = try #require(calls.firstIndex { $0.hasPrefix("ARGS session start") })
        #expect(stop < start)
    }

    // MARK: - Remote resume

    @Test("a remote resume of a rush card whose host rests starts it with a fresh token")
    func remoteResumeStartsRestingHost() async throws {
        let rush = try FakeRush()
        defer { rush.cleanup() }
        let (engine, tokens, _) = try await makeEngine(rush: rush)
        let host = MasterRemoteControlHost(engine: engine, rush: rush.adapter())
        host.resumeOutcomeWait = 2
        #expect(engine.store.state.cards.first { $0.id == Self.cardId }?.sessionStatus == .live)

        // A running host: the card is live, nothing starts.
        try rush.setHost(alive: true, sleeping: false, claudePid: 4242, state: "working")
        _ = try await host.resume(cardId: Self.cardId)
        #expect(rush.starts().isEmpty)

        // Resting, or stopped before the next scan: the resume starts it.
        try rush.setHost(alive: false, sleeping: true, claudePid: nil)
        _ = try await host.resume(cardId: Self.cardId)
        for _ in 0..<50 where rush.starts().isEmpty { try await Task.sleep(for: .milliseconds(50)) }
        let start = try #require(rush.starts().first)
        #expect(start.contains("--resume"))
        let token = try #require(Self.token(in: start))
        #expect(await tokens.issuedCard(of: token) == Self.cardId)
    }
}
