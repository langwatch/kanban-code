import Testing
import Foundation
@testable import KanbanCodeCore

@Suite("Reducer — Channels")
struct ChannelReducerTests {
    private func stateWith(_ links: [Link]) -> AppState {
        let state = AppState()
        for l in links { state.links[l.id] = l }
        return state
    }

    private func member(_ handle: String, cardId: String?) -> ChannelMember {
        ChannelMember(cardId: cardId, handle: handle, joinedAt: .now)
    }

    private func channel(name: String = "general", members: [ChannelMember] = []) -> Channel {
        Channel(
            id: "ch_\(name)",
            name: name,
            createdAt: .now,
            createdBy: ChannelParticipant(cardId: nil, handle: "user"),
            members: members
        )
    }

    @Test func channelsLoadedSortsByCreation() {
        var state = AppState()
        let a = Channel(id: "ch_a", name: "alpha", createdAt: Date(timeIntervalSince1970: 200), createdBy: ChannelParticipant(cardId: nil, handle: "u"), members: [])
        let b = Channel(id: "ch_b", name: "beta", createdAt: Date(timeIntervalSince1970: 100), createdBy: ChannelParticipant(cardId: nil, handle: "u"), members: [])
        let effects = Reducer.reduce(state: &state, action: .channelsLoaded(channels: [a, b]))
        #expect(state.channels.map(\.name) == ["beta", "alpha"])
        // New behaviour: loads messages for every channel so tiles show timestamps.
        let loaded = effects.compactMap { (e: Effect) -> String? in
            if case .loadChannelMessages(let n) = e { return n } else { return nil }
        }
        #expect(Set(loaded) == Set(["alpha", "beta"]))
    }

    @Test func selectChannelEmitsLoadMessagesEffect() {
        var state = AppState()
        let effects = Reducer.reduce(state: &state, action: .selectChannel(name: "general"))
        #expect(state.selectedChannelName == "general")
        #expect(effects.contains { if case .loadChannelMessages(let n) = $0 { return n == "general" } else { return false } })
    }

    @Test func deselectChannelEmitsNoEffect() {
        var state = AppState()
        state.selectedChannelName = "general"
        let effects = Reducer.reduce(state: &state, action: .selectChannel(name: nil))
        #expect(state.selectedChannelName == nil)
        #expect(effects.isEmpty)
    }

    @Test func createChannelNormalizesAndEmitsEffect() {
        var state = AppState()
        let effects = Reducer.reduce(state: &state, action: .createChannel(name: "#Ops"))
        var sawCreate = false
        for e in effects {
            if case .createChannelOnDisk(let n, _) = e, n == "ops" { sawCreate = true }
        }
        #expect(sawCreate, "createChannelOnDisk effect missing or wrong name")
    }

    @Test func createChannelRejectsEmptyName() {
        var state = AppState()
        let effects = Reducer.reduce(state: &state, action: .createChannel(name: "  "))
        #expect(effects.isEmpty)
    }

    @Test func kickChannelMemberRemovesOptimisticallyAndEmitsEffect() {
        var state = AppState()
        let now = Date()
        state.channels = [Channel(
            id: "ch_1", name: "general", createdAt: now,
            createdBy: ChannelParticipant(cardId: nil, handle: "me"),
            members: [
                ChannelMember(cardId: "card_A", handle: "alice", joinedAt: now),
                ChannelMember(cardId: "card_B", handle: "bob",   joinedAt: now),
            ]
        )]
        let effects = Reducer.reduce(state: &state, action: .kickChannelMember(
            channelName: "#General",
            member: ChannelParticipant(cardId: "card_A", handle: "alice")
        ))
        // Optimistic: chip disappears immediately.
        #expect(state.channels[0].members.map(\.handle) == ["bob"])
        // Effect: writes to disk + reloads so the watcher refreshes.
        var sawLeave = false
        for e in effects {
            if case .leaveChannelOnDisk(let n, let m) = e, n == "general", m.handle == "alice" {
                sawLeave = true
            }
        }
        #expect(sawLeave, "expected leaveChannelOnDisk(name: general, alice)")
    }

    @Test func kickChannelMemberMatchesByHandleWhenCardIdMissing() {
        // Covers kicking a ghost agent whose card was already deleted — the
        // roster entry still has the cardId but the dispatched action only
        // has the handle, so the reducer must fall back to handle matching.
        var state = AppState()
        state.channels = [Channel(
            id: "ch_1", name: "general", createdAt: Date(),
            createdBy: ChannelParticipant(cardId: nil, handle: "me"),
            members: [ChannelMember(cardId: "card_dead", handle: "ghost", joinedAt: Date())]
        )]
        _ = Reducer.reduce(state: &state, action: .kickChannelMember(
            channelName: "general",
            member: ChannelParticipant(cardId: nil, handle: "ghost")
        ))
        #expect(state.channels[0].members.isEmpty)
    }

