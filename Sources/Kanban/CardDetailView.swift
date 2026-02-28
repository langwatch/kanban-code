import SwiftUI
import KanbanCore

struct CardDetailView: View {
    let card: KanbanCard
    var onResume: () -> Void = {}
    var onDismiss: () -> Void = {}

    @State private var turns: [ConversationTurn] = []
    @State private var isLoadingHistory = false
    @State private var selectedTab = 0
    @State private var showTerminal = false

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

                Button(action: onDismiss) {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.borderless)
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
        .frame(minWidth: 350, idealWidth: 400, maxWidth: 500)
        .background(Color(.windowBackgroundColor))
        .task {
            await loadHistory()
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

            Button(action: copyResumeCommand) {
                Label("Copy Resume Command", systemImage: "doc.on.doc")
            }
            .buttonStyle(.bordered)

            if let jsonlPath = card.link.sessionPath {
                Button(action: { copyToClipboard("claude --resume \(card.link.sessionId)") }) {
                    Label("Copy Session ID", systemImage: "number")
                }
                .buttonStyle(.bordered)

                Text(jsonlPath)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .textSelection(.enabled)
            }

            Spacer()
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
