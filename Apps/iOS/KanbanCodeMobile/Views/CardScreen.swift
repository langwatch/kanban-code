import SwiftUI
import KanbanCodeRemoteKit

struct CardScreen: View {
    let cardId: String
    let board: BoardModel

    enum Tab: Hashable { case chat, terminal }

    @State private var tab: Tab = .chat
    @State private var transcript: TranscriptModel
    @State private var actionError: String?
    @State private var isResuming = false
    @State private var showFullTerminal = false
    @State private var terminalSession: String?
    @State private var terminal = TerminalController()

    init(cardId: String, board: BoardModel, transcript: TranscriptModel? = nil) {
        self.cardId = cardId
        self.board = board
        _transcript = State(initialValue: transcript ?? TranscriptModel(cardId: cardId, client: board.client))
    }

    private var card: RemoteCard? { board.card(id: cardId) }

    private var showsTerminal: Bool {
        board.canUseTerminal && card.map { $0.isLive && ($0.runtime != .none || !$0.terminals.isEmpty) } == true
    }

    var body: some View {
        VStack(spacing: 0) {
            if let card {
                header(card)
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
                    ChatPane(card: card, transcript: transcript, board: board, onResume: resume)
                case .terminal:
                    if showFullTerminal {
                        Color(white: 0.07)
                    } else {
                        TerminalPane(card: card, client: board.client, controller: terminal,
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
                FullScreenTerminal(card: card, client: board.client, controller: terminal, session: $terminalSession)
            }
        }
        .onChange(of: showsTerminal) { _, shows in
            if !shows { tab = .chat }
        }
        .onDisappear {
            if !showFullTerminal { terminal.disconnect() }
        }
    }

    private func header(_ card: RemoteCard) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                StatusDot(card: card, size: 10)
                Text(card.title.isEmpty ? "Untitled" : card.title)
                    .font(.headline)
                    .lineLimit(2)
            }
            HStack(spacing: 10) {
                if let project = card.projectName {
                    Label(project, systemImage: "folder")
                }
                if let branch = card.branch, !branch.isEmpty {
                    Label(branch, systemImage: "arrow.triangle.branch")
                        .truncationMode(.middle)
                }
                Spacer(minLength: 0)
                ForEach(card.prs, id: \.number) { pr in
                    if let url = pr.url.flatMap(URL.init(string:)) {
                        Link(destination: url) { PRBadge(pr: pr) }
                    } else {
                        PRBadge(pr: pr)
                    }
                }
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
