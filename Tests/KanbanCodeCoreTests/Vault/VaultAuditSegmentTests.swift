import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing
@testable import KanbanCodeCore
@testable import KanbanCodeRemoteKit

private func entry(_ secret: String, at: Date, card: String = "card_1", tier: VaultTier = .open,
                   outcome: VaultOutcome = .allowed, decider: VaultDecider = .tier, action: String = "hook",
                   command: String? = nil) -> VaultAuditEntry {
    VaultAuditEntry(at: at, machine: "box", cardId: card, sessionId: "s1", secret: secret, tier: tier,
                    outcome: outcome, decider: decider, action: action, command: command)
}

private func decode(_ lines: [Data]) -> [VaultAuditEntry] {
    lines.compactMap { try? JSONDecoder.vault.decode(VaultAuditEntry.self, from: $0) }
}

private func tempDir(_ name: String) -> String {
    NSTemporaryDirectory() + name + "-" + UUID().uuidString
}

/// Waits for the background gzip of every archived segment.
private func waitForArchives(_ dir: String) async throws {
    for _ in 0..<200 {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: dir + "/audit-archive")) ?? []
        if !names.contains(where: { $0.hasSuffix(".jsonl") && !$0.hasSuffix(".decisions.jsonl") }) { return }
        try await Task.sleep(for: .milliseconds(25))
    }
    Issue.record("archived segments were not compressed")
}

@Suite("Folding repeated open-tier releases")
struct VaultAuditFoldTests {
    @Test("repeats of one card, session and secret within the window fold into one counted line")
    func foldsRepeats() async throws {
        let store = VaultStore(directory: tempDir("audit-fold"), keys: MemoryVaultKeyProvider())
        await store.setAuditLimits(foldWindow: 3600)
        let t0 = Date(timeIntervalSince1970: 1_800_000_000)
        for n in 0..<50 {
            await store.append(entry("STRIPE", at: t0.addingTimeInterval(Double(n)), command: "ls \(n)"))
            await store.append(entry("JEV", at: t0.addingTimeInterval(Double(n) + 0.5), command: "ls \(n)"))
        }
        // One full line per secret so far; the 49 repeats each are held.
        #expect(decode(await store.auditLines()).map(\.secret) == ["STRIPE", "JEV"])

        // The window ends: the next use writes the count, then starts again.
        await store.append(entry("STRIPE", at: t0.addingTimeInterval(3700), command: "ls late"))
        let lines = decode(await store.auditLines())
        #expect(lines.count == 5)
        let counted = lines.filter { $0.repeats != nil }
        #expect(counted.count == 2)
        let stripe = try #require(counted.first { $0.secret == "STRIPE" })
        #expect(stripe.repeats == 49)
        #expect(stripe.firstAt == t0.addingTimeInterval(1))
        #expect(stripe.command == "ls 49")
        #expect(stripe.detail?.contains("49 uses from") == true)
        #expect(lines.last?.command == "ls late")
        #expect(lines.last?.repeats == nil)
        #expect(AuditChain.verify(await store.auditLines()).breaks.isEmpty)
    }

    @Test("ask-tier, denied, human and non-hook lines are always written in full")
    func neverFoldsDecisions() async throws {
        let store = VaultStore(directory: tempDir("audit-nofold"), keys: MemoryVaultKeyProvider())
        let t0 = Date(timeIntervalSince1970: 1_800_000_000)
        for n in 0..<5 {
            let at = t0.addingTimeInterval(Double(n))
            await store.append(entry("ASKED", at: at, tier: .ask, decider: .human))
            await store.append(entry("DENIED", at: at, outcome: .denied, decider: .rule))
            await store.append(entry("SKIPPED", at: at, outcome: .skipped, decider: .rule))
            await store.append(entry("RUN", at: at, action: "run"))
        }
        #expect(await store.auditLines().count == 20)
    }

