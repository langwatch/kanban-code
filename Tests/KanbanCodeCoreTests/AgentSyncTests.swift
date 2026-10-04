import Testing
import Foundation
@testable import KanbanCodeCore

// MARK: - Helpers

private func tempDir(_ name: String = "agentsync") -> String {
    let path = NSTemporaryDirectory() + "\(name)-\(UUID().uuidString.prefix(8))"
    try? FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
    // /var and /private/var are the same folder on macOS; use the real path.
    return (path as NSString).resolvingSymlinksInPath
}

private func write(_ path: String, _ text: String, mtime: Double? = nil) {
    try? FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
    FileManager.default.createFile(atPath: path, contents: Data(text.utf8))
    if let mtime {
        try? FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: mtime)], ofItemAtPath: path)
    }
}

private func read(_ path: String) -> String? {
    FileManager.default.contents(atPath: path).map { String(decoding: $0, as: UTF8.self) }
}

/// One side of a two-machine mirror, driven by hand: scan, then take the
/// other side's newer versions.
private struct Side {
    var home: String
    var machine: String
    var root: String
    var manifest: [String: SyncItem] = [:]
    var excludes = SyncExcludes(SyncConfig.defaultExcludes)

    init(home: String, machine: String, entry: String = ".claude") {
        self.home = home
        self.machine = machine
        self.root = home + "/" + entry
    }

    var scanner: SyncScanner { SyncScanner(home: home, machineId: machine) }

    mutating func scan(now: Double = Date().timeIntervalSince1970) {
        manifest = scanner.scan(root: root, excludes: excludes, previous: manifest, now: now)
    }

    /// Pulls `other` into this side; returns the actions taken.
    @discardableResult
    mutating func pull(from other: Side) throws -> [SyncAction] {
        scan()
        let actions = SyncPlanner.plan(local: manifest, remote: other.manifest)
        let applier = SyncApplier(home: home)
        for action in actions {
            switch action {
            case .adopt(let path, _):
                manifest[path]?.synced = true
            case .delete(let path, let remote):
                manifest[path] = applier.delete(root: root, rel: path, remote: remote)
            case .fetch(let path, let remote, let keep):
                let content = remote.kind == .file ? other.scanner.content(root: other.root, rel: path) : nil
                manifest[path] = try applier.write(root: root, rel: path, remote: remote, content: content, keepPrevious: keep)
            }
        }
        return actions
    }
}

/// The actions that touch the disk (an adopt only marks a path synced).
private func changes(_ actions: [SyncAction]) -> [SyncAction] {
    actions.filter { if case .adopt = $0 { false } else { true } }
}

// MARK: - Home rewriting

@Suite("Agent sync: home folder rewriting")
struct SyncHomeTests {
    @Test func replacesStandaloneHomeOnly() {
        let text = #"{"command": "/Users/rchaves/.kanban-code/hook.sh", "x": "/Users/rchavesX", "y": "/a/Users/rchaves/b", "z": "/Users/rchaves"}"#
        let normalized = SyncHome.normalize(text, home: "/Users/rchaves")
        #expect(normalized.contains(#""{{KANBAN_SYNC_HOME}}/.kanban-code/hook.sh""#))
        #expect(normalized.contains("/Users/rchavesX"))
        #expect(normalized.contains("/a/Users/rchaves/b"))
        #expect(normalized.hasSuffix(#""z": "{{KANBAN_SYNC_HOME}}"}"#))
        #expect(SyncHome.localize(normalized, home: "/root").contains(#""/root/.kanban-code/hook.sh""#))
    }

    @Test func rootHomeLeavesOtherRootsAlone() {
        let text = "cd /root/Projects && ls /rootfs /x/root"
        #expect(SyncHome.normalize(text, home: "/root") == "cd {{KANBAN_SYNC_HOME}}/Projects && ls /rootfs /x/root")
    }

    @Test func binaryContentTravelsUntouched() {
        var data = Data("/Users/rchaves".utf8)
        data.append(0)
        #expect(SyncHome.normalize(data, home: "/Users/rchaves") == data)
    }

    @Test func expandsTilde() {
        #expect(SyncHome.expand("~/.claude", home: "/root") == "/root/.claude")
        #expect(SyncHome.expand("/etc/x", home: "/root") == "/etc/x")
    }
}

// MARK: - Manifest

