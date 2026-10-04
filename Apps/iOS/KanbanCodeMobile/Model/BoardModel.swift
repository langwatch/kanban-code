import Foundation
import Observation
import KanbanCodeRemoteKit

/// The board of one master, kept live from `/v1/events`. The last board
/// seen is kept on disk, so a master that is off (a sleeping Mac, a Mac on
/// a VPN that cuts it off the tailnet) still shows its cards.
@Observable
final class BoardModel {
    enum Link: Equatable {
        case connecting
        case live
        case reconnecting(retryIn: TimeInterval)
        /// The master refused the token: pair again.
        case refused(String)
        /// Previews and tests: nothing to connect to.
        case offline
    }

    let server: SavedServer
    let client: RemoteClient?
    private(set) var board: RemoteBoard?
    private(set) var device: RemoteDevice?
    /// What the master supports beyond API version 1 (`RemoteAPI.Feature`).
    private(set) var features: Set<String> = []
    private(set) var link: Link = .connecting
    private(set) var loadError: String?
    /// The master's identity, from its board. Older servers do not name one.
    private(set) var machine: RemoteMachine?
    /// When the master was last reachable, while it is not. Nil while live.
    private(set) var offlineSince: Date?
    /// The board shown comes from the cache, not from the master.
    private(set) var isCached = false
    /// Decisions agents on this master wait on, oldest first.
    private(set) var attention: [AttentionRequest] = []
    /// What each card's chat composer offers after `/`, as last read from
    /// the master.
    private(set) var slashCommands: [String: [RemoteSlashCommand]] = [:]

    @ObservationIgnored private var eventsTask: Task<Void, Never>?
    @ObservationIgnored private var lastSaved = Date.distantPast
    @ObservationIgnored private var lastReceived: Date?
    @ObservationIgnored private var saveTask: Task<Void, Never>?

    init(server: SavedServer, client: RemoteClient?) {
        self.server = server
        self.client = client
        if let cached = BoardCache.load(server.id) {
            board = cached.board
            machine = cached.board.machine
            offlineSince = cached.savedAt
            isCached = true
        }
    }

    /// A board with no connection, for previews.
    init(preview board: RemoteBoard, scope: RemoteScope = .full, name: String = "Studio", online: Bool = true) {
        server = SavedServer(id: UUID(), name: name, baseURL: URL(string: "http://127.0.0.1:7780")!, addedAt: .now)
        client = nil
        self.board = board
        machine = board.machine
        device = RemoteDevice(id: "d1", name: "iPhone", scope: scope, createdAt: .now)
        link = online ? .offline : .reconnecting(retryIn: 8)
        offlineSince = online ? nil : .now.addingTimeInterval(-1500)
        features = Set(RemoteAPI.features)
    }

    func supports(_ feature: String) -> Bool { features.contains(feature) }

    /// Reads the card's slash commands from the master; a failed read
    /// keeps the last list.
    func loadSlashCommands(cardId: String) {
        guard supports(RemoteAPI.Feature.slashCommands), let client else { return }
        Task {
            guard let commands = try? await client.slashCommands(cardId: cardId) else { return }
            slashCommands[cardId] = commands
        }
    }

    /// Sets a card's slash commands, for previews and tests.
    func setSlashCommands(_ commands: [RemoteSlashCommand], cardId: String) {
        slashCommands[cardId] = commands
    }

    var scope: RemoteScope { device?.scope ?? .full }
    var canUseTerminal: Bool { scope == .full }

    /// Reachable right now. Previews count as online.
    var isOnline: Bool { link == .live || link == .offline }

    /// The master's machine id, or one made up from the pairing for a
    /// server that names none.
    var machineId: String { machine?.id ?? "paired-\(server.id.uuidString)" }
    var machineName: String { machine?.name ?? server.name }

    func card(id: String) -> RemoteCard? {
        board?.cards.first { $0.id == id }
    }

    func start() {
        guard let client, eventsTask == nil else { return }
        eventsTask = Task { [weak self] in
            guard let model = self else { return }
            await model.refresh()
            await model.loadDevice()
            let stream = client.events { state in
                Task { @MainActor in model.apply(state) }
            }
            do {
                for try await event in stream {
                    guard event.type != .ping else { continue }
                    if let attention = event.attention { model.attention = attention }
                    if model.isCached { model.board = nil }
                    event.apply(to: &model.board)
                    model.received()
                }
            } catch {
                model.link = .refused(error.localizedDescription)
            }
        }
    }

