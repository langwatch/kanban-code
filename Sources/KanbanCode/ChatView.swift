import SwiftUI
import KanbanCodeCore
import KanbanCodeRemoteKit
import MarkdownUI

// MARK: - Chat View

let chatMaxWidth: CGFloat = 720
let userBubbleMaxWidth: CGFloat = 504
/// Room kept above the scroll content for the pill that floats over the top
/// of the chat, so a row a jump lands at the top sits below it with a gap.
/// The scroll detectors have to know it too: at rest at the top, the content
/// offset sits at minus this margin.
let chatTopPillMargin: CGFloat = 44

struct ChatView: View {
    let turns: [ConversationTurn]
    let isLoading: Bool
    let activityState: ActivityState?
    let assistant: CodingAssistant
    var hasMoreTurns: Bool = false
    var tmuxSessionName: String?
    var cardId: String = ""
    var onSendPrompt: (String, [String]) -> Void = { _, _ in }
    var onQueuePrompt: ((String, Bool, [String]) -> Void)? // (body, sendAutomatically, imagePaths)
    var onLoadMore: (() -> Void)?
    var onLoadAroundTurn: ((Int) -> Void)?
    /// Stretches of history kept on disk, drawn as one line with a count.
    var collapsedRanges: [CollapsedTurnRange] = []
    /// Opens a page of a collapsed range; returns the first revealed line number.
    var onExpandRange: ((CollapsedTurnRange) async -> Int?)?
    /// Loads the previous typed message from disk; returns its line number.
    var onJumpToPreviousUser: (() async -> Int?)?
    var sessionPath: String?
    var sessionId: String?
    var onFork: (() -> Void)?
    var onCheckpoint: ((ConversationTurn) -> Void)?
    var onEscape: (() -> Void)?
    var githubBaseURL: String?
    @Binding var draftText: String
    @Binding var draftImages: [Data]

    @State private var contextUsage: ContextUsage?
    @State private var isBusyFromPane = false
    @State private var dismissedBusy = false
    @State private var busyGraceUntil: Date = .distantPast
    @Binding var pendingMessage: String?

    /// Use pane output as ground truth, falling back to hook state only if no tmux session.
    /// Show busy during grace period after pending clears (before tmux catches up).
    private var isAssistantBusy: Bool {
        if dismissedBusy { return false }
        if Date.now < busyGraceUntil { return true }
        if tmuxSessionName != nil { return isBusyFromPane }
        return activityState == .activelyWorking
    }

    @State private var pendingMessageTime: Date = .distantPast
    @State private var userTurnCountAtSend: Int = 0
    /// A message of the chat a catch-up link asked to show.
    @State private var jumpRequest: ChatJumpRequest?
    @State private var sideChatCollapsed = false

    /// The card's side chat (`/btw`, `/catchup`): Claude Code sessions only.
    private var sideChat: SideChatController? {
        assistant == .claude && !cardId.isEmpty ? SideChatCenter.controller(for: cardId) : nil
    }

    /// What the composer offers after `/`, from the board state.
    private var slashCommands: [RemoteSlashCommand] {
        guard !cardId.isEmpty else { return [] }
        return AppComposition.shared.engine.slashCommandsShown(cardId: cardId, assistant: assistant)
    }

    /// Sends a prompt to the session, with the waiting bubble until it lands.
    private func sendToSession(_ text: String, _ images: [String]) {
        pendingMessage = text
        pendingMessageTime = .now
        userTurnCountAtSend = turns.filter { $0.role == "user" }.count
        onSendPrompt(text, images)
    }

    private func clearPendingIfMatched() {
        guard pendingMessage != nil else { return }

        // Clear immediately when user turn was echoed (message received by Claude).
        // No delay — the pending bubble and real message must not coexist.
        let currentUserCount = turns.filter { $0.role == "user" }.count
        if currentUserCount > userTurnCountAtSend {
            pendingMessage = nil
            busyGraceUntil = Date.now.addingTimeInterval(8)
            return
        }

        // Timeout: clear pending after 30s regardless
        if Date.now.timeIntervalSince(pendingMessageTime) > 30 {
            pendingMessage = nil
            busyGraceUntil = Date.now.addingTimeInterval(8)
        }
    }

