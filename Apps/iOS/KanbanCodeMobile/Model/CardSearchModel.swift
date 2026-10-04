import Foundation
import Observation
import KanbanCodeRemoteKit

/// Cards the phone does not hold, found on the masters: archived cards,
/// All Sessions cards and Done cards past the recent ones. One master is
/// asked; it asks its peers.
@Observable
final class CardSearchModel {
    enum Phase: Equatable {
        case idle
        case loading
        case loaded
        /// No master answered.
        case failed
    }

    let fleet: FleetModel
    let scope: RemoteCardSearchScope
    private(set) var phase: Phase = .idle
    private(set) var results: [FleetCard] = []
    /// More cards matched than were sent.
    private(set) var truncated = false
    /// Masters that did not answer the one that was asked.
    private(set) var unreachable: [String] = []

    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var query = ""

    /// How long typing must pause before the masters are asked.
    static let debounce: Duration = .milliseconds(300)

    init(fleet: FleetModel, scope: RemoteCardSearchScope = .older) {
        self.fleet = fleet
        self.scope = scope
    }

    /// Searches for `text` once typing pauses. A search still running for
    /// an earlier text is cancelled.
    func update(_ text: String) {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text != query else { return }
        query = text
        task?.cancel()
        results = []
        truncated = false
        unreachable = []
        guard !text.isEmpty else {
            phase = .idle
            return
        }
        phase = .loading
        task = Task { [weak self] in
            try? await Task.sleep(for: Self.debounce)
            guard !Task.isCancelled else { return }
            await self?.run(text)
        }
    }

    /// Drops a card that left the results (brought back, deleted).
    func remove(cardId: String) {
        results.removeAll { $0.id == cardId }
    }

    private func run(_ text: String) async {
        for master in fleet.onlineMasters where master.supports(RemoteAPI.Feature.cardSearch) {
            guard let client = master.client else { continue }
            do {
                let found = try await client.searchCards(text, scope: scope, timeout: 10)
                guard !Task.isCancelled, text == query else { return }
                let entries = found.cards.map { fleet.fleetCard($0, listedBy: master) }
                fleet.remember(entries)
                results = entries
                truncated = found.truncated
                unreachable = found.unreachable
                phase = .loaded
                return
            } catch {
                if Task.isCancelled { return }
            }
        }
        guard !Task.isCancelled, text == query else { return }
        phase = .failed
    }
}
