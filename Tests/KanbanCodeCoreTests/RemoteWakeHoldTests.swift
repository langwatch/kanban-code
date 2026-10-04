import Foundation
import Synchronization
import Testing

@testable import KanbanCodeCore
import KanbanCodeRemoteKit

@Suite("Staying awake for the phone")
struct RemoteWakeHoldTests {
    private final class Power: Sendable {
        let taken = Mutex<[TimeInterval]>([])
        let dropped = Mutex<[UInt32]>([])
        let enabled = Mutex(true)

        func hold() -> RemoteWakeHold {
            RemoteWakeHold(
                take: { [self] seconds in taken.withLock { $0.append(seconds); return UInt32($0.count) } },
                drop: { [self] id in dropped.withLock { $0.append(id) } },
                enabled: { [self] in enabled.withLock { $0 } })
        }
    }

    @Test(arguments: [
        (RemoteScope.full, nil as String?, true),
        (.full, "1", true),
        (.peer, "1", true),
        (.peer, nil, false),
        (.peer, "0", false),
        (.agent, "1", false),
        (.terminal, "1", false),
    ])
    func whoActsForTheHuman(scope: RemoteScope, header: String?, counts: Bool) {
        #expect(RemoteActivityPolicy.actsForOwner(scope: scope, header: header) == counts)
    }

    @Test func onlyCardRoutesNameACard() {
        #expect(RemoteActivityPolicy.card(rest: ["cards", "c1", "side-chat"]) == "c1")
        #expect(RemoteActivityPolicy.card(rest: ["cards", "c1", "transcript"]) == "c1")
        #expect(RemoteActivityPolicy.card(rest: ["cards", "c1"]) == "c1")
        // What a paired master and an open app poll on their own.
        for rest in [["board"], ["events"], ["links"], ["sync", "state"], ["attention"], ["machines"], ["cards"]] {
            #expect(RemoteActivityPolicy.card(rest: rest) == nil)
        }
    }

    @Test func aRequestHoldsTheMacForTheWindow() {
        let power = Power()
        let hold = power.hold()
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        #expect(!hold.isHolding(now: start))
        hold.touch(card: "c1", now: start)
        #expect(power.taken.withLock { $0 } == [RemoteWakeHold.window + 30])
        #expect(hold.isHolding(now: start.addingTimeInterval(RemoteWakeHold.window - 1)))
        #expect(!hold.isHolding(now: start.addingTimeInterval(RemoteWakeHold.window + 1)))
    }

    @Test func laterRequestsExtendItAndRenewTheAssertionAtMostEveryHalfMinute() {
        let power = Power()
        let hold = power.hold()
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        hold.touch(card: "c1", now: start)
        // A side chat poll every quarter second takes no new assertion.
        hold.touch(card: "c1", now: start.addingTimeInterval(0.25))
        hold.touch(card: "c1", now: start.addingTimeInterval(20))
        #expect(power.taken.withLock { $0.count } == 1)
        hold.touch(card: "c1", now: start.addingTimeInterval(300))
        #expect(power.taken.withLock { $0.count } == 2)
        #expect(power.dropped.withLock { $0 } == [1])
        #expect(hold.isHolding(now: start.addingTimeInterval(300 + RemoteWakeHold.window - 1)))
    }

    @Test func theSwitchTurnsItOffAndLetsGo() {
        let power = Power()
        let hold = power.hold()
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        hold.touch(card: "c1", now: start)
        power.enabled.withLock { $0 = false }
        #expect(!hold.isHolding(now: start.addingTimeInterval(1)))
        hold.touch(card: "c1", now: start.addingTimeInterval(60))
        #expect(power.taken.withLock { $0.count } == 1)
        #expect(power.dropped.withLock { $0 } == [1])
    }

    @Test func theWindowCoversAWholeSideChatRun() {
        #expect(RemoteWakeHold.window >= ClaudeSideChatRunner().timeout)
    }

    @Test func theServerReportsOnlyWhatTheHumanDoesToACard() async throws {
        let dir = (NSTemporaryDirectory() as NSString).appendingPathComponent("remote-activity-\(UUID().uuidString)")
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let devices = RemoteDeviceStore(path: dir + "/devices.json")
        let phone = try devices.add(name: "iPhone", scope: .full).token
        let agent = try devices.add(name: "agent", scope: .agent).token
        let master = try devices.add(name: "box", scope: .peer).token
        let seen = Mutex<[String]>([])
        let server = RemoteControlServer(
            host: FakeRemoteHost(), devices: devices, port: 0, bindAddresses: { [RemoteNetworkAddresses.loopback] },
            options: .init(appVersion: "test", hostName: "test-mac"),
            activity: { card in seen.withLock { $0.append(card) } })
        try await server.start()
        defer { server.stop() }

        func get(_ path: String, token: String, forOwner: Bool = false) async throws {
            var request = URLRequest(url: URL(string: "http://127.0.0.1:\(server.port)\(path)")!)
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            if forOwner { request.setValue("1", forHTTPHeaderField: RemoteActingFor.header) }
            _ = try await URLSession.shared.data(for: request)
        }

        try await get("/v1/board", token: phone)
        try await get("/v1/cards/card_a/transcript", token: agent)
        // A paired master copying a transcript for itself.
        try await get("/v1/cards/card_b/transcript/raw", token: master)
        #expect(seen.withLock { $0 } == [])

        try await get("/v1/cards/card_c/transcript", token: phone)
        // A paired master passing on what the phone asked it.
        try await get("/v1/cards/card_d/transcript", token: master, forOwner: true)
        #expect(seen.withLock { $0 } == ["card_c", "card_d"])
    }
}