@Suite("Agent sync: manifest scanning")
struct SyncScannerTests {
    @Test func recordsEditsAndDeletionsAndSkipsExcludes() throws {
        let home = tempDir()
        var side = Side(home: home, machine: "A")
        write(side.root + "/CLAUDE.md", "hello", mtime: 1000)
        write(side.root + "/commands/x.md", "x", mtime: 1000)
        write(side.root + "/settings.local.json", "{}")
        write(side.root + "/.trash/old.md", "old")
        write(side.root + "/debug.log", "log")
        side.scan(now: 2000)
        #expect(Set(side.manifest.keys) == ["CLAUDE.md", "commands/x.md"])
        #expect(side.manifest["CLAUDE.md"]?.origin == "A")
        #expect(side.manifest["CLAUDE.md"]?.mtime == 1000)

        let before = side.manifest
        side.scan(now: 2100)
        #expect(side.manifest == before, "an unchanged tree keeps its manifest")

        write(side.root + "/CLAUDE.md", "hello again", mtime: 1500)
        try FileManager.default.removeItem(atPath: side.root + "/commands/x.md")
        side.scan(now: 3000)
        #expect(side.manifest["CLAUDE.md"]?.mtime == 1500)
        #expect(side.manifest["CLAUDE.md"]?.hash != before["CLAUDE.md"]?.hash)
        #expect(side.manifest["commands/x.md"]?.deleted == true)
        #expect(side.manifest["commands/x.md"]?.mtime == 3000)
    }

