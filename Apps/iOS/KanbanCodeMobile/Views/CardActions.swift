import SwiftUI
import UIKit
import KanbanCodeRemoteKit

/// What a card's menu can ask for. `CardActionController` runs them against
/// the masters and asks first for the destructive ones.
enum CardAction {
    case resume
    case interrupt
    case rename
    case setPinned(Bool)
    case moveToColumn(RemoteColumn)
    /// Continue the card on another master: `target` is its machine id.
    case continueOn(target: String, name: String)
    case archive
    case unarchive
    case delete
}

/// Runs card actions for the board and the archive: picks a master that
/// can take the call, keeps the boards in step, and holds the rename,
/// confirmation and error state the `.cardActions(_:)` modifier presents.
@Observable
final class CardActionController {
    struct Confirmation: Identifiable {
        let id = UUID()
        let entry: FleetCard
        let action: CardAction
        let title: String
        let message: String
        let button: String
    }

    let fleet: FleetModel
    var confirmation: Confirmation?
    var renaming: FleetCard?
    var renameText = ""
    var error: String?
    /// Called after an action changed or removed a card, with its id.
    @ObservationIgnored var onChange: ((String) -> Void)?

    init(fleet: FleetModel) {
        self.fleet = fleet
    }

    /// The master a call about the card goes to: its owner while online,
    /// else any online master. Every master forwards a session call to the
    /// owner, and shared edits (rename, column, archive, pin, delete) apply
    /// on any master and sync to the others.
    func master(for entry: FleetCard) -> BoardModel? {
        if entry.master.isOnline, entry.master.client != nil { return entry.master }
        return fleet.onlineMasters.first { $0.client != nil && $0.card(id: entry.id) != nil }
            ?? fleet.onlineMasters.first { $0.client != nil }
    }

    /// The master takes pin, unarchive and delete.
    func supportsCardActions(_ entry: FleetCard) -> Bool {
        master(for: entry)?.supports(RemoteAPI.Feature.cardActions) == true
    }

    /// Masters the card may continue on: the other online masters, for a
    /// Claude conversation.
    func continueTargets(for entry: FleetCard) -> [BoardModel] {
        guard entry.card.assistant == "claude", !entry.card.archived else { return [] }
        let owner = entry.card.machineId ?? entry.master.machineId
        return fleet.onlineMasters.filter { $0.machineId != owner && $0.client != nil }
    }

    func perform(_ action: CardAction, on entry: FleetCard) {
        switch action {
        case .rename:
            renameText = entry.card.title
            renaming = entry
        case .archive where entry.card.isLive:
            confirmation = Confirmation(
                entry: entry, action: action, title: "Archive this card?",
                message: "Its session ends. The conversation stays, and the card can come back from Archived cards.",
                button: "Archive")
        case .delete:
            confirmation = Confirmation(
                entry: entry, action: action, title: "Delete this card?",
                message: "The card, its subagents and its conversation file are deleted on every machine. This cannot be undone.",
                button: "Delete")
        case .continueOn(_, let name):
            confirmation = Confirmation(
                entry: entry, action: action, title: "Continue on \(name)?",
                message: "The session ends here, the branch is pushed, and \(name) picks the conversation up.",
                button: "Continue there")
        default:
            run(action, on: entry)
        }
    }

    func confirm(_ confirmation: Confirmation) {
        run(confirmation.action, on: confirmation.entry)
    }

    func commitRename() {
        guard let entry = renaming else { return }
        renaming = nil
        let name = renameText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name != entry.card.title else { return }
        edit(entry, "rename the card", RemoteCardUpdate(name: name))
    }

    private func run(_ action: CardAction, on entry: FleetCard) {
        let id = entry.id
        switch action {
        case .resume:
            call(entry, "resume the card") { try await $0.resume(cardId: id) }
        case .interrupt:
            call(entry, "interrupt the turn") { client in
                try await client.interrupt(cardId: id)
                return nil
            }
        case .rename:
            perform(action, on: entry)
        case .setPinned(let pinned):
            edit(entry, pinned ? "pin the card" : "unpin the card", RemoteCardUpdate(pinned: pinned))
        case .moveToColumn(let column):
            edit(entry, "move the card", RemoteCardUpdate(column: column))
        case .continueOn(let target, let name):
            call(entry, "continue the card on \(name)") { try await $0.move(cardId: id, to: target) }
        case .archive:
            edit(entry, "archive the card", RemoteCardUpdate(archived: true))
        case .unarchive:
            edit(entry, "bring the card back", RemoteCardUpdate(archived: false))
        case .delete:
            call(entry, "delete the card") { client in
                try await client.deleteCard(cardId: id)
                return nil
            } done: { [fleet] in
                fleet.masters.forEach { $0.remove(cardId: id) }
            }
        }
    }

