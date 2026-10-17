import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing
@testable import KanbanCodeCore
@testable import KanbanCodeRemoteKit

private actor PushCounts {
    var counts: [Int] = []
    func add(_ count: Int) { counts.append(count) }
}

@Suite("Reading the end of an audit log")
struct VaultAuditTailTests {
    private func log(_ count: Int) throws -> (path: String, lines: [Data]) {
        let dir = NSTemporaryDirectory() + "audit-tail-" + UUID().uuidString
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let lines = (0..<count).map { Data("{\"n\":\($0),\"pad\":\"\(String(repeating: "x", count: $0 % 13))\"}".utf8) }
        let path = dir + "/audit.jsonl"
        try Data(lines.joined(separator: [0x0A]) + [0x0A]).write(to: URL(fileURLWithPath: path))
        return (path, lines)
    }

    @Test("the lines after a hash come back oldest first, across block edges", arguments: [7, 64, 1 << 20])
    func linesAfterAHash(blockSize: Int) throws {
        let (path, lines) = try log(200)
        for at in [0, 1, 57, 198, 199] {
            let after = VaultStore.lines(after: AuditChain.hash(lines[at]), inFileAt: path, blockSize: blockSize)
            #expect(after == Array(lines[(at + 1)...]))
        }
    }

    @Test("a hash no line has gives nil, so the caller sends the whole log")
    func unknownHash() throws {
        let (path, _) = try log(30)
        #expect(VaultStore.lines(after: "nope", inFileAt: path, blockSize: 16) == nil)
        #expect(VaultStore.lines(after: "nope", inFileAt: path + ".missing") == nil)
    }

    @Test("the tail counts the lines and returns the last, without a trailing newline too", arguments: [5, 64, 1 << 20])
    func tail(blockSize: Int) throws {
        let (path, lines) = try log(120)
        var result = VaultStore.tail(ofFileAt: path, blockSize: blockSize)
        #expect(result.count == 120)
        #expect(result.last == lines.last)

        try Data(lines.joined(separator: [0x0A])).write(to: URL(fileURLWithPath: path))
        result = VaultStore.tail(ofFileAt: path, blockSize: blockSize)
        #expect(result.count == 120)
        #expect(result.last == lines.last)
        #expect(VaultStore.tail(ofFileAt: path + ".missing").count == 0)
    }

    @Test("a push sends only the lines the mirror lacks")
    func pushSendsTheTail() async throws {
        let dir = NSTemporaryDirectory() + "audit-push-" + UUID().uuidString
        let box = VaultStore(directory: dir + "/box", keys: MemoryVaultKeyProvider())
        let mac = VaultStore(directory: dir + "/mac", keys: MemoryVaultKeyProvider())
        let sent = PushCounts()
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
        func entry(_ secret: String) -> VaultAuditEntry {
            VaultAuditEntry(machine: "box", cardId: "card_1", secret: secret, tier: .open, outcome: .allowed, decider: .tier, action: "run")
        }
        for n in 0..<5 { await box.append(entry("S\(n)")) }
        await sync.pushAll()
        await box.append(entry("S5"))
        await sync.pushAll()
        #expect(await sent.counts == [5, 1])
        #expect(await mac.mirrorLines(machine: "box") == box.auditLines())
    }
}
