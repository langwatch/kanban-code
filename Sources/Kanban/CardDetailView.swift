import SwiftUI
import KanbanCore

struct CardDetailView: View {
    let card: KanbanCard
    var onResume: () -> Void = {}
    var onRename: (String) -> Void = { _ in }
    var onFork: () -> Void = {}
    var onDismiss: () -> Void = {}

    @State private var turns: [ConversationTurn] = []
    @State private var isLoadingHistory = false
    @State private var selectedTab: Int

    init(card: KanbanCard, onResume: @escaping () -> Void = {}, onRename: @escaping (String) -> Void = { _ in }, onFork: @escaping () -> Void = {}, onDismiss: @escaping () -> Void = {}) {
        self.card = card
        self.onResume = onResume
        self.onRename = onRename
        self.onFork = onFork
        self.onDismiss = onDismiss
        // Default to history tab when no terminal session
        _selectedTab = State(initialValue: card.link.tmuxSession == nil ? 1 : 0)
    }
    @State private var showRenameSheet = false
    @State private var renameText = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(card.displayTitle)
                        .font(.title3)
                        .fontWeight(.semibold)
                        .lineLimit(2)

                    HStack(spacing: 8) {
                        if let projectName = card.projectName {
                            Label(projectName, systemImage: "folder")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        if let branch = card.link.worktreeBranch {
                            Label(branch, systemImage: "arrow.triangle.branch")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Text(card.relativeTime)
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                }

                Spacer()
            }
            .padding(16)

            Divider()

            // Tab bar
            Picker("Tab", selection: $selectedTab) {
                Text("Terminal").tag(0)
                Text("History").tag(1)
                Text("Actions").tag(2)
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 16)
            .padding(.vertical, 8)

            // Content
            switch selectedTab {
            case 0:
                terminalView
            case 1:
                SessionHistoryView(turns: turns, isLoading: isLoadingHistory)
            case 2:
                actionsView
            default:
                EmptyView()
            }
        }
        .frame(maxWidth: .infinity)
        .task(id: card.id) {
            turns = []
            isLoadingHistory = false
            await loadHistory()
        }
        .sheet(isPresented: $showRenameSheet) {
            RenameSessionDialog(
                currentName: card.link.name ?? card.displayTitle,
                isPresented: $showRenameSheet,
                onRename: onRename
            )
        }
    }

    @ViewBuilder
    private var terminalView: some View {
        if let tmuxSession = card.link.tmuxSession {
            TerminalRepresentable.tmuxAttach(sessionName: tmuxSession)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            VStack(spacing: 12) {
                Image(systemName: "terminal")
                    .font(.system(size: 32))
                    .foregroundStyle(.tertiary)
                Text("No tmux session attached")
                    .font(.body)
                    .foregroundStyle(.secondary)
                Button(action: onResume) {
                    Label("Launch Terminal", systemImage: "play.fill")
                }
                .buttonStyle(.borderedProminent)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var actionsView: some View {
        VStack(alignment: .leading, spacing: 12) {
            Button(action: onResume) {
                Label("Resume Session", systemImage: "play.fill")
            }
            .buttonStyle(.borderedProminent)

            Button(action: { showRenameSheet = true }) {
                Label("Rename", systemImage: "pencil")
            }
            .buttonStyle(.bordered)

            Button(action: onFork) {
                Label("Fork Session", systemImage: "arrow.branch")
            }
            .buttonStyle(.bordered)

            Button(action: copyResumeCommand) {
                Label("Copy Resume Command", systemImage: "doc.on.doc")
            }
            .buttonStyle(.bordered)

            if card.link.sessionPath != nil {
                Button(action: { copyToClipboard("claude --resume \(card.link.sessionId)") }) {
                    Label("Copy Session ID", systemImage: "number")
                }
                .buttonStyle(.bordered)
            }

            if let pr = card.link.githubPR {
                Divider()
                Button(action: {}) {
                    Label("Open PR #\(pr)", systemImage: "arrow.up.right.square")
                }
                .buttonStyle(.bordered)
            }

            Spacer()

            if let jsonlPath = card.link.sessionPath {
                Text(jsonlPath)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .textSelection(.enabled)
            }
        }
        .padding(16)
    }

    private func loadHistory() async {
        guard let path = card.link.sessionPath ?? card.session?.jsonlPath else { return }
        isLoadingHistory = true
        do {
            turns = try await TranscriptReader.readTurns(from: path)
        } catch {
            // Silently fail — empty history is fine
        }
        isLoadingHistory = false
    }

    private func copyResumeCommand() {
        copyToClipboard("claude --resume \(card.link.sessionId)")
    }

    private func copyToClipboard(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

/// Native rename dialog sheet.
struct RenameSessionDialog: View {
    let currentName: String
    @Binding var isPresented: Bool
    var onRename: (String) -> Void = { _ in }

    @State private var name = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Rename Session")
                .font(.title3)
                .fontWeight(.semibold)

            TextField("Session name", text: $name)
                .textFieldStyle(.roundedBorder)

            HStack {
                Spacer()
                Button("Cancel") {
                    isPresented = false
                }
                .keyboardShortcut(.cancelAction)

                Button("Rename") {
                    let trimmed = name.trimmingCharacters(in: .whitespaces)
                    if !trimmed.isEmpty {
                        onRename(trimmed)
                    }
                    isPresented = false
                }
                .keyboardShortcut(.defaultAction)
                .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(20)
        .frame(width: 350)
        .onAppear {
            name = currentName
        }
    }
}
