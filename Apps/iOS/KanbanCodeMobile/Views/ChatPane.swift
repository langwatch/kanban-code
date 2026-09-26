import SwiftUI
import KanbanCodeRemoteKit

struct ChatPane: View {
    let card: RemoteCard
    let transcript: TranscriptModel
    let board: BoardModel
    let onResume: () -> Void

    @State private var draft = ""
    @State private var isSending = false
    @State private var sendError: String?
    @State private var sentCount = 0
    @FocusState private var composerFocused: Bool

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 12) {
                if transcript.olderCursor != nil {
                    HStack {
                        Spacer()
                        ProgressView()
                        Spacer()
                    }
                    .padding(.vertical, 8)
                    .onAppear { Task { await transcript.loadOlder() } }
                }
                ForEach(transcript.messages) { message in
                    MessageView(message: message)
                        .id(message.id)
                }
                if card.isBusy {
                    WorkingIndicator()
                }
            }
            .padding(.horizontal)
            .padding(.vertical, 12)
        }
        .defaultScrollAnchor(.bottom, for: .initialOffset)
        .defaultScrollAnchor(.bottom, for: .sizeChanges)
        .scrollDismissesKeyboard(.interactively)
        .overlay { emptyState }
        .safeAreaInset(edge: .bottom, spacing: 0) { bottomBar }
        .refreshable { await transcript.refresh() }
        .task(id: card.lastActivity ?? card.updatedAt) { await transcript.refresh() }
        .task(id: card.isBusy) {
            // Board events carry card changes; while a turn runs also poll
            // so streamed text shows up between them.
            while card.isBusy, !Task.isCancelled {
                try? await Task.sleep(for: .seconds(3))
                await transcript.refresh()
            }
        }
        .sensoryFeedback(.success, trigger: sentCount)
    }

    @ViewBuilder private var emptyState: some View {
        if transcript.messages.isEmpty {
            if let error = transcript.error {
                ContentUnavailableView {
                    Label("Cannot load the conversation", systemImage: "exclamationmark.bubble")
                } description: {
                    Text(error)
                } actions: {
                    Button("Try again") { Task { await transcript.refresh() } }
                }
            } else if transcript.loadedOnce {
                ContentUnavailableView("No messages yet", systemImage: "bubble.left.and.bubble.right",
                                       description: Text(card.isLive ? "Send a prompt to start." : "Resume the session to talk to it."))
            } else {
                ProgressView()
            }
        }
    }

    @ViewBuilder private var bottomBar: some View {
        VStack(spacing: 6) {
            if let sendError {
                Label(sendError, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            if card.isLive {
                composer
            } else {
                HStack {
                    Text("Session not running")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Resume", systemImage: "play.fill", action: onResume)
                        .buttonStyle(.borderedProminent)
                        .accessibilityIdentifier("resumeBar")
                }
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
        .background(.bar)
    }

    private var composer: some View {
        VStack(alignment: .leading, spacing: 4) {
            if card.isBusy || card.queuedPromptCount > 0 {
                Text(queueHint)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            HStack(alignment: .bottom, spacing: 8) {
                TextField("Message", text: $draft, axis: .vertical)
                    .lineLimit(1...6)
                    .focused($composerFocused)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 9)
                    .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 20))
                    .accessibilityIdentifier("composer")
                Menu {
                    Button("Send now, interrupting", systemImage: "bolt.fill") { send(.now) }
                    Button("Queue for after this turn", systemImage: "tray.and.arrow.down") { send(.queue) }
                } label: {
                    Image(systemName: isSending ? "ellipsis.circle.fill" : "arrow.up.circle.fill")
                        .font(.system(size: 34))
                        .symbolRenderingMode(.hierarchical)
                } primaryAction: {
                    send(.queue)
                }
                .disabled(trimmedDraft.isEmpty || isSending)
                .accessibilityLabel("Send")
                .accessibilityIdentifier("send")
            }
        }
    }

    private var queueHint: String {
        var parts: [String] = []
        if card.queuedPromptCount > 0 { parts.append("\(card.queuedPromptCount) queued.") }
        if card.isBusy { parts.append("Sends when the turn ends. Hold to send now.") }
        return parts.joined(separator: " ")
    }

    private var trimmedDraft: String { draft.trimmingCharacters(in: .whitespacesAndNewlines) }

    private func send(_ mode: RemotePromptRequest.Mode) {
        let text = trimmedDraft
        guard !text.isEmpty, let client = board.client, !isSending else { return }
        isSending = true
        sendError = nil
        Task {
            defer { isSending = false }
            do {
                try await client.sendPrompt(cardId: card.id, text: text, mode: mode)
                draft = ""
                sentCount += 1
                transcript.appendPending(text)
            } catch {
                sendError = error.localizedDescription
                UINotificationFeedbackGenerator().notificationOccurred(.error)
            }
        }
    }
}

struct WorkingIndicator: View {
    var body: some View {
        HStack(spacing: 6) {
            ProgressView().controlSize(.small)
            Text("Working")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
    }
}

struct MessageView: View {
    let message: RemoteMessage
    @State private var expanded = false

    var body: some View {
        switch message.role {
        case .user:
            HStack {
                Spacer(minLength: 48)
                Text(message.text)
                    .textSelection(.enabled)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 9)
                    .background(Color.accentColor.opacity(message.id.hasPrefix("pending-") ? 0.5 : 0.9),
                                in: RoundedRectangle(cornerRadius: 18))
                    .foregroundStyle(.white)
            }
        case .assistant:
            MarkdownText(text: message.text)
                .frame(maxWidth: .infinity, alignment: .leading)
        case .tool:
            Button {
                withAnimation(.snappy) { expanded.toggle() }
            } label: {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Image(systemName: "wrench.and.screwdriver")
                        .font(.caption2)
                    Text(message.text)
                        .font(.caption.monospaced())
                        .lineLimit(expanded ? nil : 1)
                        .multilineTextAlignment(.leading)
                    Spacer(minLength: 0)
                }
                .foregroundStyle(.secondary)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(Color(.tertiarySystemFill), in: RoundedRectangle(cornerRadius: 8))
            }
            .buttonStyle(.plain)
        case .system:
            Text(message.text)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity)
                .multilineTextAlignment(.center)
        }
    }
}

