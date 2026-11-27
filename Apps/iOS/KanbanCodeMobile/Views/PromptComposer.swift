import SwiftUI
import PhotosUI
import UniformTypeIdentifiers
import KanbanCodeRemoteKit

/// The composer of a card's chat, for Main and for each conversation: one
/// rounded container with the images and files, the text, then a row with + and the
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
    /// The text and images sent, and the id they went under.
    var onSent: (String, [Data], String) -> Void
    /// More buttons after + and the stash.
    @ViewBuilder var extra: () -> Extra

    @State private var isSending = false
    @State private var secretOffer: PendingSecretOffer?
    @State private var showPhotoPicker = false
    @State private var showCamera = false
    @State private var photoItems: [PhotosPickerItem] = []
    @State private var showFileImporter = false
    @State private var selection: TextSelection?
    /// Where picked images put their markers, taken when + is used.
    @State private var imageInsertion: Int?
    @State private var dictation = ComposerDictation()
    /// The text around the caret when dictation started; spoken words go between.
    @State private var dictationInsertion: DictationInsertion?
    /// The keyboard was up when dictation started; it goes down while dictating and comes back.
    @State private var keyboardBeforeDictation = false
    @Environment(\.scenePhase) private var scenePhase
    /// Between the microphone and send, so a tap meant for one does not land on the other.
    static var micGap: CGFloat { 12 }

    private var supportsImages: Bool { board.supports(RemoteAPI.Feature.images) }
    private var supportsFiles: Bool { board.supports(RemoteAPI.Feature.files) }

    var body: some View {
        VStack(spacing: 6) {
            if secretOffer != nil {
                VaultSecretOfferCard(offer: Binding(get: { secretOffer! }, set: { secretOffer = $0 }),
                                     onSave: saveOfferedSecrets, onSendAsIs: sendOfferAsIs,
                                     onReplace: answerReplace)
            }
            composer
        }
        // Videos go as files, so they show only when the master takes files,
        // and then the image limit does not cap the selection.
        .photosPicker(isPresented: $showPhotoPicker, selection: $photoItems,
                      maxSelectionCount: supportsFiles ? nil : max(1, RemoteImage.maxCount - draft.images.count),
                      matching: supportsFiles ? .any(of: [.images, .videos]) : .images,
                      preferredItemEncoding: .compatible)
        .onChange(of: photoItems) { _, items in
            guard !items.isEmpty else { return }
            photoItems = []
            Task { await addPhotos(items) }
        }
        .fullScreenCover(isPresented: $showCamera) {
            CameraPicker { data in insertImage(data) }
                .ignoresSafeArea()
        }
        .fileImporter(isPresented: $showFileImporter, allowedContentTypes: [.item],
                      allowsMultipleSelection: true) { result in
            switch result {
            case .success(let urls): Task { await addFiles(urls) }
            case .failure(let error): sendError = error.localizedDescription
            }
        }
        .task { await dictation.resolve() }
        .onChange(of: dictation.transcript) { writeDictation() }
        .onChange(of: draft.text) { _, text in
            // Typing while dictating keeps what is there and stops listening.
            if dictation.isActive, dictationInsertion?.isTyping(text) ?? false {
                dictation.cancel()
                dictationInsertion = nil
            }
        }
        .onChange(of: scenePhase) { _, phase in
            // Not on inactive: the microphone permission alert makes the scene inactive.
            if phase == .background, dictation.isActive { stopDictation() }
        }
        .onDisappear { dictation.cancel() }
        .alert(dictation.problem?.title ?? "", isPresented: Binding(get: { dictation.problem != nil },
                                                                    set: { if !$0 { dictation.problem = nil } }),
               presenting: dictation.problem) { _ in
            Button("OK", role: .cancel) {}
        } message: { problem in
            Text(problem.message)
        }
    }

    private var composer: some View {
        VStack(alignment: .leading, spacing: 4) {
            VStack(alignment: .leading, spacing: 6) {
                if !draft.images.isEmpty {
                    attachments
                }
                if !draft.files.isEmpty {
                    fileAttachments
                }
                TextField("Message", text: composerText, selection: $selection, axis: .vertical)
                    .lineLimit(1...maxLines)
                    .focused(focused)
                    .padding(.horizontal, 6)
                    .padding(.top, 4)
                    .accessibilityIdentifier("composer")
                HStack(spacing: 8) {
                    if dictation.isActive {
                        voiceBar
                            .transition(.opacity)
                    } else {
                        if supportsImages || supportsFiles {
                            attachButton
                        }
                        if !draft.stashes.isEmpty {
                            stashButton
                        }
                        extra()
                        Spacer()
                    }
                    HStack(spacing: dictation.isActive ? 6 : Self.micGap) {
                        if dictation.isOffered { dictationButton }
                        sendButton
                    }
                }
                .animation(.smooth(duration: 0.2), value: dictation.isActive)
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
    private var showsStop: Bool { onInterrupt != nil && card.isBusy && draft.isEmpty && !isSending && !dictation.isActive }

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
            // Send while dictating stops, waits for the last words and sends them.
            let enabled = (!draft.isEmpty || dictation.isActive) && !isSending && draft.filesReady
            Menu {
                Button("Send now", systemImage: "bolt.fill") { sendAfterDictation(.now) }
                Button("Stash", systemImage: "tray.and.arrow.down") {
                    if dictation.isActive { cancelDictation(restore: false) }
                    withAnimation(.snappy) { draft.stash() }
                }
            } label: {
                Image(systemName: isSending ? "ellipsis" : "arrow.up")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(enabled ? Color(.systemBackground) : Color(.tertiaryLabel))
                    .frame(width: 34, height: 34)
                    .background(enabled ? Color(.label) : Color(.tertiarySystemFill), in: Circle())
            } primaryAction: {
                sendAfterDictation(.queue)
            }
            .disabled(!enabled)
            .accessibilityLabel("Send")
            .accessibilityValue(draft.filesReady ? "" : "Waiting for files to upload")
            .accessibilityHint(card.isBusy ? "Sends when this turn ends. Touch and hold to send now or stash." : "Touch and hold to send now or stash.")
            .accessibilityIdentifier("send")
        }
    }

    /// The microphone left of send: a tap dictates, a touch and hold picks the language. While
    /// dictating a neutral stop button takes its place, with a spinner while a stop waits for
    /// the voice model.
    @ViewBuilder private var dictationButton: some View {
        if dictation.isActive {
            Button { stopDictation() } label: {
                Group {
                    if dictation.waiting != nil {
                        ProgressView().controlSize(.small)
                    } else {
                        RoundedRectangle(cornerRadius: 2.5, style: .continuous)
                            .fill(Color(.label))
                            .frame(width: 11, height: 11)
                    }
                }
                .frame(width: 34, height: 34)
                .background(Circle().fill(Color(.label).opacity(0.08)))
                .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .disabled(dictation.phase == .finishing)
            .accessibilityLabel("Stop dictating")
            .accessibilityIdentifier("dictate-stop")
        } else {
            DictationMenu(languages: dictation.languages, current: dictation.language) {
                startDictation()
            } pick: { language in
                dictation.choose(language)
                startDictation()
            }
            .equatable()
        }
    }

    /// The row's left side while dictating: cancel, the language, then the live level line, or
    /// the line saying what a stop waits for.
    private var voiceBar: some View {
        HStack(spacing: 6) {
            Button { cancelDictation() } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 16, weight: .regular))
                    .foregroundStyle(Color(.secondaryLabel))
                    .frame(width: 34, height: 34)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Cancel dictating")
            .accessibilityIdentifier("dictate-cancel")
            DictationLanguageButton(languages: dictation.languages, current: dictation.language) { language in
                switchDictationLanguage(language)
            }
            .equatable()
            .layoutPriority(1)
            if let waiting = dictation.waiting {
                Text(waiting)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .lineLimit(2)
                    .minimumScaleFactor(0.85)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.leading, 6)
                    .accessibilityIdentifier("dictation-waiting")
            } else {
                DictationLevelLine(meter: dictation.meter, color: Color(.secondaryLabel))
                    .frame(maxWidth: .infinity)
                    .padding(.leading, 6)
            }
        }
    }

    /// The caret or selection in characters, nil without a caret.
    private var selectedRange: Range<Int>? {
        guard let selection, case .selection(let range) = selection.indices else { return nil }
        let text = draft.text
        func offset(_ index: String.Index) -> Int {
            let clamped = min(index, text.endIndex)
            let utf16 = text.utf16.distance(from: text.utf16.startIndex, to: clamped)
            return text.distance(from: text.startIndex, to: String.Index(utf16Offset: utf16, in: text))
        }
        return offset(range.lowerBound)..<max(offset(range.lowerBound), offset(range.upperBound))
    }

    /// Spoken words go where the caret is, replacing a selection; without a caret, at the end.
    /// The keyboard goes down so the voice bar and the words stay in view.
    private func startDictation(restart: Bool = false) {
        if !restart { keyboardBeforeDictation = focused.wrappedValue }
        let range = selectedRange
        focused.wrappedValue = false
        dictationInsertion = DictationInsertion(text: draft.text, selection: range)
        Task { await dictation.start() }
    }

    /// Stops dictating, keeps the words and brings the keyboard back if it was up.
    private func stopDictation() {
        Task {
            guard await dictation.stop() else { return }
            dictationInsertion = nil
            if keyboardBeforeDictation { focused.wrappedValue = true }
        }
    }

    /// Stops at once; `restore` puts the draft back as it was before dictating.
    private func cancelDictation(restore: Bool = true) {
        dictation.cancel()
        if restore, let insertion = dictationInsertion {
            dictationInsertion = nil
            draft.text = insertion.original
            selection = TextSelection(insertionPoint: Self.index(insertion.prefix.count, in: draft.text))
        }
        dictationInsertion = nil
        if restore, keyboardBeforeDictation { focused.wrappedValue = true }
    }

    /// Goes on in another language, keeping the words heard so far.
    private func switchDictationLanguage(_ language: String) {
        dictation.choose(language)
        Task {
            guard await dictation.stop() else { return }
            startDictation(restart: true)
        }
    }

    /// Puts the words heard so far between the text before and after the caret; never sends.
    private func writeDictation() {
        guard var insertion = dictationInsertion else { return }
        let written = insertion.write(settled: dictation.settled, guessing: dictation.guessing)
        dictationInsertion = insertion
        guard written.text != draft.text else { return }
        draft.text = written.text
        selection = TextSelection(insertionPoint: Self.index(written.caret, in: draft.text))
    }

    /// Sends; while dictating it first stops and waits for the last words.
    private func sendAfterDictation(_ mode: RemotePromptRequest.Mode) {
        guard dictation.isActive else {
            send(mode)
            return
        }
        Task {
            guard await dictation.stop() else { return }
            dictationInsertion = nil
            send(mode)
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
            if supportsImages {
                Button("Photos", systemImage: "photo.on.rectangle") {
                    imageInsertion = caretOffset
                    showPhotoPicker = true
                }
                .disabled(!draft.canAddImages && !supportsFiles)
                if UIImagePickerController.isSourceTypeAvailable(.camera) {
                    Button("Camera", systemImage: "camera") {
                        imageInsertion = caretOffset
                        showCamera = true
                    }
                    .disabled(!draft.canAddImages)
                }
            }
            if supportsFiles {
                Button("Choose File", systemImage: "doc") {
                    imageInsertion = caretOffset
                    showFileImporter = true
                }
                .accessibilityIdentifier("chooseFile")
            }
        } label: {
            Image(systemName: "plus")
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(Color(.label))
                .frame(width: 34, height: 34)
                .background(Color(.tertiarySystemFill), in: Circle())
        }
        .tint(Color(.label))
        .disabled(isSending || (!supportsFiles && !draft.canAddImages))
        .accessibilityLabel(supportsFiles ? "Attach" : "Attach image")
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

    private var fileAttachments: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(draft.files) { file in
                    DraftFileChip(file: file) {
                        withAnimation(.snappy) { draft.removeFile(file.id) }
                    }
                }
            }
            .padding(.top, 6)
            .padding(.trailing, 6)
        }
    }

    /// Attaches files picked from Files: an image goes inline like a photo
    /// when images can still be added, any other file uploads.
    private func addFiles(_ urls: [URL]) async {
        var refusals: [String] = []
        for url in urls {
            if supportsImages, draft.canAddImages, PromptFiles.isImage(fileName: url.lastPathComponent),
               let data = Self.readImage(url), insertImage(data) {
                continue
            }
            guard supportsFiles, let client = board.client else {
                refusals.append("\(PromptFiles.displayName(of: url.path)) could not be attached.")
                continue
            }
            if let refusal = draft.attachFile(at: url, client: client, cardId: card.id) {
                refusals.append(refusal)
            }
        }
        if !refusals.isEmpty {
            sendError = refusals.joined(separator: "\n")
            UINotificationFeedbackGenerator().notificationOccurred(.error)
        }
    }

    /// The bytes of a picked image, or nil past the size an image can be
    /// read at, which then goes as a file.
    private static func readImage(_ url: URL) -> Data? {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        guard let size = try? PromptFileReader.size(of: url), size <= 50 << 20 else { return nil }
        return try? Data(contentsOf: url)
    }

    /// Images go inline; a video is exported to a file and uploads like
    /// one picked in Files.
    private func addPhotos(_ items: [PhotosPickerItem]) async {
        var failed = 0
        var refusals: [String] = []
        for item in items {
            if item.supportedContentTypes.contains(where: { $0.conforms(to: .movie) }) {
                guard supportsFiles, let client = board.client,
                      let movie = try? await item.loadTransferable(type: PickedMovie.self) else {
                    failed += 1
                    continue
                }
                if let refusal = draft.attachFile(at: movie.url, client: client, cardId: card.id, movesSource: true) {
                    refusals.append(refusal)
                }
                continue
            }
            guard let data = try? await item.loadTransferable(type: Data.self), insertImage(data) else {
                failed += 1
                continue
            }
        }
        if failed > 0 {
            refusals.append(failed == 1 ? "One item could not be attached." : "\(failed) items could not be attached.")
        }
        if !refusals.isEmpty { sendError = refusals.joined(separator: "\n") }
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
        if draft.images.isEmpty, draft.files.isEmpty, let intercept, intercept(text) {
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

    /// Sends the text with the draft's images and a line per uploaded file.
    /// The draft stays until the master took them, so a send that fails
    /// leaves everything to send again.
    private func deliver(_ typed: String, _ mode: RemotePromptRequest.Mode) {
        let images = draft.remoteImages
        let attached = draft.images.map(\.data)
        let text = draft.outgoingText(typed)
        guard !text.isEmpty || !images.isEmpty, draft.filesReady, let client = board.client, !isSending else { return }
        isSending = true
        sendError = nil
        let id = draft.sendId(for: text, images: attached)
        Task {
            defer { isSending = false }
            do {
                try await client.sendPrompt(cardId: card.id, text: text, mode: mode, images: images, human: true,
                                            conversation: conversation, id: id)
                draft.clear()
                onSent(text, attached, id)
            } catch {
                sendError = error.localizedDescription
                UINotificationFeedbackGenerator().notificationOccurred(.error)
            }
        }
    }
}

/// A file attached in the composer: its kind's icon, name and size, the
/// upload's progress or why it failed, and an x that drops it.
struct DraftFileChip: View {
    let file: ComposerDraft.DraftFile
    let onRemove: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: FileIcon.symbol(for: file.name))
                .font(.system(size: 18))
                .foregroundStyle(isFailed ? Color.red : Color.accentColor)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 1) {
                Text(file.name)
                    .font(.footnote.weight(.medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(detail)
                    .font(.caption2)
                    .foregroundStyle(isFailed ? Color.red : Color.secondary)
                    .lineLimit(2)
            }
            .frame(maxWidth: 180, alignment: .leading)
            if case .uploading(let progress) = file.state {
                ProgressRing(progress: progress)
                    .frame(width: 18, height: 18)
                    .accessibilityLabel("Uploading")
                    .accessibilityValue("\(Int(progress * 100)) percent")
            }
            Button(action: onRemove) {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 18))
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(isUploading ? "Cancel upload" : "Remove file")
            .accessibilityIdentifier("removeFile")
        }
        .padding(.leading, 10)
        .padding(.trailing, 6)
        .padding(.vertical, 7)
        .background(Color(.tertiarySystemFill), in: RoundedRectangle(cornerRadius: 12))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("fileAttachment")
    }

    private var isFailed: Bool {
        if case .failed = file.state { return true }
        return false
    }

    private var isUploading: Bool {
        if case .uploading = file.state { return true }
        return false
    }

    private var detail: String {
        let size = file.size.map(PromptFiles.formattedSize)
        switch file.state {
        case .uploading(let progress):
            return [size, "\(Int(progress * 100))%"].compactMap { $0 }.joined(separator: ", ")
        case .ready:
            return size ?? "Attached"
        case .failed(let message):
            return "Upload failed: \(message)"
        }
    }
}

