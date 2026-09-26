import SwiftUI
import PhotosUI
import KanbanCodeRemoteKit

struct ChatPane: View {
    let card: RemoteCard
    let transcript: TranscriptModel
    let board: BoardModel
    let draft: ComposerDraft
    let onResume: () -> Void
    let onInterrupt: () -> Void

    @State private var isSending = false
    @State private var sendError: String?
    @State private var sentCount = 0
    @State private var queueActions: Set<String> = []
    @State private var showPhotoPicker = false
    @State private var showCamera = false
    @State private var photoItems: [PhotosPickerItem] = []
    @FocusState private var composerFocused: Bool
    @State private var scrollPosition = ScrollPosition(edge: .bottom)

    /// Scroll geometry that decides whether the chat follows its end.
    private struct ScrollState: Equatable {
        var viewport: CGFloat
        var content: CGFloat
        var atBottom: Bool
    }

    private static let bottomID = "chat-bottom"

    private var supportsImages: Bool { board.supports(RemoteAPI.Feature.images) }
    private var supportsQueue: Bool { board.supports(RemoteAPI.Feature.queue) }

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
                ForEach(visibleMessages) { message in
                    MessageView(message: message)
                        .id(message.id)
                }
                ForEach(card.queuedPrompts) { prompt in
                    QueuedPromptView(
                        prompt: prompt,
                        isWorking: queueActions.contains(prompt.id),
                        canAct: supportsQueue && card.isLive,
                        onSendNow: { queueAction(prompt, send: true) },
                        onRemove: { queueAction(prompt, send: false) }
                    )
                    .id("queued-\(prompt.id)")
                }
                if card.isBusy {
                    WorkingIndicator()
                }
                Color.clear
                    .frame(height: 1)
                    .id(Self.bottomID)
            }
            .padding(.horizontal)
            .padding(.vertical, 12)
            // A tap anywhere on the conversation puts the keyboard away,
            // on a button too (which still does its own thing); message
            // text reports its taps through selectableTextTap.
            .contentShape(Rectangle())
            .simultaneousGesture(TapGesture().onEnded { composerFocused = false })
            .environment(\.selectableTextTap) { composerFocused = false }
        }
        .scrollPosition($scrollPosition)
        .defaultScrollAnchor(.bottom, for: .initialOffset)
        // Following the end goes through scrollTo(id:), which lays out the
        // row it scrolls to. A bottom anchor for size changes instead sets
        // the offset from the estimated heights of rows the lazy stack has
        // not laid out, so after the keyboard or a new message changed the
        // size it could land where no row is drawn and show a blank chat.
        .onScrollGeometryChange(for: ScrollState.self) { geo in
            ScrollState(viewport: geo.containerSize.height, content: geo.contentSize.height,
                        atBottom: geo.contentOffset.y + geo.containerSize.height >= geo.contentSize.height - 60)
        } action: { old, new in
            let resized = abs(old.viewport - new.viewport) > 1 || abs(old.content - new.content) > 1
            if resized && old.atBottom && !new.atBottom {
                scrollPosition.scrollTo(id: Self.bottomID, anchor: .bottom)
            }
        }
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
        .task(id: card.queuedPrompts.map(\.id)) {
            transcript.dropPending(queued: queuedTexts)
            // A queued prompt that just went out lands in the transcript.
            await transcript.refresh()
        }
        .sensoryFeedback(.success, trigger: sentCount)
        .photosPicker(isPresented: $showPhotoPicker, selection: $photoItems,
                      maxSelectionCount: max(1, RemoteImage.maxCount - draft.images.count),
                      matching: .images, preferredItemEncoding: .compatible)
        .onChange(of: photoItems) { _, items in
            guard !items.isEmpty else { return }
            photoItems = []
            Task { await addPhotos(items) }
        }
        .fullScreenCover(isPresented: $showCamera) {
            CameraPicker { data in draft.addImage(data) }
                .ignoresSafeArea()
        }
    }

    private var queuedTexts: Set<String> {
        Set(card.queuedPrompts.map { TranscriptModel.displayText($0.text, imageCount: $0.imageCount) })
    }

    /// Sent prompts that now wait in the card's queue show there instead.
    private var visibleMessages: [RemoteMessage] {
        let queued = queuedTexts
        guard !queued.isEmpty else { return transcript.messages }
        return transcript.messages.filter { !($0.id.hasPrefix("pending-") && queued.contains($0.text)) }
    }

    @ViewBuilder private var emptyState: some View {
        if transcript.messages.isEmpty && card.queuedPrompts.isEmpty {
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
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(Color(.systemBackground))
    }

    /// One rounded container: images, the text, then a row with + on the
    /// left and send on the right. Touch and hold send to send now.
    private var composer: some View {
        VStack(alignment: .leading, spacing: 4) {
            if card.isBusy && !draft.isEmpty {
                Text("Sends when this turn ends. Touch and hold send to send now.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 6)
                    .accessibilityIdentifier("queueHint")
            }
            VStack(alignment: .leading, spacing: 6) {
                if !draft.images.isEmpty {
                    attachments
                }
                TextField("Message", text: Bindable(draft).text, axis: .vertical)
                    .lineLimit(1...8)
                    .focused($composerFocused)
                    .padding(.horizontal, 6)
                    .padding(.top, 4)
                    .accessibilityIdentifier("composer")
                HStack {
                    if supportsImages {
                        attachButton
                    }
                    Spacer()
                    sendButton
                }
            }
            .padding(10)
            .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 24, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .strokeBorder(Color(.separator).opacity(0.5), lineWidth: 0.5)
            )
            // A tap on the container's empty space puts the caret in the text.
            .contentShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
            .onTapGesture { composerFocused = true }
        }
    }

    /// Stop while the agent works and nothing is typed; send otherwise.
    private var showsStop: Bool { card.isBusy && draft.isEmpty && !isSending }

    @ViewBuilder private var sendButton: some View {
        if showsStop {
            Button(action: onInterrupt) {
                Image(systemName: "stop.fill")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(Color(.systemBackground))
                    .frame(width: 34, height: 34)
                    .background(Color(.label), in: Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Stop")
            .accessibilityIdentifier("stop")
        } else {
            let enabled = !draft.isEmpty && !isSending
            Image(systemName: isSending ? "ellipsis" : "arrow.up")
                .font(.system(size: 16, weight: .bold))
                .foregroundStyle(enabled ? Color(.systemBackground) : Color(.tertiaryLabel))
                .frame(width: 34, height: 34)
                .background(enabled ? Color(.label) : Color(.tertiarySystemFill), in: Circle())
                .contentShape(Circle())
                .onTapGesture { if enabled { send(.queue) } }
                .onLongPressGesture(minimumDuration: 0.45) {
                    guard enabled else { return }
                    UIImpactFeedbackGenerator(style: .heavy).impactOccurred()
                    send(.now)
                }
                .accessibilityElement()
                .accessibilityAddTraits(.isButton)
                .accessibilityLabel("Send")
                .accessibilityHint(card.isBusy ? "Sends when this turn ends. Touch and hold to send now." : "")
                .accessibilityAction(named: "Send now") { if enabled { send(.now) } }
                .accessibilityIdentifier("send")
                .disabled(!enabled)
        }
    }

    private var attachButton: some View {
        Menu {
            Button("Photos", systemImage: "photo.on.rectangle") { showPhotoPicker = true }
            if UIImagePickerController.isSourceTypeAvailable(.camera) {
                Button("Camera", systemImage: "camera") { showCamera = true }
            }
        } label: {
            Image(systemName: "plus")
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(Color(.label))
                .frame(width: 34, height: 34)
                .background(Color(.tertiarySystemFill), in: Circle())
        }
        .tint(Color(.label))
        .disabled(!draft.canAddImages || isSending)
        .accessibilityLabel("Attach image")
        .accessibilityIdentifier("attach")
    }

    private var attachments: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(draft.images) { image in
                    ZStack(alignment: .topTrailing) {
                        Group {
                            if let ui = UIImage(data: image.data) {
                                Image(uiImage: ui).resizable().scaledToFill()
                            } else {
                                Color(.tertiarySystemFill)
                            }
                        }
                        .frame(width: 64, height: 64)
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                        Button {
                            withAnimation(.snappy) { draft.removeImage(image.id) }
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: 20))
                                .symbolRenderingMode(.palette)
                                .foregroundStyle(.white, .black.opacity(0.6))
                        }
                        .offset(x: 6, y: -6)
                        .accessibilityLabel("Remove image")
                        .accessibilityIdentifier("removeAttachment")
                    }
                    .accessibilityElement(children: .contain)
                    .accessibilityIdentifier("attachment")
                }
            }
            .padding(.top, 6)
            .padding(.trailing, 6)
        }
    }

    private func addPhotos(_ items: [PhotosPickerItem]) async {
        var failed = 0
        for item in items {
            guard let data = try? await item.loadTransferable(type: Data.self), draft.addImage(data) else {
                failed += 1
                continue
            }
        }
        if failed > 0 { sendError = failed == 1 ? "One image could not be attached." : "\(failed) images could not be attached." }
    }

    private func send(_ mode: RemotePromptRequest.Mode) {
        let text = draft.text.trimmingCharacters(in: .whitespacesAndNewlines)
        let images = draft.remoteImages
        guard !text.isEmpty || !images.isEmpty, let client = board.client, !isSending else { return }
        isSending = true
        sendError = nil
        Task {
            defer { isSending = false }
            do {
                try await client.sendPrompt(cardId: card.id, text: text, mode: mode, images: images)
                draft.clear()
                sentCount += 1
                transcript.appendPending(text, imageCount: images.count)
            } catch {
                sendError = error.localizedDescription
                UINotificationFeedbackGenerator().notificationOccurred(.error)
            }
        }
    }

    private func queueAction(_ prompt: RemoteQueuedPrompt, send: Bool) {
        guard let client = board.client, !queueActions.contains(prompt.id) else { return }
        queueActions.insert(prompt.id)
        sendError = nil
        Task {
            defer { queueActions.remove(prompt.id) }
            do {
                if send {
                    try await client.sendQueuedPromptNow(cardId: card.id, promptId: prompt.id)
                    UIImpactFeedbackGenerator(style: .rigid).impactOccurred()
                } else {
                    try await client.removeQueuedPrompt(cardId: card.id, promptId: prompt.id)
                }
            } catch RemoteClientError.notFound {
                // Already sent or removed on the Mac.
            } catch {
                sendError = error.localizedDescription
                UINotificationFeedbackGenerator().notificationOccurred(.error)
            }
            await transcript.refresh()
        }
    }
}

