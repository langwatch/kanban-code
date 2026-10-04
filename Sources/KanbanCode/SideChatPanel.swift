import SwiftUI
import KanbanCodeCore
import KanbanCodeRemoteKit
import MarkdownUI

/// The side chats of the cards, kept while the app runs so a side chat
/// stays with its card when another card is shown.
@MainActor
enum SideChatCenter {
    private static var controllers: [String: SideChatController] = [:]

    static func controller(for cardId: String) -> SideChatController {
        if let existing = controllers[cardId] { return existing }
        let controller = SideChatController(transport: transport(cardId: cardId))
        controllers[cardId] = controller
        return controller
    }

    /// The runs go through the engine: it runs them here, or on the master
    /// that owns the card.
    private static func transport(cardId: String) -> SideChatController.Transport {
        SideChatController.Transport(
            start: { request in
                do {
                    return try await AppComposition.shared.engine.startSideChat(cardId: cardId, request)
                } catch let error as RemoteHostError {
                    throw RemoteError(error.message)
                }
            },
            poll: { runId in
                do {
                    return try await AppComposition.shared.engine.sideChatRun(cardId: cardId, runId: runId)
                } catch let error as RemoteHostError {
                    throw RemoteError(error.message)
                }
            },
            cancel: { runId in await AppComposition.shared.engine.cancelSideChat(cardId: cardId, runId: runId) })
    }
}

/// A place in the main chat to scroll to and highlight: the transcript
/// offset of a message a catch-up cites.
struct ChatJumpRequest: Equatable {
    let id = UUID()
    let offset: Int
}

/// The side chat over the top of a card's chat: `/btw` answers and the
/// `/catchup` summary. Nothing in it is part of the conversation until the
/// human sends a follow-up to the main chat.
struct SideChatPanel: View {
    let controller: SideChatController
    /// Height of the folded panel with its top padding: the room the chat
    /// leaves at its top while the side chat is open, so a cited message
    /// shows under it.
    static let foldedHeight: CGFloat = 52

    /// Folded to its title bar, so the chat under it shows: a citation link
    /// folds it, a new question opens it again.
    @Binding var collapsed: Bool
    /// Scrolls the main chat to the message at a transcript offset.
    var onJump: (Int) -> Void
    /// Sends a prompt to the session, as the composer does.
    var onSendToMain: (String) -> Void

    @State private var followUp = ""
    @State private var entriesHeight: CGFloat = 0
    @FocusState private var followUpFocused: Bool

    private var state: SideChatState { controller.state }

    private var canFollowUp: Bool {
        !followUp.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !state.isRunning
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            if !collapsed {
                Divider().opacity(0.5)
                // As tall as what it holds, and scrolling past 440 points.
                ScrollViewReader { proxy in
                    ScrollView {
                        entries
                            .onGeometryChange(for: CGFloat.self) { $0.size.height.rounded(.up) } action: { entriesHeight = $0 }
                    }
                    .frame(height: min(max(entriesHeight, 40), 440))
                    .onChange(of: state.entries.last?.id, initial: true) { _, last in
                        if let last { proxy.scrollTo(last, anchor: .top) }
                    }
                }
                Divider().opacity(0.5)
                followUpBar
            }
        }
        .frame(maxWidth: chatMaxWidth)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Color.primary.opacity(0.12), lineWidth: 1))
        .shadow(color: .black.opacity(0.18), radius: 14, y: 6)
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .onAppear { followUpFocused = true }
        .accessibilityIdentifier("sideChatPanel")
    }

    private var entries: some View {
        VStack(alignment: .leading, spacing: 14) {
            if state.entries.isEmpty {
                Text("Ask about what is going on. It does not go into the conversation.")
                    .font(.app(.callout))
                    .foregroundStyle(Color(nsColor: .secondaryLabelColor))
            }
            ForEach(state.entries) { entry in
                SideChatEntryView(entry: entry, onJump: onJump, onRefresh: { controller.refresh() })
                    .id(entry.id)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "bubble.left.and.text.bubble.right")
                .foregroundStyle(.orange)
            Text("Side chat")
                .font(.app(.callout).weight(.semibold))
            Text("not in the conversation")
                .font(.app(.caption))
                .foregroundStyle(Color(nsColor: .secondaryLabelColor))
            if state.isRunning && collapsed {
                ProgressView().controlSize(.small)
            }
            Spacer()
            Button {
                withAnimation(.easeInOut(duration: 0.15)) { collapsed.toggle() }
            } label: {
                Image(systemName: collapsed ? "chevron.down" : "chevron.up")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Color(nsColor: .secondaryLabelColor))
                    .frame(width: 22, height: 22)
                    .background(Color.primary.opacity(0.06), in: Circle())
            }
            .buttonStyle(.plain)
            .pointerStyle(.link)
            .help(collapsed ? "Show the side chat" : "Fold the side chat")
            .accessibilityIdentifier("sideChatFold")
            Button {
                controller.dismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Color(nsColor: .secondaryLabelColor))
                    .frame(width: 22, height: 22)
                    .background(Color.primary.opacity(0.06), in: Circle())
            }
            .buttonStyle(.plain)
            .pointerStyle(.link)
            .help("Dismiss (Esc)")
            .accessibilityIdentifier("sideChatDismiss")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .contentShape(Rectangle())
        .onTapGesture {
            if collapsed { withAnimation(.easeInOut(duration: 0.15)) { collapsed = false } }
        }
    }

    private var followUpBar: some View {
        HStack(alignment: .bottom, spacing: 8) {
            TextField("Follow up…", text: $followUp, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.app(.callout))
                .lineLimit(1...5)
                .focused($followUpFocused)
                .onSubmit { askHere() }
                .onKeyPress(.escape) {
                    controller.dismiss()
                    return .handled
                }
                .accessibilityIdentifier("sideChatFollowUp")
            Button("Ask here") { askHere() }
                .keyboardShortcut(.return, modifiers: [])
                .disabled(!canFollowUp)
                .help("Continue in the side chat (Return)")
            Button("Send to main chat") { sendToMain() }
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(!canFollowUp)
                .help("Bring the side chat into the conversation and send this there (Command-Return)")
        }
        .controlSize(.small)
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
    }

    private func askHere() {
        guard canFollowUp else { return }
        controller.ask(.btw, question: followUp)
        followUp = ""
    }

    private func sendToMain() {
        guard canFollowUp else { return }
        let prompt = controller.mainChatPrompt(reply: followUp)
        followUp = ""
        // The panel leaves in one step: the chat is about to show the
        // message, and its layout does not wait on a closing animation.
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) { controller.dismiss() }
        onSendToMain(prompt)
    }
}

