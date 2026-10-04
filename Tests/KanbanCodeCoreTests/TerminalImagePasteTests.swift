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
        #expect(TerminalPastePlan.plan(hasText: false, hasImage: true, route: peer) == .upload(peer))
        #expect(TerminalPastePlan.plan(hasText: false, hasImage: true, route: .machine("gpu-1")) == .upload(.machine("gpu-1")))
        #expect(TerminalPastePlan.plan(hasText: false, hasImage: true, route: .local) == .text)
        #expect(TerminalPastePlan.plan(hasText: true, hasImage: true, route: peer) == .text)
        #expect(TerminalPastePlan.plan(hasText: true, hasImage: false, route: peer) == .text)
        #expect(TerminalPastePlan.plan(hasText: false, hasImage: false, route: peer) == .text)
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
