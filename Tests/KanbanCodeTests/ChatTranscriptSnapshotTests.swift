import AppKit
import SwiftUI
import Testing
import KanbanCodeCore
@testable import KanbanCode

/// Draws the chat of a transcript to PNG files, for looking at how a session
/// reads without the app:
/// `KANBAN_CHAT_SNAPSHOT=<directory> KANBAN_CHAT_SNAPSHOT_TRANSCRIPT=<file.jsonl> swift test --filter ChatTranscriptSnapshot`.
/// Draws the whole transcript, and the transcript cut after its last tool
/// call so that run is the newest one and shows its rows.
@Suite("Chat transcript snapshot")
@MainActor
struct ChatTranscriptSnapshotTests {
    private nonisolated static let directory = ProcessInfo.processInfo.environment["KANBAN_CHAT_SNAPSHOT"]
    private nonisolated static let transcript = ProcessInfo.processInfo.environment["KANBAN_CHAT_SNAPSHOT_TRANSCRIPT"]

    private func draw(_ turns: [ConversationTurn], height: CGFloat, to name: String) async throws {
        let directory = try #require(Self.directory)
        let view = ChatView(
            turns: turns,
            isLoading: false,
            activityState: nil,
            assistant: .claude,
            draftText: .constant(""),
            draftImages: .constant([]),
            pendingMessage: .constant(nil)
        )
        .frame(width: 900, height: height)
        .background(Color(nsColor: .windowBackgroundColor))
        let host = NSHostingView(rootView: view)
        host.frame = NSRect(x: 0, y: 0, width: 900, height: height)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(800))
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(400))
        let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        let png = try #require(bitmap.representation(using: .png, properties: [:]))
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        try png.write(to: URL(fileURLWithPath: directory).appendingPathComponent(name))
    }

    @Test(.enabled(if: directory != nil && transcript != nil))
    func transcriptChat() async throws {
        let path = try #require(Self.transcript)
        let turns = try await TranscriptReader.readTurns(from: path)
        try await draw(turns, height: 700, to: "chat-whole.png")
        let lastTool = try #require(turns.lastIndex { $0.contentBlocks.contains { if case .toolResult = $0.kind { return true }; return false } })
        try await draw(Array(turns[...lastTool]), height: 1100, to: "chat-newest-run.png")
    }
}