    @Test("a fold whose window ended is written by the periodic flush, and all of them on demand")
    func flushWritesCounts() async throws {
        let store = VaultStore(directory: tempDir("audit-flush"), keys: MemoryVaultKeyProvider())
        await store.setAuditLimits(foldWindow: 60)
        let t0 = Date(timeIntervalSince1970: 1_800_000_000)
        for n in 0..<10 { await store.append(entry("A", at: t0.addingTimeInterval(Double(n)))) }
        for n in 0..<3 { await store.append(entry("B", at: t0.addingTimeInterval(50 + Double(n)))) }
        await store.flushFolds(now: t0.addingTimeInterval(61))
        var lines = decode(await store.auditLines())
        #expect(lines.map(\.secret) == ["A", "B", "A"])
        #expect(lines.last?.repeats == 9)

        await store.flushFolds(now: t0.addingTimeInterval(62), all: true)
        lines = decode(await store.auditLines())
        #expect(lines.map(\.secret) == ["A", "B", "A", "B"])
        #expect(lines.last?.repeats == 2)
        #expect(AuditChain.verify(await store.auditLines()).breaks.isEmpty)
    }
}

@Suite("Audit log segments")
struct VaultAuditSegmentTests {
    @Test("past the size limit a segment is archived gzipped and the chain runs on across segments")
    func rotatesAndChains() async throws {
        let dir = tempDir("audit-rotate")
        let store = VaultStore(directory: dir, keys: MemoryVaultKeyProvider())
        await store.setAuditLimits(segmentLimit: 2_000)
        let t0 = Date(timeIntervalSince1970: 1_800_000_000)
        var written: [Data] = []
        for n in 0..<60 {
            await store.append(entry("S\(n)", at: t0.addingTimeInterval(Double(n)), action: "run", command: String(repeating: "x", count: 40)))
        }
        try await waitForArchives(dir)
        let segments = await store.archivedSegments()
        #expect(segments.paths.count >= 3)
        #expect(segments.paths.allSatisfy { $0.hasSuffix(".jsonl.gz") })
        for path in segments.paths {
            VaultStore.forEachLine(inFileAt: path) { written.append($0); return true }
        }
        let current = await store.auditLines()
        written += current
        #expect(written.count == 60)
        #expect(decode(written).map(\.secret) == (0..<60).map { "S\($0)" })
        #expect(AuditChain.verify(written).isIntact)
        #expect(AuditChain.verify(current, after: segments.head).isIntact)
        let report = VaultAuditSync.log("this machine", current, archived: segments)
        #expect(report.lines == 60 && report.breaks.isEmpty)

        // A reopened store goes on from the head.
        let reopened = VaultStore(directory: dir, keys: MemoryVaultKeyProvider())
        await reopened.append(entry("AFTER", at: t0.addingTimeInterval(100), action: "run"))
        var all: [Data] = []
        for path in await reopened.archivedSegments().paths {
            VaultStore.forEachLine(inFileAt: path) { all.append($0); return true }
        }
        all += await reopened.auditLines()
        #expect(all.count == 61)
        #expect(AuditChain.verify(all).isIntact)
    }

    @Test("lines after a hash reach back into the newest archived segment")
    func linesAfterAcrossSegments() async throws {
        let dir = tempDir("audit-after")
        let store = VaultStore(directory: dir, keys: MemoryVaultKeyProvider())
        await store.setAuditLimits(segmentLimit: 1_500)
        let t0 = Date(timeIntervalSince1970: 1_800_000_000)
        var all: [Data] = []
        for n in 0..<30 {
            await store.append(entry("S\(n)", at: t0.addingTimeInterval(Double(n)), action: "run"))
            try await waitForArchives(dir)
            all = []
            for path in await store.archivedSegments().paths {
                VaultStore.forEachLine(inFileAt: path) { all.append($0); return true }
            }
            all += await store.auditLines()
        }
        let segments = await store.archivedSegments()
        #expect(segments.paths.count >= 2)
        let current = await store.auditLines()
        // The head itself: the whole current segment.
        #expect(await store.auditLines(after: try #require(segments.head)) == current)
        // A line inside the newest archive: its rest, then the current segment.
        let headIndex = try #require(all.firstIndex { AuditChain.hash($0) == segments.head })
        let inside = AuditChain.hash(all[headIndex - 1])
        #expect(await store.auditLines(after: inside) == Array(all[headIndex...]))
        #expect(await store.auditLines(after: "unknown") == nil)
    }