/// A small ring that fills as an upload goes.
struct ProgressRing: View {
    let progress: Double

    var body: some View {
        ZStack {
            Circle().stroke(Color(.systemFill), lineWidth: 2.5)
            Circle()
                .trim(from: 0, to: max(0.02, progress))
                .stroke(Color.accentColor, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(.linear(duration: 0.2), value: progress)
        }
    }
}

/// The SF Symbol for a file, by its extension.
enum FileIcon {
    static func symbol(for name: String) -> String {
        switch (name as NSString).pathExtension.lowercased() {
        case "mov", "mp4", "m4v", "avi", "mkv", "webm": "film"
        case "mp3", "m4a", "wav", "aac", "flac", "ogg": "waveform"
        case "pdf": "doc.richtext"
        case "zip", "gz", "tgz", "tar", "bz2", "xz", "7z", "rar": "doc.zipper"
        case "png", "jpg", "jpeg", "gif", "webp", "heic", "heif", "tif", "tiff", "bmp": "photo"
        case "txt", "md", "log", "csv", "json", "yaml", "yml", "xml": "doc.plaintext"
        case "swift", "ts", "tsx", "js", "py", "go", "rs", "rb", "java", "kt", "c", "h", "cpp", "sh", "html", "css": "chevron.left.forwardslash.chevron.right"
        default: "doc"
        }
    }
}

/// A video picked in Photos, exported to a folder of its own in the app's
/// temporary directory; the upload moves it away from there.
private struct PickedMovie: Transferable {
    let url: URL

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(importedContentType: .movie) { received in
            let folder = FileManager.default.temporaryDirectory
                .appendingPathComponent("picked-videos", isDirectory: true)
                .appendingPathComponent(UUID().uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let copy = folder.appendingPathComponent(received.file.lastPathComponent)
            try FileManager.default.copyItem(at: received.file, to: copy)
            return PickedMovie(url: copy)
        }
    }
}

/// The microphone left of send: a tap dictates, a touch and hold opens every language. It redraws
/// only when its look changes, so typing does not rebuild an open menu.
struct DictationMenu: View, Equatable {
    let languages: ComposerDictation.Languages
    let current: String?
    let dictate: () -> Void
    let pick: (String) -> Void

    nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.languages == rhs.languages && lhs.current == rhs.current
    }

    var body: some View {
        Menu {
            DictationLanguageRows(languages: languages, current: current, pick: pick)
        } label: {
            Image(systemName: "mic")
                .font(.system(size: 19, weight: .regular))
                .foregroundStyle(Color(.secondaryLabel))
                .frame(width: 34, height: 34)
                .contentShape(Circle())
        } primaryAction: {
            dictate()
        }
        .menuOrder(.fixed)
        .tint(Color(.label))
        .accessibilityLabel("Dictate")
        .accessibilityValue(current.map(ComposerDictation.name) ?? "")
        .accessibilityHint("Touch and hold to pick the language.")
        .accessibilityIdentifier("dictate")
    }
}

/// The voice bar's language: its name with a chevron, opening every language.
struct DictationLanguageButton: View, Equatable {
    let languages: ComposerDictation.Languages
    let current: String?
    let pick: (String) -> Void

    nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.languages == rhs.languages && lhs.current == rhs.current
    }

    var body: some View {
        Menu {
            DictationLanguageRows(languages: languages, current: current, pick: pick)
        } label: {
            HStack(spacing: 3) {
                Text(current.map(ComposerDictation.name) ?? "")
                    .lineLimit(1)
                    .truncationMode(.tail)
                Image(systemName: "chevron.down").font(.system(size: 10, weight: .semibold))
            }
            .font(.footnote)
            .foregroundStyle(Color(.secondaryLabel))
            .frame(minHeight: 34)
            .contentShape(Rectangle())
        }
        .menuOrder(.fixed)
        .tint(Color(.label))
        .accessibilityLabel("Dictation language")
        .accessibilityValue(current.map(ComposerDictation.name) ?? "")
        .accessibilityIdentifier("dictation-language")
    }
}
