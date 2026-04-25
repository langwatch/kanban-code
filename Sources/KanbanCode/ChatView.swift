import SwiftUI
import KanbanCodeCore
import MarkdownUI

// MARK: - Chat View

let chatMaxWidth: CGFloat = 720
let userBubbleMaxWidth: CGFloat = 504

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
                    sessionPath: sessionPath,
                    onFork: onFork,
                    onCheckpoint: onCheckpoint,
                    githubBaseURL: githubBaseURL,
                    onSendAnswer: { answer in
                        onSendPrompt(answer, [])
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
                                        try? await TmuxAdapter().sendInterrupt(sessionName: session)
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

            if tmuxSessionName != nil {
            ChatInputBar(
                assistant: assistant,
                isReady: !isAssistantBusy,
                cardId: cardId,
                contextUsage: contextUsage,
                userMessageHistory: turns.filter { $0.role == "user" }.reversed().compactMap {
                    let text = $0.contentBlocks.compactMap { b in if case .text = b.kind { return b.text } else { return nil } }.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
                    return text.isEmpty ? nil : text
                },
                onSend: { text, images in
                    pendingMessage = text
                    pendingMessageTime = .now
                    userTurnCountAtSend = turns.filter { $0.role == "user" }.count
                    onSendPrompt(text, images)
                },
                onQueuePrompt: onQueuePrompt,
                onEscape: onEscape,
                text: $draftText,
                pastedImages: $draftImages
            )
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
    var sessionPath: String?
    var onFork: (() -> Void)?
    var onCheckpoint: ((ConversationTurn) -> Void)?
    var githubBaseURL: String?
    var onSendAnswer: ((String) -> Void)?

    @State private var isAtBottom = true
    @State private var isNearTop = false
    @State private var firstVisibleLineNumber: Int?
    @State private var loadMoreTask: Task<Void, Never>?
    @State private var hasNewMessages = false
    @State private var lastSeenCount = 0
    @State private var lastSeenLineNumber: Int?
    @State private var expandedTextBlocks: Set<String> = []
    /// Whether to auto-scroll on new content. Only set to false when we show
    /// the "New messages" badge (user deliberately scrolled away). Reset to true
    /// when user sends a message, clicks "New messages", or scrolls back to bottom.
    @State private var shouldAutoScroll = true
    @State private var scrollPosition = ScrollPosition(edge: .bottom)

    // Search state
    @State private var showSearch = false
    @State private var searchText = ""
    @State private var activeQuery = ""
    @State private var searchMatchIndices: [Int] = []
    @State private var currentMatchPosition: Int = 0
    @State private var searchDebounceTask: Task<Void, Never>?
    @State private var searchScanTask: Task<Void, Never>?
    @State private var isSearchScanning = false
    @State private var pendingMatchScroll = false
    @FocusState private var isSearchFieldFocused: Bool

    private var currentMatchTurnIndex: Int? {
        guard showSearch, !searchMatchIndices.isEmpty,
              currentMatchPosition < searchMatchIndices.count else { return nil }
        return searchMatchIndices[currentMatchPosition]
    }

    var body: some View {
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

    private var scrollableMessageList: some View {
        scrollViewWithTracking
            .task(id: tmuxSessionName) {
                await pollBusyState()
            }
            .overlay(alignment: .bottom) { newMessagesButton }
            .animation(.easeInOut(duration: 0.2), value: hasNewMessages)
            .onReceive(NotificationCenter.default.publisher(for: .chatCardExpanded)) { _ in
                if isAtBottom { scrollPosition.scrollTo(edge: .bottom) }
            }
    }

    private var scrollViewWithTracking: some View {
        ScrollView {
            messageListContent
        }
        .scrollPosition($scrollPosition)
        .modifier(ScrollBottomTracker(isAtBottom: $isAtBottom, hasNewMessages: $hasNewMessages, shouldAutoScroll: $shouldAutoScroll))
        .modifier(ScrollNearTopDetector(isNearTop: $isNearTop))
        .onChange(of: isNearTop) { if isNearTop { checkLoadMore() } }
        .onScrollGeometryChange(for: Bool.self, of: { geo in
            geo.contentOffset.y < -10  // overscroll / pull gesture
        }, action: { wasOverscrolling, isOverscrolling in
            if !wasOverscrolling && isOverscrolling { checkLoadMore() }
        })
        .onChange(of: turns.count) {
            // Load completed — clear the loading marker so the spinner
            // hides immediately and a new load can be triggered.
            if loadMoreTask != nil {
                loadMoreTask?.cancel()
                loadMoreTask = nil
            }
        }
        .onChange(of: turns.last?.lineNumber) { handleNewTurns() }
        .onChange(of: currentMatchPosition) { handleMatchNavigation() }
        .onChange(of: pendingMessage) {
            if pendingMessage != nil {
                shouldAutoScroll = true
                hasNewMessages = false
                scrollPosition.scrollTo(edge: .bottom)
                pollKick += 1
            }
        }
        .onAppear {
            lastSeenCount = turns.count
            lastSeenLineNumber = turns.last?.lineNumber
            isAtBottom = true
            shouldAutoScroll = true
        }
        .onChange(of: turns.first?.lineNumber) { handleFirstTurnChange() }
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
            .glassEffect(.regular, in: .capsule)
            .shadow(color: .black.opacity(0.15), radius: 4, y: 2)
            .padding(.bottom, 8)
            .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }

    private func handleNewTurns() {
        guard let newLast = turns.last?.lineNumber else { return }
        let isInitial = lastSeenLineNumber == nil
        if !activeQuery.isEmpty {
            if pendingMatchScroll {
                pendingMatchScroll = false
                scrollToCurrentMatch(delay: true)
            }
        } else {
            let isNewAtBottom = newLast != lastSeenLineNumber
            if isInitial || (isNewAtBottom && shouldAutoScroll) {
                scrollPosition.scrollTo(edge: .bottom)
            } else if isNewAtBottom {
                hasNewMessages = true
                shouldAutoScroll = false
            }
        }
        lastSeenLineNumber = newLast
        lastSeenCount = turns.count
    }

    private func handleMatchNavigation() {
        guard !searchMatchIndices.isEmpty,
              currentMatchPosition < searchMatchIndices.count else { return }
        let idx = searchMatchIndices[currentMatchPosition]
        if turns.contains(where: { $0.index == idx }) {
            scrollToCurrentMatch(delay: false)
        } else {
            pendingMatchScroll = true
            onLoadAroundTurn?(idx)
        }
    }

    private func handleFirstTurnChange() {
        let lastUnchanged = turns.last?.lineNumber == lastSeenLineNumber
        if lastUnchanged {
            lastSeenCount = turns.count
            if let anchor = firstVisibleLineNumber {
                scrollPosition.scrollTo(id: anchor, anchor: .top)
            }
        } else {
            lastSeenLineNumber = nil
            lastSeenCount = 0
            isAtBottom = true
            hasNewMessages = false
            loadMoreTask?.cancel()
            loadMoreTask = nil
            scrollPosition = ScrollPosition(edge: .bottom)
        }
    }

    private func pollBusyState() async {
        guard let session = tmuxSessionName else {
            isBusyFromPane = false
            return
        }
        let tmux = TmuxAdapter()
        while !Task.isCancelled {
            let newBusy: Bool
            do {
                let output = try await tmux.capturePane(sessionName: session)
                newBusy = PaneOutputParser.isWorking(output)
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

                    let groupInfo = Self.computeGroupInfo(turns: turns)
                    let toolResults = Self.computeToolResults(turns: turns)
                    let turnGroups = Self.groupConsecutiveToolTurns(turns: turns)
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

                    ForEach(Array(turnGroups.enumerated()), id: \.element.first?.lineNumber) { gi, group in
                        if group.count > 1 {
                            // Multiple consecutive tool-only turns — single shared bubble
                            let toolTurns = group.filter { $0.role == "assistant" }
                            VStack(alignment: .leading, spacing: 2) {
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
                                        isCurrentMatch: currentMatchTurnIndex == toolTurn.index,
                                        sessionPath: sessionPath,
                                        tmuxSessionName: tmuxSessionName,
                                        hasLastToolCall: toolTurn.lineNumber == lastToolCallLN,
                                        githubBaseURL: githubBaseURL,
                                        expandedTextBlocks: $expandedTextBlocks
                                    )
                                }
                            }
                            .id(group.first?.lineNumber ?? 0)
                            .background(
                                RoundedRectangle(cornerRadius: 8)
                                    .fill(Color.primary.opacity(0.04))
                                    .padding(.leading, -8)
                            )
                            .frame(maxWidth: chatMaxWidth, alignment: .leading)
                            .padding(.vertical, 4)
                        } else if ChatMessageView.turnHasContent(group[0]) {
                            let turn = group[0]
                            // Collect all text from consecutive same-role turns for copy
                            let groupText: String = {
                                guard groupInfo[turn.lineNumber] == true else { return "" }
                                var texts: [String] = []
                                // Walk backwards from this turn to find all consecutive same-role turns
                                if let turnIdx = turns.firstIndex(where: { $0.lineNumber == turn.lineNumber }) {
                                    var i = turnIdx
                                    while i >= 0 && turns[i].role == turn.role {
                                        let t = turns[i].contentBlocks
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
                                isCurrentMatch: currentMatchTurnIndex == turn.index,
                                sessionPath: sessionPath,
                                tmuxSessionName: tmuxSessionName,
                                hasLastToolCall: turn.lineNumber == lastToolCallLN,
                                githubBaseURL: githubBaseURL,
                                expandedTextBlocks: $expandedTextBlocks
                            )
                            .id(turn.lineNumber)
                            .padding(.vertical, 4)
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
                    Text("\(searchMatchIndices.count) found…")
                        .font(.app(.caption2))
                        .foregroundStyle(.secondary)
                } else if searchMatchIndices.isEmpty {
                    Text("0 results")
                        .font(.app(.caption2))
                        .foregroundStyle(.secondary)
                } else {
                    Text("\(searchMatchIndices.count - currentMatchPosition)/\(searchMatchIndices.count)")
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
            searchMatchIndices = []
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
        searchMatchIndices = []
        currentMatchPosition = 0
        guard let path = sessionPath, !activeQuery.isEmpty else { return }
        isSearchScanning = true
        let query = activeQuery
        searchScanTask = Task {
            var matches: [Int] = []
            for await matchIndex in TranscriptReader.scanForMatches(from: path, query: query) {
                if Task.isCancelled { break }
                matches.append(matchIndex)
                if matches.count == 1 || matches.count % 50 == 0 {
                    searchMatchIndices = matches
                }
            }
            guard !Task.isCancelled else { return }
            searchMatchIndices = matches
            isSearchScanning = false
            if !matches.isEmpty {
                currentMatchPosition = matches.count - 1
            }
        }
    }

    private func navigateSearch(forward: Bool) {
        guard !searchMatchIndices.isEmpty else { return }
        if forward {
            currentMatchPosition = (currentMatchPosition + 1) % searchMatchIndices.count
        } else {
            currentMatchPosition = (currentMatchPosition - 1 + searchMatchIndices.count) % searchMatchIndices.count
        }
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
        guard !searchMatchIndices.isEmpty,
              currentMatchPosition < searchMatchIndices.count else { return }
        let idx = searchMatchIndices[currentMatchPosition]
        guard let turn = turns.first(where: { $0.index == idx }) else { return }
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

    /// Continuously loads more history while the user is near the top.
    /// Uses a task guard to prevent overlapping calls and a 500ms cooldown
    /// between loads so re-renders can settle before the next batch.
    private func checkLoadMore() {
        guard isNearTop, hasMoreTurns, activeQuery.isEmpty else { return }
        guard loadMoreTask == nil else { return }
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
        let visibleTurns = turns.filter { turn in
            if turn.role == "user" {
                return turn.contentBlocks.contains {
                    if case .text = $0.kind { return !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
                    return false
                }
            }
            return turn.contentBlocks.contains { block in
                switch block.kind {
                case .text: return !block.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                case .toolUse, .agentCall, .planModeExit, .askUserQuestion, .planModeEnter: return true
                case .toolResult: return false
                case .thinking: return !block.text.isEmpty
                }
            }
        }
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

/// Detects when the user scrolls within 50pt of the top.
private struct ScrollNearTopDetector: ViewModifier {
    @Binding var isNearTop: Bool

    func body(content: Content) -> some View {
        content.onScrollGeometryChange(for: Bool.self, of: { geo in
            geo.contentOffset.y < 50
        }, action: { _, newNearTop in
            isNearTop = newNearTop
        })
    }
}