    @Test func homeRewrittenCopiesHashTheSame() {
        let mac = tempDir(), box = tempDir()
        var a = Side(home: mac, machine: "A"), b = Side(home: box, machine: "B")
        write(a.root + "/settings.json", #"{"hook": "\#(mac)/.kanban-code/hook.sh"}"#)
        write(b.root + "/settings.json", #"{"hook": "\#(box)/.kanban-code/hook.sh"}"#)
        a.scan()
        b.scan()
        #expect(a.manifest["settings.json"]?.hash == b.manifest["settings.json"]?.hash)
    }
}

// MARK: - Newest wins

@Suite("Agent sync: newest wins between two machines")
struct SyncMirrorTests {
    @Test func editTravelsRewrittenAndDoesNotBounce() throws {
        let mac = tempDir(), box = tempDir()
        var a = Side(home: mac, machine: "A"), b = Side(home: box, machine: "B")
        write(a.root + "/settings.json", #"{"hook": "\#(mac)/.kanban-code/hook.sh"}"#, mtime: 1000)
        a.scan()
        try b.pull(from: a)
        #expect(read(b.root + "/settings.json") == #"{"hook": "\#(box)/.kanban-code/hook.sh"}"#)

        // Neither side has anything left to take.
        #expect(try changes(a.pull(from: b)).isEmpty)
        #expect(try changes(b.pull(from: a)).isEmpty)
        #expect(a.manifest["settings.json"]?.sameVersion(as: b.manifest["settings.json"]!) == true)
    }

    @Test func newerRemoteWinsAndOlderIsIgnored() throws {
        let mac = tempDir(), box = tempDir()
        var a = Side(home: mac, machine: "A"), b = Side(home: box, machine: "B")
        write(a.root + "/CLAUDE.md", "v1", mtime: 1000)
        a.scan()
        try b.pull(from: a)

        write(b.root + "/CLAUDE.md", "v2 from box", mtime: 2000)
        b.scan()
        let taken = try a.pull(from: b)
        #expect(taken.count == 1)
        #expect(read(a.root + "/CLAUDE.md") == "v2 from box")

        // An older edit on the Mac does not beat the box's version.
        write(a.root + "/CLAUDE.md", "old edit", mtime: 1500)
        a.scan()
        #expect(try changes(b.pull(from: a)).isEmpty)
        #expect(read(b.root + "/CLAUDE.md") == "v2 from box")
    }

    @Test func deletionPropagates() throws {
        let mac = tempDir(), box = tempDir()
        var a = Side(home: mac, machine: "A"), b = Side(home: box, machine: "B")
        write(a.root + "/commands/review.md", "review", mtime: 1000)
        a.scan()
        try b.pull(from: a)
        #expect(read(b.root + "/commands/review.md") == "review")

        try FileManager.default.removeItem(atPath: a.root + "/commands/review.md")
        a.scan(now: Date().timeIntervalSince1970)
        try b.pull(from: a)
        #expect(!FileManager.default.fileExists(atPath: b.root + "/commands/review.md"))
        #expect(!FileManager.default.fileExists(atPath: b.root + "/commands"), "an emptied folder goes too")
        #expect(b.manifest["commands/review.md"]?.deleted == true)
        #expect(try changes(a.pull(from: b)).isEmpty, "the deletion does not come back")
    }

    @Test func deletingAReceivedFileDeletesItAtItsOrigin() throws {
        let mac = tempDir(), box = tempDir()
        var a = Side(home: mac, machine: "A"), b = Side(home: box, machine: "B")
        write(b.root + "/commands/check.md", "check", mtime: 1000)
        b.scan()
        try a.pull(from: b)
        #expect(read(a.root + "/commands/check.md") == "check")

        // The Mac deletes it before the box ever pulled from the Mac.
        try FileManager.default.removeItem(atPath: a.root + "/commands/check.md")
        a.scan()
        #expect(b.manifest["commands/check.md"]?.synced == false)
        try b.pull(from: a)
        #expect(!FileManager.default.fileExists(atPath: b.root + "/commands/check.md"))
    }

    @Test func peerNeverDeletesAFileItNeverSaw() throws {
        let mac = tempDir(), box = tempDir()
        var a = Side(home: mac, machine: "A"), b = Side(home: box, machine: "B")
        a.manifest["notes.md"] = SyncItem(hash: "", mtime: 9_999_999_999, origin: "A", deleted: true, synced: true)
        write(b.root + "/notes.md", "box only", mtime: 1000)
        try b.pull(from: a)
        #expect(read(b.root + "/notes.md") == "box only")
    }

    @Test func firstSyncKeepsTheLoserOnce() throws {
        let mac = tempDir(), box = tempDir()
        var a = Side(home: mac, machine: "A"), b = Side(home: box, machine: "B")
        write(a.root + "/settings.json", "mac settings", mtime: 2000)
        write(b.root + "/settings.json", "box settings", mtime: 1000)
        a.scan()
        let actions = try b.pull(from: a)
        #expect(actions == [.fetch(path: "settings.json", remote: a.manifest["settings.json"]!, keepPrevious: true)])
        #expect(read(b.root + "/settings.json") == "mac settings")
        #expect(read(b.root + "/settings.json.sync-prev") == "box settings")

        // The kept copy is not synced, and a later overwrite does not replace it.
        b.scan()
        #expect(b.manifest["settings.json.sync-prev"] == nil)
        write(a.root + "/settings.json", "mac settings 2", mtime: 3000)
        a.scan()
        try b.pull(from: a)
        #expect(read(b.root + "/settings.json.sync-prev") == "box settings")
        #expect(read(b.root + "/settings.json") == "mac settings 2")
    }

    @Test func symlinkTargetsAreRewritten() throws {
        let mac = tempDir(), box = tempDir()
        var a = Side(home: mac, machine: "A", entry: ".claude/skills")
        var b = Side(home: box, machine: "B", entry: ".claude/skills")
        try FileManager.default.createDirectory(atPath: a.root, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: a.root + "/review", withDestinationPath: mac + "/Projects/skills/skills/review")
        try FileManager.default.createSymbolicLink(atPath: a.root + "/pptx", withDestinationPath: "../../.agents/skills/pptx")
        write(a.root + "/boxd-cli/SKILL.md", "# boxd")
        a.scan()
        try b.pull(from: a)
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: b.root + "/review") == box + "/Projects/skills/skills/review")
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: b.root + "/pptx") == "../../.agents/skills/pptx")
        #expect(read(b.root + "/boxd-cli/SKILL.md") == "# boxd")
        #expect(try changes(a.pull(from: b)).isEmpty)
        #expect(try changes(b.pull(from: a)).isEmpty)
    }

    @Test func singleFileSymlinkEntry() throws {
        let mac = tempDir(), box = tempDir()
        var a = Side(home: mac, machine: "A", entry: ".codex/AGENTS.md")
        var b = Side(home: box, machine: "B", entry: ".codex/AGENTS.md")
        try FileManager.default.createDirectory(atPath: mac + "/.codex", withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: a.root, withDestinationPath: mac + "/.claude/CLAUDE.md")
        a.scan()
        #expect(Set(a.manifest.keys) == [""])
        try b.pull(from: a)
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: b.root) == box + "/.claude/CLAUDE.md")
    }

    @Test func executableBitTravels() throws {
        let mac = tempDir(), box = tempDir()
        var a = Side(home: mac, machine: "A", entry: ".optmem/memo")
        var b = Side(home: box, machine: "B", entry: ".optmem/memo")
        write(a.root, "#!/usr/bin/env python3\n")
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: a.root)
        a.scan()
        try b.pull(from: a)
        #expect(FileManager.default.isExecutableFile(atPath: b.root))
    }
}

// MARK: - One-way follow

