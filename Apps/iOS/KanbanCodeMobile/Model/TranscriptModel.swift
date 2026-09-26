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
            // A queued prompt shows until the transcript has it.
            let delivered = Set(page.messages.filter { $0.role == .user }.map { $0.text.trimmingCharacters(in: .whitespacesAndNewlines) })
            messages += pending.filter { !delivered.contains($0.text.trimmingCharacters(in: .whitespacesAndNewlines)) }
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

    /// Shows a sent prompt before the transcript catches up.
    func appendPending(_ text: String) {
        messages.append(RemoteMessage(id: "pending-\(UUID().uuidString)", role: .user, text: text, at: .now))
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