    @Test("human decisions of archived segments still show as approvals and asks")
    func decisionsSurviveArchiving() async throws {
        let dir = tempDir("audit-decisions")
        let store = VaultStore(directory: dir, keys: MemoryVaultKeyProvider())
        await store.setAuditLimits(segmentLimit: 1_000)
        let t0 = Date()
        var approval = entry("ASKED", at: t0, tier: .ask, decider: .human, action: "run")
        approval.requestId = "req_1"
        await store.append(approval)
        for n in 0..<20 {
            await store.append(entry("S\(n)", at: t0.addingTimeInterval(Double(n)), action: "run", command: String(repeating: "y", count: 60)))
        }
        try await waitForArchives(dir)
        #expect(await !store.archivedSegments().paths.isEmpty)
        #expect(!decode(await store.auditLines()).contains { $0.secret == "ASKED" })
        let approvals = await store.approvals(since: t0.addingTimeInterval(-60))
        #expect(approvals.map(\.secret) == ["ASKED"])
    }
}

private actor Pushes {
    var counts: [Int] = []
    func add(_ n: Int) { counts.append(n) }
}

@Suite("Audit mirrors")
struct VaultAuditMirrorTests {
    private func line(_ n: Int, prev: String) -> String {
        "{\"n\":\(n),\"prev\":\"\(prev)\"}"
    }

    private func chain(_ count: Int, from prev: String = "") -> [String] {
        var out: [String] = []
        var last = prev
        for n in 0..<count {
            let l = line(n, prev: last)
            out.append(l)
            last = AuditChain.hash(Data(l.utf8))
        }
        return out
    }

    @Test("lines that follow the mirror's last one are added without reading the mirror")
    func incrementalIngest() async throws {
        let store = VaultStore(directory: tempDir("mirror-inc"), keys: MemoryVaultKeyProvider())
        let lines = chain(300)
        _ = await store.appendMirror(machine: "mac", lines: Array(lines[0..<100]))
        let tail = await store.appendMirror(machine: "mac", lines: Array(lines[100..<300]))
        #expect(tail.count == 300)
        #expect(tail.lastHash == AuditChain.hash(Data(lines[299].utf8)))
        #expect(await store.mirrorStates["mac"]?.known == nil)

        // A resend of what is there adds nothing; only then are hashes read.
        let again = await store.appendMirror(machine: "mac", lines: Array(lines[250..<300]))
        #expect(again.count == 300)
        #expect(await store.mirrorStates["mac"]?.known?.count == 300)
        #expect(await store.mirrorLines(machine: "mac").map { String(decoding: $0, as: UTF8.self) } == lines)

        // A fresh store (a restart) reads the tail once and goes on.
        let reopened = VaultStore(directory: await store.directory, keys: MemoryVaultKeyProvider())
        let more = chain(5, from: AuditChain.hash(Data(lines[299].utf8)))
        #expect(await reopened.appendMirror(machine: "mac", lines: more).count == 305)
        #expect(await reopened.mirrorStates["mac"]?.known == nil)
    }

    @Test("a mirror archives its segments too and its tail stays the last line mirrored")
    func mirrorRotates() async throws {
        let dir = tempDir("mirror-rotate")
        let store = VaultStore(directory: dir, keys: MemoryVaultKeyProvider())
        await store.setAuditLimits(segmentLimit: 1_000)
        let lines = chain(100)
        for start in stride(from: 0, to: 100, by: 10) {
            _ = await store.appendMirror(machine: "mac", lines: Array(lines[start..<start + 10]))
        }
        try await waitForArchives(dir)
        let last = AuditChain.hash(Data(lines[99].utf8))
        #expect(await store.mirrorTail(machine: "mac").lastHash == last)
        let reopened = VaultStore(directory: dir, keys: MemoryVaultKeyProvider())
        #expect(await reopened.mirrorTail(machine: "mac").lastHash == last)
        let segments = await reopened.archivedSegments(mirror: "mac")
        #expect(!segments.paths.isEmpty)
        var all: [String] = []
        for path in segments.paths {
            VaultStore.forEachLine(inFileAt: path) { all.append(String(decoding: $0, as: UTF8.self)); return true }
        }
        all += await reopened.mirrorLines(machine: "mac").map { String(decoding: $0, as: UTF8.self) }
        #expect(all == lines)
        #expect(VaultAuditSync.log("mirror", await reopened.mirrorLines(machine: "mac"), archived: segments).breaks.isEmpty)
    }