private struct SideChatEntryView: View {
    let entry: SideChatState.Entry
    var onJump: (Int) -> Void
    /// Runs the catch-up again.
    var onRefresh: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text("❯").foregroundStyle(.orange)
                Text(entry.question)
                    .font(.app(.callout).weight(.semibold))
                    .textSelection(.enabled)
            }
            if let since = entry.since {
                sinceLine(since)
            }
            if let summary = entry.catchUp {
                CatchUpSummaryView(summary: summary, refs: entry.refs, onJump: onJump)
            } else if !entry.answer.isEmpty, entry.kind == .btw || !entry.isRunning {
                // A catch-up that did not parse reads as the text it is.
                Markdown(entry.answerText)
                    .markdownTextStyle { FontSize(13) }
                    .textSelection(.enabled)
            }
            if entry.kind == .catchup, !entry.isRunning, entry.error == nil {
                HStack(spacing: 8) {
                    if let note = entry.reopenedNote() {
                        Text(note)
                            .font(.app(.caption))
                            .foregroundStyle(Color(nsColor: .secondaryLabelColor))
                            .accessibilityIdentifier("catchUpReopened")
                    }
                    Button(action: onRefresh) {
                        Label("Refresh", systemImage: "arrow.clockwise")
                            .font(.app(.caption))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(Color.accentColor)
                    .pointerStyle(.link)
                    .help("Run the catch-up again")
                    .accessibilityIdentifier("catchUpRefresh")
                }
            }
            if entry.isRunning {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text(entry.answer.isEmpty ? "Reading the session…" : "Writing…")
                        .font(.app(.caption))
                        .foregroundStyle(Color(nsColor: .secondaryLabelColor))
                }
            }
            if let error = entry.error {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.app(.callout))
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
            }
        }
    }

    @ViewBuilder
    private func sinceLine(_ since: RemoteSideChatSince) -> some View {
        let quote = since.text.split(whereSeparator: \.isNewline).joined(separator: " ")
        let label = "Since you sent: “\(quote.count > 120 ? String(quote.prefix(120)) + "…" : quote)”"
        if let offset = since.offset {
            Button { onJump(offset) } label: {
                Text(label)
                    .font(.app(.caption))
                    .foregroundStyle(Color(nsColor: .secondaryLabelColor))
                    .multilineTextAlignment(.leading)
            }
            .buttonStyle(.plain)
            .pointerStyle(.link)
            .help("Show this message in the chat")
        } else {
            Text(label + " (still queued)")
                .font(.app(.caption))
                .foregroundStyle(Color(nsColor: .secondaryLabelColor))
        }
    }
}

/// A catch-up drawn as its sections; every citation is a link that shows
/// the cited message in the main chat.
struct CatchUpSummaryView: View {
    let summary: CatchUpSummary
    let refs: [RemoteSideChatRef]
    var onJump: (Int) -> Void

    private func offset(of item: CatchUpSummary.Item) -> Int? {
        item.refs.lazy.compactMap { citation in refs.first { $0.ref == citation }?.offset }.first
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(summary.sections) { section in
                VStack(alignment: .leading, spacing: 4) {
                    Text(section.title.uppercased())
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(section.id == "waiting" || section.id == "blocked" ? Color.orange : Color(nsColor: .secondaryLabelColor))
                    ForEach(section.items) { item in
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Text("•").foregroundStyle(Color(nsColor: .tertiaryLabelColor))
                            Text(SideChatLinks.attributed(item, refs: refs))
                                .font(.app(.callout))
                                .textSelection(.enabled)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                if section.id == "status", let report = summary.report, let offset = offset(of: report) {
                    reportButton(report, offset: offset)
                }
            }
            // No status section to sit under: the report link still shows.
            if !summary.sections.contains(where: { $0.id == "status" }),
               let report = summary.report, let offset = offset(of: report) {
                reportButton(report, offset: offset)
            }
        }
        .environment(\.openURL, OpenURLAction { url in
            guard let citation = SideChatLinks.ref(from: url) else { return .systemAction }
            if let target = refs.first(where: { $0.ref == citation }) { onJump(target.offset) }
            return .handled
        })
    }

    private func reportButton(_ report: CatchUpSummary.Item, offset: Int) -> some View {
        Button { onJump(offset) } label: {
            Label(report.text, systemImage: "doc.text")
                .font(.app(.callout).weight(.medium))
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.small)
        .pointerStyle(.link)
        .help("Show the report in the chat")
        .accessibilityIdentifier("catchUpReport")
    }
}