    var body: some View {
        RenderDiagnostics.measure(
            "ChatView.body",
            metadata: "turns=\(turns.count) assistant=\(assistant.rawValue) card=\(cardId.prefix(12))"
        ) {
            VStack(spacing: 0) {
            if turns.isEmpty && isLoading {
                VStack {
                    Spacer()
                    ProgressView()
                        .controlSize(.regular)
                    Spacer()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            ZStack(alignment: .bottom) {
                ChatMessageList(
                    turns: turns,
                    assistant: assistant,
                    hasMoreTurns: hasMoreTurns,
                    tmuxSessionName: tmuxSessionName,
                    sessionId: sessionId,
                    isBusyFromPane: $isBusyFromPane,
                    contextUsage: $contextUsage,
                    pendingMessage: pendingMessage,
                    onLoadMore: onLoadMore,
                    onLoadAroundTurn: onLoadAroundTurn,
                    collapsedRanges: collapsedRanges,
                    onExpandRange: onExpandRange,
                    onJumpToPreviousUser: onJumpToPreviousUser,
                    sessionPath: sessionPath,
                    onFork: onFork,
                    onCheckpoint: onCheckpoint,
                    githubBaseURL: githubBaseURL,
                    jumpRequest: jumpRequest,
                    topInset: sideChat?.state.isOpen == true ? SideChatPanel.foldedHeight : 0,
                    onSendAnswer: { answer in
                        let cardId = cardId
                        Task { @MainActor in
                            if let answerCard = AppServices.answerCard, await answerCard(cardId, answer) { return }
                            onSendPrompt(answer, [])
                        }
                    }
                )

                // Working indicator — left-aligned pill, same bg as page
                if isAssistantBusy {
                    HStack {
                        Spacer(minLength: 0)
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small)
                            Text("\(assistant.displayName) is working...")
                                .font(.app(.callout))
                                .foregroundStyle(.secondary)
                            Button {
                                dismissedBusy = true
                                if let session = tmuxSessionName {
                                    Task {
                                        try? await AppServices.tmux.sendInterrupt(sessionName: session)
                                    }
                                }
                            } label: {
                                Image(systemName: "stop.fill")
                                    .font(.system(size: 9))
                                    .foregroundStyle(.secondary)
                                    .frame(width: 20, height: 20)
                                    .background(Color.primary.opacity(0.06), in: Circle())
                            }
                            .buttonStyle(.plain)
                            .help("Stop (Ctrl+C)")
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(Color(.windowBackgroundColor), in: Capsule())
                        .frame(maxWidth: chatMaxWidth + 40, alignment: .leading)
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 16)
                    .padding(.bottom, 2)
                }
            }
            // Only the panel animates, inside its overlay: the chat's top
            // inset changes in one step, so its layout never follows an
            // animated height.
            .overlay(alignment: .top) {
                ZStack(alignment: .top) {
                    if let sideChat, sideChat.state.isOpen {
                        SideChatPanel(
                            controller: sideChat,
                            collapsed: $sideChatCollapsed,
                            onJump: { offset in
                                // The panel folds so the message shows under it.
                                withAnimation(.easeInOut(duration: 0.15)) { sideChatCollapsed = true }
                                jumpRequest = ChatJumpRequest(offset: offset)
                            },
                            onSendToMain: { prompt in sendToSession(prompt, []) }
                        )
                        .transition(.move(edge: .top).combined(with: .opacity))
                    }
                }
                .animation(.easeInOut(duration: 0.18), value: sideChat?.state.isOpen)
            }

            if tmuxSessionName != nil {
            ChatInputBar(
                assistant: assistant,
                isReady: !isAssistantBusy,
                cardId: cardId,
                contextUsage: contextUsage,
                userMessageHistory: turns.filter { $0.role == "user" }.reversed().compactMap {
                    let text = $0.contentBlocks.compactMap { b in if case .text = b.kind { return b.text } else { return nil } }.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
                    // A compaction summary is not a message to recall.
                    return text.isEmpty || HarnessNote.classify(text) == .compactionSummary ? nil : text
                },
                onSend: { text, images in
                    // /btw and /catchup open the side chat; nothing goes to the session.
                    if let sideChat, let command = SideChatCommand.parse(text) {
                        sideChatCollapsed = false
                        sideChat.run(command)
                        return
                    }
                    sendToSession(text, images)
                },
                onCatchUp: sideChat.map { sideChat in
                    {
                        sideChatCollapsed = false
                        sideChat.run(.catchup)
                    }
                },
                onQueuePrompt: onQueuePrompt,
                onEscape: onEscape,
                slashCommands: slashCommands,
                onSlashMenuOpen: {
                    guard !cardId.isEmpty else { return }
                    AppComposition.shared.engine.refreshSlashCommands(cardId: cardId)
                },
                text: $draftText,
                pastedImages: $draftImages
            )
            }
            }
        }
        .onAppear {
            clearPendingIfMatched()
        }
        .onChange(of: turns.count) {
            clearPendingIfMatched()
        }
        .onChange(of: turns.last?.lineNumber) {
            clearPendingIfMatched()
        }
        .onChange(of: isBusyFromPane) {
            // If Claude starts working again after dismiss (e.g. background agents),
            // allow the indicator to come back
            if isBusyFromPane && dismissedBusy {
                dismissedBusy = false
            }
        }
        .environment(\.openURL, OpenURLAction { url in
            // File paths: URL(string:) mangles paths with +, spaces, etc.
            // Detect file:// or bare absolute paths and open via fileURLWithPath.
            if url.scheme == "file" {
                let path = url.path
                if FileManager.default.fileExists(atPath: path) {
                    NSWorkspace.shared.open(URL(fileURLWithPath: path))
                    return .handled
                }
            }
            // Bare absolute paths that ended up as URL fragments or opaque strings
            let str = url.absoluteString
            if str.hasPrefix("/") || str.hasPrefix("file:///") {
                let path = str.hasPrefix("file:///")
                    ? String(str.dropFirst("file://".count))
                    : str
                let decoded = path.removingPercentEncoding ?? path
                if FileManager.default.fileExists(atPath: decoded) {
                    NSWorkspace.shared.open(URL(fileURLWithPath: decoded))
                    return .handled
                }
            }
            // Regular URLs — let the system handle
            return .systemAction
        })
    }

}

// MARK: - Chat Message List (isolated from input bar state)

private struct ChatMessageList: View {
    let turns: [ConversationTurn]
    let assistant: CodingAssistant
    var hasMoreTurns: Bool = false
    var tmuxSessionName: String?
    var sessionId: String?
    @Binding var isBusyFromPane: Bool
    @Binding var contextUsage: ContextUsage?
    @State private var pollKick: Int = 0
    @State private var lastBusyDetected: Date = .distantPast
    var pendingMessage: String?
    var onLoadMore: (() -> Void)?
    var onLoadAroundTurn: ((Int) -> Void)?
    var collapsedRanges: [CollapsedTurnRange] = []
    var onExpandRange: ((CollapsedTurnRange) async -> Int?)?
    var onJumpToPreviousUser: (() async -> Int?)?
    var sessionPath: String?
    var onFork: (() -> Void)?
    var onCheckpoint: ((ConversationTurn) -> Void)?
    var githubBaseURL: String?
    /// A message to scroll to and highlight, by transcript offset.
    var jumpRequest: ChatJumpRequest?
    /// Room left at the top of the list for what sits over it.
    var topInset: CGFloat = 0
    var onSendAnswer: ((String) -> Void)?

    /// The row a catch-up link landed on, tinted for a moment.
    @State private var highlightedLineNumber: Int?
    /// A jump whose message is being read off disk.
    @State private var pendingJumpOffset: Int?

    @State private var isAtBottom = true
    @State private var isNearTop = false
    @State private var firstVisibleLineNumber: Int?
    @State private var loadMoreTask: Task<Void, Never>?
    @State private var hasNewMessages = false
    @State private var lastSeenLineNumber: Int?
    /// What is moving the scroll right now. Only the reader's own gesture
    /// may load history: rows measuring, segments landing, and programmatic
    /// jumps all move the geometry too, and none of that is a request.
    @State private var scrollPhase: ScrollPhase = .idle
    @State private var expandedTextBlocks: Set<String> = []
    /// Runs of tool calls the reader has opened again, by run.
    @State private var expandedToolRuns: Set<String> = []
    @State private var visibleRows = ChatVisibleRows()
    /// A jump backwards reading the previous message off disk. The pill
    /// shows a spinner while this is true, so a click on a long file is
    /// seen to be working rather than stuck.
    @State private var isJumpLoading = false
    /// Collapsed ranges being read off disk, by range id.
    @State private var expandingRangeIds: Set<Int> = []
    /// Whether to auto-scroll on new content. Only set to false when we show
    /// the "New messages" badge (user deliberately scrolled away). Reset to true
    /// when user sends a message, clicks "New messages", or scrolls back to bottom.
    @State private var shouldAutoScroll = true
    @State private var scrollPosition = ScrollPosition(edge: .bottom)

    /// Carries a drag from one message's text view into the next.
    @State private var selectionCoordinator = ChatSelectionCoordinator()

    // Search state
    @State private var showSearch = false
    @State private var searchText = ""
    @State private var activeQuery = ""
    @State private var searchMatchOffsets: [Int] = []
    @State private var currentMatchPosition: Int = 0
    @State private var searchDebounceTask: Task<Void, Never>?
    @State private var searchScanTask: Task<Void, Never>?
    @State private var isSearchScanning = false
    @State private var pendingMatchScroll = false
    @FocusState private var isSearchFieldFocused: Bool

