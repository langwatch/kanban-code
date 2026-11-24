import Foundation
import Testing

@testable import KanbanCodeCore

@Suite("Images pasted into a card's terminal")
struct TerminalImagePasteTests {
    @Test("the route is the card's owner, then the machine, then this Mac")
    func route() {
        #expect(TerminalImageRoute.route(peerCard: nil, machine: nil) == .local)
        #expect(TerminalImageRoute.route(peerCard: nil, machine: "gpu-1") == .machine("gpu-1"))
        #expect(TerminalImageRoute.route(peerCard: ("machine_box", "card_1"), machine: nil)
            == .peer(machineId: "machine_box", cardId: "card_1"))
        // A card another master owns streams from there, whatever this Mac knows of the session.
        #expect(TerminalImageRoute.route(peerCard: ("machine_box", "card_1"), machine: "gpu-1")
            == .peer(machineId: "machine_box", cardId: "card_1"))
    }

    @Test("an image alone is uploaded when the assistant runs elsewhere; text wins; a local card pastes as before")
    func plan() {
        let peer = TerminalImageRoute.peer(machineId: "machine_box", cardId: "card_1")
        for isRush in [false, true] {
            #expect(TerminalPastePlan.plan(hasText: false, hasImage: true, route: peer, isRush: isRush) == .upload(peer))
            #expect(TerminalPastePlan.plan(hasText: false, hasImage: true, route: .machine("gpu-1"), isRush: isRush)
                == .upload(.machine("gpu-1")))
            #expect(TerminalPastePlan.plan(hasText: true, hasImage: true, route: peer, isRush: isRush) == .text)
            #expect(TerminalPastePlan.plan(hasText: true, hasImage: false, route: peer, isRush: isRush) == .text)
            #expect(TerminalPastePlan.plan(hasText: false, hasImage: false, route: peer, isRush: isRush) == .text)
            #expect(TerminalPastePlan.plan(hasText: true, hasImage: true, route: .local, isRush: isRush) == .text)
        }
        // Claude Code in a local tmux session reads the Mac's clipboard on an empty paste.
        #expect(TerminalPastePlan.plan(hasText: false, hasImage: true, route: .local, isRush: false) == .text)
    }

    @Test("an image pasted into a local rush card is stored here and its path typed, since rush reads no clipboard on a paste")
    func localRush() {
        #expect(TerminalPastePlan.plan(hasText: false, hasImage: true, route: .local, isRush: true) == .upload(.local))
        #expect(TerminalPastePlan.typesPathInTerminal(route: .local, isRush: true))
    }

    @Test("the path goes through the terminal for rush and peer cards, through the machine's tmux otherwise")
    func pathDelivery() {
        let peer = TerminalImageRoute.peer(machineId: "machine_box", cardId: "card_1")
        #expect(TerminalPastePlan.typesPathInTerminal(route: peer, isRush: false))
        #expect(TerminalPastePlan.typesPathInTerminal(route: peer, isRush: true))
        #expect(TerminalPastePlan.typesPathInTerminal(route: .machine("gpu-1"), isRush: true))
        // tmux.pasteText on a rush session would send the path as a message of its own.
        #expect(!TerminalPastePlan.typesPathInTerminal(route: .machine("gpu-1"), isRush: false))
    }

    @Test("a stored image keeps its bytes, takes its extension from them, and old ones go")
    func store() throws {
        let home = (NSTemporaryDirectory() as NSString).appendingPathComponent("pasted-store-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(atPath: home) }
        let png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 9, 9])
        let jpeg = Data([0xFF, 0xD8, 0xFF, 0xE0, 1, 2])
        let now = Date()

        let first = try PastedImages.store(png, kanbanHome: home, now: now)
        #expect(first.hasPrefix(home + "/images/pasted/") && first.hasSuffix(".png"))
        #expect(FileManager.default.contents(atPath: first) == png)
        let second = try PastedImages.store(jpeg, kanbanHome: home, now: now)
        #expect(second.hasSuffix(".jpg") && second != first)
        #expect(FileManager.default.fileExists(atPath: first))

        // Eight days later the next image clears both.
        let later = try PastedImages.store(png, kanbanHome: home, now: now.addingTimeInterval(8 * 24 * 3600))
        #expect(!FileManager.default.fileExists(atPath: first))
        #expect(!FileManager.default.fileExists(atPath: second))
        #expect(FileManager.default.fileExists(atPath: later))
    }

    @Test("what is not an image, or is too large, is refused")
    func refused() {
        let home = NSTemporaryDirectory()
        #expect(throws: RemoteHostError.self) { try PastedImages.store(Data(), kanbanHome: home) }
        #expect(throws: RemoteHostError.self) { try PastedImages.store(Data("#!/bin/sh".utf8), kanbanHome: home) }
        let big = Data([0x89, 0x50, 0x4E, 0x47]) + Data(count: PastedImages.maxBytes)
        #expect(throws: RemoteHostError.self) { try PastedImages.store(big, kanbanHome: home) }
    }
}