    private func edit(_ entry: FleetCard, _ what: String, _ update: RemoteCardUpdate) {
        let id = entry.id
        call(entry, what) { try await $0.updateCard(cardId: id, update) }
    }

    /// Runs `body` on the card's master; a returned card replaces the
    /// board's copy right away, before the next event.
    private func call(_ entry: FleetCard, _ what: String,
                      _ body: @escaping (RemoteClient) async throws -> RemoteCard?,
                      done: (() -> Void)? = nil) {
        guard let master = master(for: entry), let client = master.client else {
            error = "Could not \(what): \(entry.machineName) is offline and no other machine is online."
            return
        }
        Task {
            do {
                if let card = try await body(client) { master.upsert(card) }
                done?()
                UINotificationFeedbackGenerator().notificationOccurred(.success)
                onChange?(entry.id)
            } catch {
                self.error = "Could not \(what): \(error.localizedDescription)"
                UINotificationFeedbackGenerator().notificationOccurred(.error)
            }
        }
    }

    /// Columns a card can be put in by hand, as on the Mac: In Review needs
    /// a pull request and Done a merged one. In Progress is a resume and
    /// All Sessions an archive, so they are actions of their own.
    static func columnTargets(_ card: RemoteCard) -> [RemoteColumn] {
        var out: [RemoteColumn] = [.backlog, .waiting]
        if !card.prs.isEmpty { out.append(.inReview) }
        if card.prs.contains(where: { $0.status == "merged" }) { out.append(.done) }
        return out.filter { $0 != card.column }
    }
}

/// The items of a card's touch-and-hold menu. Plain buttons only: a picker
/// in a menu that changes while it is open can abort UIKit.
///
/// Items go by index rather than ForEach: the menu belongs to the row, and
/// SwiftUI may call a row's ForEach content off the main thread, where this
/// target's main-actor closures trap (see `PRBadges`).
struct CardActionsMenu: View {
    let entry: FleetCard
    let controller: CardActionController
    @Environment(\.openURL) private var openURL

    private var card: RemoteCard { entry.card }

    var body: some View {
        let online = controller.master(for: entry) != nil
        let full = controller.supportsCardActions(entry)
        Section {
            if card.isBusy {
                Button("Interrupt", systemImage: "stop.fill", role: .destructive) { act(.interrupt) }
                    .disabled(!online)
            } else if !card.isLive && !card.archived && card.sessionStatus == nil {
                Button(card.sessionId == nil ? "Start" : "Resume", systemImage: "play.fill") { act(.resume) }
                    .disabled(!online)
            }
            if !card.archived {
                Button("Rename", systemImage: "pencil") { act(.rename) }
                    .disabled(!online)
                if full && card.parentCardId == nil {
                    Button(card.pinned ? "Unpin" : "Pin", systemImage: card.pinned ? "pin.slash" : "pin") {
                        act(.setPinned(!card.pinned))
                    }
                    .disabled(!online)
                }
                let columns = CardActionController.columnTargets(card)
                if !columns.isEmpty {
                    Menu {
                        columnButton(columns, 0)
                        columnButton(columns, 1)
                        columnButton(columns, 2)
                        columnButton(columns, 3)
                    } label: {
                        Label("Move to", systemImage: "rectangle.2.swap")
                    }
                    .disabled(!online)
                }
                let targets = controller.continueTargets(for: entry)
                if !targets.isEmpty {
                    Menu {
                        continueButton(targets, 0)
                        continueButton(targets, 1)
                        continueButton(targets, 2)
                    } label: {
                        Label("Continue on", systemImage: "arrow.up.forward.app")
                    }
                }
            }
        }
        if !card.prs.isEmpty {
            Section {
                prButton(0)
                prButton(1)
                prButton(2)
            }
        }
        Section {
            Button("Copy Card ID", systemImage: "number") { UIPasteboard.general.string = card.id }
            if let session = card.sessionId {
                Button("Copy Session ID", systemImage: "desktopcomputer") { UIPasteboard.general.string = session }
            }
            if let branch = card.branch, !branch.isEmpty {
                Button("Copy Branch Name", systemImage: "arrow.triangle.branch") { UIPasteboard.general.string = branch }
            }
        }
        Section {
            if card.archived {
                if full {
                    Button("Bring back to board", systemImage: "tray.and.arrow.up") { act(.unarchive) }
                        .disabled(!online)
                    Button("Delete Card", systemImage: "trash", role: .destructive) { act(.delete) }
                        .disabled(!online)
                }
            } else {
                if card.column == .allSessions {
                    Button("Bring back to board", systemImage: "tray.and.arrow.up") { act(.moveToColumn(.backlog)) }
                        .disabled(!online)
                }
                Button("Archive", systemImage: "archivebox", role: card.isLive ? .destructive : nil) { act(.archive) }
                    .disabled(!online)
            }
        }
    }

