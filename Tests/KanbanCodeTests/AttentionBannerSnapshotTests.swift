import AppKit
import SwiftUI
import Testing
import KanbanCodeCore
import struct KanbanCodeCore.Link
@testable import KanbanCode

private struct NoDiscovery: SessionDiscovery {
    func discoverSessions() async throws -> [Session] { [] }
    func discoverNewOrModified(since: Date) async throws -> [Session] { [] }
}

/// Draws the sidebar with the attention banner, and the list of open
/// requests, to PNGs:
/// `KANBAN_ATTENTION_SNAPSHOT=<directory> swift test --filter AttentionBannerSnapshot`.
@Suite("Attention banner snapshot")
@MainActor
struct AttentionBannerSnapshotTests {
    private nonisolated static let directory = ProcessInfo.processInfo.environment["KANBAN_ATTENTION_SNAPSHOT"]

    private func makeStore(home: String) -> BoardStore {
        let coordination = CoordinationStore(basePath: home)
        return BoardStore(
            effectHandler: EffectHandler(coordinationStore: coordination,
                                         queuedPromptJournal: QueuedPromptJournal(basePath: home)),
            discovery: NoDiscovery(),
            coordinationStore: coordination
        )
    }

    private func card(_ id: String, _ name: String, _ column: KanbanCodeColumn, pinned: Bool = false) -> Link {
        var link = Link(id: id, name: name, projectPath: "/Users/me/Projects/langwatch", column: column,
                        lastActivity: .now.addingTimeInterval(-600), source: .manual)
        if pinned { link.pinnedAt = .now.addingTimeInterval(-600) }
        return link
    }

    private func requests() -> [AttentionRequest] {
        [
            AttentionRequest(
                id: "vault_1", cardId: nil, kind: .vaultApproval,
                title: "A process outside any card wants to use the Stripe API key",
                body: "", options: AttentionRequest.vaultApprovalOptions,
                createdAt: .now.addingTimeInterval(-240), requiresBiometry: true),
            AttentionRequest(
                id: "att_2", cardId: "card_pin1", kind: .question,
                title: "Which database should the migration target?", body: "Postgres or SQLite?",
                options: ["Postgres", "SQLite"], createdAt: .now.addingTimeInterval(-60)),
        ]
    }

    private func write<V: View>(_ view: V, size: NSSize, name: String, to directory: String) throws {
        let host = NSHostingView(rootView: view
            .frame(width: size.width, height: size.height, alignment: .top)
            .background(Color(nsColor: .windowBackgroundColor)))
        host.frame = NSRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        let png = try #require(bitmap.representation(using: .png, properties: [:]))
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        try png.write(to: URL(fileURLWithPath: directory).appendingPathComponent(name))
    }

    @Test(.enabled(if: directory != nil))
    func banner() throws {
        let directory = try #require(Self.directory)
        let home = NSTemporaryDirectory() + "kanban-attention-snapshot-\(UUID().uuidString)"
        defer { try? FileManager.default.removeItem(atPath: home) }
        let store = makeStore(home: home)
        for link in [card("card_pin1", "Release notes for 3.24", .waiting, pinned: true),
                     card("card_wait", "Review the onboarding copy", .waiting),
                     card("card_prog", "Evaluator retries", .inProgress)] {
            store.dispatch(.createManualTask(link))
        }
        let all = requests()
        store.dispatch(.attentionRaised(all[0]))
        #expect(store.state.attentionBanner?.target == .request("vault_1"))

        let sidebar = ListBoardView(
            store: store, onShowSubagents: { _ in }, onSetCardPinned: { _, _ in },
            onSetSelfCompactContextThreshold: { _, _ in }, inSidebar: true)
        try write(sidebar, size: NSSize(width: 340, height: 420), name: "sidebar-one.png", to: directory)

        store.dispatch(.attentionRaised(all[1]))
        #expect(store.state.attentionBanner?.count == 2)
        try write(sidebar, size: NSSize(width: 340, height: 420), name: "sidebar-two.png", to: directory)

        let board = BoardView(
            store: store, onShowSubagents: { _ in }, onSetCardPinned: { _, _ in },
            onSetSelfCompactContextThreshold: { _, _ in })
        try write(board, size: NSSize(width: 900, height: 420), name: "board-rail.png", to: directory)

        let list = AttentionRequestList(
            requests: store.state.openAttentionRequests,
            cardName: { AttentionListSheet.cardName($0, in: store.state) },
            onPick: { _ in }, onClose: {})
        try write(list, size: NSSize(width: 560, height: 260), name: "list-sheet.png", to: directory)
    }
}
