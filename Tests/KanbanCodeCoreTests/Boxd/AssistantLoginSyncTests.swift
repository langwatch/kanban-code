import Foundation
import Testing
@testable import KanbanCodeCore

private func withLock<T>(_ lock: NSLock, _ body: () -> T) -> T {
    lock.lock()
    defer { lock.unlock() }
    return body()
}

/// A login store held in memory.
final class FakeLoginStore: LocalLoginStore, @unchecked Sendable {
    private let lock = NSLock()
    private var _logins: [AssistantLoginKind: Data] = [:]
    private var _failures: [AssistantLoginKind: String] = [:]
    private var _account: [String: Any]?
    private var _writes: [AssistantLoginKind] = []
    private let rush: String?

    init(logins: [AssistantLoginKind: Data] = [:], account: [String: Any]? = nil, failures: [AssistantLoginKind: String] = [:], rush: String? = nil) {
        _logins = logins
        _account = account
        _failures = failures
        self.rush = rush
    }

    func rushClaudeConfig() async -> String? { rush }

    var writes: [AssistantLoginKind] { withLock(lock) { _writes } }
    func data(_ kind: AssistantLoginKind) -> Data? { withLock(lock) { _logins[kind] } }

    func read(_ kind: AssistantLoginKind) async -> LocalLoginRead {
        withLock(lock) {
            if let failure = _failures[kind] { return .failed(failure) }
            return _logins[kind].map { .found($0) } ?? .absent
        }
    }
    func write(_ kind: AssistantLoginKind, data: Data) async throws {
        withLock(lock) {
            _logins[kind] = data
            _writes.append(kind)
        }
    }
    func claudeAccount() async -> [String: Any]? { withLock(lock) { _account } }
}

/// Token owners by access token.
struct FakeOwners: ClaudeTokenOwnerResolver {
    let byToken: [String: String]
    init(_ byToken: [String: String]) { self.byToken = byToken }
    func owner(of login: AssistantLogin) async -> String? {
        let object = try? JSONSerialization.jsonObject(with: login.data) as? [String: Any]
        let token = (object?["claudeAiOauth"] as? [String: Any])?["accessToken"] as? String
        return token.flatMap { byToken[$0] }
    }
}

/// Milliseconds since 1970 far in the future (2096): copies built on it
/// have not expired.
private let future = 4_000_000_000_000

private func claudeLogin(access: String, expiresAt: Int) -> Data {
    let json = """
    {"claudeAiOauth":{"accessToken":"\(access)","refreshToken":"sk-ant-ort01-r","expiresAt":\(expiresAt),"scopes":["user:inference"],"subscriptionType":"max"}}
    """
    return json.data(using: .utf8)!
}

private func codexLogin(refreshed: String?, token: String = "id", accessExpiresAt: Int? = nil) -> Data {
    let refresh = refreshed.map { ",\"last_refresh\":\"\($0)\"" } ?? ""
    let access = accessExpiresAt.map { ",\"access_token\":\"\(jwt(exp: $0))\"" } ?? ""
    return "{\"auth_mode\":\"chatgpt\",\"tokens\":{\"id_token\":\"\(token)\"\(access)}\(refresh)}".data(using: .utf8)!
}

