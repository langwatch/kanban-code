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

/// Draws the Mac sidebar card list to a PNG, for looking at it without the
/// app: `KANBAN_SIDEBAR_SNAPSHOT=<directory> swift test --filter SidebarSnapshot`.
@Suite("Sidebar snapshot")
@MainActor
struct SidebarSnapshotTests {
    private nonisolated static let directory = ProcessInfo.processInfo.environment["KANBAN_SIDEBAR_SNAPSHOT"]

    private func link(_ id: String, _ name: String, _ column: KanbanCodeColumn, minutesAgo: Double,
                      session: String? = nil, pinned: Bool = false, branch: String? = nil) -> Link {
        var link = Link(id: id, name: name, projectPath: "/Users/me/Projects/langwatch", column: column,
                        lastActivity: .now.addingTimeInterval(-minutesAgo * 60), source: .manual)
        if let session { link.tmuxLink = TmuxLink(sessionName: session) }
        if pinned { link.pinnedAt = .now.addingTimeInterval(-minutesAgo * 60) }
        if let branch { link.worktreeLink = WorktreeLink(path: "/Users/me/Projects/langwatch/.claude/worktrees/\(branch)", branch: branch) }
        return link
    }

    @Test(.enabled(if: directory != nil))
    func sidebar() throws {
        let directory = try #require(Self.directory)
        let home = NSTemporaryDirectory() + "kanban-sidebar-snapshot-\(UUID().uuidString)"
        defer { try? FileManager.default.removeItem(atPath: home) }
        let coordination = CoordinationStore(basePath: home)
        let store = BoardStore(
            effectHandler: EffectHandler(coordinationStore: coordination,
                                         queuedPromptJournal: QueuedPromptJournal(basePath: home)),
            discovery: NoDiscovery(),
            coordinationStore: coordination
        )
        var busy = link("card_busy", "Fix trace search timeouts", .inProgress, minutesAgo: 2, session: "t-busy", branch: "fix-trace-search")
        busy.isLaunching = true
        let links = [
            link("card_pin1", "Release notes for 3.24", .waiting, minutesAgo: 40, pinned: true),
            link("card_pin2", "Box master health", .done, minutesAgo: 600, session: "t-pin2", pinned: true),
            busy,
            link("card_idle", "Dataset slugs migration", .waiting, minutesAgo: 8, session: "t-idle"),
            link("card_wait", "Review the onboarding copy", .waiting, minutesAgo: 90),
            link("card_prog", "Evaluator retries", .inProgress, minutesAgo: 30),
            link("card_rev", "Gateway budget alerts", .inReview, minutesAgo: 120, branch: "gateway-budgets"),
            link("card_done1", "Docs: OCSF export", .done, minutesAgo: 300),
            link("card_done2", "CLI login with project key", .done, minutesAgo: 1500),
            link("card_back", "Try the new trace drawer layout", .backlog, minutesAgo: 3000),
        ]
        for link in links { store.dispatch(.createManualTask(link)) }
        store.dispatch(.tmuxLivenessScanned(live: ["t-busy", "t-idle", "t-pin2"]))

        let view = ListBoardView(
            store: store,
            onShowSubagents: { _ in },
            onSetCardPinned: { _, _ in },
            onSetSelfCompactContextThreshold: { _, _ in },
            inSidebar: true
        )
        .frame(width: 340, height: 980)
        .background(Color(nsColor: .windowBackgroundColor))
        let host = NSHostingView(rootView: view)
        host.frame = NSRect(x: 0, y: 0, width: 340, height: 980)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        let png = try #require(bitmap.representation(using: .png, properties: [:]))
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        try png.write(to: URL(fileURLWithPath: directory).appendingPathComponent("mac-sidebar.png"))

        #expect(store.state.sidebarSections.map(\.kind.title) == ["Pinned", "Live", "Waiting", "In Progress", "In Review", "Done", "Backlog"])
    }
}
