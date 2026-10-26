import AppKit
import SwiftUI
import Testing
import KanbanCodeRemoteKit
@testable import KanbanCode

/// Draws a card's conversation rows in the sidebar to a PNG, for looking at
/// them without the app:
/// `KANBAN_CONVERSATION_SNAPSHOT=<directory> swift test --filter ConversationSidebarSnapshot`.
/// KANBAN_CONVERSATION_LOG=<card log .jsonl> draws that log instead of the sample.
@Suite("Conversation sidebar snapshot")
@MainActor
struct ConversationSidebarSnapshotTests {
    private nonisolated static let directory = ProcessInfo.processInfo.environment["KANBAN_CONVERSATION_SNAPSHOT"]
    private nonisolated static let log = ProcessInfo.processInfo.environment["KANBAN_CONVERSATION_LOG"]

    private func sample() -> [RemoteConversation] {
        let at = Date(timeIntervalSince1970: 1_800_000_000)
        let lines = [
            ConversationEvent.created("swift-otter", by: "human", at: at),
            .message("swift-otter", id: "m1", role: .human, text: "can we harden the vault next?", at: at),
            .title("swift-otter", "Vault hardening", by: "agent", at: at.addingTimeInterval(30)),
            .message("swift-otter", id: "m2", role: .agent, text: "Yes, three steps.", at: at.addingTimeInterval(30)),
            .created("calm-heron", by: "human", at: at.addingTimeInterval(60)),
            .message("calm-heron", id: "m3", role: .human, text: "and the docs?", at: at.addingTimeInterval(60)),
        ].map { $0.line() }
        return ConversationLog.fold(lines.reduce(Data(), +)).map(\.summary)
    }

    @Test(.enabled(if: directory != nil))
    func sidebarRows() throws {
        let directory = try #require(Self.directory)
        let conversations = try Self.log.map { ConversationLog.fold(try Data(contentsOf: URL(fileURLWithPath: $0))).map(\.summary) } ?? sample()
        let view = VStack(alignment: .leading, spacing: 2) {
            HStack {
                Circle().fill(Color.green).frame(width: 8, height: 8)
                Text("Conversations dogfood").font(.app(.body, weight: .medium))
                Spacer()
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 6).fill(Color.accentColor.opacity(0.18)))
            SidebarConversationRows(cardId: "card", conversations: conversations,
                                    openId: conversations.first?.id, isCardSelected: true)
            Spacer()
        }
        .padding(10)
        .frame(width: 320, height: 60 + CGFloat(conversations.count) * 34)
        .background(Color(nsColor: .windowBackgroundColor))
        let host = NSHostingView(rootView: view)
        host.frame = NSRect(origin: .zero, size: host.fittingSize)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        let png = try #require(bitmap.representation(using: .png, properties: [:]))
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        try png.write(to: URL(fileURLWithPath: directory).appendingPathComponent("mac-sidebar-conversations.png"))
    }
}