@Suite("Agent sync: follower copy of a home")
struct SyncFollowTests {
    @Test func followTakesEveryDifferenceAndDropsExtras() {
        let item = { (hash: String) in SyncItem(hash: hash, mtime: 1, origin: "H") }
        let local = ["memory/LOG.txt": item("old"), "memory/TREE/2": item("same"), "stray": item("x")]
        let home = ["memory/LOG.txt": item("new"), "memory/TREE/2": item("same"), "WAKE.md": item("w")]
        let actions = SyncPlanner.follow(local: local, home: home)
        #expect(actions.map(\.path) == ["WAKE.md", "memory/LOG.txt", "stray"])
        if case .delete = actions[2] {} else { Issue.record("stray should be deleted") }
    }
}

// MARK: - OptMem spool

@Suite("Agent sync: OptMem spool replay")
struct OptmemSpoolTests {
    @Test func replaysInOrderAndStopsAtTheFirstFailure() async throws {
        let dir = tempDir("spool")
        let spool = OptmemSpool(directory: dir)
        let base = Date(timeIntervalSince1970: 1_800_000_000)
        for (i, text) in ["first", "second", "third"].enumerated() {
            try spool.enqueue(OptmemRunRequest(id: "id\(i)", argv: ["note", text], date: "2026-09-28"),
                              at: base.addingTimeInterval(Double(i)))
        }
        #expect(spool.pending().map(\.request.argv[1]) == ["first", "second", "third"])

        final class Box: @unchecked Sendable { var seen: [String] = [] }
        let box = Box()
        struct Down: Error {}
        let partial = await spool.replay { request in
            if request.argv[1] == "second" { throw Down() }
            box.seen.append(request.argv[1])
            return OptmemRunResult(status: 0, stdout: "Saved as #\(box.seen.count).", stderr: "")
        }
        #expect(partial.sent == 1)
        #expect(partial.remaining == 2)
        #expect(spool.pending().map(\.request.argv[1]) == ["second", "third"])

        let rest = await spool.replay { request in
            box.seen.append(request.argv[1])
            return OptmemRunResult(status: 0, stdout: "", stderr: "")
        }
        #expect(rest.sent == 2)
        #expect(rest.remaining == 0)
        #expect(box.seen == ["first", "second", "third"])
        #expect(read(dir + "/replayed.log")?.split(separator: "\n").count == 3)
    }

    @Test func aHeldLockSkipsTheRound() async throws {
        let dir = tempDir("spool")
        let spool = OptmemSpool(directory: dir)
        try spool.enqueue(OptmemRunRequest(id: "a", argv: ["note", "x"]))
        let lock = OptmemSpool.tryLock(dir + "/.lock")
        #expect(lock != nil)
        let result = await spool.replay { _ in OptmemRunResult(status: 0, stdout: "", stderr: "") }
        #expect(result.sent == 0)
        #expect(result.remaining == 1)
        if let lock { close(lock) }
    }
}

// MARK: - Engines talking

/// Routes the sync calls of one engine to another, in process.
private final class LoopbackTransport: SyncTransport, @unchecked Sendable {
    var engines: [String: AgentSyncEngine] = [:]
    var runs: [OptmemRunRequest] = []

    func state(peer: SyncPeer) async throws -> SyncStateResponse {
        guard let engine = engines[peer.machine.id] else { throw SyncTransportError.http(502, "down") }
        return await engine.state()
    }

    func file(peer: SyncPeer, entryId: String, path: String) async throws -> Data {
        guard let data = await engines[peer.machine.id]?.file(entryId: entryId, path: path) else {
            throw SyncTransportError.http(404, path)
        }
        return data
    }

    func notify(peer: SyncPeer, machineId: String, what: String) async {
        await engines[peer.machine.id]?.poke(machineId: machineId, what: what)
    }

    func optmemRun(url: String, token: String, request: OptmemRunRequest) async throws -> OptmemRunResult {
        guard engines[url] != nil else { throw SyncTransportError.http(502, "down") }
        runs.append(request)
        return OptmemRunResult(status: 0, stdout: "Saved as #\(runs.count).", stderr: "")
    }
}

@Suite("Agent sync: engines")
struct AgentSyncEngineTests {
    private func engine(home: String, identity: MachineIdentity, peer: MachineIdentity, transport: LoopbackTransport,
                        entries: [SyncEntry]) throws -> AgentSyncEngine {
        let kanban = home + "/.kanban-code"
        try FileManager.default.createDirectory(atPath: kanban, withIntermediateDirectories: true)
        try JSONEncoder().encode(SyncConfig(updatedAt: 1, entries: entries)).write(to: URL(fileURLWithPath: kanban + "/sync.json"))
        var options = AgentSyncEngine.Options()
        options.scanInterval = 0
        options.pullInterval = 0
        options.gitInterval = 1e9
        let peerRef = SyncPeer(machine: peer, url: peer.id, token: "t", online: true)
        return AgentSyncEngine(home: home, kanbanHome: kanban, identity: identity,
                               peers: { [peerRef] }, transport: transport, options: options)
    }