    private static let mountedTurnLimit = 500

    private var renderedTurns: [ConversationTurn] {
        // Capped, so SwiftUI is never asked to lay out thousands of rows whose
        // heights it can only learn by measuring them.
        guard turns.count > Self.mountedTurnLimit else { return turns }
        // A search has to keep the turn it stopped on mounted, so during one the
        // window follows the match instead of the end of the list.
        if let lineNumber = currentMatchLineNumber ?? highlightedLineNumber,
            let position = turns.firstIndex(where: { $0.lineNumber == lineNumber })
        {
            let start = min(
                max(0, position - Self.mountedTurnLimit / 2),
                turns.count - Self.mountedTurnLimit
            )
            return Array(turns[start..<(start + Self.mountedTurnLimit)])
        }
        if isNearTop && hasMoreTurns {
            return Array(turns.prefix(Self.mountedTurnLimit))
        }
        return Array(turns.suffix(Self.mountedTurnLimit))
    }

    private var currentMatchOffset: Int? {
        guard showSearch, !searchMatchOffsets.isEmpty,
              currentMatchPosition < searchMatchOffsets.count else { return nil }
        return searchMatchOffsets[currentMatchPosition]
    }

    /// The loaded turn a match falls inside, identified the way every row here
    /// is: by the byte offset it starts at.
    ///
    /// Not an equality test, because consecutive assistant entries are merged
    /// into one turn that keeps the first one's offset. A match on the second
    /// half of a merged turn matches no row exactly, and used to leave the
    /// search reporting a count it could neither scroll to nor paint.
    private func loadedTurn(containing offset: Int) -> ConversationTurn? {
        var enclosing: ConversationTurn?
        for turn in turns {
            if turn.lineNumber > offset { break }
            enclosing = turn
        }
        return enclosing
    }

    private var currentMatchLineNumber: Int? {
        guard let offset = currentMatchOffset else { return nil }
        return loadedTurn(containing: offset)?.lineNumber
    }

    var body: some View {
        RenderDiagnostics.measure(
            "ChatMessageList.body",
            metadata: "turns=\(turns.count) mounted=\(renderedTurns.count) search=\(!activeQuery.isEmpty)"
        ) {
            ZStack(alignment: .top) {
                scrollableMessageList
                // Search bar overlay
                if showSearch {
                    chatSearchBar
                }
            }
            .background {
                Button("") {
                    showSearch = true
                    isSearchFieldFocused = true
                }
                .keyboardShortcut("f", modifiers: .command)
                .hidden()
            }
        }
    }

    private var scrollableMessageList: some View {
        scrollViewWithTracking
            .safeAreaInset(edge: .top, spacing: 0) {
                if topInset > 0 { Color.clear.frame(height: topInset) }
            }
            .task(id: tmuxSessionName) {
                await pollBusyState()
            }
            .overlay(alignment: .bottom) { newMessagesButton }
            .overlay(alignment: .top) { previousUserMessageButton }
            .animation(.easeInOut(duration: 0.2), value: hasNewMessages)
            .animation(.easeInOut(duration: 0.2), value: isAtBottom)
            .onReceive(NotificationCenter.default.publisher(for: .chatCardExpanded)) { _ in
                if isAtBottom { scrollPosition.scrollTo(edge: .bottom) }
            }
    }

    private var scrollViewWithTracking: some View {
        ScrollView {
            messageListContent
        }
        .contentMargins(.top, chatTopPillMargin, for: .scrollContent)
        .scrollPosition($scrollPosition)
        .modifier(ScrollBottomTracker(isAtBottom: $isAtBottom, hasNewMessages: $hasNewMessages, shouldAutoScroll: $shouldAutoScroll))
        .modifier(ScrollNearTopDetector(isNearTop: $isNearTop))
        .onScrollPhaseChange { _, newPhase in scrollPhase = newPhase }
        .onScrollGeometryChange(for: CGFloat.self, of: { $0.contentOffset.y }) { oldY, newY in
            // The reader's own upward scroll near the top asks for older
            // history. Each segment is paid for by real movement: a load
            // never chains off the previous one, so sitting parked at the
            // top loads nothing until the reader scrolls again.
            let isReaderScroll =
                scrollPhase == .tracking || scrollPhase == .interacting
                || scrollPhase == .decelerating
            if isReaderScroll, newY < oldY, newY < 50 { loadMoreNow() }
        }
        .onChange(of: turns.count) {
            // Load completed: clear the loading marker so the spinner
            // hides immediately and a new load can be triggered.
            if loadMoreTask != nil {
                loadMoreTask?.cancel()
                loadMoreTask = nil
            }
            // A chunk loaded for a search match can land between turns
            // without touching either end of the list, so the pending
            // scroll is finished from here as well.
            if pendingMatchScroll {
                pendingMatchScroll = false
                scrollToCurrentMatch(delay: true)
            }
            finishPendingJump()
        }
        .onChange(of: jumpRequest) { _, request in
            if let request { jump(toOffset: request.offset) }
        }
        .onChange(of: TurnsEdges(first: turns.first?.lineNumber, last: turns.last?.lineNumber)) {
            old, new in
            handleTurnsEdgeChange(old: old, new: new)
        }
        .onChange(of: pendingMessage) {
            if pendingMessage != nil {
                shouldAutoScroll = true
                hasNewMessages = false
                scrollPosition.scrollTo(edge: .bottom)
                pollKick += 1
            }
        }
        .onAppear {
            lastSeenLineNumber = turns.last?.lineNumber
            isAtBottom = true
            shouldAutoScroll = true
        }
    }

