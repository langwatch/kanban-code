import SwiftUI
import KanbanCodeRemoteKit

struct BoardScreen: View {
    @Environment(ServerStore.self) private var servers
    @State private var model: BoardModel
    @State private var path: [String] = []
    @State private var search = ""
    @State private var showNewTask = false
    @State private var showAddMac = false
    @State private var expandedColumns: Set<RemoteColumn> = []

    /// Cards shown per column before a "Show all" row.
    private static let columnPreviewCount = ProcessInfo.processInfo.environment["KANBANCODE_COLUMN_PREVIEW"].flatMap(Int.init) ?? 15

    init(server: SavedServer, client: RemoteClient?) {
        _model = State(initialValue: BoardModel(server: server, client: client))
    }

    init(server: SavedServer) {
        self.init(server: server, client: ServerStore.client(for: server))
    }

    init(model: BoardModel) {
        _model = State(initialValue: model)
    }

    var body: some View {
        NavigationStack(path: $path) {
            content
                .navigationTitle(model.server.name)
                .navigationSubtitle(linkText)
                .searchable(text: $search, prompt: "Search cards")
                .refreshable { await model.refresh() }
                .toolbar { toolbar }
                .navigationDestination(for: String.self) { id in
                    CardScreen(cardId: id, board: model)
                }
        }
        .environment(model)
        .task { model.start() }
        .onDisappear { model.stop() }
        .sheet(isPresented: $showNewTask) {
            NewTaskSheet(board: model) { card in
                model.upsert(card)
                path = [card.id]
            }
        }
        .sheet(isPresented: $showAddMac) {
            NavigationStack { PairingView() }
        }
    }

    @ViewBuilder private var content: some View {
        if case .refused(let message) = model.link {
            ContentUnavailableView {
                Label("Pairing no longer valid", systemImage: "lock.slash")
            } description: {
                Text("\(message)\nAdd this device again in Settings > Remote Control on the Mac, then pair.")
            } actions: {
                Button("Pair again") { showAddMac = true }
                    .buttonStyle(.borderedProminent)
            }
        } else if let board = model.board {
            let sections = sections(of: board)
            if sections.isEmpty {
                if search.isEmpty {
                    ContentUnavailableView {
                        Label("No cards", systemImage: "rectangle.stack")
                    } description: {
                        Text("Start a task and it runs on your Mac.")
                    } actions: {
                        Button("New task") { showNewTask = true }
                            .buttonStyle(.borderedProminent)
                    }
                } else {
                    ContentUnavailableView.search(text: search)
                }
            } else {
                List {
                    ForEach(sections, id: \.column) { section in
                        Section {
                            let collapsed = search.isEmpty && !expandedColumns.contains(section.column)
                                && section.cards.count > Self.columnPreviewCount
                            ForEach(collapsed ? Array(section.cards.prefix(Self.columnPreviewCount)) : section.cards) { card in
                                NavigationLink(value: card.id) {
                                    CardRow(card: card)
                                }
                                .accessibilityIdentifier("card-\(card.id)")
                            }
                            if search.isEmpty && section.cards.count > Self.columnPreviewCount {
                                Button {
                                    withAnimation {
                                        if collapsed { expandedColumns.insert(section.column) } else { expandedColumns.remove(section.column) }
                                    }
                                } label: {
                                    Text(collapsed ? "Show all \(section.cards.count)" : "Show fewer")
                                        .font(.subheadline.weight(.medium))
                                }
                                .accessibilityIdentifier("showAll-\(section.column.rawValue)")
                            }
                        } header: {
                            HStack {
                                Text(section.column.displayName)
                                Spacer()
                                Text("\(section.cards.count)")
                                    .monospacedDigit()
                            }
                        }
                    }
                }
                .listStyle(.insetGrouped)
            }
        } else if let error = model.loadError {
            ContentUnavailableView {
                Label("Cannot reach \(model.server.name)", systemImage: "wifi.exclamationmark")
            } description: {
                Text("\(error)\n\nCheck that the Mac is on, Remote Control is on in its Settings, and this phone is on the same tailnet.")
            } actions: {
                Button("Try again") { Task { await model.refresh() } }
                    .buttonStyle(.borderedProminent)
            }
        } else {
            ProgressView("Loading board")
        }
    }

    @ToolbarContentBuilder private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) {
            Menu {
                Section("Macs") {
                    ForEach(servers.servers) { server in
                        Button {
                            servers.selectedID = server.id
                        } label: {
                            if server.id == model.server.id {
                                Label(server.name, systemImage: "checkmark")
                            } else {
                                Text(server.name)
                            }
                        }
                    }
                }
                Button("Add a Mac", systemImage: "plus") { showAddMac = true }
                if let current = servers.servers.first(where: { $0.id == model.server.id }) {
                    Button("Forget \(current.name)", systemImage: "trash", role: .destructive) {
                        servers.remove(current)
                    }
                }
            } label: {
                Label("Macs", systemImage: "desktopcomputer")
            }
            .accessibilityIdentifier("macsMenu")
        }
        ToolbarItem(placement: .topBarTrailing) {
            Button {
                showNewTask = true
            } label: {
                Label("New task", systemImage: "plus")
            }
            .disabled(model.board == nil)
            .accessibilityIdentifier("newTask")
        }
    }

    private var linkText: String {
        switch model.link {
        case .connecting: "Connecting"
        case .live: "Live"
        case .reconnecting(let retryIn): "Offline, retrying in \(Int(retryIn))s"
        case .refused: "Refused"
        case .offline: "Preview"
        }
    }

    private struct ColumnSection {
        let column: RemoteColumn
        let cards: [RemoteCard]
    }

    private func sections(of board: RemoteBoard) -> [ColumnSection] {
        let query = search.trimmingCharacters(in: .whitespaces).lowercased()
        let visible = board.cards.filter { card in
            guard !card.archived else { return false }
            guard !query.isEmpty else { return true }
            return [card.title, card.projectName, card.branch]
                .compactMap { $0?.lowercased() }
                .contains { $0.contains(query) }
                || card.prs.contains { "#\($0.number)".contains(query) }
        }
        return RemoteColumn.phoneOrder.compactMap { column in
            let cards = visible.filter { $0.column == column }
                .sorted { ($0.lastActivity ?? $0.updatedAt) > ($1.lastActivity ?? $1.updatedAt) }
            return cards.isEmpty ? nil : ColumnSection(column: column, cards: cards)
        }
    }
}

#Preview("Board") {
    BoardScreen(model: BoardModel(preview: PreviewData.board))
        .environment(ServerStore())
        .environment(PairingCoordinator())
}