    @Test func kickChannelMemberIsNoOpForUnknownChannel() {
        var state = AppState()
        let effects = Reducer.reduce(state: &state, action: .kickChannelMember(
            channelName: "does-not-exist",
            member: ChannelParticipant(cardId: nil, handle: "alice")
        ))
        #expect(effects.isEmpty)
    }

    @Test func channelMessageAppendedIsSortedAndDeduped() {
        var state = AppState()
        let p = ChannelParticipant(cardId: "card_A", handle: "alice")
        let m1 = ChannelMessage(id: "msg_1", ts: Date(timeIntervalSince1970: 100), from: p, body: "first")
        let m2 = ChannelMessage(id: "msg_2", ts: Date(timeIntervalSince1970: 200), from: p, body: "second")
        _ = Reducer.reduce(state: &state, action: .channelMessageAppended(channelName: "general", message: m2))
        _ = Reducer.reduce(state: &state, action: .channelMessageAppended(channelName: "general", message: m1))
        _ = Reducer.reduce(state: &state, action: .channelMessageAppended(channelName: "general", message: m1)) // dup
        let msgs = state.channelMessages["general"] ?? []
        #expect(msgs.count == 2)
        #expect(msgs.map(\.body) == ["first", "second"])
    }

    @Test func sendChannelMessageProducesDiskEffectWithMemberSessions() {
        var state = AppState()
        // Two cards with tmux sessions linked
        state.links["card_A"] = Link(id: "card_A", name: "alice", column: .inProgress, tmuxLink: TmuxLink(sessionName: "sess-a"))
        state.links["card_B"] = Link(id: "card_B", name: "bob",   column: .inProgress, tmuxLink: TmuxLink(sessionName: "sess-b"))
        let ch = channel(members: [
            member("user", cardId: nil),
            member("alice", cardId: "card_A"),
            member("bob",   cardId: "card_B"),
        ])
        state.channels = [ch]

        let effects = Reducer.reduce(
            state: &state,
            action: .sendChannelMessage(channelName: "general", body: "hello")
        )
        var foundSessions: [String] = []
        for e in effects {
            if case .sendChannelMessageToDisk(_, _, _, _, let targets) = e {
                foundSessions = targets.map(\.sessionName)
            }
        }
        #expect(foundSessions.sorted() == ["sess-a", "sess-b"])
    }

    @Test func sendChannelMessageSkipsUserlikeMembers() {
        var state = AppState()
        let ch = channel(members: [ member("user", cardId: nil) ])
        state.channels = [ch]
        let effects = Reducer.reduce(
            state: &state,
            action: .sendChannelMessage(channelName: "general", body: "nobody here")
        )
        for e in effects {
            if case .sendChannelMessageToDisk(_, _, _, _, let targets) = e {
                #expect(targets.isEmpty)
            }
        }
    }

    @Test func markChannelReadStoresLatestMessageId() {
        var state = AppState()
        let p = ChannelParticipant(cardId: "card_A", handle: "alice")
        state.channelMessages["general"] = [
            ChannelMessage(id: "m1", ts: Date(timeIntervalSince1970: 100), from: p, body: "old"),
            ChannelMessage(id: "m2", ts: Date(timeIntervalSince1970: 1000), from: p, body: "newest"),
        ]
        let effects = Reducer.reduce(state: &state, action: .markChannelRead(name: "general"))
        #expect(state.channelLastReadMessageId["general"] == "m2")
        var sawPersist = false
        for e in effects {
            if case .persistChannelReadState(let ch, _) = e, ch["general"] == "m2" { sawPersist = true }
        }
        #expect(sawPersist)
    }

