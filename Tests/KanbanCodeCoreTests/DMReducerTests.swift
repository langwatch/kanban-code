import Testing
import Foundation
@testable import KanbanCodeCore

@Suite("Reducer — DMs")
struct DMReducerTests {
    private func mkLink(id: String, tmuxName: String) -> Link {
        Link(id: id, name: id, column: .inProgress, tmuxLink: TmuxLink(sessionName: tmuxName))
    }

    @Test func selectDMEmitsLoadEffect() {
        var state = AppState()
        let other = ChannelParticipant(cardId: "card_A", handle: "alice")
        let effects = Reducer.reduce(state: &state, action: .selectDM(other: other))
        #expect(state.selectedDMParticipant == other)
        var sawLoad = false
        for e in effects {
            if case .loadDMMessages(_, let o) = e, o == other { sawLoad = true }
        }
        #expect(sawLoad)
    }

    @Test func deselectDMClearsState() {
        var state = AppState()
        state.selectedDMParticipant = ChannelParticipant(cardId: "x", handle: "y")
        let effects = Reducer.reduce(state: &state, action: .selectDM(other: nil))
        #expect(state.selectedDMParticipant == nil)
        #expect(effects.isEmpty)
    }

    @Test func dmMessagesLoadedKeysByOther() {
        var state = AppState()
        let other = ChannelParticipant(cardId: "card_A", handle: "alice")
        let p = ChannelParticipant(cardId: "card_A", handle: "alice")
        let msgs = [ChannelMessage(id: "m1", ts: .now, from: p, body: "hi")]
        _ = Reducer.reduce(state: &state, action: .dmMessagesLoaded(other: other, messages: msgs))
        #expect(state.dmMessages[Reducer.dmKey(other)]?.count == 1)
    }

    @Test func dmMessagesLoadedEmptyReloadPreservesExistingMessages() {
        var state = AppState()
        let other = ChannelParticipant(cardId: "card_A", handle: "alice")
        let existing = [
            ChannelMessage(id: "m1", ts: Date(timeIntervalSince1970: 100), from: other, body: "one"),
            ChannelMessage(id: "m2", ts: Date(timeIntervalSince1970: 200), from: other, body: "two"),
        ]
        state.dmMessages[Reducer.dmKey(other)] = existing

        let effects = Reducer.reduce(state: &state, action: .dmMessagesLoaded(other: other, messages: []))

        #expect(effects.isEmpty)
        #expect(state.dmMessages[Reducer.dmKey(other)] == existing)
    }

    @Test func sendDirectMessageEmitsDiskEffectWithTmuxSession() {
        var state = AppState()
        state.links["card_A"] = mkLink(id: "card_A", tmuxName: "sess-a")
        let other = ChannelParticipant(cardId: "card_A", handle: "alice")
        let effects = Reducer.reduce(state: &state, action: .sendDirectMessage(to: other, body: "hello"))
        var found = false
        for e in effects {
            if case .sendDMToDisk(_, let to, let body, _, let target) = e {
                #expect(to == other)
                #expect(body == "hello")
                #expect(target?.sessionName == "sess-a")
                found = true
            }
        }
        #expect(found)
    }

    @Test func sendDirectMessageWithNoCardEmitsNoTmuxSession() {
        var state = AppState()
        let other = ChannelParticipant(cardId: nil, handle: "no-card")
        let effects = Reducer.reduce(state: &state, action: .sendDirectMessage(to: other, body: "hi"))
        for e in effects {
            if case .sendDMToDisk(_, _, _, _, let target) = e {
                #expect(target == nil)
            }
        }
    }

    @Test func dmMessageAppendedIsSortedAndDeduped() {
        var state = AppState()
        let other = ChannelParticipant(cardId: "card_A", handle: "alice")
        let p = ChannelParticipant(cardId: "card_A", handle: "alice")
        let early = ChannelMessage(id: "m1", ts: Date(timeIntervalSince1970: 100), from: p, body: "first")
        let late  = ChannelMessage(id: "m2", ts: Date(timeIntervalSince1970: 200), from: p, body: "second")
        _ = Reducer.reduce(state: &state, action: .dmMessageAppended(other: other, message: late))
        _ = Reducer.reduce(state: &state, action: .dmMessageAppended(other: other, message: early))
        _ = Reducer.reduce(state: &state, action: .dmMessageAppended(other: other, message: late)) // dup
        let out = state.dmMessages[Reducer.dmKey(other)] ?? []
        #expect(out.count == 2)
        #expect(out.map(\.body) == ["first", "second"])
    }

