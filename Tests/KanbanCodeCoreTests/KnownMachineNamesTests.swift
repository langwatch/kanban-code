import Testing
import Foundation
@testable import KanbanCodeCore

@Suite("Known machine names")
struct KnownMachineNamesTests {
    private func board(owner: String) -> AppState {
        let state = AppState()
        _ = Reducer.reduce(state: state, action: .localMachineLoaded(MachineIdentity(id: "machine_mac", name: "mac")))
        var link = Link(id: "card_box", name: "Box card", projectPath: "/Users/acme/widgets", column: .inProgress)
        link.ownerMachine = owner
        state.links[link.id] = link
        return state
    }

    @Test("a card on a peer that has not answered shows the name the peer last reported, offline")
    func cachedNameWhileOffline() {
        let state = board(owner: "machine_box")
        _ = Reducer.reduce(state: state, action: .knownMachineNamesLoaded(["machine_box": "rchaves-platform"]))
        _ = Reducer.reduce(state: state, action: .peerStatusChanged(PeerStatus(peerId: "peer_box", online: false)))
        state.rebuildCards()
        let owner = state.cards.first?.owner
        #expect(owner?.name == "rchaves-platform")
        #expect(owner?.online == false)
        #expect(state.peerMachineNames["machine_box"] == "rchaves-platform")
        #expect(state.peerMachineName("machine_box") == "rchaves-platform")
    }

    @Test("a machine never seen still shows its id")
    func neverSeenShowsId() {
        let state = board(owner: "machine_unknown")
        _ = Reducer.reduce(state: state, action: .knownMachineNamesLoaded(["machine_box": "rchaves-platform"]))
        state.rebuildCards()
        #expect(state.cards.first?.owner?.name == "machine_unknown")
        #expect(state.cards.first?.owner?.online == false)
        #expect(state.peerMachineName("machine_unknown") == nil)
    }

    @Test("a peer that answers records its name for the next launch, and a rename wins over the stored name")
    func peerAnswerPersistsName() {
        let state = board(owner: "machine_box")
        _ = Reducer.reduce(state: state, action: .knownMachineNamesLoaded(["machine_box": "old-name"]))
        let answered = PeerStatus(peerId: "peer_box", machine: MachineIdentity(id: "machine_box", name: "rchaves-platform"), online: true)
        let effects = Reducer.reduce(state: state, action: .peerStatusChanged(answered))
        #expect(effects.contains { if case .persistKnownMachineNames(let names) = $0 { names == ["machine_box": "rchaves-platform"] } else { false } })
        // The same name again writes nothing.
        let again = Reducer.reduce(state: state, action: .peerStatusChanged(answered))
        #expect(!again.contains { if case .persistKnownMachineNames = $0 { true } else { false } })
        // A stale file loaded late does not undo the name the peer reported.
        _ = Reducer.reduce(state: state, action: .knownMachineNamesLoaded(["machine_box": "old-name"]))
        #expect(state.knownMachineNames["machine_box"] == "rchaves-platform")
        state.rebuildCards()
        #expect(state.cards.first?.owner == CardOwner(id: "machine_box", name: "rchaves-platform", online: true))
    }

    @Test("the store round-trips names and reads a missing file as empty")
    func storeRoundTrip() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("known-machines-\(UUID().uuidString)").path
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let store = KnownMachinesStore(basePath: dir)
        #expect(store.read().isEmpty)
        try store.write(["machine_box": "rchaves-platform"])
        #expect(store.read() == ["machine_box": "rchaves-platform"])
    }
}
