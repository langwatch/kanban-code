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
    @State private var notice: String?
    @State private var secretOffer: PendingSecretOffer?
    @State private var sentCount = 0
    @State private var queueActions: Set<String> = []
    @State private var showPhotoPicker = false
    @State private var showCamera = false
    @State private var photoItems: [PhotosPickerItem] = []
    @FocusState private var composerFocused: Bool
    @State private var composerSelection: TextSelection?
    /// Where picked images put their markers, taken when + is used.
    @State private var imageInsertion: Int?
    @State private var scrollPosition = ScrollPosition(edge: .bottom)
    @State private var follow = FollowState()
    /// Top of the keyboard and bottom of the chat, in window coordinates.
    @State private var keyboardTop: CGFloat?
    @State private var paneBottom: CGFloat = 0
    /// The card's side chat (`/btw`, `/catchup`), made when first used.
    @State private var sideChat: SideChatController?
    @State private var sideChatCollapsed = false
    /// The message a catch-up link landed on, tinted for a moment.
    @State private var highlightedMessage: String?

    /// How much of the chat the keyboard still covers after SwiftUI made
    /// room for it: nothing, unless SwiftUI missed the suggestion bar.
    private var keyboardShortfall: CGFloat {
        guard let keyboardTop else { return 0 }
        return max(0, paneBottom - keyboardTop)
    }

    /// Whether the chat keeps to its end: from opening until the user
    /// scrolls away, and again once they scroll back to it. A class, so
    /// scrolling does not redraw the view.
    private final class FollowState {
        var followsEnd = true
        var userScrolling = false
        /// A scroll to the end waits for the next turn of the run loop.
        var scrollScheduled = false
        /// When the last scrolls to the end were made, newest last.
        var recentScrolls: [Date] = []

        /// Scrolls to the end allowed within one second. A chat that
        /// cannot reach its end (rows whose height keeps changing) then
        /// retries at this pace instead of in every layout pass.
        static let scrollsPerSecond = 30

        /// Whether another scroll to the end may be made now, counting it.
        func takeScroll(now: Date = .now) -> Bool {
            recentScrolls.removeAll { now.timeIntervalSince($0) > 1 }
            guard recentScrolls.count < Self.scrollsPerSecond else { return false }
            recentScrolls.append(now)
            return true
        }
    }

    /// Distance from the end of the conversation to the bottom of what is shown.
    private static func distanceToEnd(_ geo: ScrollGeometry) -> CGFloat {
        geo.contentSize.height + geo.contentInsets.bottom - (geo.contentOffset.y + geo.containerSize.height)
    }

    private static let bottomID = "chat-bottom"

    private var supportsImages: Bool { board.supports(RemoteAPI.Feature.images) }
    private var supportsQueue: Bool { board.supports(RemoteAPI.Feature.queue) }
    /// The side chat forks a Claude Code session.
    private var supportsSideChat: Bool {
        board.supports(RemoteAPI.Feature.sideChat) && card.assistant == "claude" && card.sessionId != nil
    }

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
                        .background {
                            if highlightedMessage == message.id {
                                RoundedRectangle(cornerRadius: 12)
                                    .fill(Color.accentColor.opacity(0.18))
                                    .padding(-6)
                                    .accessibilityElement()
                                    .accessibilityIdentifier("citedMessage")
                            }
                        }
                        .id(message.id)
                }
                ForEach(card.queuedPrompts) { prompt in
                    QueuedPromptView(
                        prompt: prompt,
                        isWorking: queueActions.contains(prompt.id),
                        canAct: supportsQueue && card.isLive,
                        onSendNow: { queueAction(prompt, .sendNow) },
                        onEdit: { queueAction(prompt, .edit) },
                        onDelete: { queueAction(prompt, .delete) }
                    )
                    .id("queued-\(prompt.id)")
                }
                if card.isBusy {
                    WorkingIndicator()
                }
                // The last row reaches the end of the content, so scrolling
                // to it ends at the true bottom.
                Color.clear
                    .frame(height: 12)
                    .id(Self.bottomID)
            }
            .padding(.horizontal)
            .padding(.top, 12)
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
        // One scrollTo can still land short: the long rows it brings on
        // screen are measured only then and push the end further down. So
        // while the chat follows its end, every change that leaves it off
        // the end scrolls again, until it is there. The scroll is made on
        // the next turn of the run loop, never inside the layout pass that
        // reported the change: a scroll made there changes the geometry
        // again within the same pass, and a chat whose end keeps moving
        // (an inset in the middle of an animation, a long row measured
        // late) would keep the main thread in that pass.
        .onScrollGeometryChange(for: CGFloat.self) { geo in
            Self.distanceToEnd(geo).rounded()
        } action: { _, distance in
            if distance > 1 { followEnd() }
        }
        .onScrollPhaseChange { _, phase, context in
            switch phase {
            case .tracking, .interacting, .decelerating:
                follow.userScrolling = true
            case .idle:
                if follow.userScrolling {
                    follow.userScrolling = false
                    follow.followsEnd = Self.distanceToEnd(context.geometry) < 60
                }
            case .animating:
                break
            @unknown default:
                break
            }
        }
        .scrollDismissesKeyboard(.interactively)
        .overlay { emptyState }
        // The room the folded panel takes at the top of the chat comes and
        // goes in one step. Only the panel itself animates, inside its
        // overlay: the chat's layout never follows an animated height.
        .safeAreaInset(edge: .top, spacing: 0) {
            if sideChat?.state.isOpen == true {
                Color.clear.frame(height: SideChatPanel.foldedHeight)
            }
        }
        .overlay(alignment: .top) {
            ZStack(alignment: .top) {
                if let sideChat, sideChat.state.isOpen {
                    // The reader's height is what shows above the composer and
                    // the keyboard: the panel never reaches under them.
                    GeometryReader { geo in
                        SideChatPanel(controller: sideChat, collapsed: $sideChatCollapsed,
                                      maxHeight: geo.size.height - keyboardShortfall - 12,
                                      onJump: jump(toOffset:),
                                      onSendToMain: handOff,
                                      machineName: board.machineName, machineOffline: !board.isOnline)
                    }
                    .transition(.move(edge: .top).combined(with: .opacity))
                }
            }
            .animation(.snappy, value: sideChat?.state.isOpen)
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            bottomBar
                .padding(.bottom, keyboardShortfall)
                .background(Color(.systemBackground))
        }
        .onGeometryChange(for: CGFloat.self) { $0.frame(in: .global).maxY.rounded() } action: { paneBottom = $0 }
        .background {
            KeyboardTopReader { top, duration in
                if duration > 0 {
                    withAnimation(.easeOut(duration: duration)) { keyboardTop = top }
                } else {
                    keyboardTop = top
                }
            }
            .ignoresSafeArea()
        }
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
            CameraPicker { data in insertImage(data) }
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
            if let notice {
                Text(notice)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityIdentifier("composerNotice")
                    .task(id: notice) {
                        try? await Task.sleep(for: .seconds(4))
                        self.notice = nil
                    }
            }
            if secretOffer != nil {
                VaultSecretOfferCard(offer: Binding(get: { secretOffer! }, set: { secretOffer = $0 }),
                                     onSave: saveOfferedSecrets, onSendAsIs: sendOfferAsIs)
            }
            if card.isLive, card.sessionStatus?.kind != .machine {
                composer
            } else {
                // The same status the Mac shows in the card: a start or a
                // move in flight, a failed start, a machine that is away.
                let status = card.sessionStatus
                HStack {
                    if let status, status.kind == .starting || status.kind == .moving {
                        ProgressView()
                    }
                    Text(status?.text ?? "Session not running")
                        .font(.subheadline)
                        .foregroundStyle(status?.kind == .failed ? AnyShapeStyle(Color.red) : AnyShapeStyle(.secondary))
                        .accessibilityIdentifier("sessionStatus")
                    Spacer()
                    if supportsSideChat {
                        catchUpButton
                    }
                    if status == nil || status?.canResume == true {
                        Button("Resume", systemImage: "play.fill", action: onResume)
                            .buttonStyle(.borderedProminent)
                            .accessibilityIdentifier("resumeBar")
                    }
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
            VStack(alignment: .leading, spacing: 6) {
                if !draft.images.isEmpty {
                    attachments
                }
                TextField("Message", text: composerText, selection: $composerSelection, axis: .vertical)
                    .lineLimit(1...8)
                    .focused($composerFocused)
                    .padding(.horizontal, 6)
                    .padding(.top, 4)
                    .accessibilityIdentifier("composer")
                HStack(spacing: 8) {
                    if supportsImages {
                        attachButton
                    }
                    if !draft.stashes.isEmpty {
                        stashButton
                    }
                    if supportsSideChat {
                        catchUpButton
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
        // The list lies over the chat, above the composer: it takes no
        // room, so the chat keeps its place while it opens and closes.
        .overlay(alignment: .top) {
            if !slashMatches.isEmpty {
                SlashCommandList(matches: slashMatches, onSelect: pickSlashCommand)
                    .frame(height: 0, alignment: .bottom)
                    .offset(y: -8)
            }
        }
        // The list is read again each time a command name starts.
        .onChange(of: SlashCommandMenu.query(in: draft.text) != nil) { _, typing in
            if typing { board.loadSlashCommands(cardId: card.id) }
        }
    }

    /// The commands matching the `/name` being typed; empty outside one.
    private var slashMatches: [RemoteSlashCommand] {
        guard secretOffer == nil, let query = SlashCommandMenu.query(in: draft.text) else { return [] }
        let known = board.slashCommands[card.id] ?? RemoteSlashCommand.kanban
        let usable = supportsSideChat ? known : known.filter { $0.source != RemoteSlashCommand.Source.kanban }
        return SlashCommandMenu.matches(query: query, in: usable)
    }

    private func pickSlashCommand(_ command: RemoteSlashCommand) {
        draft.text = SlashCommandMenu.completion(for: command)
        composerSelection = TextSelection(insertionPoint: draft.text.endIndex)
        composerFocused = true
    }

    /// The typed text; a deletion into an [Image #N] marker takes the
    /// whole marker, and the caret goes where it was.
    private var composerText: Binding<String> {
        Binding {
            draft.text
        } set: { newText in
            guard let deletion = draft.markerDeletion(to: newText) else {
                draft.text = newText
                return
            }
            draft.holdText(newText)
            DispatchQueue.main.async {
                draft.text = deletion.text
                composerSelection = TextSelection(insertionPoint: Self.index(deletion.caret, in: draft.text))
            }
        }
    }

    private static func index(_ offset: Int, in text: String) -> String.Index {
        text.index(text.startIndex, offsetBy: min(max(offset, 0), text.count))
    }

    /// The caret's place in the composer, in characters, or nil when the
    /// composer has no caret.
    private var caretOffset: Int? {
        guard let composerSelection, case .selection(let range) = composerSelection.indices else { return nil }
        let text = draft.text
        // The selection can outlive the text it was made in (a send or a
        // dictation rewrite shortens the draft), so its index is clamped
        // before any distance is measured.
        let upper = min(range.upperBound, text.endIndex)
        let utf16 = text.utf16.distance(from: text.utf16.startIndex, to: upper)
        let index = String.Index(utf16Offset: utf16, in: text)
        return text.distance(from: text.startIndex, to: index)
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
            Menu {
                Button("Send now", systemImage: "bolt.fill") { send(.now) }
                Button("Stash", systemImage: "tray.and.arrow.down") {
                    withAnimation(.snappy) { draft.stash() }
                }
            } label: {
                Image(systemName: isSending ? "ellipsis" : "arrow.up")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(enabled ? Color(.systemBackground) : Color(.tertiaryLabel))
                    .frame(width: 34, height: 34)
                    .background(enabled ? Color(.label) : Color(.tertiarySystemFill), in: Circle())
            } primaryAction: {
                send(.queue)
            }
            .disabled(!enabled)
            .accessibilityLabel("Send")
            .accessibilityHint(card.isBusy ? "Sends when this turn ends. Touch and hold to send now or stash." : "Touch and hold to send now or stash.")
            .accessibilityIdentifier("send")
        }
    }

    /// Brings back the latest stash; touch and hold to pick or delete one.
    private var stashButton: some View {
        Menu {
            ForEach(draft.stashes.reversed()) { stash in
                Menu(stash.preview) {
                    Button("Restore", systemImage: "arrow.uturn.backward") {
                        withAnimation(.snappy) { draft.restore(stash.id) }
                    }
                    Button("Delete", systemImage: "trash", role: .destructive) {
                        withAnimation(.snappy) { draft.deleteStash(stash.id) }
                    }
                }
            }
        } label: {
            Image(systemName: "tray.and.arrow.up")
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(Color(.label))
                .frame(width: 34, height: 34)
                .background(Color(.tertiarySystemFill), in: Circle())
                .overlay(alignment: .topTrailing) {
                    if draft.stashes.count > 1 {
                        Text("\(draft.stashes.count)")
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(Color(.systemBackground))
                            .padding(.horizontal, 4)
                            .frame(minWidth: 16, minHeight: 16)
                            .background(Color(.label), in: Capsule())
                            .offset(x: 4, y: -4)
                    }
                }
        } primaryAction: {
            withAnimation(.snappy) { draft.restore() }
        }
        .tint(Color(.label))
        .accessibilityLabel(draft.stashes.count == 1 ? "Restore stashed message" : "Restore stashed message, \(draft.stashes.count) stashed")
        .accessibilityHint("Touch and hold to pick or delete a stash.")
        .accessibilityIdentifier("unstash")
    }

    /// What happened since the human's last message, in the side chat.
    private var catchUpButton: some View {
        Button {
            runSideChat(.catchup)
        } label: {
            Image(systemName: "clock.arrow.circlepath")
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(Color(.label))
                .frame(width: 34, height: 34)
                .background(Color(.tertiarySystemFill), in: Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Catch me up")
        .accessibilityHint("Sums up what happened since your last message.")
        .accessibilityIdentifier("catchUp")
    }

    private func runSideChat(_ command: SideChatCommand) {
        guard let client = board.client else { return }
        let controller = sideChat ?? SideChatController(transport: .remote(client, cardId: card.id))
        sideChat = controller
        composerFocused = false
        sideChatCollapsed = false
        controller.run(command)
    }

    /// Shows the message at a transcript offset: older pages load until it
    /// is there, then the chat scrolls to it and tints it. The side chat
    /// folds so the message shows under it.
    private func jump(toOffset offset: Int) {
        withAnimation(.snappy) { sideChatCollapsed = true }
        follow.followsEnd = false
        Task {
            guard let message = await transcript.message(atOffset: offset) else { return }
            // One turn later, so rows that just loaded are laid out.
            try? await Task.sleep(for: .milliseconds(120))
            withAnimation(.snappy) {
                scrollPosition.scrollTo(id: message.id, anchor: .top)
                highlightedMessage = message.id
            }
            try? await Task.sleep(for: .seconds(3))
            if highlightedMessage == message.id {
                withAnimation(.easeOut(duration: 0.6)) { highlightedMessage = nil }
            }
        }
    }

    private var attachButton: some View {
        Menu {
            Button("Photos", systemImage: "photo.on.rectangle") {
                imageInsertion = caretOffset
                showPhotoPicker = true
            }
            if UIImagePickerController.isSourceTypeAvailable(.camera) {
                Button("Camera", systemImage: "camera") {
                    imageInsertion = caretOffset
                    showCamera = true
                }
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
                ForEach(Array(draft.images.enumerated()), id: \.element.id) { number, image in
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
                        // The number of its [Image #N] marker in the text.
                        .overlay(alignment: .bottomLeading) {
                            Text("#\(number + 1)")
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 2)
                                .background(.black.opacity(0.6), in: Capsule())
                                .padding(4)
                        }
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
            guard let data = try? await item.loadTransferable(type: Data.self), insertImage(data) else {
                failed += 1
                continue
            }
        }
        if failed > 0 { sendError = failed == 1 ? "One image could not be attached." : "\(failed) images could not be attached." }
    }

    /// Attaches an image with its marker where the caret was when + was
    /// used; the next image goes after it.
    @discardableResult
    private func insertImage(_ data: Data) -> Bool {
        guard let caret = draft.addImage(data, at: imageInsertion) else { return false }
        imageInsertion = caret
        composerSelection = TextSelection(insertionPoint: Self.index(caret, in: draft.text))
        return true
    }

    /// Sends the draft, or first offers to save the secrets it carries.
    private func send(_ mode: RemotePromptRequest.Mode) {
        let text = draft.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard secretOffer == nil, !isSending else { return }
        // /btw and /catchup open the side chat; nothing goes to the session.
        if supportsSideChat, draft.images.isEmpty, let command = SideChatCommand.parse(text) {
            draft.clear()
            runSideChat(command)
            return
        }
        guard !text.isEmpty, !SecretDetector.find(in: text).isEmpty, let client = board.client else {
            deliver(text, mode)
            return
        }
        isSending = true
        Task {
            let names = (try? await client.vaultSecretNames()) ?? []
            let proposals = SecretDetector.proposals(in: text, existingNames: names)
            isSending = false
            if proposals.isEmpty {
                deliver(text, mode)
            } else {
                composerFocused = false
                withAnimation(.snappy) { secretOffer = PendingSecretOffer(text: text, mode: mode, proposals: proposals) }
            }
        }
    }

    private func sendOfferAsIs() {
        guard let offer = secretOffer else { return }
        secretOffer = nil
        deliver(offer.text, offer.mode)
    }

    private func saveOfferedSecrets() {
        guard var offer = secretOffer, !offer.isSaving, let client = board.client else { return }
        offer.isSaving = true
        offer.error = nil
        secretOffer = offer
        Task {
            let result = await PhoneVault.save(offer, client: client)
            if let error = result.error {
                // What was saved stays referenced; the rest stays offered.
                secretOffer = PendingSecretOffer(text: result.text, mode: offer.mode, proposals: result.remaining, error: error)
                UINotificationFeedbackGenerator().notificationOccurred(.error)
                return
            }
            secretOffer = nil
            deliver(result.text, offer.mode)
        }
    }

    /// Sends what the human wrote: the draft with its images, or with
    /// `fromDraft` false a text of its own that leaves the draft alone.
    private func deliver(_ text: String, _ mode: RemotePromptRequest.Mode, fromDraft: Bool = true) {
        let images = fromDraft ? draft.remoteImages : []
        guard !text.isEmpty || !images.isEmpty, let client = board.client, !isSending else { return }
        isSending = true
        sendError = nil
        Task {
            defer { isSending = false }
            do {
                try await client.sendPrompt(cardId: card.id, text: text, mode: mode, images: images, human: true)
                if fromDraft { draft.clear() }
                follow.followsEnd = true
                sentCount += 1
                transcript.appendPending(text, imageCount: images.count)
            } catch {
                sendError = error.localizedDescription
                UINotificationFeedbackGenerator().notificationOccurred(.error)
            }
        }
    }

    /// Scrolls to the end on the next turn of the run loop, when the chat
    /// follows its end. Changes reported in between share that one scroll.
    private func followEnd() {
        guard follow.followsEnd, !follow.userScrolling, !follow.scrollScheduled else { return }
        follow.scrollScheduled = true
        Task { @MainActor in
            follow.scrollScheduled = false
            guard follow.followsEnd, !follow.userScrolling, follow.takeScroll() else { return }
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) {
                scrollPosition.scrollTo(id: Self.bottomID, anchor: .bottom)
            }
        }
    }

    /// Sends a side chat follow-up to the session. The message shows at
    /// once as a pending bubble and the composer stays free while the
    /// machine takes it. A send that fails takes the bubble away and puts
    /// the text in the composer, with what was typed there stashed.
    private func handOff(_ text: String) {
        guard !text.isEmpty, let client = board.client else { return }
        sendError = nil
        follow.followsEnd = true
        let pending = transcript.appendPending(text)
        Task {
            do {
                try await client.sendPrompt(cardId: card.id, text: text, mode: .queue, human: true)
                sentCount += 1
            } catch {
                transcript.removePending(pending)
                if !draft.isEmpty { draft.stash() }
                draft.load(text: text, images: [])
                sendError = error.localizedDescription
                UINotificationFeedbackGenerator().notificationOccurred(.error)
            }
        }
    }

    private enum QueueAction { case sendNow, edit, delete }

    private func queueAction(_ prompt: RemoteQueuedPrompt, _ action: QueueAction) {
        guard let client = board.client, !queueActions.contains(prompt.id) else { return }
        queueActions.insert(prompt.id)
        sendError = nil
        Task {
            defer { queueActions.remove(prompt.id) }
            do {
                switch action {
                case .sendNow:
                    try await client.sendQueuedPromptNow(cardId: card.id, promptId: prompt.id)
                    UIImpactFeedbackGenerator(style: .rigid).impactOccurred()
                case .delete:
                    try await client.removeQueuedPrompt(cardId: card.id, promptId: prompt.id)
                case .edit:
                    try await client.removeQueuedPrompt(cardId: card.id, promptId: prompt.id)
                    // Whatever is typed now waits in a stash.
                    draft.stash()
                    // Its images stay on the Mac, so their markers go too.
                    draft.load(text: PromptImageLayout.removingMarkers(from: prompt.text, imageCount: prompt.imageCount),
                               images: [])
                    if prompt.imageCount > 0 {
                        notice = prompt.imageCount == 1
                            ? "Its image stays on the Mac; attach it again to send it."
                            : "Its \(prompt.imageCount) images stay on the Mac; attach them again to send them."
                    }
                    composerFocused = true
                }
            } catch RemoteClientError.notFound {
                if action == .edit { notice = "Already sent." }
            } catch {
                sendError = error.localizedDescription
                UINotificationFeedbackGenerator().notificationOccurred(.error)
            }
            await transcript.refresh()
        }
    }
}

/// A prompt waiting on the Mac for the turn to end. Touch and hold for
/// Send now, Edit and Delete.
struct QueuedPromptView: View {
    let prompt: RemoteQueuedPrompt
    let isWorking: Bool
    let canAct: Bool
    let onSendNow: () -> Void
    let onEdit: () -> Void
    let onDelete: () -> Void

    var body: some View {
        HStack {
            Spacer(minLength: 48)
            VStack(alignment: .trailing, spacing: 4) {
                Text(TranscriptModel.displayText(prompt.text, imageCount: prompt.imageCount))
                    .padding(.horizontal, 14)
                    .padding(.vertical, 9)
                    .background(
                        RoundedRectangle(cornerRadius: 18)
                            .strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 1.5, dash: [5, 4]))
                    )
                    .contentShape(.contextMenuPreview, RoundedRectangle(cornerRadius: 18))
                    .contextMenu {
                        if canAct {
                            Button("Send now", systemImage: "bolt.fill", action: onSendNow)
                            Button("Edit", systemImage: "pencil", action: onEdit)
                            Button("Delete", systemImage: "trash", role: .destructive, action: onDelete)
                        }
                    }
                    .accessibilityIdentifier("queuedBubble")
                HStack(spacing: 4) {
                    if isWorking {
                        ProgressView().controlSize(.mini)
                    } else {
                        Image(systemName: "clock")
                    }
                    Text("Queued")
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
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
    @State private var showsWhole = false

    /// Characters of a message shown before "Show the whole message": a
    /// pasted log or a dump runs to hundreds of KB, which the phone lays out
    /// slowly and the user rarely reads in full.
    static let shownLimit = 20_000

    /// The message as shown: cut at `shownLimit` until the user asks for all of it.
    private var text: String {
        guard !showsWhole, message.text.utf16.count > Self.shownLimit else { return message.text }
        return String(message.text.prefix(Self.shownLimit)) + "\n…"
    }

    private var isCut: Bool { !showsWhole && message.text.utf16.count > Self.shownLimit }

    var body: some View {
        VStack(alignment: message.role == .user ? .trailing : .leading, spacing: 6) {
            content
            if isCut {
                Button("Show the whole message (\(message.text.count.formatted()) characters)") { showsWhole = true }
                    .font(.caption.weight(.medium))
                    .frame(maxWidth: .infinity, alignment: message.role == .user ? .trailing : .leading)
                    .accessibilityIdentifier("showWholeMessage")
            }
        }
    }

    @ViewBuilder private var content: some View {
        switch message.role {
        case .user:
            HStack {
                Spacer(minLength: 48)
                SelectableText(text: SelectableTextStyle.plain(text, color: .white))
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 9)
                    .background(Color.accentColor.opacity(message.id.hasPrefix("pending-") ? 0.5 : 0.9),
                                in: RoundedRectangle(cornerRadius: 18))
                    .foregroundStyle(.white)
            }
        case .assistant:
            MarkdownText(text: text)
                .frame(maxWidth: .infinity, alignment: .leading)
        case .tool:
            Button {
                withAnimation(.snappy) { expanded.toggle() }
            } label: {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Image(systemName: "wrench.and.screwdriver")
                        .font(.caption2)
                    Text(text)
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
            if let detail = message.detail {
                systemNote(detail: detail)
            } else {
                SelectableText(text: SelectableTextStyle.plain(text, font: .preferredFont(forTextStyle: .caption1),
                                                               color: .secondaryLabel),
                               alignment: .center)
                    .frame(maxWidth: .infinity)
            }
        }
    }

    /// A note that opens to the long text behind it: a compaction and
    /// its summary.
    private func systemNote(detail: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                withAnimation(.snappy) { expanded.toggle() }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "arrow.down.right.and.arrow.up.left")
                    Text(message.text)
                    Image(systemName: expanded ? "chevron.up" : "chevron.down")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("systemNote")
            if expanded {
                let shown = !showsWhole && detail.utf16.count > Self.shownLimit
                    ? String(detail.prefix(Self.shownLimit)) + "\n…" : detail
                SelectableText(text: SelectableTextStyle.plain(shown, font: .preferredFont(forTextStyle: .caption1),
                                                               color: .secondaryLabel))
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color(.tertiarySystemFill), in: RoundedRectangle(cornerRadius: 8))
                if detail.utf16.count > Self.shownLimit, !showsWhole {
                    Button("Show the whole text (\(detail.count.formatted()) characters)") { showsWhole = true }
                        .font(.caption.weight(.medium))
                }
            }
        }
    }
}

/// Assistant markdown: fenced code as monospaced blocks, tables as grids,
/// headings and lists by line, inline styles through AttributedString.
struct MarkdownText: View {
    let text: String

    private enum Block: Hashable {
        case code(String)
        case heading(String)
        case paragraph(String)
        case table(MarkdownTable)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                switch block {
                case .code(let code):
                    let styled = SelectableTextStyle.plain(
                        code, font: .monospacedSystemFont(ofSize: UIFont.preferredFont(forTextStyle: .footnote).pointSize, weight: .regular)
                    )
                    Group {
                        if Self.wrapsCode(code) {
                            SelectableText(text: styled)
                                .fixedSize(horizontal: false, vertical: true)
                                .padding(10)
                        } else {
                            ScrollView(.horizontal, showsIndicators: false) {
                                SelectableText(text: styled, wraps: false)
                                    .padding(10)
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 8))
                case .heading(let line):
                    SelectableText(text: SelectableTextStyle.markdown(line, font: .preferredFont(forTextStyle: .headline)))
                        .fixedSize(horizontal: false, vertical: true)
                case .paragraph(let para):
                    SelectableText(text: SelectableTextStyle.markdown(para))
                        .fixedSize(horizontal: false, vertical: true)
                case .table(let table):
                    MarkdownTableView(table: table)
                }
            }
        }
    }

    /// Code with a line too long to scroll sideways (minified JSON, a
    /// base64 blob) wraps: unwrapped it would be a text view hundreds of
    /// thousands of points wide.
    static func wrapsCode(_ code: String) -> Bool {
        code.split(separator: "\n", omittingEmptySubsequences: false).contains { $0.utf16.count > 2_000 }
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
        let lines = text.components(separatedBy: "\n")
        var index = 0
        while index < lines.count {
            let raw = lines[index]
            index += 1
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
            if let (table, lineCount) = MarkdownTable.parse(lines, at: index - 1) {
                flush()
                out.append(.table(table))
                index += lineCount - 1
                continue
            }
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
