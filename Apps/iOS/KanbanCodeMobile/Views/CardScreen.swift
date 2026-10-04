import SwiftUI
import KanbanCodeRemoteKit

/// A card of the merged board, shown through the master that owns it:
/// its chat, prompts, queue and terminals all go to that master.
struct FleetCardScreen: View {
    let cardId: String
    let fleet: FleetModel

    var body: some View {
        if let entry = fleet.entry(cardId: cardId) {
            CardScreen(cardId: cardId, board: entry.master, machineName: fleet.showsMachines ? entry.machineName : nil,
                       fallback: entry.card)
                .id(entry.master.server.id)
        } else {
            ContentUnavailableView("Card not found", systemImage: "questionmark.square.dashed",
                                   description: Text("It may have been deleted on its machine."))
        }
    }
}

struct CardScreen: View {
    let cardId: String
    let board: BoardModel
    /// The machine that runs the card, named when there are several.
    var machineName: String?
    /// The card as the merged board lists it, while its owner's board does not.
    var fallback: RemoteCard?

    enum Tab: Hashable { case chat, terminal }

    @State private var tab: Tab = .chat
    @State private var transcript: TranscriptModel
    @State private var actionError: String?
    @State private var isResuming = false
    @State private var isBringingBack = false
    @State private var showFullTerminal = false
    @State private var terminalSession: String?
    @State private var terminal = TerminalController()
    @State private var draft: ComposerDraft

    init(cardId: String, board: BoardModel, machineName: String? = nil, fallback: RemoteCard? = nil,
         transcript: TranscriptModel? = nil) {
        self.cardId = cardId
        self.board = board
        self.machineName = machineName
        self.fallback = fallback
        _transcript = State(initialValue: transcript ?? TranscriptModel(cardId: cardId, client: board.client))
        _draft = State(initialValue: board.client == nil
                       ? ComposerDraft(preview: "")
                       : ComposerDraft(server: board.server.id, cardId: cardId))
    }

    private var card: RemoteCard? { board.card(id: cardId) ?? fallback }

    private var showsTerminal: Bool {
        board.canUseTerminal && board.isOnline && card.map { $0.isLive && ($0.runtime != .none || !$0.terminals.isEmpty) } == true
    }