    @ViewBuilder
    private var previousUserMessageButton: some View {
        if !isAtBottom {
            Button {
                jumpToPreviousUserMessage()
            } label: {
                HStack(spacing: 4) {
                    if isJumpLoading {
                        ProgressView()
                            .controlSize(.mini)
                    } else {
                        Image(systemName: "arrow.up")
                            .font(.system(size: 11, weight: .medium))
                    }
                    Text("Previous user message")
                        .font(.system(size: 12, weight: .medium))
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
            }
            .buttonStyle(.plain)
            .disabled(isJumpLoading)
            // The chat is a page of selectable text, so without this the
            // pointer stays the caret it is over the words behind the pill.
            .pointerStyle(.link)
            .glassEffect(.regular, in: .capsule)
            .shadow(color: .black.opacity(0.15), radius: 4, y: 2)
            // Below the search bar, which owns the same corner of the view.
            .padding(.top, showSearch ? 44 : 8)
            .transition(.move(edge: .top).combined(with: .opacity))
        }
    }

    /// Walk back to the message before the one at the top of the view.
    ///
    /// What you asked for is the landmark in a conversation, so a jump goes to
    /// the message before whatever is on screen, and puts it at the top with
    /// the reply underneath it. Pressing again walks back another one. A
    /// message not loaded yet is read off disk on its own, everything between
    /// it and the window stays behind a collapsed range, and the pill spins
    /// until the scroll lands.
    private func jumpToPreviousUserMessage() {
        let mounted = Set(renderedTurns.map(\.lineNumber))
            .union(collapsedRanges.map(\.id))
        let ceiling = visibleRows.top(among: mounted) ?? turns.last?.lineNumber ?? Int.max
        if let target = ChatTranscript.previousUserTurn(in: turns, above: ceiling) {
            scrollToPreviousUser(target.lineNumber)
            return
        }
        guard hasMoreTurns, !isJumpLoading, let onJumpToPreviousUser else { return }
        isJumpLoading = true
        firstVisibleLineNumber = nil
        Task { @MainActor in
            defer { isJumpLoading = false }
            guard let lineNumber = await onJumpToPreviousUser() else { return }
            // One turn later, so the arriving row is laid out and the scroll
            // has a place to land.
            try? await Task.sleep(for: .milliseconds(80))
            scrollToPreviousUser(lineNumber)
        }
    }

    private func scrollToPreviousUser(_ lineNumber: Int) {
        visibleRows.pinTop(lineNumber)
        withAnimation(.easeInOut(duration: 0.2)) {
            scrollPosition.scrollTo(id: lineNumber, anchor: .top)
        }
    }

    @ViewBuilder
    private var newMessagesButton: some View {
        if hasNewMessages {
            Button {
                scrollPosition.scrollTo(edge: .bottom)
                hasNewMessages = false
                isAtBottom = true
                shouldAutoScroll = true
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "arrow.down")
                        .font(.system(size: 11, weight: .medium))
                    Text("New messages")
                        .font(.system(size: 12, weight: .medium))
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
            }
            .buttonStyle(.plain)
            // The chat is a page of selectable text, so without this the
            // pointer stays the caret it is over the words behind the pill.
            .pointerStyle(.link)
            .glassEffect(.regular, in: .capsule)
            .shadow(color: .black.opacity(0.15), radius: 4, y: 2)
            .padding(.bottom, 8)
            .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }

    /// One handler for both ends of the list. A card switch changes both
    /// ends in the same update, so the decision cannot be split across two
    /// observers: whichever ran first changed the state the other read, and
    /// the reset-to-bottom branch was skipped.
    private func handleTurnsEdgeChange(old: TurnsEdges, new: TurnsEdges) {
        let transition = ChatTranscript.edgeTransition(
            oldFirst: old.first, oldLast: old.last,
            newFirst: new.first, newLast: new.last,
            lastSeen: lastSeenLineNumber, turns: turns
        )

        guard !transition.switched else {
            // A different transcript: start over, following the bottom.
            pendingJumpOffset = nil
            highlightedLineNumber = nil
            lastSeenLineNumber = new.last
            isAtBottom = true
            hasNewMessages = false
            shouldAutoScroll = true
            loadMoreTask?.cancel()
            loadMoreTask = nil
            firstVisibleLineNumber = nil
            pendingMatchScroll = false
            visibleRows = ChatVisibleRows()
            scrollPosition = ScrollPosition(edge: .bottom)
            return
        }

        // A chunk loaded for a catch-up link, the same way.
        if pendingJumpOffset != nil {
            finishPendingJump()
            lastSeenLineNumber = new.last
            return
        }

        // A chunk loaded for a search match can land at either end of the
        // list without being new conversation content.
        if pendingMatchScroll {
            pendingMatchScroll = false
            scrollToCurrentMatch(delay: true)
            lastSeenLineNumber = new.last
            return
        }

        if transition.prepended, let anchor = firstVisibleLineNumber {
            // Older turns arrived above: keep the row the reader was on in
            // place, even when a live session appended in the same update.
            scrollPosition.scrollTo(id: anchor, anchor: .top)
        } else if transition.appended, activeQuery.isEmpty {
            let isInitial = lastSeenLineNumber == nil
            let isNewAtBottom = new.last != lastSeenLineNumber
            if isInitial || (isNewAtBottom && shouldAutoScroll) {
                scrollPosition.scrollTo(edge: .bottom)
            } else if isNewAtBottom {
                hasNewMessages = true
                shouldAutoScroll = false
            }
        }

        lastSeenLineNumber = new.last
    }

    private func handleMatchNavigation() {
        guard let offset = currentMatchOffset else { return }
        // A match inside a collapsed range has a neighbour turn that would
        // claim to enclose it, so the range check comes first: those bytes
        // are on disk, not on screen, and must be loaded to be scrolled to.
        let hidden = collapsedRanges.contains {
            offset >= $0.startOffset && offset < $0.endOffset
        }
        // Nothing encloses a match that sits before everything loaded, which is
        // most of them: the chat opens on the tail and a search runs the file.
        if !hidden, loadedTurn(containing: offset) != nil {
            scrollToCurrentMatch(delay: false)
        } else {
            pendingMatchScroll = true
            onLoadAroundTurn?(offset)
        }
    }

    /// Show the message at a transcript offset: scroll it to the top and
    /// tint it. A message not loaded yet is read off disk first.
    private func jump(toOffset offset: Int) {
        let hidden = collapsedRanges.contains { offset >= $0.startOffset && offset < $0.endOffset }
        if !hidden, let turn = loadedTurn(containing: offset) {
            scrollToJumpTarget(turn.lineNumber)
        } else {
            pendingJumpOffset = offset
            firstVisibleLineNumber = nil
            onLoadAroundTurn?(offset)
        }
    }

    private func finishPendingJump() {
        guard let offset = pendingJumpOffset else { return }
        let hidden = collapsedRanges.contains { offset >= $0.startOffset && offset < $0.endOffset }
        guard !hidden, let turn = loadedTurn(containing: offset) else { return }
        pendingJumpOffset = nil
        scrollToJumpTarget(turn.lineNumber)
    }

    private func scrollToJumpTarget(_ lineNumber: Int) {
        shouldAutoScroll = false
        highlightedLineNumber = lineNumber
        Task { @MainActor in
            // One turn later, so a row that just arrived is laid out.
            try? await Task.sleep(for: .milliseconds(80))
            withAnimation(.easeInOut(duration: 0.2)) {
                scrollPosition.scrollTo(id: lineNumber, anchor: .top)
            }
            try? await Task.sleep(for: .seconds(3))
            if highlightedLineNumber == lineNumber {
                withAnimation(.easeOut(duration: 0.6)) { highlightedLineNumber = nil }
            }
        }
    }

    private func pollBusyState() async {
        guard let session = tmuxSessionName else {
            isBusyFromPane = false
            return
        }
        let tmux = AppServices.tmux
        while !Task.isCancelled {
            let newBusy: Bool
            do {
                if let rushId = RushSessionName.rushId(fromName: session) {
                    newBusy = try await tmux.rush(forSession: session).info(id: rushId)?.isBusy ?? false
                } else {
                    let output = try await tmux.capturePane(sessionName: session)
                    newBusy = PaneOutputParser.isWorking(output, assistant: assistant)
                }
            } catch {
                newBusy = false
            }
            if newBusy { lastBusyDetected = .now }
            if newBusy != isBusyFromPane && (newBusy || pendingMessage == nil) {
                isBusyFromPane = newBusy
            }
            if let sid = sessionId {
                let newUsage = ContextUsageReader.read(sessionId: sid)
                if newUsage != contextUsage { contextUsage = newUsage }
            }
            let recentlyBusy = Date.now.timeIntervalSince(lastBusyDetected) < 10
            let needsFastPoll = isBusyFromPane || pendingMessage != nil || recentlyBusy
            let interval: Int = needsFastPoll ? 250 : 3000
            let kickBefore = pollKick
            let steps = max(1, interval / 250)
            for _ in 0..<steps {
                try? await Task.sleep(for: .milliseconds(250))
                if pollKick != kickBefore || Task.isCancelled { break }
            }
        }
    }

    private var messageListContent: some View {
            VStack(spacing: 0) {
                    // Spacer for search bar
                    if showSearch { Color.clear.frame(height: 36) }
                    if loadMoreTask != nil {
                        ProgressView()
                            .controlSize(.small)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 8)
                    }

                    let visibleTurns = renderedTurns
                    let groupInfo = Self.computeGroupInfo(turns: visibleTurns)
                    let toolResults = Self.computeToolResults(turns: visibleTurns)
                    let turnGroups = Self.groupConsecutiveToolTurns(turns: visibleTurns)
                    let newestGroupId = turnGroups.last?.first?.lineNumber
                    let rows = ChatTranscript.weaveRows(groups: turnGroups, ranges: collapsedRanges)
                    // Find the turn containing the last tool call in the conversation.
                    // This turn's last tool call will be auto-expanded.
                    let lastToolCallLN: Int? = {
                        for turn in turns.reversed() {
                            guard turn.role == "assistant" else { continue }
                            if turn.contentBlocks.contains(where: { if case .toolUse = $0.kind { return true }; return false }) {
                                return turn.lineNumber
                            }
                        }
                        return nil
                    }()

                    ForEach(rows) { row in
                        switch row {
                        case .collapsed(let range):
                            collapsedRangeRow(range)
                        case .group(let group):
                            groupRow(
                                group,
                                isNewestGroup: group.first?.lineNumber == newestGroupId,
                                groupInfo: groupInfo,
                                toolResults: toolResults,
                                lastToolCallLN: lastToolCallLN,
                                allVisibleTurns: visibleTurns
                            )
                        }
                    }
                    // Optimistic pending message (sending...)
                    if let pending = pendingMessage {
                        HStack {
                            Spacer(minLength: 0)
                            Text(pending)
                                .font(.app(.body))
                                .padding(.horizontal, 14)
                                .padding(.vertical, 10)
                                .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 18))
                                .opacity(0.5)
                                .overlay(alignment: .leading) {
                                    ProgressView()
                                        .controlSize(.small)
                                        .opacity(0.5)
                                        .offset(x: -24)
                                }
                                .frame(maxWidth: userBubbleMaxWidth, alignment: .trailing)
                                .frame(maxWidth: chatMaxWidth, alignment: .trailing)
                            Spacer(minLength: 0)
                        }
                        .padding(.vertical, 4)
                        .id("pending")
                    }

