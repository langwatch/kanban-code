import Foundation
import KanbanCodeRemoteKit
import Testing

@testable import KanbanCodeCore

@Suite("Usage limit")
struct UsageLimitTests {
    static let amsterdam = TimeZone(identifier: "Europe/Amsterdam")!
    static let britishEnglish = Locale(identifier: "en_GB")
    /// Wednesday 4 Nov 2026, 19:00 in Amsterdam.
    static let now = ISO8601DateFormatter().date(from: "2026-11-04T18:00:00Z")!
    /// Saturday 7 Nov 2026, 08:00 in Amsterdam.
    static let saturday = ISO8601DateFormatter().date(from: "2026-11-07T07:00:00Z")!

    /// `rush session list --json` of a host stopped on its weekly limit.
    static let limitedHost = #"""
    {"id":"ed3d7731","sessionId":"ed3d7731-b17d","cwd":"/root/Projects/langwatch","name":"laze","state":"idle",
     "detail":"usage limit reached","limit":{"resetsAt":"2026-11-07T07:00:00Z","window":"seven_day","continue":false,"ask":true},
     "meta":{"kanban_card":"card_laze","kanban_session":"rush-ed3d7731"},"alive":true}
    """#

    @Test("rush's limit decodes, holds until it resets, and not while a turn runs again")
    func rushLimit() throws {
        let host = try JSONDecoder().decode(RushSessionInfo.self, from: Data(Self.limitedHost.utf8))
        #expect(host.limit == RemoteUsageLimit(window: "seven_day", resetsAt: Self.saturday))
        #expect(host.usageLimit(at: Self.now) == host.limit)
        #expect(host.usageLimit(at: Self.saturday.addingTimeInterval(1)) == nil)

        let working = try JSONDecoder().decode(RushSessionInfo.self, from: Data(
            Self.limitedHost.replacingOccurrences(of: #""state":"idle""#, with: #""state":"working""#).utf8))
        #expect(working.usageLimit(at: Self.now) == nil)

        let offset = try JSONDecoder().decode(RushSessionInfo.self, from: Data(
            Self.limitedHost.replacingOccurrences(of: "2026-11-07T07:00:00Z", with: "2026-11-07T08:00:00+01:00").utf8))
        #expect(offset.limit?.resetsAt == Self.saturday)
    }

    @Test("the paused line names the window and when it resets, in local time")
    func pausedLine() {
        let weekly = RemoteUsageLimit(window: "seven_day", resetsAt: Self.saturday)
        #expect(weekly.pausedLine(now: Self.now, timeZone: Self.amsterdam, locale: Self.britishEnglish)
            == "Paused: Claude weekly usage limit reached, resets Sat 08:00")

        let later = ISO8601DateFormatter().date(from: "2026-11-04T21:40:00Z")!
        let fiveHour = RemoteUsageLimit(window: "five_hour", resetsAt: later)
        #expect(fiveHour.pausedLine(assistant: "Codex", now: Self.now, timeZone: Self.amsterdam, locale: Self.britishEnglish)
            == "Paused: Codex 5-hour usage limit reached, resets 22:40")

        #expect(RemoteUsageLimit(window: "other").pausedLine(now: Self.now) == "Paused: Claude usage limit reached")
    }

    @Test("a rush scan puts the limit on the local card, and the remote card carries it while it holds")
    func localCard() {
        var state = AppState()
        let link = Link(id: "card_laze", name: "laze", projectPath: "/repo", column: .inProgress,
                        tmuxLink: TmuxLink(sessionName: "rush-ed3d7731"))
        state.links[link.id] = link
        let limit = RemoteUsageLimit(window: "seven_day", resetsAt: Date().addingTimeInterval(3600))
        let sessions = [TmuxSession(name: "rush-ed3d7731", path: "/repo", rushQueue: [], rushLimit: limit),
                        TmuxSession(name: "rush-other", path: "/repo", rushQueue: [])]
        _ = Reducer.reduce(state: &state, action: .rushLimitsScanned(BoardStore.rushLimits(in: sessions)))
        state.rebuildCards()

        let card = state.cards.first { $0.id == link.id }!
        #expect(card.activeUsageLimit() == limit)
        let remote = RemoteBoardMapper.card(card, liveSessions: ["rush-ed3d7731"])
        #expect(remote.usageLimit == limit)
        #expect(remote.pausedLine()?.hasPrefix("Paused: Claude weekly usage limit reached, resets ") == true)

        let lifted = RemoteUsageLimit(window: "seven_day", resetsAt: Date().addingTimeInterval(-60))
        _ = Reducer.reduce(state: &state, action: .rushLimitsScanned(["rush-ed3d7731": lifted]))
        state.rebuildCards()
        let after = state.cards.first { $0.id == link.id }!
        #expect(after.activeUsageLimit() == nil)
        #expect(RemoteBoardMapper.card(after, liveSessions: []).usageLimit == nil)
    }

    @Test("a card another master runs takes the limit its owner reports")
    func peerCard() throws {
        var state = AppState()
        state.localMachineId = "machine_mac"
        state.peerStatuses["peer_box"] = PeerStatus(peerId: "peer_box", machine: MachineIdentity(id: "machine_box", name: "box"), online: true)
        var link = Link(id: "card_laze", name: "laze", projectPath: "/repo", column: .inProgress,
                        tmuxLink: TmuxLink(sessionName: "rush-ed3d7731"))
        link.ownerMachine = "machine_box"
        state.links[link.id] = link

        let limit = RemoteUsageLimit(window: "seven_day", resetsAt: Date().addingTimeInterval(3600))
        let owner = RemoteCard(id: link.id, title: "laze", column: .inProgress, isLive: true, updatedAt: Date(), usageLimit: limit)
        let wire = try JSONEncoder.remote.encode(owner)
        let decoded = try JSONDecoder.remote.decode(RemoteCard.self, from: wire)
        #expect(decoded.usageLimit?.window == "seven_day")

        _ = Reducer.reduce(state: &state, action: .peerActivityScanned(cards: [link.id: PeerTranscriptMirror.state(of: decoded)]))
        state.rebuildCards()
        #expect(state.cards.first { $0.id == link.id }?.activeUsageLimit()?.window == "seven_day")
    }

    @Test("a card with no limit leaves the key out of its JSON")
    func noLimitJSON() throws {
        let card = RemoteCard(id: "c", title: "t", column: .backlog, updatedAt: Date())
        let json = String(decoding: try JSONEncoder.remote.encode(card), as: UTF8.self)
        #expect(!json.contains("usageLimit"))
    }
}
