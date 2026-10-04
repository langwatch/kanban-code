import SwiftUI
import KanbanCodeRemoteKit

/// The side chat over the top of a card's chat: `/btw` answers and the
/// `/catchup` summary. Nothing in it is part of the conversation until a
/// follow-up is sent to the main chat.
struct SideChatPanel: View {
    let controller: SideChatController
    /// Height of the folded panel: the room the chat leaves at its top
    /// while the side chat is open, so a cited message shows under it.
    static let foldedHeight: CGFloat = 58

    /// Folded to its title bar, so the chat under it shows: a citation link
    /// folds it, a new question opens it again.
    @Binding var collapsed: Bool
    /// The height the chat leaves for the panel, above the composer and
    /// the keyboard.
    var maxHeight: CGFloat = 520
    /// Shows the message at a transcript offset in the main chat.
    var onJump: (Int) -> Void
    /// Sends a prompt to the session, as the composer does.
    var onSendToMain: (String) -> Void
    /// The machine that owns the card, and whether the app has lost it.
    var machineName = ""
    var machineOffline = false

    @State private var followUp = ""
    @State private var entriesHeight: CGFloat = 0
    @State private var headerHeight: CGFloat = 46
    @State private var followUpHeight: CGFloat = 90

    /// The entries take what the title bar and the follow-up leave.
    private var entriesLimit: CGFloat {
        max(44, min(400, maxHeight - headerHeight - followUpHeight - 8))
    }
    @FocusState private var followUpFocused: Bool

    private var state: SideChatState { controller.state }