    @Test func mirrorAndConfigTravelBetweenEngines() async throws {
        let mac = tempDir(), box = tempDir()
        let macId = MachineIdentity(id: "machine_mac", name: "mac")
        let boxId = MachineIdentity(id: "machine_box", name: "box", alwaysOn: true)
        let transport = LoopbackTransport()
        let entries = [SyncEntry(mode: .mirror, path: "~/.claude/CLAUDE.md", excludes: SyncConfig.defaultExcludes)]
        let a = try engine(home: mac, identity: macId, peer: boxId, transport: transport, entries: entries)
        let b = try engine(home: box, identity: boxId, peer: macId, transport: transport, entries: entries)
        transport.engines = [macId.id: a, boxId.id: b]

        write(mac + "/.claude/CLAUDE.md", "memory at \(mac)/.optmem")
        await a.round()
        await b.round()
        #expect(read(box + "/.claude/CLAUDE.md") == "memory at \(box)/.optmem")

        // A new entry added on the Mac reaches the box's settings.
        let more = entries + [SyncEntry(mode: .mirror, path: "~/.claude/commands", excludes: SyncConfig.defaultExcludes)]
        await a.setEntries(more)
        write(mac + "/.claude/commands/ship.md", "ship it")
        await a.round()
        await b.round()
        #expect(await b.currentConfig().entries == more)
        await b.round()
        #expect(read(box + "/.claude/commands/ship.md") == "ship it")
    }

    @Test func loginFilesNeverTravelWhateverTheExcludes() async throws {
        let mac = tempDir(), box = tempDir()
        let macId = MachineIdentity(id: "machine_mac", name: "mac")
        let boxId = MachineIdentity(id: "machine_box", name: "box", alwaysOn: true)
        let transport = LoopbackTransport()
        let entries = [
            SyncEntry(mode: .mirror, path: "~/.claude"),
            SyncEntry(mode: .mirror, path: "~/.codex/"),
            SyncEntry(mode: .mirror, path: "~/.claude/.credentials.json"),
        ]
        let a = try engine(home: mac, identity: macId, peer: boxId, transport: transport, entries: entries)
        let b = try engine(home: box, identity: boxId, peer: macId, transport: transport, entries: entries)
        transport.engines = [macId.id: a, boxId.id: b]

        write(mac + "/.claude/.credentials.json", "{\"claudeAiOauth\":{}}")
        write(mac + "/.claude/CLAUDE.md", "rules")
        write(mac + "/.codex/auth.json", "{\"tokens\":{}}")
        write(mac + "/.codex/config.toml", "model = 1")
        await a.round()
        await b.round()
        #expect(read(box + "/.claude/CLAUDE.md") == "rules")
        #expect(read(box + "/.codex/config.toml") == "model = 1")
        #expect(!FileManager.default.fileExists(atPath: box + "/.claude/.credentials.json"))
        #expect(!FileManager.default.fileExists(atPath: box + "/.codex/auth.json"))
        #expect(await a.file(entryId: entries[0].id, path: ".credentials.json") == nil)
    }

    @Test func loginFileExcludesAreRelativeToTheEntry() {
        #expect(SyncConfig.loginFileExcludes(entryPath: "~") == [".claude/.credentials.json", ".codex/auth.json"])
        #expect(SyncConfig.loginFileExcludes(entryPath: "~/.claude/") == [".credentials.json"])
        #expect(SyncConfig.loginFileExcludes(entryPath: "~/.codex") == ["auth.json"])
        #expect(SyncConfig.loginFileExcludes(entryPath: "~/.claude/skills").isEmpty)
        #expect(SyncConfig.isLoginFile(entryPath: "~/.codex/auth.json"))
        #expect(!SyncConfig.isLoginFile(entryPath: "~/.codex/config.toml"))
    }