    @ViewBuilder private func columnButton(_ columns: [RemoteColumn], _ index: Int) -> some View {
        if index < columns.count {
            Button(columns[index].displayName) { act(.moveToColumn(columns[index])) }
        }
    }

    @ViewBuilder private func continueButton(_ targets: [BoardModel], _ index: Int) -> some View {
        if index < targets.count {
            Button(targets[index].machineName) {
                act(.continueOn(target: targets[index].machineId, name: targets[index].machineName))
            }
        }
    }

    /// "Open PR #N" for the newest PRs that have a link, at most three.
    @ViewBuilder private func prButton(_ index: Int) -> some View {
        let linked = card.prs.filter { $0.url.flatMap(URL.init(string:)) != nil }.sorted { $0.number > $1.number }
        if index < linked.count, let url = linked[index].url.flatMap(URL.init(string:)) {
            Button("Open PR #\(String(linked[index].number))", systemImage: "arrow.up.right.square") { openURL(url) }
        }
    }

    private func act(_ action: CardAction) {
        controller.perform(action, on: entry)
    }
}

extension View {
    /// Presents what `controller` asks: the rename field, confirmations of
    /// destructive actions and errors.
    func cardActions(_ controller: CardActionController) -> some View {
        modifier(CardActionsPresenter(controller: controller))
    }
}

private struct CardActionsPresenter: ViewModifier {
    @Bindable var controller: CardActionController

    func body(content: Content) -> some View {
        content
            .alert("Rename card", isPresented: Binding(
                get: { controller.renaming != nil }, set: { if !$0 { controller.renaming = nil } }
            )) {
                TextField("Name", text: $controller.renameText)
                    .accessibilityIdentifier("renameField")
                Button("Cancel", role: .cancel) { controller.renaming = nil }
                Button("Rename") { controller.commitRename() }
            }
            .alert(controller.confirmation?.title ?? "", isPresented: Binding(
                get: { controller.confirmation != nil }, set: { if !$0 { controller.confirmation = nil } }
            ), presenting: controller.confirmation) { confirmation in
                Button("Cancel", role: .cancel) {}
                Button(confirmation.button, role: .destructive) { controller.confirm(confirmation) }
            } message: { confirmation in
                Text(confirmation.message)
            }
            .alert("Something went wrong", isPresented: Binding(
                get: { controller.error != nil }, set: { if !$0 { controller.error = nil } }
            )) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(controller.error ?? "")
            }
    }
}

/// The archived cards of the masters, newest first, to open, bring back or
/// delete. The board leaves them out. Its search field looks through every
/// card the board does not hold: archived, All Sessions and older Done.
struct ArchivedCardsSheet: View {
    let fleet: FleetModel
    @Environment(\.dismiss) private var dismiss
    @State private var controller: CardActionController
    @State private var entries: [FleetCard] = []
    @State private var loaded = false
    @State private var failures: [String] = []
    @State private var search = ""
    @State private var found: CardSearchModel
    @State private var path: [String] = []
    /// The rows while a card is open on top of the list, which must not
    /// change under it (see `BoardScreen.covered`).
    @State private var covered: [FleetCard]?

    /// Archived cards listed, at most.
    static let limit = 200

    init(fleet: FleetModel) {
        self.fleet = fleet
        _controller = State(initialValue: CardActionController(fleet: fleet))
        _found = State(initialValue: CardSearchModel(fleet: fleet))
    }