    private var canFollowUp: Bool {
        !followUp.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !state.isRunning
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .onGeometryChange(for: CGFloat.self) { $0.size.height.rounded(.up) } action: { headerHeight = $0 }
            if !collapsed {
                Divider()
                // As tall as what it holds, scrolling past the height the
                // composer and the keyboard leave.
                ScrollViewReader { proxy in
                    ScrollView {
                        entries
                            .onGeometryChange(for: CGFloat.self) { $0.size.height.rounded(.up) } action: { entriesHeight = $0 }
                    }
                    .frame(height: min(max(entriesHeight, 44), entriesLimit))
                    .onChange(of: state.entries.last?.id, initial: true) { _, last in
                        if let last { proxy.scrollTo(last, anchor: .top) }
                    }
                }
                Divider()
                followUpBar
                    .onGeometryChange(for: CGFloat.self) { $0.size.height.rounded(.up) } action: { followUpHeight = $0 }
            }
        }
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(Color(.separator).opacity(0.6), lineWidth: 0.5))
        .shadow(color: .black.opacity(0.18), radius: 12, y: 5)
        .padding(.horizontal, 10)
        .padding(.top, 6)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("sideChatPanel")
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "bubble.left.and.text.bubble.right")
                .foregroundStyle(.orange)
            Text("Side chat")
                .font(.subheadline.weight(.semibold))
            Text("not in the conversation")
                .font(.caption)
                .foregroundStyle(Color(.secondaryLabel))
                .lineLimit(1)
            if state.isRunning && collapsed {
                ProgressView().controlSize(.small)
            }
            Spacer(minLength: 4)
            Button {
                withAnimation(.snappy) { collapsed.toggle() }
            } label: {
                Image(systemName: collapsed ? "chevron.down" : "chevron.up")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color(.secondaryLabel))
                    .frame(width: 30, height: 30)
                    .background(Color(.tertiarySystemFill), in: Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(collapsed ? "Show the side chat" : "Fold the side chat")
            .accessibilityIdentifier("sideChatFold")
            Button {
                controller.dismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color(.secondaryLabel))
                    .frame(width: 30, height: 30)
                    .background(Color(.tertiarySystemFill), in: Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Dismiss the side chat")
            .accessibilityIdentifier("sideChatDismiss")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .contentShape(Rectangle())
        .onTapGesture {
            if collapsed { withAnimation(.snappy) { collapsed = false } }
        }
    }

    private var entries: some View {
        VStack(alignment: .leading, spacing: 14) {
            if state.entries.isEmpty {
                Text("Ask about what is going on. It does not go into the conversation.")
                    .font(.subheadline)
                    .foregroundStyle(Color(.secondaryLabel))
            }
            ForEach(state.entries) { entry in
                SideChatEntryView(entry: entry, onJump: onJump, onRefresh: { controller.refresh() },
                                  failure: SideChatFailure.text(for: entry, machine: machineName, machineOffline: machineOffline),
                                  onRetry: entry.id == state.failedEntry?.id ? { controller.retry() } : nil)
                    .id(entry.id)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
    }

    private var followUpBar: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextField("Follow up", text: $followUp, axis: .vertical)
                .lineLimit(1...3)
                .focused($followUpFocused)
                .accessibilityIdentifier("sideChatFollowUp")
            HStack(spacing: 8) {
                Button("Ask here") { askHere() }
                    .buttonStyle(.borderedProminent)
                    .accessibilityIdentifier("sideChatAskHere")
                Button("Send to main chat") { sendToMain() }
                    .buttonStyle(.bordered)
                    .accessibilityIdentifier("sideChatSendToMain")
                Spacer()
            }
            .controlSize(.small)
            .disabled(!canFollowUp)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
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
        followUpFocused = false
        controller.dismiss()
        onSendToMain(prompt)
    }
}

private struct SideChatEntryView: View {
    let entry: SideChatState.Entry
    var onJump: (Int) -> Void
    /// Runs the catch-up again.
    var onRefresh: () -> Void
    /// What the failure reads as: the machine being offline, or its error.
    var failure: String?
    /// Asks the failed question again; nil for an entry that cannot.
    var onRetry: (() -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text("❯").foregroundStyle(.orange)
                Text(entry.question)
                    .font(.subheadline.weight(.semibold))
            }
            if let since = entry.since {
                sinceLine(since)
            }
            if let summary = entry.catchUp {
                CatchUpSummaryView(summary: summary, refs: entry.refs, onJump: onJump)
            } else if !entry.answer.isEmpty, entry.kind == .btw || !entry.isRunning {
                // A catch-up that did not parse reads as the text it is.
                MarkdownText(text: entry.answerText)
                    .font(.subheadline)
                    .accessibilityIdentifier("sideChatAnswer")
            }
            if entry.kind == .catchup, !entry.isRunning, entry.error == nil {
                HStack(spacing: 10) {
                    if let note = entry.reopenedNote() {
                        Text(note)
                            .font(.caption)
                            .foregroundStyle(Color(.secondaryLabel))
                            .accessibilityIdentifier("catchUpReopened")
                    }
                    Button(action: onRefresh) {
                        Label("Refresh", systemImage: "arrow.clockwise")
                            .font(.caption)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(Color.accentColor)
                    .accessibilityIdentifier("catchUpRefresh")
                }
            }
            if entry.isRunning {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text(entry.answer.isEmpty ? "Reading the session…" : "Writing…")
                        .font(.caption)
                        .foregroundStyle(Color(.secondaryLabel))
                }
            }
            if let failure {
                Label(failure, systemImage: "exclamationmark.triangle.fill")
                    .font(.subheadline)
                    .foregroundStyle(.red)
                    .accessibilityIdentifier("sideChatError")
                if let onRetry {
                    Button(action: onRetry) {
                        Label("Retry", systemImage: "arrow.clockwise")
                            .font(.subheadline)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .accessibilityIdentifier("sideChatRetry")
                }
            }
        }
    }

    @ViewBuilder
    private func sinceLine(_ since: RemoteSideChatSince) -> some View {
        let quote = since.text.split(whereSeparator: \.isNewline).joined(separator: " ")
        let label = "Since you sent: “\(quote.count > 90 ? String(quote.prefix(90)) + "…" : quote)”"
        if let offset = since.offset {
            Button { onJump(offset) } label: {
                Text(label)
                    .font(.caption)
                    .foregroundStyle(Color(.secondaryLabel))
                    .multilineTextAlignment(.leading)
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("catchUpSince")
        } else {
            Text(label + " (still queued)")
                .font(.caption)
                .foregroundStyle(Color(.secondaryLabel))
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
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(section.id == "waiting" || section.id == "blocked" ? Color.orange : Color(.secondaryLabel))
                    ForEach(section.items) { item in
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Text("•").foregroundStyle(Color(.tertiaryLabel))
                            Text(SideChatLinks.attributed(item, refs: refs))
                                .font(.subheadline)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("catchUpSection-\(section.id)")
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
                .font(.subheadline.weight(.medium))
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.small)
        .accessibilityIdentifier("catchUpReport")
    }
}