                    // Bottom spacer for scroll anchor — tall enough to keep
                    // the last message visible above the "working..." bar + input.
                    Color.clear.frame(height: 48)
                        .id("bottom-spacer")
                }
                .padding(.horizontal, 16)
                .textSelection(.enabled)
                .environment(\.chatSelectionCoordinator, selectionCoordinator)
    }

    /// One line standing in for a stretch of history still on disk. A click
    /// reads a page of it in place and keeps the first revealed row where
    /// the line was.
    @ViewBuilder
    private func collapsedRangeRow(_ range: CollapsedTurnRange) -> some View {
        CollapsedHistoryDivider(
            count: range.messageCount,
            isLoading: expandingRangeIds.contains(range.id)
        ) {
            expandCollapsedRange(range)
        }
        .frame(maxWidth: chatMaxWidth)
        .padding(.vertical, 6)
        .id(range.id)
        .onScrollVisibilityChange(threshold: 0.01) { visible in
            visibleRows.set(range.startOffset, visible: visible)
        }
    }

    private func expandCollapsedRange(_ range: CollapsedTurnRange) {
        guard !expandingRangeIds.contains(range.id), let onExpandRange else { return }
        expandingRangeIds.insert(range.id)
        firstVisibleLineNumber = nil
        Task { @MainActor in
            let firstRevealed = await onExpandRange(range)
            expandingRangeIds.remove(range.id)
            guard let firstRevealed else { return }
            try? await Task.sleep(for: .milliseconds(80))
            withAnimation(.easeInOut(duration: 0.2)) {
                scrollPosition.scrollTo(id: firstRevealed, anchor: .top)
            }
        }
    }

    @ViewBuilder
    private func groupRow(
        _ group: [ConversationTurn],
        isNewestGroup: Bool,
        groupInfo: [Int: Bool],
        toolResults: [Int: [String: ContentBlock]],
        lastToolCallLN: Int?,
        allVisibleTurns: [ConversationTurn]
    ) -> some View {
        if group.count > 1 {
            toolRunRow(
                group, isNewestGroup: isNewestGroup, toolResults: toolResults,
                lastToolCallLN: lastToolCallLN)
        } else if ChatMessageView.turnHasContent(group[0]) {
            singleTurnRow(
                group[0], isNewestGroup: isNewestGroup, groupInfo: groupInfo,
                toolResults: toolResults, lastToolCallLN: lastToolCallLN,
                allVisibleTurns: allVisibleTurns)
        }
    }

    /// Multiple consecutive tool-only turns — single shared bubble.
    @ViewBuilder
    private func toolRunRow(
        _ group: [ConversationTurn],
        isNewestGroup: Bool,
        toolResults: [Int: [String: ContentBlock]],
        lastToolCallLN: Int?
    ) -> some View {
        let toolTurns = group.filter { $0.role == "assistant" }
        let runKey = "run:\(group.first?.lineNumber ?? 0)"
        let callCount = ChatTranscript.toolCallCount(in: toolTurns)
        let runIsOpen = expandedToolRuns.contains(runKey)
        // The newest run is the one being worked on, so it stays as it is.
        // Everything behind it is done, and a search match inside one opens
        // it whatever its age, or the search would land on nothing.
        let collapses = CollapsedToolRunCard.collapses(
            callCount: callCount,
            isNewestRun: isNewestGroup,
            holdsSearchMatch: toolTurns.contains {
                $0.lineNumber == currentMatchLineNumber
            }
        )
        VStack(alignment: .leading, spacing: 2) {
            if collapses {
                CollapsedToolRunCard(count: callCount, isExpanded: runIsOpen) {
                    if runIsOpen {
                        expandedToolRuns.remove(runKey)
                    } else {
                        expandedToolRuns.insert(runKey)
                    }
                }
            }
            if !collapses || runIsOpen {
                ForEach(toolTurns, id: \.lineNumber) { toolTurn in
                    ChatMessageView(
                        turn: toolTurn,
                        assistant: assistant,
                        toolResultMap: toolResults[toolTurn.lineNumber] ?? [:],
                        isLastInGroup: false,
                        onCopy: { text in
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(text, forType: .string)
                        },
                        onFork: onFork,
                        onCheckpoint: onCheckpoint,
                        onSendAnswer: onSendAnswer,
                        suppressBackground: true,
                        highlightText: activeQuery.isEmpty ? nil : activeQuery,
                        isCurrentMatch: currentMatchLineNumber == toolTurn.lineNumber,
                        sessionPath: sessionPath,
                        tmuxSessionName: tmuxSessionName,
                        hasLastToolCall: toolTurn.lineNumber == lastToolCallLN,
                        githubBaseURL: githubBaseURL,
                        expandedTextBlocks: $expandedTextBlocks,
                        expandedToolRuns: $expandedToolRuns
                    )
                    .equatable()
                    // Every turn is addressable, not just the
                    // first: search scrolls to a line number,
                    // and a match on the third tool call in a
                    // group would otherwise have no target.
                    .id(toolTurn.lineNumber)
                    .onScrollVisibilityChange(threshold: 0.01) { visible in
                        visibleRows.set(toolTurn.lineNumber, visible: visible)
                    }
                }
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.primary.opacity(0.04))
                .padding(.leading, -8)
        )
        .frame(maxWidth: chatMaxWidth, alignment: .leading)
        .padding(.vertical, 4)
        // The run reports for itself as well as its rows,
        // because a collapsed one has no rows to report.
        .onScrollVisibilityChange(threshold: 0.01) { visible in
            if let first = group.first?.lineNumber {
                visibleRows.set(first, visible: visible)
            }
        }
    }

    @ViewBuilder
    private func singleTurnRow(
        _ turn: ConversationTurn,
        isNewestGroup: Bool,
        groupInfo: [Int: Bool],
        toolResults: [Int: [String: ContentBlock]],
        lastToolCallLN: Int?,
        allVisibleTurns: [ConversationTurn]
    ) -> some View {
        // Collect all text from consecutive same-role turns for copy
        let groupText: String = {
            guard groupInfo[turn.lineNumber] == true else { return "" }
            var texts: [String] = []
            // Walk backwards from this turn to find all consecutive same-role turns
            if let turnIdx = allVisibleTurns.firstIndex(where: { $0.lineNumber == turn.lineNumber }) {
                var i = turnIdx
                while i >= 0 && allVisibleTurns[i].role == turn.role {
                    let t = allVisibleTurns[i].contentBlocks
                        .filter { if case .text = $0.kind { return true }; return false }
                        .map(\.text).joined(separator: "\n")
                    if !t.isEmpty { texts.insert(t, at: 0) }
                    i -= 1
                }
            }
            return texts.joined(separator: "\n\n")
        }()
        ChatMessageView(
            turn: turn,
            assistant: assistant,
            toolResultMap: toolResults[turn.lineNumber] ?? [:],
            isLastInGroup: groupInfo[turn.lineNumber] ?? true,
            onCopy: { _ in
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(groupText, forType: .string)
            },
            onFork: onFork,
            onCheckpoint: onCheckpoint,
            onSendAnswer: onSendAnswer,
            highlightText: activeQuery.isEmpty ? nil : activeQuery,
            isCurrentMatch: currentMatchLineNumber == turn.lineNumber,
            sessionPath: sessionPath,
            tmuxSessionName: tmuxSessionName,
            hasLastToolCall: turn.lineNumber == lastToolCallLN,
            githubBaseURL: githubBaseURL,
            toolRunIsFinished: !isNewestGroup,
            expandedTextBlocks: $expandedTextBlocks,
            expandedToolRuns: $expandedToolRuns
        )
        .equatable()
        .id(turn.lineNumber)
        .padding(.vertical, 4)
        .background {
            if highlightedLineNumber == turn.lineNumber {
                RoundedRectangle(cornerRadius: 10)
                    .fill(Color.accentColor.opacity(0.16))
                    .padding(.horizontal, -8)
                    .transition(.opacity)
            }
        }
        .onScrollVisibilityChange(threshold: 0.01) { visible in
            visibleRows.set(turn.lineNumber, visible: visible)
        }
    }

    // MARK: - Search Bar

    private var chatSearchBar: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.app(.caption))
                .foregroundStyle(.secondary)

            TextField("Search...", text: $searchText)
                .textFieldStyle(.plain)
                .font(.app(.callout))
                .focused($isSearchFieldFocused)
                .onKeyPress(.escape) { dismissSearch(); return .handled }
                .onSubmit { navigateSearch(forward: false) }
                .onChange(of: searchText) { scheduleSearch() }

            if !activeQuery.isEmpty {
                if isSearchScanning {
                    ProgressView().controlSize(.mini)
                    Text("\(searchMatchOffsets.count) found…")
                        .font(.app(.caption2))
                        .foregroundStyle(.secondary)
                } else if searchMatchOffsets.isEmpty {
                    Text("0 results")
                        .font(.app(.caption2))
                        .foregroundStyle(.secondary)
                } else {
                    Text("\(searchMatchOffsets.count - currentMatchPosition)/\(searchMatchOffsets.count)")
                        .font(.app(.caption2))
                        .foregroundStyle(.secondary)
                        .monospacedDigit()

                    Button { navigateSearch(forward: false) } label: {
                        Image(systemName: "chevron.up").font(.app(.caption2))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)

                    Button { navigateSearch(forward: true) } label: {
                        Image(systemName: "chevron.down").font(.app(.caption2))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                }
            }

            Button { dismissSearch() } label: {
                Image(systemName: "xmark").font(.app(.caption2))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(.bar, in: RoundedRectangle(cornerRadius: 6))
        .padding(.leading, 16)
        .padding(.trailing, 52)
        .padding(.top, 6)
        .zIndex(1)
    }

    // MARK: - Search Logic

    private func scheduleSearch() {
        searchDebounceTask?.cancel()
        if searchText.isEmpty {
            activeQuery = ""
            searchMatchOffsets = []
            currentMatchPosition = 0
            searchScanTask?.cancel()
            isSearchScanning = false
            return
        }
        guard searchText.count >= 2 else { return }
        searchDebounceTask = Task {
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
            activeQuery = searchText
            startScan()
        }
    }

    private func startScan() {
        searchScanTask?.cancel()
        searchMatchOffsets = []
        currentMatchPosition = 0
        guard let path = sessionPath, !activeQuery.isEmpty else { return }
        isSearchScanning = true
        let query = activeQuery
        searchScanTask = Task {
            var matches: [Int] = []
            for await matchOffset in TranscriptReader.scanForMatchOffsets(from: path, query: query) {
                if Task.isCancelled { break }
                matches.append(matchOffset)
                if matches.count == 1 || matches.count % 50 == 0 {
                    searchMatchOffsets = matches
                }
            }
            guard !Task.isCancelled else { return }
            searchMatchOffsets = matches
            isSearchScanning = false
            if !matches.isEmpty {
                currentMatchPosition = matches.count - 1
                // Called rather than left to the change notification. A search
                // that finds exactly one match lands back on the position the
                // scan started from, so nothing changes, and the one match
                // would never be loaded, scrolled to or highlighted.
                handleMatchNavigation()
            }
        }
    }

    private func navigateSearch(forward: Bool) {
        guard !searchMatchOffsets.isEmpty else { return }
        if forward {
            currentMatchPosition = (currentMatchPosition + 1) % searchMatchOffsets.count
        } else {
            currentMatchPosition = (currentMatchPosition - 1 + searchMatchOffsets.count) % searchMatchOffsets.count
        }
        handleMatchNavigation()
    }

    private func dismissSearch() {
        searchDebounceTask?.cancel()
        searchScanTask?.cancel()
        isSearchScanning = false
        showSearch = false
        isSearchFieldFocused = false
        searchText = ""
        activeQuery = ""
    }

    private func scrollToCurrentMatch(delay: Bool) {
        guard let offset = currentMatchOffset,
              let turn = loadedTurn(containing: offset) else { return }
        if delay {
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(80))
                withAnimation(.easeInOut(duration: 0.2)) {
                    scrollPosition.scrollTo(id: turn.lineNumber, anchor: .center)
                }
            }
        } else {
            withAnimation(.easeInOut(duration: 0.2)) {
                scrollPosition.scrollTo(id: turn.lineNumber, anchor: .center)
            }
        }
    }

    /// Read one more batch of history.
    ///
    /// A search does not stop the history from being read backwards. It used
    /// to, which made a conversation that was being searched the one you
    /// could not scroll back through.
    private func loadMoreNow() {
        guard loadMoreTask == nil, hasMoreTurns else { return }
        firstVisibleLineNumber = turns.first?.lineNumber
        onLoadMore?()
        // Marker to prevent re-entry while loading. Cleared immediately
        // when turns.count changes (load completed). Safety timeout in
        // case the load silently fails and no turns change arrives.
        loadMoreTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(5))
            loadMoreTask = nil
        }
    }

    /// Precompute which turns are the last in their group (O(n) once, not O(n²) per render).
    private static func computeGroupInfo(turns: [ConversationTurn]) -> [Int: Bool] {
        var result: [Int: Bool] = [:]
        let visibleTurns = turns.filter(\.hasVisibleChatContent)
        for (i, turn) in visibleTurns.enumerated() {
            let isLast = (i == visibleTurns.count - 1) || visibleTurns[i + 1].role != turn.role
            result[turn.lineNumber] = isLast
        }
        return result
    }
    /// Precompute tool result pairing: maps turn lineNumber → (toolUseId → result ContentBlock).
    private static func computeToolResults(turns: [ConversationTurn]) -> [Int: [String: ContentBlock]] {
        var result: [Int: [String: ContentBlock]] = [:]
        for (i, turn) in turns.enumerated() where turn.role == "assistant" {
            // Look at the next turn for tool results
            if i + 1 < turns.count && turns[i + 1].role == "user" {
                let userTurn = turns[i + 1]
                var map: [String: ContentBlock] = [:]
                for block in userTurn.contentBlocks {
                    if case .toolResult(_, let toolUseId) = block.kind, let id = toolUseId {
                        map[id] = block
                    }
                }
                if !map.isEmpty {
                    result[turn.lineNumber] = map
                }
            }
        }
        return result
    }

    /// Group consecutive assistant turns that contain only tool calls (no visible text)
    /// into arrays so the list can render them in a single box.
    private static func groupConsecutiveToolTurns(turns: [ConversationTurn]) -> [[ConversationTurn]] {
        var groups: [[ConversationTurn]] = []
        var currentToolRun: [ConversationTurn] = []
        // Invisible user turns (only tool_result, no text) that sit between tool-only
        // assistant turns — buffer them so they don't break the tool group.
        var bufferedInvisibleUsers: [ConversationTurn] = []

        for turn in turns {
            if turn.role == "assistant" && isToolOnlyTurn(turn) {
                // Flush buffered invisible users into the tool run
                currentToolRun.append(contentsOf: bufferedInvisibleUsers)
                bufferedInvisibleUsers = []
                currentToolRun.append(turn)
            } else if turn.role == "user" && isToolResultOnlyTurn(turn) && !currentToolRun.isEmpty {
                // Buffer invisible user turn — might be between consecutive tool calls
                bufferedInvisibleUsers.append(turn)
            } else {
                if !currentToolRun.isEmpty {
                    groups.append(currentToolRun)
                    currentToolRun = []
                }
                // Flush any buffered invisible users as their own group
                for u in bufferedInvisibleUsers { groups.append([u]) }
                bufferedInvisibleUsers = []
                groups.append([turn])
            }
        }
        if !currentToolRun.isEmpty {
            groups.append(currentToolRun)
        }
        for u in bufferedInvisibleUsers { groups.append([u]) }
        return groups
    }

    private static func isToolResultOnlyTurn(_ turn: ConversationTurn) -> Bool {
        guard turn.role == "user" else { return false }
        return !turn.contentBlocks.contains {
            if case .text = $0.kind { return !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            return false
        }
    }

    private static func isToolOnlyTurn(_ turn: ConversationTurn) -> Bool {
        guard turn.role == "assistant" else { return false }
        let visible = turn.contentBlocks.filter { block in
            switch block.kind {
            case .text: return !block.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            case .toolResult: return false
            default: return true
            }
        }
        return !visible.isEmpty && visible.allSatisfy { if case .toolUse = $0.kind { return true }; return false }
    }
}

