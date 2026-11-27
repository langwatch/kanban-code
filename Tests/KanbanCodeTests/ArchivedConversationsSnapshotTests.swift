import AppKit
import SwiftUI
import Testing
import KanbanCodeCore
import KanbanCodeRemoteKit
@testable import KanbanCode

/// Draws the archived conversations sheet to PNGs:
/// `KANBAN_ARCHIVED_SNAPSHOT=<directory> swift test --filter ArchivedConversationsSnapshot`.
@Suite("Archived conversations snapshot")
@MainActor
struct ArchivedConversationsSnapshotTests {
    private nonisolated static let directory = ProcessInfo.processInfo.environment["KANBAN_ARCHIVED_SNAPSHOT"]

    private func conversation(_ id: String, _ title: String?, minutesAgo: Double, preview: String?, messages: Int) -> RemoteConversation {
        RemoteConversation(id: id, title: title, createdAt: .now.addingTimeInterval(-86_400),
                           updatedAt: .now.addingTimeInterval(-minutesAgo * 60), messageCount: messages,
                           preview: preview, archived: true)
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
    func sheet() throws {
        let directory = try #require(Self.directory)
        let groups = ArchivedConversationGroup.groups(conversations: [
            "laze": [
                conversation("swift-otter", "Vault approval copy", minutesAgo: 30, preview: "Done, the card now says who asked.", messages: 12),
                conversation("quiet-heron", nil, minutesAgo: 600, preview: nil, messages: 2),
            ],
            "docs": [
                conversation("late-lynx", "OCSF export docs", minutesAgo: 5, preview: "Pushed the new page to main.", messages: 6),
            ],
        ], titles: ["laze": "laze", "docs": "Docs: OCSF export"])
        let all = ArchivedConversationsSheet(groups: groups, singleCard: false,
                                             onOpen: { _, _ in }, onUnarchive: { _, _ in }, onClose: {})
        try write(all, size: NSSize(width: 560, height: 400), name: "archived-all.png", to: directory)
        let one = ArchivedConversationsSheet(groups: groups.filter { $0.cardId == "laze" }, singleCard: true,
                                             onOpen: { _, _ in }, onUnarchive: { _, _ in }, onClose: {})
        try write(one, size: NSSize(width: 560, height: 300), name: "archived-card.png", to: directory)
    }
}