    func stop() {
        eventsTask?.cancel()
        eventsTask = nil
        saveTask?.cancel()
        saveTask = nil
        if let board, let lastReceived { BoardCache.save(board, seenAt: lastReceived, for: server.id) }
    }

    func refresh() async {
        guard let client else { return }
        do {
            board = try await client.board()
            isCached = false
            received()
            if let open = try? await client.attention() { attention = open }
        } catch let error as RemoteClientError where error.isAuthFailure {
            link = .refused(error.localizedDescription)
        } catch {
            loadError = error.localizedDescription
            if offlineSince == nil { offlineSince = .now }
        }
    }

    /// Answers a decision on this master; it clears on every device.
    func resolveAttention(_ request: AttentionRequest, resolution: String, unsealed: VaultUnsealed? = nil) async throws {
        guard let client else { return }
        try await client.resolveAttention(id: request.id, resolution: resolution, by: "phone", unsealed: unsealed)
        attention.removeAll { $0.id == request.id }
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

    /// Drops a deleted card right away, before the next event.
    func remove(cardId: String) {
        guard var board, board.cards.contains(where: { $0.id == cardId }) else { return }
        board.cards.removeAll { $0.id == cardId }
        self.board = board
    }

    /// The device and features, once per connection until both are known:
    /// a master that was off at launch tells them when it comes back.
    private func loadDevice() async {
        guard let client, device == nil || features.isEmpty else { return }
        async let me = try? client.me()
        async let health = try? client.health()
        if let me = await me { device = me }
        if let features = await health?.features { self.features = Set(features) }
    }

    /// Fresh data from the master.
    private func received() {
        isCached = false
        loadError = nil
        offlineSince = nil
        lastReceived = .now
        if case .refused = link {} else { link = .live }
        if let found = board?.machine { machine = found }
        scheduleSave()
    }

    /// Writes the board at most every 5 seconds.
    private func scheduleSave() {
        guard saveTask == nil else { return }
        let wait = max(0, 5 - Date.now.timeIntervalSince(lastSaved))
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(wait))
            guard let self, !Task.isCancelled else { return }
            if let board = self.board, let seen = self.lastReceived {
                BoardCache.save(board, seenAt: seen, for: self.server.id)
            }
            self.lastSaved = .now
            self.saveTask = nil
        }
    }

    private func apply(_ state: RemoteConnectionState) {
        if case .refused = link { return }
        switch state {
        case .connecting:
            if link != .live { link = .connecting }
        case .connected:
            link = .live
            offlineSince = nil
            Task { await loadDevice() }
        case .reconnecting(let retryIn, _):
            if link == .live || offlineSince == nil { offlineSince = lastReceived ?? .now }
            link = .reconnecting(retryIn: retryIn)
        }
    }
}

/// The last board of each master, in Application Support.
enum BoardCache {
    struct Entry: Codable {
        var board: RemoteBoard
        var savedAt: Date
    }

    private static var directory: URL {
        URL.applicationSupportDirectory.appending(path: "boards", directoryHint: .isDirectory)
    }

    private static func file(_ id: UUID) -> URL {
        directory.appending(path: "\(id.uuidString).json")
    }

    static func load(_ id: UUID) -> Entry? {
        guard let data = try? Data(contentsOf: file(id)) else { return nil }
        return try? JSONDecoder.remote.decode(Entry.self, from: data)
    }

    /// `seenAt`: when the master last sent it.
    static func save(_ board: RemoteBoard, seenAt: Date, for id: UUID) {
        guard let data = try? JSONEncoder.remote.encode(Entry(board: board, savedAt: seenAt)) else { return }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? data.write(to: file(id), options: .atomic)
    }

    static func remove(_ id: UUID) {
        try? FileManager.default.removeItem(at: file(id))
    }
}

extension RemoteColumn {
    /// Board order on the phone: what needs me first.
    static let phoneOrder: [RemoteColumn] = [.waiting, .inProgress, .inReview, .backlog, .done, .allSessions]
}