// MARK: - Scroll Bottom Tracker

/// Tracks whether the scroll view is at the bottom using scroll geometry.
/// Extracted to a ViewModifier to help the Swift type-checker.
private struct ScrollBottomTracker: ViewModifier {
    @Binding var isAtBottom: Bool
    @Binding var hasNewMessages: Bool
    @Binding var shouldAutoScroll: Bool

    /// True while the user is actively driving the scroll (touch / mouse /
    /// momentum). We only demote `shouldAutoScroll` during these phases so
    /// content-growth-induced "not at bottom" transitions (a tall assistant
    /// message arrives and pushes the viewport up) don't accidentally turn
    /// off auto-scroll.
    @State private var userDrivenScroll: Bool = false

    func body(content: Content) -> some View {
        content
            .onScrollPhaseChange { _, newPhase in
                switch newPhase {
                case .interacting, .tracking, .decelerating:
                    userDrivenScroll = true
                case .idle, .animating:
                    userDrivenScroll = false
                @unknown default:
                    userDrivenScroll = false
                }
            }
            .onScrollGeometryChange(for: Bool.self, of: { geo in
                geo.contentOffset.y + geo.containerSize.height >= geo.contentSize.height - 150
            }, action: { _, newAtBottom in
                guard newAtBottom != isAtBottom else { return }
                isAtBottom = newAtBottom
                if newAtBottom {
                    hasNewMessages = false
                    shouldAutoScroll = true
                } else if userDrivenScroll {
                    // The user scrolled away from the bottom — disable
                    // auto-scroll immediately. Without this, `shouldAutoScroll`
                    // only flipped to false inside `handleNewTurns` *after*
                    // the next message arrived, so that first new message
                    // would yank the user back down mid-read. The
                    // `userDrivenScroll` guard avoids demoting when a tall
                    // message simply pushed the viewport off the bottom on
                    // its own (content grew under us).
                    shouldAutoScroll = false
                }
            })
    }
}