    var body: some View {
        VStack(spacing: 0) {
            if let card {
                header(card)
                if !board.isOnline {
                    offlineBanner
                }
                if !CardSearch.isOnBoard(card) {
                    archivedBanner(card)
                }
                if showsTerminal {
                    Picker("View", selection: $tab) {
                        Text("Chat").tag(Tab.chat)
                        Text("Terminal").tag(Tab.terminal)
                    }
                    .pickerStyle(.segmented)
                    .padding(.horizontal)
                    .padding(.bottom, 8)
                    .accessibilityIdentifier("cardTabs")
                }
                Divider()
                switch tab {
                case .chat:
                    ChatPane(card: card, transcript: transcript, board: board, draft: draft, onResume: resume,
                             onInterrupt: { Task { await interrupt(card) } })
                case .terminal:
                    if showFullTerminal {
                        Color(white: 0.07)
                    } else {
                        TerminalPane(card: card, client: board.client,
                                     serverScroll: board.supports(RemoteAPI.Feature.terminalScroll), controller: terminal,
                                     session: $terminalSession, onFullScreen: { showFullTerminal = true })
                    }
                }
            } else {
                ContentUnavailableView("Card not found", systemImage: "questionmark.square.dashed",
                                       description: Text("It may have been deleted on the Mac."))
            }
        }
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { toolbar }
        .alert("Something went wrong", isPresented: Binding(
            get: { actionError != nil }, set: { if !$0 { actionError = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(actionError ?? "")
        }
        .fullScreenCover(isPresented: $showFullTerminal) {
            if let card {
                FullScreenTerminal(card: card, client: board.client,
                                   serverScroll: board.supports(RemoteAPI.Feature.terminalScroll),
                                   controller: terminal, session: $terminalSession)
            }
        }
        .onChange(of: showsTerminal) { _, shows in
            if !shows { tab = .chat }
        }
        .onDisappear {
            if !showFullTerminal { terminal.disconnect() }
        }
    }

    private var offlineBanner: some View {
        Label("\(board.machineName): \(MachineStatusLine.status(board))", systemImage: "bolt.horizontal.circle")
            .font(.caption)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal)
            .padding(.vertical, 6)
            .background(Color(.secondarySystemBackground))
            .accessibilityIdentifier("machineOffline")
    }

    /// A card that is off the board: archived, or left in All Sessions. Its
    /// conversation reads as it is; one tap puts it in the backlog.
    private func archivedBanner(_ card: RemoteCard) -> some View {
        HStack(spacing: 10) {
            Label(card.archived ? "Archived" : "In All Sessions, not on the board", systemImage: "archivebox")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Spacer(minLength: 8)
            Button {
                bringBack(card)
            } label: {
                if isBringingBack {
                    ProgressView()
                } else {
                    Label("Bring back to board", systemImage: "tray.and.arrow.up")
                }
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            .disabled(isBringingBack || !board.isOnline || board.client == nil)
            .accessibilityIdentifier("bringBack")
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
        .background(Color(.secondarySystemBackground))
    }

    /// Unarchives the card, or places an All Sessions card in the backlog;
    /// either way it lands in the backlog and stays.
    private func bringBack(_ card: RemoteCard) {
        guard let client = board.client, !isBringingBack else { return }
        isBringingBack = true
        Task {
            defer { isBringingBack = false }
            do {
                let update = card.archived ? RemoteCardUpdate(archived: false) : RemoteCardUpdate(column: .backlog)
                board.upsert(try await client.updateCard(cardId: cardId, update))
                UINotificationFeedbackGenerator().notificationOccurred(.success)
            } catch {
                actionError = "Could not bring the card back: \(error.localizedDescription)"
            }
        }
    }

    private func header(_ card: RemoteCard) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                StatusDot(card: card, size: 10, unknown: !board.isOnline)
                Text(card.title.isEmpty ? "Untitled" : card.title)
                    .font(.headline)
                    .lineLimit(2)
            }
            HStack(spacing: 10) {
                if let project = card.projectName {
                    Label(project, systemImage: "folder")
                        .layoutPriority(2)
                }
                if let machineName {
                    MachineLabel(name: machineName, offline: !board.isOnline)
                        .layoutPriority(1)
                        .accessibilityIdentifier("cardMachine")
                }
                if let branch = card.branch, !branch.isEmpty {
                    Label(branch, systemImage: "arrow.triangle.branch")
                }
                Spacer(minLength: 0)
                PRBadges(prs: card.prs, linked: true)
            }
            .labelStyle(CompactLabelStyle())
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal)
        .padding(.vertical, 8)
    }

    @ToolbarContentBuilder private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .principal) {
            Text(card?.column.displayName ?? "")
                .font(.subheadline.weight(.semibold))
        }
        if let card {
            if card.isBusy {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(role: .destructive) {
                        Task { await interrupt(card) }
                    } label: {
                        Label("Interrupt", systemImage: "stop.fill")
                    }
                    .tint(.red)
                    .accessibilityIdentifier("interrupt")
                }
            }
        }
    }

    private func interrupt(_ card: RemoteCard) async {
        guard let client = board.client else { return }
        do {
            try await client.interrupt(cardId: card.id)
            UIImpactFeedbackGenerator(style: .rigid).impactOccurred()
        } catch {
            actionError = error.localizedDescription
        }
    }

    private func resume() {
        guard let client = board.client, !isResuming else { return }
        isResuming = true
        Task {
            defer { isResuming = false }
            do {
                let updated = try await client.resume(cardId: cardId)
                board.upsert(updated)
                UINotificationFeedbackGenerator().notificationOccurred(.success)
            } catch {
                actionError = error.localizedDescription
            }
        }
    }
}

#Preview("Card") {
    let board = BoardModel(preview: PreviewData.board)
    NavigationStack {
        CardScreen(cardId: PreviewData.board.cards[0].id, board: board,
                   transcript: TranscriptModel(preview: PreviewData.messages))
    }
}
