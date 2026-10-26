import SwiftUI
import PhotosUI
import KanbanCodeRemoteKit

/// The composer of a card's chat, for Main and for each conversation: one
/// rounded container with the images, the text, then a row with + and the
/// other buttons on the left and send on the right. Touch and hold send to
/// send now or stash. Text that carries secrets first offers to save them
/// in the vault. The draft is kept until the master takes the prompt.
struct PromptComposer<Extra: View>: View {
    let card: RemoteCard
    let board: BoardModel
    let draft: ComposerDraft
    /// The conversation it sends in; nil sends to Main.
    var conversation: String? = nil
    /// Why the last send or attach failed, shown by the screen above.
    @Binding var sendError: String?
    var focused: FocusState<Bool>.Binding
    /// The most lines the text shows before it scrolls.
    var maxLines = 8
    /// Lists the card's slash commands while a `/name` is typed.
    var slashCommands = false
    /// The slash commands include Kanban's own (the side chat).
    var kanbanCommands = false
    /// Stop while the agent works and nothing is typed; nil never shows it.
    var onInterrupt: (() -> Void)? = nil
    /// Takes the text before it is sent; true when it handled it (a `/btw`).
    /// Text with images always goes to the session.
    var intercept: ((String) -> Bool)? = nil
    /// The master took the prompt: its text and its images as attached.
    var onSent: (String, [Data]) -> Void
    /// More buttons after + and the stash.
    @ViewBuilder var extra: () -> Extra

    @State private var isSending = false
    @State private var secretOffer: PendingSecretOffer?
    @State private var showPhotoPicker = false
    @State private var showCamera = false
    @State private var photoItems: [PhotosPickerItem] = []
    @State private var selection: TextSelection?
    /// Where picked images put their markers, taken when + is used.
    @State private var imageInsertion: Int?

    private var supportsImages: Bool { board.supports(RemoteAPI.Feature.images) }

    var body: some View {
        VStack(spacing: 6) {
            if secretOffer != nil {
                VaultSecretOfferCard(offer: Binding(get: { secretOffer! }, set: { secretOffer = $0 }),
                                     onSave: saveOfferedSecrets, onSendAsIs: sendOfferAsIs,
                                     onReplace: answerReplace)
            }
            composer
        }
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

    private var composer: some View {
        VStack(alignment: .leading, spacing: 4) {
            VStack(alignment: .leading, spacing: 6) {
                if !draft.images.isEmpty {
                    attachments
                }
                TextField("Message", text: composerText, selection: $selection, axis: .vertical)
                    .lineLimit(1...maxLines)
                    .focused(focused)
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
                    extra()
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
            .onTapGesture { focused.wrappedValue = true }
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
            if typing, slashCommands { board.loadSlashCommands(cardId: card.id) }
        }
    }

    /// The commands matching the `/name` being typed; empty outside one.
    private var slashMatches: [RemoteSlashCommand] {
        guard slashCommands, secretOffer == nil, let query = SlashCommandMenu.query(in: draft.text) else { return [] }
        let known = board.slashCommands[card.id] ?? RemoteSlashCommand.kanban
        let usable = kanbanCommands ? known : known.filter { $0.source != RemoteSlashCommand.Source.kanban }
        return SlashCommandMenu.matches(query: query, in: usable)
    }

    private func pickSlashCommand(_ command: RemoteSlashCommand) {
        draft.text = SlashCommandMenu.completion(for: command)
        selection = TextSelection(insertionPoint: draft.text.endIndex)
        focused.wrappedValue = true
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
                selection = TextSelection(insertionPoint: Self.index(deletion.caret, in: draft.text))
            }
        }
    }

    private static func index(_ offset: Int, in text: String) -> String.Index {
        text.index(text.startIndex, offsetBy: min(max(offset, 0), text.count))
    }

    /// The caret's place in the composer, in characters, or nil when the
    /// composer has no caret.
    private var caretOffset: Int? {
        guard let selection, case .selection(let range) = selection.indices else { return nil }
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
    private var showsStop: Bool { onInterrupt != nil && card.isBusy && draft.isEmpty && !isSending }

    @ViewBuilder private var sendButton: some View {
        if showsStop, let onInterrupt {
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
        selection = TextSelection(insertionPoint: Self.index(caret, in: draft.text))
        return true
    }

    /// Sends the draft, or first offers to save the secrets it carries.
    private func send(_ mode: RemotePromptRequest.Mode) {
        let text = draft.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard secretOffer == nil, !isSending else { return }
        if draft.images.isEmpty, let intercept, intercept(text) {
            draft.clear()
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
                focused.wrappedValue = false
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
        guard var offer = secretOffer, !offer.isSaving, offer.replaceName == nil, let client = board.client else { return }
        offer.isSaving = true
        offer.error = nil
        secretOffer = offer
        Task {
            let result = await PhoneVault.save(offer, client: client) { waiting in
                secretOffer?.waiting = waiting
            }
            if result.error != nil || result.replace != nil {
                // What was saved stays referenced; the rest stays offered,
                // the first with its replace question when it has one.
                secretOffer = PendingSecretOffer(text: result.text, mode: offer.mode, proposals: result.remaining,
                                                 error: result.error, replaceName: result.replace)
                if result.error != nil { UINotificationFeedbackGenerator().notificationOccurred(.error) }
                return
            }
            secretOffer = nil
            deliver(result.text, offer.mode)
        }
    }

    /// Replace saves again with the stored name confirmed; the other answer
    /// puts the free name back for another edit.
    private func answerReplace(_ replace: Bool) {
        guard var offer = secretOffer, offer.replaceName != nil, !offer.isSaving else { return }
        offer.replaceName = nil
        offer.proposals = SecretDetector.answeringReplace(offer.proposals, replace: replace)
        secretOffer = offer
        if replace { saveOfferedSecrets() }
    }

    /// Sends the text with the draft's images. The draft stays until the
    /// master took them, so a send that fails leaves everything to send again.
    private func deliver(_ text: String, _ mode: RemotePromptRequest.Mode) {
        let images = draft.remoteImages
        let attached = draft.images.map(\.data)
        guard !text.isEmpty || !images.isEmpty, let client = board.client, !isSending else { return }
        isSending = true
        sendError = nil
        Task {
            defer { isSending = false }
            do {
                try await client.sendPrompt(cardId: card.id, text: text, mode: mode, images: images, human: true,
                                            conversation: conversation)
                draft.clear()
                onSent(text, attached)
            } catch {
                sendError = error.localizedDescription
                UINotificationFeedbackGenerator().notificationOccurred(.error)
            }
        }
    }
}