    @Test("a push after the sender archived its log sends only what the mirror lacks")
    func pushAcrossRotation() async throws {
        let dir = tempDir("push-rotate")
        let box = VaultStore(directory: dir + "/box", keys: MemoryVaultKeyProvider())
        let mac = VaultStore(directory: dir + "/mac", keys: MemoryVaultKeyProvider())
        await box.setAuditLimits(segmentLimit: 1_200)
        let sent = Pushes()
        let sync = VaultAuditSync(store: box, machine: "box", peers: {
            [PeerConfig(id: "mac", name: "Mac", url: "http://mac", token: "t", enabled: true)]
        }) { request in
            if request.httpMethod == "GET" {
                return (try JSONEncoder().encode(await mac.mirrorTail(machine: "box")), 200)
            }
            let push = try JSONDecoder().decode(VaultAuditMirrorPush.self, from: request.httpBody ?? Data())
            await sent.add(push.lines.count)
            return (try JSONEncoder().encode(await mac.appendMirror(machine: push.machine, lines: push.lines)), 200)
        }
        let t0 = Date(timeIntervalSince1970: 1_800_000_000)
        for n in 0..<4 { await box.append(entry("S\(n)", at: t0.addingTimeInterval(Double(n)), action: "run")) }
        await sync.pushAll()
        // The mac falls behind while the box archives a segment or two.
        for n in 4..<30 { await box.append(entry("S\(n)", at: t0.addingTimeInterval(Double(n)), action: "run")) }
        try await waitForArchives(dir + "/box")
        #expect(await !box.archivedSegments().paths.isEmpty)
        await sync.pushAll()
        await sync.pushAll()
        let mirrored = decode(await mac.mirrorLines(machine: "box"))
        let pushed = await sent.counts
        // Only lines the mac lacked crossed, all of them once.
        #expect(pushed.reduce(0, +) <= 30)
        #expect(mirrored.map(\.secret).suffix(await box.auditLines().count) == decode(await box.auditLines()).map(\.secret))
        #expect(AuditChain.verify(await mac.mirrorLines(machine: "box")).isIntact)
    }

    @Test("comparing a mirror with its peer ignores what either side archived")
    func compareAcrossSegments() {
        let lines = chain(20).map { Data($0.utf8) }
        let hashes = lines.map(AuditChain.hash)
        // The peer archived through line 9; the mirror still holds all 20.
        var result = VaultAuditSync.compare(mirror: lines, mirrorHead: nil,
                                            peer: VaultAuditHashes(machine: "p", hashes: Array(hashes[10...]), head: hashes[9]))
        #expect(result.gone.isEmpty && result.notMirroredYet == 0)
        // The mirror archived through line 14; the peer has all 20.
        result = VaultAuditSync.compare(mirror: Array(lines[15...]), mirrorHead: hashes[14],
                                        peer: VaultAuditHashes(machine: "p", hashes: hashes))
        #expect(result.gone.isEmpty && result.notMirroredYet == 0)
        // Two lines behind, and one line the peer no longer has.
        var tampered = Array(hashes[..<18])
        tampered.remove(at: 5)
        result = VaultAuditSync.compare(mirror: Array(lines[..<16]), mirrorHead: nil,
                                        peer: VaultAuditHashes(machine: "p", hashes: tampered + Array(hashes[18...])))
        #expect(result.gone == [lines[5]])
        #expect(result.notMirroredYet == 4)
    }
}