/// A prompt waiting on the Mac for the turn to end.
struct QueuedPromptView: View {
    let prompt: RemoteQueuedPrompt
    let isWorking: Bool
    let canAct: Bool
    let onSendNow: () -> Void
    let onRemove: () -> Void

    var body: some View {
        HStack {
            Spacer(minLength: 48)
            VStack(alignment: .trailing, spacing: 6) {
                Text(TranscriptModel.displayText(prompt.text, imageCount: prompt.imageCount))
                    .padding(.horizontal, 14)
                    .padding(.vertical, 9)
                    .background(
                        RoundedRectangle(cornerRadius: 18)
                            .strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 1.5, dash: [5, 4]))
                    )
                HStack(spacing: 10) {
                    Label("Queued", systemImage: "clock")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if canAct {
                        if isWorking {
                            ProgressView().controlSize(.small)
                        } else {
                            Button(action: onSendNow) {
                                Label("Send now", systemImage: "bolt.fill")
                                    .font(.caption.weight(.semibold))
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                            .tint(.orange)
                            .accessibilityIdentifier("queuedSendNow")
                            Button(role: .destructive, action: onRemove) {
                                Image(systemName: "trash")
                                    .font(.caption)
                            }
                            .buttonStyle(.borderless)
                            .accessibilityLabel("Remove queued message")
                            .accessibilityIdentifier("queuedRemove")
                        }
                    }
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("queuedPrompt")
    }
}

/// The camera, for a photo to attach.
struct CameraPicker: UIViewControllerRepresentable {
    let onImage: (Data) -> Void
    @Environment(\.dismiss) private var dismiss

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = .camera
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ controller: UIImagePickerController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let parent: CameraPicker
        init(_ parent: CameraPicker) { self.parent = parent }

        func imagePickerController(_ picker: UIImagePickerController,
                                   didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            if let image = info[.originalImage] as? UIImage, let data = image.jpegData(compressionQuality: 0.9) {
                parent.onImage(data)
            }
            parent.dismiss()
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            parent.dismiss()
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
                SelectableText(text: SelectableTextStyle.plain(message.text, color: .white))
                    .fixedSize(horizontal: false, vertical: true)
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
            SelectableText(text: SelectableTextStyle.plain(message.text, font: .preferredFont(forTextStyle: .caption1),
                                                           color: .secondaryLabel),
                           alignment: .center)
                .frame(maxWidth: .infinity)
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
                        SelectableText(text: SelectableTextStyle.plain(
                            code, font: .monospacedSystemFont(ofSize: UIFont.preferredFont(forTextStyle: .footnote).pointSize, weight: .regular)
                        ), wraps: false)
                        .padding(10)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 8))
                case .heading(let line):
                    SelectableText(text: SelectableTextStyle.markdown(line, font: .preferredFont(forTextStyle: .headline)))
                        .fixedSize(horizontal: false, vertical: true)
                case .paragraph(let para):
                    SelectableText(text: SelectableTextStyle.markdown(para))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
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
                // A list starts its own block after a paragraph.
                if let last = paragraph.last, !last.trimmingCharacters(in: .whitespaces).hasPrefix("• ") { flush() }
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
