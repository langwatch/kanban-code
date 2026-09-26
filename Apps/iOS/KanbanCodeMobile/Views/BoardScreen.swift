import SwiftUI
import KanbanCodeRemoteKit

struct BoardScreen: View {
    @Environment(ServerStore.self) private var servers
    @State private var model: BoardModel
    @State private var path: [String] = []
    @State private var search = ""
    @State private var showNewTask = false
    @State private var showAddMac = false
    @State private var expandedSections: Set<String> = []
    /// Project path the board is narrowed to, "" for every project. Kept per Mac.
    @State private var projectFilter = ""

    /// Cards shown per column before a "Show all" row.
    private static let columnPreviewCount = ProcessInfo.processInfo.environment["KANBANCODE_COLUMN_PREVIEW"].flatMap(Int.init) ?? 15

    init(server: SavedServer, client: RemoteClient?) {
        _model = State(initialValue: BoardModel(server: server, client: client))
        _projectFilter = State(initialValue: UserDefaults.standard.string(forKey: Self.filterKey(server)) ?? "")
    }

    private static func filterKey(_ server: SavedServer) -> String { "projectFilter.\(server.id.uuidString)" }

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
                .navigationSubtitle(subtitle)
                .onChange(of: projectFilter) { _, value in
                    UserDefaults.standard.set(value, forKey: Self.filterKey(model.server))
                }
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
                    ForEach(sections, id: \.id) { section in
                        Section {
                            let collapsed = search.isEmpty && !expandedSections.contains(section.id)
                                && section.cards.count > Self.columnPreviewCount
                            ForEach(collapsed ? Array(section.cards.prefix(Self.columnPreviewCount)) : section.cards) { card in
                                NavigationLink(value: card.id) {
                                    CardRow(card: card, showsColumn: section.id == Self.liveSectionID)
                                }
                                .accessibilityIdentifier("card-\(card.id)")
                            }
                            if search.isEmpty && section.cards.count > Self.columnPreviewCount {
                                Button {
                                    withAnimation {
                                        if collapsed { expandedSections.insert(section.id) } else { expandedSections.remove(section.id) }
                                    }
                                } label: {
                                    Text(collapsed ? "Show all \(section.cards.count)" : "Show fewer")
                                        .font(.subheadline.weight(.medium))
                                }
                                .accessibilityIdentifier("showAll-\(section.id)")
                            }
                        } header: {
                            HStack {
                                Text(section.title)
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
            Menu {
                Picker("Project", selection: $projectFilter) {
                    Text("All projects").tag("")
                    ForEach(projects) { project in
                        Text(project.name).tag(project.path)
                    }
                }
            } label: {
                Label("Project", systemImage: projectFilter.isEmpty
                      ? "line.3.horizontal.decrease.circle" : "line.3.horizontal.decrease.circle.fill")
            }
            .disabled(projects.isEmpty)
            .accessibilityIdentifier("projectFilter")
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

    private var subtitle: String {
        guard let name = filteredProjectName else { return linkText }
        return "\(linkText) · \(name)"
    }

    private var projects: [RemoteProject] {
        (model.board?.projects ?? []).sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private var filteredProjectName: String? {
        guard !projectFilter.isEmpty else { return nil }
        return projects.first { $0.path == projectFilter }?.name
            ?? URL(fileURLWithPath: projectFilter).lastPathComponent
    }

    private static let liveSectionID = "live"

    private struct BoardSection {
        let id: String
        let title: String
        let cards: [RemoteCard]
    }

    /// Live sessions first, whatever their column (busy ones on top), then
    /// the columns without them.
    private func sections(of board: RemoteBoard) -> [BoardSection] {
        let query = search.trimmingCharacters(in: .whitespaces).lowercased()
        let filterName = filteredProjectName
        let visible = board.cards.filter { card in
            guard !card.archived else { return false }
            if !projectFilter.isEmpty,
               card.projectPath != projectFilter, card.projectName == nil || card.projectName != filterName {
                return false
            }
            guard !query.isEmpty else { return true }
            return [card.title, card.projectName, card.branch]
                .compactMap { $0?.lowercased() }
                .contains { $0.contains(query) }
                || card.prs.contains { "#\($0.number)".contains(query) }
        }
        func recent(_ a: RemoteCard, _ b: RemoteCard) -> Bool {
            (a.lastActivity ?? a.updatedAt) > (b.lastActivity ?? b.updatedAt)
        }
        let live = visible.filter(\.isLive).sorted { a, b in
            a.isBusy != b.isBusy ? a.isBusy : recent(a, b)
        }
        var out: [BoardSection] = []
        if !live.isEmpty { out.append(BoardSection(id: Self.liveSectionID, title: "Live", cards: live)) }
        let rest = visible.filter { !$0.isLive }
        for column in RemoteColumn.phoneOrder {
            let cards = rest.filter { $0.column == column }.sorted(by: recent)
            if !cards.isEmpty { out.append(BoardSection(id: column.rawValue, title: column.displayName, cards: cards)) }
        }
        return out
    }
}

#Preview("Board") {
    BoardScreen(model: BoardModel(preview: PreviewData.board))
        .environment(ServerStore())
        .environment(PairingCoordinator())
}