/// A row of the chat list: a group of turns, or a collapsed stretch of
/// history still on disk.
enum ChatRow: Identifiable {
    case group([ConversationTurn])
    case collapsed(CollapsedTurnRange)

    var id: Int {
        switch self {
        case .group(let turns): return turns.first?.lineNumber ?? -1
        case .collapsed(let range): return range.startOffset
        }
    }

    var offset: Int { self.id }
}

/// Rules the chat list follows, kept out of the view so they can be read and
/// checked on their own.
@MainActor
/// The two ends of the loaded window, watched as one value so a change to
/// both arrives as one update.
struct TurnsEdges: Equatable {
    var first: Int?
    var last: Int?
}

enum ChatTranscript {
    /// How the ends of the loaded window moved in one update.
    struct EdgeTransition: Equatable {
        /// The turns belong to a different conversation.
        var switched: Bool
        /// New content at the bottom.
        var appended: Bool
        /// Older content above the top.
        var prepended: Bool
    }

    /// Decide what a change at the ends of the loaded turns means.
    ///
    /// Still the same conversation as long as the last turn we knew is in the
    /// list. Requiring it to still be the last turn is not enough: older
    /// messages loading above and a live session appending below can land in
    /// the same update.
    static func edgeTransition(
        oldFirst: Int?, oldLast: Int?,
        newFirst: Int?, newLast: Int?,
        lastSeen: Int?, turns: [ConversationTurn]
    ) -> EdgeTransition {
        let sameConversation =
            lastSeen == nil
            || newLast == lastSeen
            || turns.contains { $0.lineNumber == lastSeen }
        return EdgeTransition(
            switched: !sameConversation,
            appended: newLast != oldLast,
            prepended: newFirst != oldFirst
        )
    }