    @Test func handEditOfSyncJsonAppliesAndTravels() async throws {
        let mac = tempDir(), box = tempDir()
        let macId = MachineIdentity(id: "machine_mac", name: "mac")
        let boxId = MachineIdentity(id: "machine_box", name: "box", alwaysOn: true)
        let transport = LoopbackTransport()
        let entries = [SyncEntry(mode: .mirror, path: "~/.claude/CLAUDE.md")]
        let a = try engine(home: mac, identity: macId, peer: boxId, transport: transport, entries: entries)
        let b = try engine(home: box, identity: boxId, peer: macId, transport: transport, entries: entries)
        transport.engines = [macId.id: a, boxId.id: b]

        let edited = entries + [SyncEntry(mode: .mirror, path: "~/.agents/skills")]
        try await Task.sleep(for: .milliseconds(20))
        try JSONEncoder().encode(SyncConfig(updatedAt: 1, entries: edited))
            .write(to: URL(fileURLWithPath: box + "/.kanban-code/sync.json"))
        await b.round()
        #expect(await b.currentConfig().entries == edited)
        #expect(await b.currentConfig().updatedAt > 1)
        await a.round()
        #expect(await a.currentConfig().entries == edited)
    }

    @Test func followerWaitsForASeededHomeThenReplaysItsQueue() async throws {
        let mac = tempDir(), box = tempDir()
        let macId = MachineIdentity(id: "machine_mac", name: "mac")
        let boxId = MachineIdentity(id: "machine_box", name: "box", alwaysOn: true)
        let transport = LoopbackTransport()
        let entries = [SyncEntry(mode: .optmem, path: "~/.optmem")]
        let a = try engine(home: mac, identity: macId, peer: boxId, transport: transport, entries: entries)
        let b = try engine(home: box, identity: boxId, peer: macId, transport: transport, entries: entries)
        transport.engines = [macId.id: a, boxId.id: b]

        let record = { (i: Int) in "#\(i) 2026-09-28 memory \(i)".padding(toLength: 319, withPad: " ", startingAt: 0) + "\n" }
        write(mac + "/.optmem/memory/LOG.txt", record(0) + record(1))
        write(mac + "/.optmem/WAKE.md", "mac wake")
        write(box + "/.optmem/memory/LOG.txt", record(0))
        write(box + "/.optmem/WAKE.md", "box wake")

        // The home has fewer memories: the Mac keeps its own and does not forward.
        await b.round()
        await a.round()
        #expect(read(mac + "/.optmem/memory/LOG.txt") == record(0) + record(1))
        #expect(!FileManager.default.fileExists(atPath: mac + "/.optmem/home.json"))
        #expect(await a.entryStatuses()["optmem:~/.optmem"]?.level == .warning)

        // Seeded: the Mac follows the home and forwards to it.
        write(box + "/.optmem/memory/LOG.txt", record(0) + record(1) + record(2))
        write(box + "/.optmem/WAKE.md", "box wake 3")
        try OptmemSpool(optmemRoot: mac + "/.optmem").enqueue(OptmemRunRequest(id: "q1", argv: ["note", "queued"]))
        await b.round()
        await a.round()
        #expect(read(mac + "/.optmem/memory/LOG.txt") == record(0) + record(1) + record(2))
        #expect(read(mac + "/.optmem/WAKE.md") == "box wake 3")
        #expect(FileManager.default.fileExists(atPath: mac + "/.optmem/home.json"))
        await a.round()
        #expect(transport.runs.map(\.id) == ["q1"])
        #expect(OptmemSpool(optmemRoot: mac + "/.optmem").pending().isEmpty)
        #expect(!FileManager.default.fileExists(atPath: box + "/.optmem/home.json"))
    }
}

// MARK: - Settings keys

@Suite("Agent sync: named keys of a JSON file")
struct SyncJSONKeysTests {
    private let mac = """
    {
      "hideMinimap": true,
      "logins": {
        "work": {"token": "mac-only"}
      },
      "view": "list",
      "keys": {
        "a": [1, 2],
        "b": "x, y"
      }
    }

    """

    private func text(_ data: Data?) -> String? { data.map { String(decoding: $0, as: UTF8.self) } }

    @Test func projectionHoldsOnlyTheNamedKeysSortedAndWithoutWhitespace() {
        let projection = SyncJSONKeys.projection(of: Data(mac.utf8), keys: ["view", "keys", "hideMinimap", "absent"])
        #expect(text(projection) == #"{"hideMinimap":true,"keys":{"a":[1,2],"b":"x, y"},"view":"list"}"#)
        // The same values written another way give the same bytes.
        let compact = #"{"view":"list","logins":{},"keys":{"a":[1,2],"b":"x, y"},"hideMinimap":true}"#
        #expect(SyncJSONKeys.projection(of: Data(compact.utf8), keys: ["hideMinimap", "keys", "view"]) == projection)
        #expect(text(SyncJSONKeys.projection(of: Data("{}".utf8), keys: ["view"])) == "{}")
    }

