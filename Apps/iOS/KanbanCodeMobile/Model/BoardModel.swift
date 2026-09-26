import Foundation
import Observation
import KanbanCodeRemoteKit

/// The board of one Mac, kept live from `/v1/events`.
@Observable
final class BoardModel {
    enum Link: Equatable {
        case connecting
        case live
        case reconnecting(retryIn: TimeInterval)
        /// The Mac refused the token: pair again.
        case refused(String)
        /// Previews and tests: nothing to connect to.
        case offline
    }

    let server: SavedServer
    let client: RemoteClient?
    private(set) var board: RemoteBoard?
    private(set) var device: RemoteDevice?
    /// What the Mac supports beyond API version 1 (`RemoteAPI.Feature`).
    private(set) var features: Set<String> = []
    private(set) var link: Link = .connecting
    private(set) var loadError: String?

    @ObservationIgnored private var eventsTask: Task<Void, Never>?

    init(server: SavedServer, client: RemoteClient?) {
        self.server = server
        self.client = client
    }

    /// A board with no connection, for previews.
    init(preview board: RemoteBoard, scope: RemoteScope = .full) {
        server = SavedServer(id: UUID(), name: "Studio", baseURL: URL(string: "http://127.0.0.1:7780")!, addedAt: .now)
        client = nil
        self.board = board
        device = RemoteDevice(id: "d1", name: "iPhone", scope: scope, createdAt: .now)
        link = .offline
        features = Set(RemoteAPI.features)
    }

    func supports(_ feature: String) -> Bool { features.contains(feature) }

    var scope: RemoteScope { device?.scope ?? .full }
    var canUseTerminal: Bool { scope == .full }

    func card(id: String) -> RemoteCard? {
        board?.cards.first { $0.id == id }
    }

    func start() {
        guard let client, eventsTask == nil else { return }
        eventsTask = Task { [weak self] in
            guard let model = self else { return }
            async let me = try? client.me()
            async let health = try? client.health()
            await model.refresh()
            model.device = await me
            model.features = Set(await health?.features ?? [])
            let stream = client.events { state in
                Task { @MainActor in model.apply(state) }
            }
            do {
                for try await event in stream {
                    guard event.type != .ping else { continue }
                    event.apply(to: &model.board)
                    model.loadError = nil
                    model.link = .live
                }
            } catch {
                model.link = .refused(error.localizedDescription)
            }
        }
    }

    func stop() {
        eventsTask?.cancel()
        eventsTask = nil
    }

    func refresh() async {
        guard let client else { return }
        do {
            board = try await client.board()
            loadError = nil
        } catch let error as RemoteClientError where error.isAuthFailure {
            link = .refused(error.localizedDescription)
        } catch {
            loadError = error.localizedDescription
        }
    }

    /// Replaces one card right away after an action, before the next event.
    func upsert(_ card: RemoteCard) {
        guard var board else { return }
        if let index = board.cards.firstIndex(where: { $0.id == card.id }) {
            board.cards[index] = card
        } else {
            board.cards.append(card)
        }
        self.board = board
    }

    private func apply(_ state: RemoteConnectionState) {
        if case .refused = link { return }
        switch state {
        case .connecting: if link != .live { link = .connecting }
        case .connected: link = .live
        case .reconnecting(let retryIn, _): link = .reconnecting(retryIn: retryIn)
        }
    }
}

extension RemoteColumn {
    /// Board order on the phone: what needs me first.
    static let phoneOrder: [RemoteColumn] = [.waiting, .inProgress, .inReview, .backlog, .done, .allSessions]
}