    // Regression: the last entry in the jsonl was a join event, so pinning
    // `last?.id` pointed at an id that the unread counter filters out of its
    // search, and counted *every* real message as unread on the next render.
    // After the fix, we pin to the last `.message`, skipping join/leave/system.
    @Test func markChannelReadSkipsTrailingJoinEvents() {
        var state = AppState()
        let alice = ChannelParticipant(cardId: "card_A", handle: "alice")
        let bob = ChannelParticipant(cardId: "card_B", handle: "bob")
        state.channelMessages["general"] = [
            ChannelMessage(id: "m1", ts: Date(timeIntervalSince1970: 100), from: alice, body: "hi"),
            ChannelMessage(id: "m2", ts: Date(timeIntervalSince1970: 200), from: alice, body: "later"),
            ChannelMessage(id: "j1", ts: Date(timeIntervalSince1970: 300), from: bob, body: "joined", type: .join),
        ]
        _ = Reducer.reduce(state: &state, action: .markChannelRead(name: "general"))
        #expect(state.channelLastReadMessageId["general"] == "m2",
                "read marker must pin to the last real message, not the trailing join event")
    }

    @Test func selectChannelSkipsTrailingJoinEvents() {
        var state = AppState()
        let alice = ChannelParticipant(cardId: "card_A", handle: "alice")
        let bob = ChannelParticipant(cardId: "card_B", handle: "bob")
        state.channelMessages["general"] = [
            ChannelMessage(id: "m1", ts: Date(timeIntervalSince1970: 100), from: alice, body: "hi"),
            ChannelMessage(id: "m2", ts: Date(timeIntervalSince1970: 200), from: alice, body: "later"),
            ChannelMessage(id: "j1", ts: Date(timeIntervalSince1970: 300), from: bob, body: "joined", type: .join),
        ]
        _ = Reducer.reduce(state: &state, action: .selectChannel(name: "general"))
        #expect(state.channelLastReadMessageId["general"] == "m2")
    }

    @Test func incomingJoinEventWhileFocusedDoesNotMoveReadMarker() {
        // If the drawer is open and someone joins, the reducer used to pin the
        // read marker to the join event id — breaking the unread counter from
        // that point forward.
        var state = AppState()
        state.selectedChannelName = "general"
        let alice = ChannelParticipant(cardId: "card_A", handle: "alice")
        let bob = ChannelParticipant(cardId: "card_B", handle: "bob")
        state.channelMessages["general"] = [
            ChannelMessage(id: "m1", ts: Date(timeIntervalSince1970: 100), from: alice, body: "hi"),
        ]
        state.channelLastReadMessageId["general"] = "m1"

        let join = ChannelMessage(id: "j1", ts: Date(timeIntervalSince1970: 200), from: bob, body: "joined", type: .join)
        _ = Reducer.reduce(state: &state, action: .channelMessageAppended(channelName: "general", message: join))
        #expect(state.channelLastReadMessageId["general"] == "m1",
                "a join event must not advance the read marker")
    }

    @Test func selectChannelMarksAsRead() {
        var state = AppState()
        let p = ChannelParticipant(cardId: "card_A", handle: "alice")
        state.channelMessages["general"] = [
            ChannelMessage(id: "m1", ts: Date(timeIntervalSince1970: 2000), from: p, body: "newest"),
        ]
        _ = Reducer.reduce(state: &state, action: .selectChannel(name: "general"))
        #expect(state.channelLastReadMessageId["general"] == "m1")
    }

    @Test func channelMessageAppendedForMyMessageMarksAsRead() {
        var state = AppState()
        state.humanHandle = "rchaves"
        state.selectedChannelName = nil
        let me = ChannelParticipant(cardId: nil, handle: "rchaves")
        let mine = ChannelMessage(id: "m1", ts: Date(timeIntervalSince1970: 5000), from: me, body: "hi")
        _ = Reducer.reduce(state: &state, action: .channelMessageAppended(channelName: "general", message: mine))
        #expect(state.channelLastReadMessageId["general"] == "m1")
    }

    @Test func channelMessageAppendedForOthersDoesNotBumpWhenDrawerClosed() {
        var state = AppState()
        state.humanHandle = "rchaves"
        state.selectedChannelName = nil
        let other = ChannelParticipant(cardId: "card_A", handle: "alice")
        let msg = ChannelMessage(id: "m1", ts: Date(timeIntervalSince1970: 5000), from: other, body: "hi")
        _ = Reducer.reduce(state: &state, action: .channelMessageAppended(channelName: "general", message: msg))
        #expect(state.channelLastReadMessageId["general"] == nil)
    }

    @Test func channelMessageAppendedForOthersBumpsReadIfFocused() {
        var state = AppState()
        state.humanHandle = "rchaves"
        state.selectedChannelName = "general"
        let other = ChannelParticipant(cardId: "card_A", handle: "alice")
        let msg = ChannelMessage(id: "m1", ts: Date(timeIntervalSince1970: 5000), from: other, body: "hi")
        _ = Reducer.reduce(state: &state, action: .channelMessageAppended(channelName: "general", message: msg))
        #expect(state.channelLastReadMessageId["general"] == "m1")
    }

    @Test func openDrawerEnforcesMutualExclusion() {
        var state = AppState()
        state.selectedCardId = "card_X"
        #expect(state.openDrawer == .card("card_X"))
        #expect(state.selectedChannelName == nil)

        state.selectedChannelName = "general"
        #expect(state.openDrawer == .channel("general"))
        #expect(state.selectedCardId == nil) // card got evicted by enum

        let other = ChannelParticipant(cardId: "card_Y", handle: "alice")
        state.selectedDMParticipant = other
        #expect(state.openDrawer == .dm(other))
        #expect(state.selectedChannelName == nil) // channel got evicted
    }

    @Test func closeDrawerClearsEverything() {
        var state = AppState()
        state.openDrawer = .channel("general")
        _ = Reducer.reduce(state: &state, action: .closeDrawer)
        #expect(state.openDrawer == .none)
        #expect(state.selectedChannelName == nil)
    }

    @Test func sendChannelMessageCarriesPerMemberAssistantForImageFanout() {
        var state = AppState()
        state.links["card_A"] = Link(
            id: "card_A", name: "alice", column: .inProgress,
            tmuxLink: TmuxLink(sessionName: "sess-a")
        )
        state.links["card_B"] = Link(
            id: "card_B", name: "bob", column: .inProgress,
            tmuxLink: TmuxLink(sessionName: "sess-b")
        )
        // Override assistant: bob is on Gemini (doesn't support images).
        state.links["card_B"]?.assistant = .gemini
        let ch = channel(members: [
            member("alice", cardId: "card_A"),
            member("bob",   cardId: "card_B"),
        ])
        state.channels = [ch]
        let effects = Reducer.reduce(
            state: &state,
            action: .sendChannelMessage(channelName: "general", body: "hi", imagePaths: ["/tmp/x.png"])
        )
        var saw: [ChannelMemberTarget] = []
        for e in effects {
            if case .sendChannelMessageToDisk(_, _, _, _, let targets) = e {
                saw = targets
            }
        }
        // Both members represented, each with their assistant attached so the
        // EffectHandler can pick image-paste path per-target.
        let bySession = Dictionary(uniqueKeysWithValues: saw.map { ($0.sessionName, $0.assistant) })
        #expect(bySession["sess-a"] == .claude)
        #expect(bySession["sess-b"] == .gemini)
    }

    @Test func channelMessagesLoadedSeedsReadMarkerOnFirstLoad() {
        var state = AppState()
        let p = ChannelParticipant(cardId: "card_A", handle: "alice")
        let messages = [
            ChannelMessage(id: "m1", ts: Date(timeIntervalSince1970: 100), from: p, body: "one"),
            ChannelMessage(id: "m2", ts: Date(timeIntervalSince1970: 200), from: p, body: "two"),
        ]
        _ = Reducer.reduce(state: &state, action: .channelMessagesLoaded(channelName: "general", messages: messages))
        // First-load seeds lastReadMessageId to latest so pre-existing history
        // doesn't blast N unreads.
        #expect(state.channelLastReadMessageId["general"] == "m2")
    }

    @Test func channelMessagesLoadedSecondLoadDoesNotReseedReadMarker() {
        var state = AppState()
        state.channelMessages["general"] = []
        state.channelLastReadMessageId["general"] = "m1" // already seeded
        let p = ChannelParticipant(cardId: "card_A", handle: "alice")
        let messages = [
            ChannelMessage(id: "m1", ts: Date(timeIntervalSince1970: 100), from: p, body: "one"),
            ChannelMessage(id: "m2", ts: Date(timeIntervalSince1970: 200), from: p, body: "two"),
        ]
        state.selectedChannelName = nil // drawer closed
        _ = Reducer.reduce(state: &state, action: .channelMessagesLoaded(channelName: "general", messages: messages))
        // Second load should NOT advance the marker (m2 would make m2 appear read).
        #expect(state.channelLastReadMessageId["general"] == "m1")
    }

    @Test func channelMessagesLoadedEmptyReloadPreservesExistingMessages() {
        var state = AppState()
        let p = ChannelParticipant(cardId: "card_A", handle: "alice")
        let existing = [
            ChannelMessage(id: "m1", ts: Date(timeIntervalSince1970: 100), from: p, body: "one"),
            ChannelMessage(id: "m2", ts: Date(timeIntervalSince1970: 200), from: p, body: "two"),
        ]
        state.channelMessages["general"] = existing

        let effects = Reducer.reduce(state: &state, action: .channelMessagesLoaded(channelName: "general", messages: []))

        #expect(effects.isEmpty)
        #expect(state.channelMessages["general"] == existing)
    }

    @Test func draftActionsPersistToState() {
        var state = AppState()
        let effects = Reducer.reduce(state: &state, action: .setChannelDraft(channelName: "general", body: "hey"))
        #expect(state.channelDrafts["general"] == "hey")
        var sawPersist = false
        for e in effects {
            if case .persistDrafts(let ch, _) = e, ch["general"] == "hey" { sawPersist = true }
        }
        #expect(sawPersist)

        // Empty body removes the draft.
        _ = Reducer.reduce(state: &state, action: .setChannelDraft(channelName: "general", body: ""))
        #expect(state.channelDrafts["general"] == nil)
    }

    @Test func channelReadStateLoadedPopulatesState() {
        var state = AppState()
        _ = Reducer.reduce(state: &state, action: .channelReadStateLoaded(channels: ["general": "m1"], dms: [:]))
        #expect(state.channelLastReadMessageId["general"] == "m1")
    }
}