    @Test func whatIsNotAJSONObjectHasNoProjection() {
        #expect(SyncJSONKeys.projection(of: Data(mac.dropLast(20).utf8), keys: ["view"]) == nil)
        #expect(SyncJSONKeys.projection(of: Data("[1, 2]".utf8), keys: ["view"]) == nil)
        #expect(SyncJSONKeys.projection(of: Data(), keys: ["view"]) == nil)
    }

    @Test func mergeSetsAddsAndRemovesTheNamedKeysAndLeavesTheRestByteForByte() throws {
        let box = """
        {
          "logins": {
            "work": {"token": "box-only"}
          },
          "view": "board",
          "groupBy": "project",
          "sideWidth": 40
        }

        """
        let keys = ["hideMinimap", "view", "groupBy", "keys"]
        let projection = try #require(SyncJSONKeys.projection(of: Data(mac.utf8), keys: keys))
        let merged = try #require(text(SyncJSONKeys.merge(into: Data(box.utf8), keys: keys, from: projection)))
        #expect(merged == """
        {
          "logins": {
            "work": {"token": "box-only"}
          },
          "view": "list",
          "sideWidth": 40,
          "hideMinimap": true,
          "keys": {"a":[1,2],"b":"x, y"}
        }

        """)
        // Now both files give the same projection, and a second merge changes nothing.
        #expect(SyncJSONKeys.projection(of: Data(merged.utf8), keys: keys) == projection)
        #expect(SyncJSONKeys.merge(into: Data(merged.utf8), keys: keys, from: projection) == Data(merged.utf8))
    }

    @Test func mergeKeepsAOneLineFileOnOneLineAndRefusesWhatIsNoObject() {
        let projection = Data(#"{"view":"list"}"#.utf8)
        let merged = SyncJSONKeys.merge(into: Data(#"{"a":1,"view":"board"}"#.utf8), keys: ["view"], from: projection)
        #expect(text(merged) == #"{"a":1,"view":"list"}"#)
        #expect(text(SyncJSONKeys.merge(into: Data("{}".utf8), keys: ["view"], from: projection)) == #"{"view":"list"}"#)
        #expect(SyncJSONKeys.merge(into: Data("[]".utf8), keys: ["view"], from: projection) == nil)
        #expect(SyncJSONKeys.merge(into: Data(#"{"view": "bo"#.utf8), keys: ["view"], from: projection) == nil)
    }

    @Test func aChangeToAnotherKeyIsNoNewVersionAndAHalfWrittenFileKeepsTheLast() {
        let home = tempDir()
        let path = home + "/config.json"
        write(path, #"{"view": "list", "logins": {"a": 1}}"#, mtime: 1000)
        let scanner = SyncScanner(home: home, machineId: "A", jsonKeys: ["view"])
        let first = scanner.scan(root: path, excludes: SyncExcludes([]), previous: [:])
        #expect(first[""]?.mtime == 1000)

        write(path, #"{"view": "list", "logins": {"a": 1, "b": 2}}"#, mtime: 2000)
        let second = scanner.scan(root: path, excludes: SyncExcludes([]), previous: first)
        #expect(second[""]?.hash == first[""]?.hash)
        #expect(second[""]?.mtime == 1000)

        write(path, #"{"view": "li"#, mtime: 3000)
        let third = scanner.scan(root: path, excludes: SyncExcludes([]), previous: second)
        #expect(third[""]?.hash == first[""]?.hash)
        #expect(third[""]?.deleted == false)

        write(path, #"{"view": "board", "logins": {}}"#, mtime: 4000)
        let fourth = scanner.scan(root: path, excludes: SyncExcludes([]), previous: third)
        #expect(fourth[""]?.hash != first[""]?.hash)
        #expect(fourth[""]?.mtime == 4000)
    }
}

extension AgentSyncEngineTests {
    @Test func namedKeysTravelBetweenFilesAtDifferentPathsAndTheRestStays() async throws {
        let mac = tempDir(), box = tempDir()
        let macId = MachineIdentity(id: "machine_mac", name: "mac")
        let boxId = MachineIdentity(id: "machine_box", name: "Box", alwaysOn: true)
        let transport = LoopbackTransport()
        let entries = [
            SyncEntry(mode: .json, path: "~/.config/app/config.json", keys: ["hideMinimap", "view"],
                      paths: ["box": "~/.config/old/config.json"]),
            SyncEntry(mode: .mirror, path: "~/.config/app/keybindings.json", paths: ["machine_box": "~/.config/old/keybindings.json"]),
        ]
        let a = try engine(home: mac, identity: macId, peer: boxId, transport: transport, entries: entries)
        let b = try engine(home: box, identity: boxId, peer: macId, transport: transport, entries: entries)
        transport.engines = [macId.id: a, boxId.id: b]

        let boxConfig = box + "/.config/old/config.json"
        write(boxConfig, "{\n  \"logins\": {\"box\": \"secret\"},\n  \"view\": \"board\"\n}\n", mtime: 1000)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: boxConfig)
        write(mac + "/.config/app/config.json", "{\n  \"hideMinimap\": true,\n  \"logins\": {\"mac\": \"other\"},\n  \"view\": \"list\"\n}\n", mtime: 2000)
        write(mac + "/.config/app/keybindings.json", "{\"quit\": \"q\"}")
        await a.round()
        await b.round()

        // The box took the Mac's keys, kept its own login and permissions, and has a copy of what it had.
        #expect(read(boxConfig) == "{\n  \"logins\": {\"box\": \"secret\"},\n  \"view\": \"list\",\n  \"hideMinimap\": true\n}\n")
        #expect((try FileManager.default.attributesOfItem(atPath: boxConfig)[.posixPermissions] as? NSNumber)?.intValue == 0o600)
        #expect(read(boxConfig + ".sync-prev")?.contains("\"board\"") == true)
        #expect(read(box + "/.config/old/keybindings.json") == "{\"quit\": \"q\"}")
        #expect(!FileManager.default.fileExists(atPath: box + "/.config/app"))
        await a.round()
        #expect(read(mac + "/.config/app/config.json")?.contains("\"mac\": \"other\"") == true)
        #expect(await a.file(entryId: entries[0].id, path: "") == Data(#"{"hideMinimap":true,"view":"list"}"#.utf8))

        // A key changed on the box reaches the Mac; a login added there does not.
        write(boxConfig, "{\n  \"logins\": {\"box\": \"secret\", \"new\": \"x\"},\n  \"view\": \"list\",\n  \"hideMinimap\": false\n}\n",
              mtime: Date().timeIntervalSince1970 + 10)
        await b.round()
        await a.round()
        let macConfig = try #require(read(mac + "/.config/app/config.json"))
        #expect(macConfig.contains("\"hideMinimap\": false"))
        #expect(macConfig.contains("\"mac\": \"other\"") && !macConfig.contains("secret") && !macConfig.contains("\"new\""))

        // The file removed on the Mac stays on the box.
        try FileManager.default.removeItem(atPath: mac + "/.config/app/config.json")
        await a.round()
        await b.round()
        #expect(FileManager.default.fileExists(atPath: boxConfig))
    }

    @Test func aMachineWithoutTheFileIsLeftWithoutIt() async throws {
        let mac = tempDir(), box = tempDir()
        let macId = MachineIdentity(id: "machine_mac", name: "mac")
        let boxId = MachineIdentity(id: "machine_box", name: "box", alwaysOn: true)
        let transport = LoopbackTransport()
        let entries = [SyncEntry(mode: .json, path: "~/.config/app/config.json", keys: ["view"])]
        let a = try engine(home: mac, identity: macId, peer: boxId, transport: transport, entries: entries)
        let b = try engine(home: box, identity: boxId, peer: macId, transport: transport, entries: entries)
        transport.engines = [macId.id: a, boxId.id: b]
        write(mac + "/.config/app/config.json", #"{"view": "list"}"#)
        await a.round()
        await b.round()
        #expect(!FileManager.default.fileExists(atPath: box + "/.config/app/config.json"))
        #expect(await b.entryStatuses()[entries[0].id]?.level == .warning)

        // Once its program creates the file, the keys arrive.
        write(box + "/.config/app/config.json", #"{"own": 1}"#, mtime: 1000)
        await b.round()
        #expect(read(box + "/.config/app/config.json") == #"{"own":1,"view":"list"}"#)
    }

    @Test func entriesWithKeysAndPathsSurviveSyncJson() throws {
        let entry = SyncEntry(mode: .json, path: "~/a.json", keys: ["x"], paths: ["box": "~/b.json"])
        let decoded = try JSONDecoder().decode(SyncEntry.self, from: JSONEncoder().encode(entry))
        #expect(decoded == entry)
        #expect(entry.id == "json:~/a.json")
        #expect(entry.path(on: MachineIdentity(id: "m1", name: "BOX")) == "~/b.json")
        #expect(entry.path(on: MachineIdentity(id: "m2", name: "mac")) == "~/a.json")
        let old = try JSONDecoder().decode(SyncEntry.self, from: Data(#"{"mode":"mirror","path":"~/x"}"#.utf8))
        #expect(old.keys.isEmpty && old.paths.isEmpty)
    }
}