/// Assistant markdown: fenced code as monospaced blocks, headings and lists
/// by line, inline styles through AttributedString.
struct MarkdownText: View {
    let text: String

    private enum Block: Hashable {
        case code(String)
        case heading(String)
        case paragraph(String)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                switch block {
                case .code(let code):
                    ScrollView(.horizontal, showsIndicators: false) {
                        Text(code)
                            .font(.footnote.monospaced())
                            .textSelection(.enabled)
                            .padding(10)
                    }
                    .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 8))
                case .heading(let line):
                    Text(inline(line)).font(.headline)
                case .paragraph(let para):
                    Text(inline(para)).textSelection(.enabled)
                }
            }
        }
    }

    private func inline(_ s: String) -> AttributedString {
        (try? AttributedString(markdown: s, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(s)
    }

    private var blocks: [Block] {
        var out: [Block] = []
        var paragraph: [String] = []
        var code: [String]? = nil
        func flush() {
            let joined = paragraph.joined(separator: "\n").trimmingCharacters(in: .newlines)
            if !joined.isEmpty { out.append(.paragraph(joined)) }
            paragraph = []
        }
        for raw in text.components(separatedBy: "\n") {
            let trimmed = raw.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") {
                if let lines = code {
                    out.append(.code(lines.joined(separator: "\n")))
                    code = nil
                } else {
                    flush()
                    code = []
                }
                continue
            }
            if code != nil { code!.append(raw); continue }
            if trimmed.hasPrefix("#") {
                flush()
                out.append(.heading(String(trimmed.drop { $0 == "#" }).trimmingCharacters(in: .whitespaces)))
            } else if trimmed.isEmpty {
                flush()
            } else if trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ") {
                let indent = String(raw.prefix { $0 == " " })
                paragraph.append(indent + "• " + trimmed.dropFirst(2))
            } else {
                paragraph.append(raw)
            }
        }
        if let lines = code { out.append(.code(lines.joined(separator: "\n"))) }
        flush()
        return out
    }
}

#Preview("Markdown") {
    ScrollView {
        MarkdownText(text: PreviewData.messages[1].text).padding()
    }
}
