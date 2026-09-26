import Foundation
import Observation
import KanbanCodeRemoteKit

/// The conversation of one card: the latest page, older pages on demand.
@Observable
final class TranscriptModel {
    let cardId: String
    let client: RemoteClient?
    private(set) var messages: [RemoteMessage] = []
    private(set) var olderCursor: String?
    private(set) var isLoading = false
    private(set) var isLoadingOlder = false
    private(set) var error: String?
    private(set) var loadedOnce = false

    static let pageSize = 50

    init(cardId: String, client: RemoteClient?) {
        self.cardId = cardId
        self.client = client
    }

    init(preview messages: [RemoteMessage], cardId: String = "preview") {
        self.cardId = cardId
        client = nil
        self.messages = messages
        loadedOnce = true
    }

    /// Fetches the latest page and merges it under what is already loaded.
    func refresh() async {
        guard let client, !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            let page = try await client.transcript(cardId: cardId, limit: Self.pageSize)
            let pending = messages.filter { $0.id.hasPrefix("pending-") }
            merge(latest: page)
            // A sent prompt shows until the transcript has it.
            let delivered = page.messages.filter { $0.role == .user }
            messages += pending.filter { p in !delivered.contains { Self.delivers($0, pending: p) } }
            error = nil
        } catch {
            if messages.isEmpty { self.error = error.localizedDescription }
        }
        loadedOnce = true
    }

    func loadOlder() async {
        guard let client, let cursor = olderCursor, !isLoadingOlder else { return }
        isLoadingOlder = true
        defer { isLoadingOlder = false }
        do {
            let page = try await client.transcript(cardId: cardId, limit: Self.pageSize, before: cursor)
            let known = Set(messages.map(\.id))
            messages = page.messages.filter { !known.contains($0.id) } + messages
            olderCursor = page.olderCursor
        } catch {
            self.error = error.localizedDescription
        }
    }

    /// Shows a sent prompt before the transcript catches up, written the way
    /// the transcript writes a prompt with images.
    func appendPending(_ text: String, imageCount: Int = 0) {
        messages.append(RemoteMessage(id: "pending-\(UUID().uuidString)", role: .user,
                                      text: Self.displayText(text, imageCount: imageCount), at: .now))
    }

    /// Drops sent prompts that now wait in the card's queue: the queue shows
    /// them from here on, and the transcript once they go out.
    func dropPending(queued texts: Set<String>) {
        guard !texts.isEmpty else { return }
        messages.removeAll { $0.id.hasPrefix("pending-") && texts.contains($0.text) }
    }

    static func displayText(_ text: String, imageCount: Int) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard imageCount > 0 else { return trimmed }
        let tag = imageTag(imageCount)
        return trimmed.isEmpty ? tag : trimmed + "\n\n" + tag
    }

    static func imageTag(_ count: Int) -> String { count == 1 ? "[image]" : "[\(count) images]" }

    /// The transcript's user message is this pending prompt: the same text
    /// (the assistant may add image markers around it), or for images alone
    /// a user message with images that came after it was sent.
    static func delivers(_ message: RemoteMessage, pending: RemoteMessage) -> Bool {
        let delivered = message.text.trimmingCharacters(in: .whitespacesAndNewlines)
        let sent = pending.text.trimmingCharacters(in: .whitespacesAndNewlines)
        if delivered == sent { return true }
        let core = coreText(sent)
        if !core.isEmpty { return delivered.contains(core) }
        guard delivered.hasSuffix("[image]") || delivered.hasSuffix(" images]") else { return false }
        guard let sentAt = pending.at, let at = message.at else { return true }
        return at >= sentAt.addingTimeInterval(-60)
    }

    /// The text of a displayed prompt without its image tag.
    private static func coreText(_ text: String) -> String {
        for suffix in ["[image]", " images]"] where text.hasSuffix(suffix) {
            guard let tagStart = text.range(of: "[", options: .backwards)?.lowerBound else { break }
            return String(text[..<tagStart]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return text
    }

    private func merge(latest page: RemoteTranscript) {
        let settled = messages.filter { !$0.id.hasPrefix("pending-") }
        guard let first = page.messages.first,
              let overlap = settled.firstIndex(where: { $0.id == first.id }) else {
            // No overlap with what is loaded: start over from this page.
            if !(page.messages.isEmpty && !settled.isEmpty) {
                messages = page.messages
                olderCursor = page.olderCursor
            }
            return
        }
        messages = Array(settled[..<overlap]) + page.messages
        if overlap == 0 { olderCursor = page.olderCursor }
    }
}