    @Test func humanHandleUsesNSUserName() {
        let h = AppState.defaultHumanHandle()
        #expect(!h.isEmpty)
        // Slug rule: lowercase, digits, underscores only
        for ch in h {
            let isOk = ch.isLetter || ch.isNumber || ch == "_"
            #expect(isOk, "unexpected character in handle: \(ch)")
        }
    }

    @Test func sendChannelMessageUsesHumanParticipant() {
        var state = AppState()
        state.humanHandle = "rchaves"
        state.channels = [
            Channel(
                id: "ch", name: "general", createdAt: .now,
                createdBy: ChannelParticipant(cardId: nil, handle: "rchaves"),
                members: []
            )
        ]
        let effects = Reducer.reduce(state: &state, action: .sendChannelMessage(channelName: "general", body: "hi"))
        for e in effects {
            if case .sendChannelMessageToDisk(_, let from, _, _, _) = e {
                #expect(from.handle == "rchaves")
                #expect(from.cardId == nil)
            }
        }
    }

    @Test func dmMessagesLoadedDoesNotNotifyOnFirstLoad() {
        var state = AppState()
        state.humanHandle = "rchaves"
        let other = ChannelParticipant(cardId: "card_A", handle: "alice")
        let msg = ChannelMessage(id: "m1", ts: .now, from: other, body: "hey")
        // First load seeds the lastSeen marker; must NOT notify (would spam on app startup).
        let effects = Reducer.reduce(
            state: &state,
            action: .dmMessagesLoaded(other: other, messages: [msg])
        )
        #expect(!effects.contains { if case .notifyDMReceived = $0 { return true } else { return false } })
    }

    @Test func dmMessagesLoadedEmitsNotificationForNewInboundAfterFirstLoad() {
        var state = AppState()
        state.humanHandle = "rchaves"
        state.appIsFrontmost = false
        let other = ChannelParticipant(cardId: "card_A", handle: "alice")
        let existing = ChannelMessage(id: "m0", ts: Date(timeIntervalSince1970: 50), from: other, body: "old")
        // First load (backfill)
        _ = Reducer.reduce(state: &state, action: .dmMessagesLoaded(other: other, messages: [existing]))
        // Now a fresh inbound arrives.
        let fresh = ChannelMessage(id: "m1", ts: Date(timeIntervalSince1970: 100), from: other, body: "hey")
        let effects = Reducer.reduce(
            state: &state,
            action: .dmMessagesLoaded(other: other, messages: [existing, fresh])
        )
        var notified = false
        for e in effects {
            if case .notifyDMReceived(let from, let body) = e {
                #expect(from == "alice")
                #expect(body == "hey")
                notified = true
            }
        }
        #expect(notified)
        // Same load again should NOT re-notify.
        let effects2 = Reducer.reduce(
            state: &state,
            action: .dmMessagesLoaded(other: other, messages: [existing, fresh])
        )
        #expect(!effects2.contains { if case .notifyDMReceived = $0 { return true } else { return false } })
    }

    @Test func dmMessagesLoadedDoesNotNotifyWhenDrawerIsOpen() {
        var state = AppState()
        state.humanHandle = "rchaves"
        let other = ChannelParticipant(cardId: "card_A", handle: "alice")
        state.selectedDMParticipant = other
        let existing = ChannelMessage(id: "m0", ts: Date(timeIntervalSince1970: 50), from: other, body: "old")
        _ = Reducer.reduce(state: &state, action: .dmMessagesLoaded(other: other, messages: [existing]))
        let fresh = ChannelMessage(id: "m1", ts: .now, from: other, body: "hey")
        let effects = Reducer.reduce(
            state: &state,
            action: .dmMessagesLoaded(other: other, messages: [existing, fresh])
        )
        #expect(!effects.contains { if case .notifyDMReceived = $0 { return true } else { return false } })
    }