/// An unsigned JWT with only an `exp` claim, base64url like a real one.
private func jwt(exp: Int) -> String {
    func encode(_ text: String) -> String {
        Data(text.utf8).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
    return encode("{\"alg\":\"none\"}") + "." + encode("{\"exp\":\(exp),\"sub\":\"user\"}") + ".sig"
}

/// One remote answer line: the login, base64, as the read script prints it.
private func line(_ data: Data?) -> String { data?.base64EncodedString() ?? "" }

@Suite("Assistant logins")
struct AssistantLoginTests {
    @Test("A Claude login is as fresh as its expiry")
    func claudeFreshness() throws {
        let login = try #require(AssistantLogin(kind: .claude, data: claudeLogin(access: "a", expiresAt: 1_788_125_398_307)))
        #expect(login.freshness == 1_788_125_398.307)
    }

    @Test("A Codex login is as fresh as its last refresh")
    func codexFreshness() throws {
        let login = try #require(AssistantLogin(kind: .codex, data: codexLogin(refreshed: "2026-08-21T12:59:57.237947Z")))
        #expect(abs(login.freshness - 1_787_317_197.238) < 0.01)
        let noDate = try #require(AssistantLogin(kind: .codex, data: codexLogin(refreshed: nil)))
        #expect(noDate.freshness == 0)
    }

    @Test("Bytes that hold no token are not a login")
    func rejectsNonLogins() {
        #expect(AssistantLogin(kind: .claude, data: Data("not json".utf8)) == nil)
        #expect(AssistantLogin(kind: .claude, data: Data("{\"claudeAiOauth\":{\"accessToken\":\"\"}}".utf8)) == nil)
        #expect(AssistantLogin(kind: .claude, data: Data("{\"mcpOAuth\":{}}".utf8)) == nil)
        #expect(AssistantLogin(kind: .codex, data: Data("{\"tokens\":{}}".utf8)) == nil)
    }

    @Test("The newest copy wins, the Mac on a tie")
    func decision() throws {
        let older = try #require(AssistantLogin(kind: .claude, data: claudeLogin(access: "old", expiresAt: future + 1_000)))
        let newer = try #require(AssistantLogin(kind: .claude, data: claudeLogin(access: "new", expiresAt: future + 2_000)))
        let sameAge = try #require(AssistantLogin(kind: .claude, data: claudeLogin(access: "other", expiresAt: future + 2_000)))
        #expect(AssistantLogin.decide(local: .absent, remote: nil) == .none)
        #expect(AssistantLogin.decide(local: .present(newer), remote: nil) == .push)
        #expect(AssistantLogin.decide(local: .absent, remote: newer) == .pull)
        #expect(AssistantLogin.decide(local: .present(newer), remote: newer) == .none)
        #expect(AssistantLogin.decide(local: .present(newer), remote: older) == .push)
        #expect(AssistantLogin.decide(local: .present(older), remote: newer) == .pull)
        #expect(AssistantLogin.decide(local: .present(newer), remote: sameAge) == .push)
        #expect(AssistantLogin.decide(local: .present(older), remote: newer, localAccount: "a", remoteAccount: "a") == .pull)
        #expect(AssistantLogin.decide(local: .present(older), remote: newer, localAccount: "a", remoteAccount: "b") == .push)
        #expect(AssistantLogin.decide(local: .present(older), remote: newer, localAccount: nil, remoteAccount: "b") == .pull)
        #expect(AssistantLogin.decide(local: .absent, remote: newer, localAccount: "a", remoteAccount: "b") == .pull)
        #expect(AssistantLogin.decide(local: .present(newer), remote: newer, localAccount: "a", remoteAccount: "b") == .none)
    }

    @Test("A Mac login that could not be read is never replaced")
    func unreadableLocalMovesNothing() throws {
        let remote = try #require(AssistantLogin(kind: .claude, data: claudeLogin(access: "new", expiresAt: future + 2_000)))
        #expect(AssistantLogin.decide(local: .unreadable("timed out"), remote: remote) == .none)
        #expect(AssistantLogin.decide(local: .unreadable("timed out"), remote: nil) == .none)
        #expect(LocalLogin(.found(Data("garbage".utf8)), kind: .claude) == .unreadable("7 bytes that are not a Claude login"))
        #expect(LocalLogin(.failed("exit 51"), kind: .claude) == .unreadable("exit 51"))
        #expect(LocalLogin(.absent, kind: .claude) == .absent)
    }

    @Test("Copies holding the same tokens are equal however their JSON is written")
    func semanticEquality() throws {
        let compact = Data(#"{"claudeAiOauth":{"accessToken":"a/b","refreshToken":"r","expiresAt":2000,"scopes":["user:inference"]},"mcpOAuth":{"x":1}}"#.utf8)
        let pretty = Data("""
        {
          "mcpOAuth" : { "x" : 2 },
          "claudeAiOauth" : {
            "scopes" : [ "user:inference" ],
            "expiresAt" : 2000,
            "refreshToken" : "r",
            "accessToken" : "a\\/b"
          }
        }

        """.utf8)
        let local = try #require(AssistantLogin(kind: .claude, data: compact))
        let remote = try #require(AssistantLogin(kind: .claude, data: pretty))
        #expect(local.data != remote.data)
        #expect(local == remote)
        #expect(AssistantLogin.decide(local: .present(local), remote: remote) == .none)
        let refreshed = try #require(AssistantLogin(kind: .claude, data: claudeLogin(access: "a/b", expiresAt: future + 3_000)))
        #expect(AssistantLogin.decide(local: .present(local), remote: refreshed) == .pull)
    }

    @Test("Paths of the login files on a machine")
    func remotePaths() {
        #expect(AssistantLoginKind.claude.remoteRelativePath == ".claude/.credentials.json")
        #expect(AssistantLoginKind.codex.remoteRelativePath == ".codex/auth.json")
        let script = AssistantLoginSync.readScript(remoteHome: "/home/boxd")
        #expect(script.contains("'/home/boxd/.claude/.credentials.json' '/home/boxd/.codex/auth.json'"))
        #expect(script.contains("base64 -w0"))
        #expect(script.contains("'/home/boxd/.claude.json'"))
        #expect(script.contains("oauthAccount"))
    }
}

@Suite("Login notices")
struct LoginNoticeTests {
    private let account: [String: Any] = ["accountUuid": "acc-2", "emailAddress": "me@example.com"]

    @Test("A token rotation stays quiet")
    func rotationIsQuiet() {
        let outcome = BoxdMachineSupervisor.loginNotices(
            previousAccountId: "acc-2", account: account, pushedClaudeTo: ["kanban-repo-1"], accountMoves: [], time: "17:53")
        #expect(outcome.notices.isEmpty)
        #expect(outcome.accountId == "acc-2")
    }

    @Test("An account switch on the Mac is told with the machines it reached")
    func accountSwitch() {
        let one = BoxdMachineSupervisor.loginNotices(
            previousAccountId: "acc-1", account: account, pushedClaudeTo: ["kanban-repo-1"], accountMoves: [], time: "17:53")
        #expect(one.notices == ["Claude login changed to me@example.com at 17:53, sent to kanban-repo-1"])
        #expect(one.accountId == "acc-2")
        let many = BoxdMachineSupervisor.loginNotices(
            previousAccountId: "acc-1", account: account, pushedClaudeTo: ["a", "b"], accountMoves: [], time: "17:53")
        #expect(many.notices == ["Claude login changed to me@example.com at 17:53, sent to 2 machines"])
        let none = BoxdMachineSupervisor.loginNotices(
            previousAccountId: "acc-1", account: ["accountUuid": "acc-2"], pushedClaudeTo: [], accountMoves: [], time: "17:53")
        #expect(none.notices == ["Claude login changed at 17:53"])
    }

    @Test("The first account seen is not a switch")
    func firstObservation() {
        let outcome = BoxdMachineSupervisor.loginNotices(
            previousAccountId: nil, account: account, pushedClaudeTo: ["kanban-repo-1"], accountMoves: [], time: "17:53")
        #expect(outcome.notices.isEmpty)
        #expect(outcome.accountId == "acc-2")
        let unknown = BoxdMachineSupervisor.loginNotices(
            previousAccountId: "acc-2", account: nil, pushedClaudeTo: [], accountMoves: [], time: "17:53")
        #expect(unknown.notices.isEmpty)
        #expect(unknown.accountId == "acc-2")
    }

    @Test("A login refreshed on a machine and taken by the Mac stays quiet")
    func refreshPullIsQuiet() {
        let outcome = BoxdMachineSupervisor.loginNotices(
            previousAccountId: "acc-2", account: account, pushedClaudeTo: [], accountMoves: [], time: "17:53")
        #expect(outcome.notices.isEmpty)
    }

    @Test("A login of another account taken from a machine is told")
    func accountPullIsTold() {
        let outcome = BoxdMachineSupervisor.loginNotices(
            previousAccountId: "acc-2", account: account, pushedClaudeTo: [],
            accountMoves: [BoxdMachineSupervisor.LoginMove(kind: .claude, machineName: "kanban-repo-1", decision: .pull)],
            time: "17:53")
        #expect(outcome.notices == ["Claude login on kanban-repo-1 is another account, this Mac switched to it at 17:53"])
    }

    @Test("A machine on another account replaced by the Mac's is told once")
    func accountPushIsTold() {
        let codex = BoxdMachineSupervisor.loginNotices(
            previousAccountId: "acc-2", account: account, pushedClaudeTo: [],
            accountMoves: [BoxdMachineSupervisor.LoginMove(kind: .codex, machineName: "box", decision: .push)],
            time: "17:53")
        #expect(codex.notices == ["Codex login on box was another account, replaced by this Mac's at 17:53"])
        let macSwitch = BoxdMachineSupervisor.loginNotices(
            previousAccountId: "acc-1", account: account, pushedClaudeTo: ["box"],
            accountMoves: [BoxdMachineSupervisor.LoginMove(kind: .claude, machineName: "box", decision: .push)],
            time: "17:53")
        #expect(macSwitch.notices == ["Claude login changed to me@example.com at 17:53, sent to box"])
    }

    @Test("The clock text is hours and minutes")
    func clockText() {
        var components = DateComponents()
        components.year = 2026; components.month = 8; components.day = 30; components.hour = 17; components.minute = 53
        let date = Calendar.current.date(from: components)!
        #expect(BoxdMachineSupervisor.clockText(date) == "17:53")
    }
}

@Suite("Assistant login sync")
struct AssistantLoginSyncTests {
    private let home = "/home/boxd"

    private func remoteAnswer(claude: Data?, codex: Data?, claudeAccount: String? = nil, rush: String? = nil) -> ShellCommand.Result {
        let lines = [claude, codex].map { $0?.base64EncodedString() ?? "" } + [claudeAccount ?? "", rush ?? ""]
        return ShellCommand.Result(exitCode: 0, stdout: lines.joined(separator: "\n") + "\n", stderr: "")
    }

    private func readCall() -> [String] {
        ["bash", "-c", AssistantLoginSync.readScript(remoteHome: home)]
    }

    @Test("A newer login on the Mac goes to the machine with the account")
    func pushesNewerLocal() async {
        let local = claudeLogin(access: "new", expiresAt: future + 2_000)
        let runner = FakeRemoteCommandRunner()
        runner.script(readCall(), remoteAnswer(claude: claudeLogin(access: "old", expiresAt: future + 1_000), codex: nil))
        let store = FakeLoginStore(logins: [.claude: local], account: ["accountUuid": "u1", "emailAddress": "a@b.c"])

        let changes = await AssistantLoginSync(runner: runner, store: store, remoteHome: home).run()

        #expect(changes == [AssistantLoginSync.Change(kind: .claude, decision: .push)])
        #expect(runner.files["/home/boxd/.claude/.credentials.json"] == local)
        #expect(runner.mode(of: "/home/boxd/.claude/.credentials.json") == 0o600)
        let node = runner.execCalls.first { $0.count == 5 && $0[3] == "node" }
        #expect(node?[2].contains("exec node -e") == true)
        #expect(node?[4].contains("config.oauthAccount = {") == true)
        #expect(node?[4].contains("\"accountUuid\":\"u1\"") == true)
        #expect(node?[4].contains("/home/boxd/.claude.json") == true)
        #expect(store.writes.isEmpty)
    }

    @Test("A newer login on the machine comes back to the Mac")
    func pullsNewerRemote() async {
        let remote = claudeLogin(access: "refreshed", expiresAt: future + 3_000)
        let runner = FakeRemoteCommandRunner()
        runner.script(readCall(), remoteAnswer(claude: remote, codex: nil))
        let store = FakeLoginStore(logins: [.claude: claudeLogin(access: "old", expiresAt: future + 2_000)])

        let changes = await AssistantLoginSync(runner: runner, store: store, remoteHome: home).run()

        #expect(changes == [AssistantLoginSync.Change(kind: .claude, decision: .pull)])
        #expect(store.data(.claude) == remote)
        #expect(runner.files.isEmpty)
    }

    @Test("A Mac login that could not be read is not overwritten by the machine's")
    func unreadableLocalIsKept() async {
        let runner = FakeRemoteCommandRunner()
        runner.script(readCall(), remoteAnswer(claude: claudeLogin(access: "refreshed", expiresAt: future + 3_000), codex: nil))
        let store = FakeLoginStore(failures: [.claude: "Keychain read exited 36"])

        let changes = await AssistantLoginSync(runner: runner, store: store, remoteHome: home).run()

        #expect(changes.isEmpty)
        #expect(store.writes.isEmpty)
        #expect(runner.files.isEmpty)
    }

    @Test("The same login written differently on the machine moves nothing")
    func reformattedCopyMovesNothing() async throws {
        let local = claudeLogin(access: "same", expiresAt: future + 2_000)
        let object = try JSONSerialization.jsonObject(with: local)
        let pretty = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted])
        let runner = FakeRemoteCommandRunner()
        runner.script(readCall(), remoteAnswer(claude: pretty, codex: nil))
        let store = FakeLoginStore(logins: [.claude: local])

        let changes = await AssistantLoginSync(runner: runner, store: store, remoteHome: home).run()

        #expect(changes.isEmpty)
        #expect(store.writes.isEmpty)
        #expect(runner.files.isEmpty)
    }

    @Test("A machine that never agreed with the Mac gets the Mac's account, however fresh its own")
    func otherAccountOnMachineGetsTheMacs() async {
        let local = claudeLogin(access: "mac", expiresAt: future + 2_000)
        let remote = claudeLogin(access: "machine", expiresAt: future + 3_000)
        let runner = FakeRemoteCommandRunner()
        runner.script(readCall(), remoteAnswer(claude: remote, codex: nil, claudeAccount: "u2"))
        let store = FakeLoginStore(logins: [.claude: local], account: ["accountUuid": "u1"])
        let memory = InMemoryLoginAccountMemory()

        let changes = await AssistantLoginSync(runner: runner, store: store, remoteHome: home, accounts: memory).run()

        #expect(changes == [AssistantLoginSync.Change(kind: .claude, decision: .push, accountChanged: true)])
        #expect(runner.files["/home/boxd/.claude/.credentials.json"] == local)
        #expect(store.writes.isEmpty)
        #expect(await memory.agreed(.claude, machine: "machine") == "u1")
    }

    @Test("A machine that switched account since it last agreed with the Mac keeps it")
    func machineSwitchIsKept() async {
        let local = claudeLogin(access: "mac", expiresAt: future + 2_000)
        let remote = claudeLogin(access: "machine", expiresAt: future + 3_000)
        let runner = FakeRemoteCommandRunner()
        runner.script(readCall(), remoteAnswer(claude: remote, codex: nil, claudeAccount: "u2"))
        let store = FakeLoginStore(logins: [.claude: local], account: ["accountUuid": "u1"])
        let memory = InMemoryLoginAccountMemory(["machine|claude": "u1"])

        let changes = await AssistantLoginSync(runner: runner, store: store, remoteHome: home, accounts: memory).run()

        #expect(changes.isEmpty)
        #expect(runner.files.isEmpty)
        #expect(store.writes.isEmpty)
        #expect(await memory.agreed(.claude, machine: "machine") == "u1")
    }

    @Test("A Mac that switched account since it last agreed sends it to the machine")
    func macSwitchIsSent() async {
        let local = claudeLogin(access: "mac", expiresAt: future + 2_000)
        let remote = claudeLogin(access: "machine", expiresAt: future + 3_000)
        let runner = FakeRemoteCommandRunner()
        runner.script(readCall(), remoteAnswer(claude: remote, codex: nil, claudeAccount: "u2"))
        let store = FakeLoginStore(logins: [.claude: local], account: ["accountUuid": "u3"])
        let memory = InMemoryLoginAccountMemory(["machine|claude": "u2"])

        let changes = await AssistantLoginSync(runner: runner, store: store, remoteHome: home, accounts: memory).run()

        #expect(changes == [AssistantLoginSync.Change(kind: .claude, decision: .push, accountChanged: true)])
        #expect(runner.files["/home/boxd/.claude/.credentials.json"] == local)
        #expect(await memory.agreed(.claude, machine: "machine") == "u3")
    }

    @Test("A fresher login of the same account comes back to the Mac")
    func sameAccountPulls() async {
        let remote = claudeLogin(access: "refreshed", expiresAt: future + 3_000)
        for remoteAccount in ["u1", ""] {
            let runner = FakeRemoteCommandRunner()
            runner.script(readCall(), remoteAnswer(claude: remote, codex: nil, claudeAccount: remoteAccount))
            let store = FakeLoginStore(logins: [.claude: claudeLogin(access: "old", expiresAt: future + 2_000)], account: ["accountUuid": "u1"])

            let changes = await AssistantLoginSync(runner: runner, store: store, remoteHome: home).run()

            #expect(changes == [AssistantLoginSync.Change(kind: .claude, decision: .pull)])
            #expect(store.data(.claude) == remote)
        }
    }

    @Test("Equal tokens move nothing, whatever account each side's record names")
    func equalTokensIgnoreAccountRecords() async {
        let login = claudeLogin(access: "same", expiresAt: future + 2_000)
        let runner = FakeRemoteCommandRunner()
        runner.script(readCall(), remoteAnswer(claude: login, codex: nil, claudeAccount: "u2"))
        let store = FakeLoginStore(logins: [.claude: login], account: ["accountUuid": "u1"])

        let changes = await AssistantLoginSync(runner: runner, store: store, remoteHome: home).run()

        #expect(changes.isEmpty)
        #expect(runner.files.isEmpty)
    }

    @Test("The tokens' owner beats the account the records name")
    func tokenOwnerDecides() async {
        // The Mac's record and the machine's both name u1, but the machine
        // holds u2's fresher tokens: they must not come back to the Mac.
        let local = claudeLogin(access: "mac", expiresAt: future + 2_000)
        let remote = claudeLogin(access: "machine", expiresAt: future + 3_000)
        let runner = FakeRemoteCommandRunner()
        runner.script(readCall(), remoteAnswer(claude: remote, codex: nil, claudeAccount: "u1"))
        let store = FakeLoginStore(logins: [.claude: local], account: ["accountUuid": "u1"])
        let owners = FakeOwners(["mac": "u1", "machine": "u2"])

        let changes = await AssistantLoginSync(runner: runner, store: store, remoteHome: home, owners: owners).run()

        #expect(changes == [AssistantLoginSync.Change(kind: .claude, decision: .push, accountChanged: true)])
        #expect(runner.files["/home/boxd/.claude/.credentials.json"] == local)
        #expect(store.writes.isEmpty)

        let sameOwner = FakeOwners(["mac": "u1", "machine": "u1"])
        let runner2 = FakeRemoteCommandRunner()
        runner2.script(readCall(), remoteAnswer(claude: remote, codex: nil, claudeAccount: "u9"))
        let store2 = FakeLoginStore(logins: [.claude: local], account: ["accountUuid": "u1"])
        let pulled = await AssistantLoginSync(runner: runner2, store: store2, remoteHome: home, owners: sameOwner).run()
        #expect(pulled == [AssistantLoginSync.Change(kind: .claude, decision: .pull)])
    }

    @Test("Equal copies move nothing, each assistant on its own")
    func equalCopiesAndCodex() async {
        let claude = claudeLogin(access: "same", expiresAt: future + 2_000)
        let codexLocal = codexLogin(refreshed: "2026-08-21T12:59:57Z", token: "new")
        let runner = FakeRemoteCommandRunner()
        runner.script(readCall(), remoteAnswer(claude: claude, codex: codexLogin(refreshed: "2026-08-01T00:00:00Z", token: "old")))
        let store = FakeLoginStore(logins: [.claude: claude, .codex: codexLocal])

        let changes = await AssistantLoginSync(runner: runner, store: store, remoteHome: home).run()

        #expect(changes == [AssistantLoginSync.Change(kind: .codex, decision: .push)])
        #expect(runner.files["/home/boxd/.codex/auth.json"] == codexLocal)
        #expect(runner.files["/home/boxd/.claude/.credentials.json"] == nil)
    }

    @Test("A machine without login files gets the Mac's")
    func seedsEmptyMachine() async {
        let runner = FakeRemoteCommandRunner()
        runner.script(readCall(), ShellCommand.Result(exitCode: 0, stdout: "\n\n", stderr: ""))
        let local = claudeLogin(access: "mine", expiresAt: future + 2_000)
        let store = FakeLoginStore(logins: [.claude: local])

        let changes = await AssistantLoginSync(runner: runner, store: store, remoteHome: home).run()

        #expect(changes == [AssistantLoginSync.Change(kind: .claude, decision: .push)])
        #expect(runner.files["/home/boxd/.claude/.credentials.json"] == local)
    }

    @Test("A failed read moves nothing")
    func failedReadMovesNothing() async {
        let runner = FakeRemoteCommandRunner()
        runner.setFallback(ShellCommand.Result(exitCode: 1, stdout: "", stderr: "boom"))
        let store = FakeLoginStore(logins: [.claude: claudeLogin(access: "mine", expiresAt: future + 2_000)])

        let changes = await AssistantLoginSync(runner: runner, store: store, remoteHome: home).run()

        #expect(changes.isEmpty)
        #expect(runner.files.isEmpty)
    }

    @Test("An expired Claude login on the Mac is never sent, whatever the machine holds")
    func expiredLocalIsNeverPushed() async {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let expired = claudeLogin(access: "dead", expiresAt: 1_999_000_000_000)
        for remote in [nil, claudeLogin(access: "older-dead", expiresAt: 1_000_000_000_000)] as [Data?] {
            let runner = FakeRemoteCommandRunner()
            runner.script(readCall(), remoteAnswer(claude: remote, codex: nil))
            let store = FakeLoginStore(logins: [.claude: expired], account: ["accountUuid": "u1"])

            let changes = await AssistantLoginSync(runner: runner, store: store, remoteHome: home, now: { now }).run()

            #expect(changes.isEmpty)
            #expect(runner.files.isEmpty)
            #expect(store.writes.isEmpty)
        }
    }

    @Test("An expired Claude login on the Mac never replaces a live one of another account")
    func expiredLocalNeverReplacesOtherAccount() async {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let runner = FakeRemoteCommandRunner()
        runner.script(readCall(), remoteAnswer(
            claude: claudeLogin(access: "live", expiresAt: 2_001_000_000_000), codex: nil, claudeAccount: "u2"))
        let store = FakeLoginStore(
            logins: [.claude: claudeLogin(access: "dead", expiresAt: 1_999_000_000_000)], account: ["accountUuid": "u1"])

        let changes = await AssistantLoginSync(runner: runner, store: store, remoteHome: home, now: { now }).run()

        #expect(changes.isEmpty)
        #expect(runner.files.isEmpty)
        #expect(store.writes.isEmpty)
    }

    @Test("An expired login on the machine never comes back to the Mac")
    func expiredRemoteIsNeverPulled() async {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let runner = FakeRemoteCommandRunner()
        runner.script(readCall(), remoteAnswer(
            claude: claudeLogin(access: "dead", expiresAt: 1_999_000_000_000),
            codex: codexLogin(refreshed: "2026-08-21T12:59:57Z", token: "dead", accessExpiresAt: 1_999_000_000)))
        let store = FakeLoginStore()

        let changes = await AssistantLoginSync(runner: runner, store: store, remoteHome: home, now: { now }).run()

        #expect(changes.isEmpty)
        #expect(store.writes.isEmpty)
    }

    @Test("An expired Codex login is never sent, a live one still is")
    func codexExpiry() async {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let dead = codexLogin(refreshed: "2026-08-21T12:59:57Z", token: "dead", accessExpiresAt: 1_999_000_000)
        let runner = FakeRemoteCommandRunner()
        runner.script(readCall(), remoteAnswer(claude: nil, codex: nil))
        let changes = await AssistantLoginSync(
            runner: runner, store: FakeLoginStore(logins: [.codex: dead]), remoteHome: home, now: { now }).run()
        #expect(changes.isEmpty)
        #expect(runner.files.isEmpty)

        let live = codexLogin(refreshed: "2026-08-21T12:59:57Z", token: "live", accessExpiresAt: 2_001_000_000)
        let runner2 = FakeRemoteCommandRunner()
        runner2.script(readCall(), remoteAnswer(claude: nil, codex: nil))
        let pushed = await AssistantLoginSync(
            runner: runner2, store: FakeLoginStore(logins: [.codex: live]), remoteHome: home, now: { now }).run()
        #expect(pushed == [AssistantLoginSync.Change(kind: .codex, decision: .push)])
        #expect(runner2.files["/home/boxd/.codex/auth.json"] == live)
    }

    @Test("A machine where rush manages Claude accounts gets no Claude login, Codex still syncs")
    func rushRemoteSkipsClaude() async {
        let codexLocal = codexLogin(refreshed: "2026-08-21T12:59:57Z", token: "new")
        let runner = FakeRemoteCommandRunner()
        runner.script(readCall(), remoteAnswer(
            claude: claudeLogin(access: "rush", expiresAt: future + 1_000),
            codex: codexLogin(refreshed: "2026-08-01T00:00:00Z", token: "old"),
            claudeAccount: "u2", rush: "/root/.config/agtop"))
        let store = FakeLoginStore(
            logins: [.claude: claudeLogin(access: "mac", expiresAt: future + 2_000), .codex: codexLocal],
            account: ["accountUuid": "u1"])

        let changes = await AssistantLoginSync(runner: runner, store: store, remoteHome: home).run()

        #expect(changes == [AssistantLoginSync.Change(kind: .codex, decision: .push)])
        #expect(runner.files["/home/boxd/.claude/.credentials.json"] == nil)
        #expect(runner.files["/home/boxd/.codex/auth.json"] == codexLocal)
        #expect(!runner.execCalls.contains { $0.count == 5 && $0[3] == "node" })
        #expect(store.writes.isEmpty)
    }

    @Test("A Mac where rush manages Claude accounts still sends its live login but never takes one")
    func rushLocalNeverPulls() async {
        let runner = FakeRemoteCommandRunner()
        runner.script(readCall(), remoteAnswer(claude: claudeLogin(access: "refreshed", expiresAt: future + 3_000), codex: nil))
        let store = FakeLoginStore(logins: [.claude: claudeLogin(access: "old", expiresAt: future + 2_000)], rush: "/Users/me/.config/rush")
        let changes = await AssistantLoginSync(runner: runner, store: store, remoteHome: home).run()
        #expect(changes.isEmpty)
        #expect(store.writes.isEmpty)

        let local = claudeLogin(access: "new", expiresAt: future + 3_000)
        let runner2 = FakeRemoteCommandRunner()
        runner2.script(readCall(), remoteAnswer(claude: claudeLogin(access: "old", expiresAt: future + 1_000), codex: nil))
        let store2 = FakeLoginStore(logins: [.claude: local], rush: "/Users/me/.config/rush")
        let pushed = await AssistantLoginSync(runner: runner2, store: store2, remoteHome: home).run()
        #expect(pushed == [AssistantLoginSync.Change(kind: .claude, decision: .push)])
        #expect(runner2.files["/home/boxd/.claude/.credentials.json"] == local)
    }
}