    private var isSearching: Bool {
        !search.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// The archive, or what the search found, without the cards that are
    /// back on a board.
    private var rows: [FleetCard] {
        let onBoard = fleet.boardCardIds
        return (isSearching ? found.results : entries).filter { !onBoard.contains($0.id) }
    }

    var body: some View {
        NavigationStack(path: $path) {
            let rows = covered ?? self.rows
            Group {
                if !loaded && !isSearching {
                    ProgressView("Loading archived cards")
                } else if rows.isEmpty && !isSearching {
                    ContentUnavailableView("No archived cards", systemImage: "archivebox",
                                           description: Text(failures.joined(separator: "\n")))
                } else if rows.isEmpty && found.phase == .loaded {
                    ContentUnavailableView.search(text: search)
                } else {
                    List {
                        Section {
                            ForEach(rows) { entry in
                                NavigationLink(value: entry.card.id) {
                                    CardRow(card: entry.card, showsColumn: isSearching,
                                            machine: fleet.showsMachines ? entry.machineName : nil,
                                            machineOffline: !entry.master.isOnline)
                                }
                                .contextMenu { CardActionsMenu(entry: entry, controller: controller) }
                                .swipeActions(edge: .trailing) {
                                    if entry.card.archived, controller.supportsCardActions(entry) {
                                        Button("Delete", systemImage: "trash", role: .destructive) {
                                            controller.perform(.delete, on: entry)
                                        }
                                        Button("Bring back", systemImage: "tray.and.arrow.up") {
                                            controller.perform(.unarchive, on: entry)
                                        }
                                        .tint(.blue)
                                    }
                                }
                                .accessibilityIdentifier("archived-\(entry.card.id)")
                            }
                            if isSearching {
                                switch found.phase {
                                case .loading:
                                    HStack(spacing: 10) {
                                        ProgressView()
                                        Text("Searching older cards")
                                            .foregroundStyle(.secondary)
                                    }
                                    .accessibilityElement(children: .combine)
                                    .accessibilityIdentifier("olderLoading")
                                case .failed:
                                    Label("Could not search older cards", systemImage: "exclamationmark.triangle")
                                        .foregroundStyle(.secondary)
                                        .accessibilityIdentifier("olderFailed")
                                case .loaded, .idle:
                                    EmptyView()
                                }
                            }
                        } footer: {
                            if isSearching {
                                if found.phase == .loaded {
                                    Text(OlderSearchNote.text(truncated: found.truncated, unreachable: found.unreachable))
                                }
                            } else if !failures.isEmpty {
                                Text(failures.joined(separator: "\n"))
                            } else if entries.count >= Self.limit {
                                Text("The \(Self.limit) most recent. Search to find an older one.")
                            }
                        }
                    }
                    .listStyle(.insetGrouped)
                }
            }
            .navigationTitle("Archived cards")
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $search, placement: .navigationBarDrawer(displayMode: .always),
                        prompt: "Search archived and older cards")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                        .accessibilityIdentifier("archivedDone")
                }
            }
            .navigationDestination(for: String.self) { id in
                FleetCardScreen(cardId: id, fleet: fleet)
            }
            .refreshable { await load() }
            .task { await load() }
            .cardActions(controller)
        }
        .onChange(of: search) { _, text in found.update(text) }
        .onChange(of: path.isEmpty) { _, isEmpty in
            covered = isEmpty ? nil : rows
        }
        .onAppear {
            controller.onChange = { id in
                // A card brought back is on a board and leaves the rows by
                // itself; a deleted one is on none and is dropped here.
                guard fleet.masters.allSatisfy({ $0.card(id: id) == nil }) else { return }
                entries.removeAll { $0.id == id }
                found.remove(cardId: id)
            }
        }
    }

    /// The newest archived cards of each online master, a card two masters
    /// list taken from its owner. A master with card search sends only
    /// those; an older one sends every card (`?all=1`).
    private func load() async {
        var byId: [String: FleetCard] = [:]
        var failed: [String] = []
        for master in fleet.onlineMasters {
            guard let client = master.client else { continue }
            do {
                let cards: [RemoteCard]
                if master.supports(RemoteAPI.Feature.cardSearch) {
                    cards = try await client.searchCards("", scope: .archived, limit: Self.limit, local: true).cards
                } else {
                    cards = try await client.board(all: true).cards.filter { $0.archived && $0.parentCardId == nil }
                }
                for card in cards {
                    let entry = fleet.fleetCard(card, listedBy: master)
                    if byId[card.id] == nil || entry.master === master { byId[card.id] = entry }
                }
            } catch {
                failed.append("\(master.machineName): \(error.localizedDescription)")
            }
        }
        entries = Array(byId.values
            .sorted { ($0.card.lastActivity ?? $0.card.updatedAt) > ($1.card.lastActivity ?? $1.card.updatedAt) }
            .prefix(Self.limit))
        fleet.remember(entries)
        failures = failed
        loaded = true
    }
}
