import AppKit
import SwiftUI
import Testing
import KanbanCodeCore
import KanbanCodeRemoteKit
@testable import KanbanCode

/// Draws the chat composer with its slash command list to PNG files, for
/// looking at it without the app:
/// `KANBAN_SLASH_SNAPSHOT=<directory> swift test --filter SlashCommandListSnapshot`.
@Suite("Slash command list snapshot")
@MainActor
struct SlashCommandListSnapshotTests {
    private nonisolated static let directory = ProcessInfo.processInfo.environment["KANBAN_SLASH_SNAPSHOT"]

    private static let commands = SlashCommandCatalog.merged(assistant: .claude, sideChat: true, disk: [
        RemoteSlashCommand(name: "deploy", description: "Ship the current branch to staging", source: "project"),
        RemoteSlashCommand(name: "review", description: "Review recent code changes for correctness, regressions and test strategy before merge", source: "user"),
        RemoteSlashCommand(name: "catalog:search", description: "Search the product catalog", source: "plugin"),
        RemoteSlashCommand(name: "catalog:reindex", description: "Rebuild the catalog index", source: "plugin"),
    ])

    private func draw(text: String, to name: String) async throws {
        let directory = try #require(Self.directory)
        let view = VStack(spacing: 0) {
            Color(nsColor: .windowBackgroundColor)
            ChatInputBar(assistant: .claude, isReady: true, cardId: "card", slashCommands: Self.commands,
                         text: .constant(text), pastedImages: .constant([]))
        }
        .frame(width: 760, height: 380)
        .background(Color(nsColor: .windowBackgroundColor))
        let host = NSHostingView(rootView: view)
        host.frame = NSRect(x: 0, y: 0, width: 760, height: 380)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(400))
        host.layoutSubtreeIfNeeded()
        let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        let png = try #require(bitmap.representation(using: .png, properties: [:]))
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        try png.write(to: URL(fileURLWithPath: directory).appendingPathComponent(name))
    }

    @Test(.enabled(if: directory != nil))
    func composerWithList() async throws {
        try await draw(text: "/", to: "mac-slash-all.png")
        try await draw(text: "/c", to: "mac-slash-c.png")
        try await draw(text: "/catchu", to: "mac-slash-catchu.png")
        try await draw(text: "hello", to: "mac-slash-none.png")
    }
}