@Suite("rush detection")
struct RushClaudeAccountsTests {
    private func makeHome() throws -> String {
        let home = NSTemporaryDirectory() + "rush-detect-" + UUID().uuidString
        try FileManager.default.createDirectory(atPath: home, withIntermediateDirectories: true)
        return home
    }

    private func write(_ text: String, to path: String) throws {
        try FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        try Data(text.utf8).write(to: URL(fileURLWithPath: path))
    }

    /// Runs the machine-side check with bash, as a machine would.
    private func detectRemote(home: String, environment: [String: String] = [:]) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = ["-c", RushClaudeAccounts.detectScript(home: home)]
        var env = ProcessInfo.processInfo.environment
        env.removeValue(forKey: "RUSH_HOME")
        env.merge(environment) { _, new in new }
        process.environment = env
        let pipe = Pipe()
        process.standardOutput = pipe
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    @Test("An active account or a list of sign-ins means rush manages Claude, on the Mac and on a machine")
    func detects() throws {
        let using = try makeHome()
        defer { try? FileManager.default.removeItem(atPath: using) }
        try write("acc-1\n", to: "\(using)/.config/agtop/claude/using")
        #expect(RushClaudeAccounts.managingFolder(home: using, environment: [:]) == "\(using)/.config/agtop")
        #expect(try detectRemote(home: using) == "\(using)/.config/agtop")

        let logins = try makeHome()
        defer { try? FileManager.default.removeItem(atPath: logins) }
        try write("{\n  \"logins\": [\n    {\"id\": \"a\"}\n  ]\n}", to: "\(logins)/.config/rush/config.json")
        #expect(RushClaudeAccounts.managingFolder(home: logins, environment: [:]) == "\(logins)/.config/rush")
        #expect(try detectRemote(home: logins) == "\(logins)/.config/rush")

        let custom = try makeHome()
        defer { try? FileManager.default.removeItem(atPath: custom) }
        try write("acc-1", to: "\(custom)/elsewhere/claude/using")
        let empty = try makeHome()
        defer { try? FileManager.default.removeItem(atPath: empty) }
        #expect(RushClaudeAccounts.managingFolder(home: empty, environment: ["RUSH_HOME": "\(custom)/elsewhere"]) == "\(custom)/elsewhere")
        #expect(try detectRemote(home: empty, environment: ["RUSH_HOME": "\(custom)/elsewhere"]) == "\(custom)/elsewhere")
    }

    @Test("No rush, or rush without Claude accounts, means the login syncs")
    func ignoresOthers() throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(atPath: home) }
        #expect(RushClaudeAccounts.managingFolder(home: home, environment: [:]) == nil)
        #expect(try detectRemote(home: home) == "")
        try write("{\"logins\": [], \"view\": \"board\"}", to: "\(home)/.config/rush/config.json")
        try write("  \n", to: "\(home)/.config/rush/claude/using")
        #expect(RushClaudeAccounts.managingFolder(home: home, environment: [:]) == nil)
        #expect(try detectRemote(home: home) == "")
    }

    @Test("The machine read script ends with the rush check")
    func readScriptChecksRush() {
        let script = AssistantLoginSync.readScript(remoteHome: "/root")
        #expect(script.hasSuffix(RushClaudeAccounts.detectScript(home: "/root")))
        #expect(script.contains("'/root/.config/agtop'"))
    }
}