    @Test func dmMessagesLoadedDoesNotNotifyForOutbound() {
        var state = AppState()
        state.humanHandle = "rchaves"
        let other = ChannelParticipant(cardId: "card_A", handle: "alice")
        let mine = ChannelParticipant(cardId: nil, handle: "rchaves")
        let seed = ChannelMessage(id: "m0", ts: Date(timeIntervalSince1970: 50), from: other, body: "old")
        _ = Reducer.reduce(state: &state, action: .dmMessagesLoaded(other: other, messages: [seed]))
        let msg = ChannelMessage(id: "m1", ts: .now, from: mine, body: "hey")
        let effects = Reducer.reduce(
            state: &state,
            action: .dmMessagesLoaded(other: other, messages: [seed, msg])
        )
        #expect(!effects.contains { if case .notifyDMReceived = $0 { return true } else { return false } })
    }

    @Test func channelMessagesLoadedNotifiesOnlyForUnfocusedChannelsFromOthers() {
        var state = AppState()
        state.humanHandle = "rchaves"
        state.appIsFrontmost = false
        let other = ChannelParticipant(cardId: "card_A", handle: "alice")
        let seed = ChannelMessage(id: "m0", ts: Date(timeIntervalSince1970: 50), from: other, body: "old")
        _ = Reducer.reduce(state: &state, action: .channelMessagesLoaded(channelName: "general", messages: [seed]))
        let fresh = ChannelMessage(id: "m1", ts: .now, from: other, body: "standup in 5")
        let effects = Reducer.reduce(
            state: &state,
            action: .channelMessagesLoaded(channelName: "general", messages: [seed, fresh])
        )
        #expect(effects.contains { if case .notifyChannelMessage = $0 { return true } else { return false } })

        // Focused channel: do NOT notify on fresh msg.
        let seed2 = ChannelMessage(id: "o0", ts: Date(timeIntervalSince1970: 50), from: other, body: "old")
        _ = Reducer.reduce(state: &state, action: .channelMessagesLoaded(channelName: "ops", messages: [seed2]))
        state.selectedChannelName = "ops"
        let fresh2 = ChannelMessage(id: "o1", ts: .now, from: other, body: "x")
        let effects2 = Reducer.reduce(
            state: &state,
            action: .channelMessagesLoaded(channelName: "ops", messages: [seed2, fresh2])
        )
        #expect(!effects2.contains { if case .notifyChannelMessage = $0 { return true } else { return false } })
    }

    @Test func notificationsSuppressedWhenAppIsFrontmost() {
        var state = AppState()
        state.humanHandle = "rchaves"
        state.appIsFrontmost = true
        let other = ChannelParticipant(cardId: "card_A", handle: "alice")
        let seed = ChannelMessage(id: "m0", ts: Date(timeIntervalSince1970: 50), from: other, body: "old")
        _ = Reducer.reduce(state: &state, action: .dmMessagesLoaded(other: other, messages: [seed]))
        let fresh = ChannelMessage(id: "m1", ts: .now, from: other, body: "hey")
        let effects = Reducer.reduce(
            state: &state,
            action: .dmMessagesLoaded(other: other, messages: [seed, fresh])
        )
        #expect(!effects.contains { if case .notifyDMReceived = $0 { return true } else { return false } })
    }

    @Test func setAppFrontmostUpdatesState() {
        var state = AppState()
        #expect(state.appIsFrontmost == true) // default
        _ = Reducer.reduce(state: &state, action: .setAppFrontmost(false))
        #expect(state.appIsFrontmost == false)
        _ = Reducer.reduce(state: &state, action: .setAppFrontmost(true))
        #expect(state.appIsFrontmost == true)
    }

    @Test func channelsLoadedEmitsLoadEffectForEveryChannel() {
        var state = AppState()
        let chA = Channel(id: "ch_a", name: "alpha", createdAt: .now, createdBy: ChannelParticipant(cardId: nil, handle: "u"), members: [])
        let chB = Channel(id: "ch_b", name: "beta",  createdAt: .now, createdBy: ChannelParticipant(cardId: nil, handle: "u"), members: [])
        let effects = Reducer.reduce(state: &state, action: .channelsLoaded(channels: [chA, chB]))
        let names: [String] = effects.compactMap {
            if case .loadChannelMessages(let n) = $0 { return n } else { return nil }
        }
        #expect(Set(names) == Set(["alpha", "beta"]))
    }
}