    /// The last thing you asked for before `ceiling`.
    static func previousUserTurn(in turns: [ConversationTurn], above ceiling: Int)
        -> ConversationTurn?
    {
        turns.last { $0.lineNumber < ceiling && self.isTypedMessage($0) }
    }

    /// Whether a turn is something the person typed.
    ///
    /// The user side of a transcript carries far more than that: the result of
    /// every tool call, an agent reporting that it finished, the note left
    /// where a run was interrupted, the wrapper around a slash command, and
    /// the reminders the harness injects. None of those is a landmark in a
    /// conversation, and a jump that lands on one lands on nothing.
    static func isTypedMessage(_ turn: ConversationTurn) -> Bool {
        TranscriptClassifier.isTypedMessage(turn)
    }

    static func isTypedText(_ text: String) -> Bool {
        TranscriptClassifier.isTypedText(text)
    }

    /// How many tool calls a run of tool-only turns holds. A turn can carry
    /// more than one, so the number of rows is not the number of turns.
    static func toolCallCount(in turns: [ConversationTurn]) -> Int {
        turns.reduce(0) { total, turn in
            total
                + turn.contentBlocks.count { block in
                    if case .toolUse = block.kind { return true }
                    return false
                }
        }
    }

    /// Lay turn groups and collapsed ranges into one list, in file order.
    static func weaveRows(
        groups: [[ConversationTurn]], ranges: [CollapsedTurnRange]
    ) -> [ChatRow] {
        var rows: [ChatRow] = []
        rows.reserveCapacity(groups.count + ranges.count)
        var remaining = ranges.sorted { $0.startOffset < $1.startOffset }[...]
        for group in groups {
            let groupOffset = group.first?.lineNumber ?? Int.max
            while let range = remaining.first, range.startOffset < groupOffset {
                rows.append(.collapsed(range))
                remaining = remaining.dropFirst()
            }
            rows.append(.group(group))
        }
        rows.append(contentsOf: remaining.map { .collapsed($0) })
        return rows
    }
}

/// Which message rows are on screen.
///
/// A reference type on purpose, and not observed: scrolling changes this many
/// times a second, and a value the view watched would redraw the whole list
/// with every row that crossed an edge. It is written while scrolling and read
/// once, when a jump asks where the reader is.
@MainActor
final class ChatVisibleRows {
    private var visible: Set<Int> = []
    private var pinned: Int?
    private var unpinTask: Task<Void, Never>?

    func set(_ lineNumber: Int, visible isVisible: Bool) {
        if isVisible {
            self.visible.insert(lineNumber)
        } else {
            self.visible.remove(lineNumber)
        }
    }

    /// The topmost row on screen, or the row a jump has just been aimed at.
    ///
    /// Rows that are no longer mounted are ignored rather than trusted: a row
    /// the list drops as the window moves has no way to report that it left.
    func top(among mounted: Set<Int>) -> Int? {
        if let pinned { return pinned }
        return self.visible.intersection(mounted).min()
    }

    /// Hold a row as the top until the scroll to it has settled, so two presses
    /// in a row walk two messages back instead of landing on the same one.
    func pinTop(_ lineNumber: Int) {
        self.pinned = lineNumber
        self.unpinTask?.cancel()
        self.unpinTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled else { return }
            self?.pinned = nil
        }
    }
}

/// Detects when the user scrolls within 50pt of the top.
private struct ScrollNearTopDetector: ViewModifier {
    @Binding var isNearTop: Bool

    func body(content: Content) -> some View {
        content.onScrollGeometryChange(for: Bool.self, of: { geo in
            geo.contentOffset.y < 50
        }, action: { _, newNearTop in
            guard newNearTop != isNearTop else { return }
            isNearTop = newNearTop
        })
    }
}
