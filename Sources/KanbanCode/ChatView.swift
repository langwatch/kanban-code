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
    var isLoadingMore: Bool = false
    var tmuxSessionName: String?
    var cardId: String = ""
    var onSendPrompt: (String, [String]) -> Void = { _, _ in }
    var onQueuePrompt: ((String, Bool, [String]) -> Void)? // (body, sendAutomatically, imagePaths)
    var onLoadMore: (() -> Void)?
    var onLoadAroundTurn: ((Int) -> Void)?
    var sessionPath: String?
    var onFork: (() -> Void)?
    var onCheckpoint: ((ConversationTurn) -> Void)?
    @Binding var draftText: String
    @Binding var draftImages: [Data]

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

        // If any new user turn arrived since we sent, dismiss the pending message.
        // This is simple and reliable — we can only have one pending at a time,
        // and a new user turn in the transcript means our message was received.
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
                    isBusyFromPane: $isBusyFromPane,
                    pendingMessage: pendingMessage,
                    onLoadMore: onLoadMore,
                    onLoadAroundTurn: onLoadAroundTurn,
                    sessionPath: sessionPath,
                    onFork: onFork,
                    onCheckpoint: onCheckpoint,
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
    }

}

// MARK: - Chat Message List (isolated from input bar state)

private struct ChatMessageList: View {
    let turns: [ConversationTurn]
    let assistant: CodingAssistant
    var hasMoreTurns: Bool = false
    var tmuxSessionName: String?
    @Binding var isBusyFromPane: Bool
    @State private var pollKick: Int = 0
    @State private var lastBusyDetected: Date = .distantPast
    var pendingMessage: String?
    var onLoadMore: (() -> Void)?
    var onLoadAroundTurn: ((Int) -> Void)?
    var sessionPath: String?
    var onFork: (() -> Void)?
    var onCheckpoint: ((ConversationTurn) -> Void)?
    var onSendAnswer: ((String) -> Void)?

    @State private var isAtBottom = true
    @State private var isNearTop = false
    @State private var isLoadingMore = false
    @State private var firstVisibleLineNumber: Int?
    @State private var hasNewMessages = false
    @State private var lastSeenCount = 0
    @State private var lastSeenLineNumber: Int?
    @State private var expandedTextBlocks: Set<String> = []

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
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 0) {
                    // Spacer for search bar
                    if showSearch { Color.clear.frame(height: 36) }
                    if hasMoreTurns && !turns.isEmpty {
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
                                        expandedTextBlocks: $expandedTextBlocks
                                    )
                                    .equatable()
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
                        } else {
                            let turn = group[0]
                            ChatMessageView(
                                turn: turn,
                                assistant: assistant,
                                toolResultMap: toolResults[turn.lineNumber] ?? [:],
                                isLastInGroup: groupInfo[turn.lineNumber] ?? true,
                                onCopy: { text in
                                    NSPasteboard.general.clearContents()
                                    NSPasteboard.general.setString(text, forType: .string)
                                },
                                onFork: onFork,
                                onCheckpoint: onCheckpoint,
                                onSendAnswer: onSendAnswer,
                                highlightText: activeQuery.isEmpty ? nil : activeQuery,
                                isCurrentMatch: currentMatchTurnIndex == turn.index,
                                sessionPath: sessionPath,
                                tmuxSessionName: tmuxSessionName,
                                hasLastToolCall: turn.lineNumber == lastToolCallLN,
                                expandedTextBlocks: $expandedTextBlocks
                            )
                            .equatable()
                            .id(turn.lineNumber)
                            .padding(.vertical, 4)
                        }
                    }

                    // Optimistic pending message (sending...)
                    if let pending = pendingMessage {
                        HStack {
                            Spacer(minLength: 0)
                            HStack(spacing: 8) {
                                ProgressView()
                                    .controlSize(.small)
                                    .opacity(0.5)
                                Text(pending)
                                    .font(.app(.body))
                                    .padding(.horizontal, 14)
                                    .padding(.vertical, 10)
                                    .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 18))
                                    .opacity(0.5)
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
                    Color.clear.frame(height: 30)
                        .id("bottom-spacer")
                }
                .padding(.horizontal, 16)
                .textSelection(.enabled)
            }
            .defaultScrollAnchor(.bottom)
            .modifier(ScrollBottomTracker(isAtBottom: $isAtBottom, hasNewMessages: $hasNewMessages))
            .modifier(ScrollNearTopDetector(isNearTop: $isNearTop))
            .onChange(of: isNearTop) {
                if isNearTop && hasMoreTurns && !isLoadingMore && activeQuery.isEmpty {
                    triggerLoadMore()
                }
            }
            .onChange(of: turns.last?.lineNumber) {
                guard let newLast = turns.last?.lineNumber else { return }
                let isInitial = lastSeenLineNumber == nil
                // During search, handle pending match scroll instead of auto-scroll
                if !activeQuery.isEmpty {
                    if pendingMatchScroll {
                        pendingMatchScroll = false
                        scrollToCurrentMatch(proxy: proxy, delay: true)
                    }
                    lastSeenLineNumber = newLast
                    lastSeenCount = turns.count
                } else {
                    // Only auto-scroll for NEW messages at the bottom, not load-more prepends
                    let isNewAtBottom = newLast != lastSeenLineNumber
                    if isInitial {
                        scrollToBottom(proxy: proxy, delay: true)
                    } else if isNewAtBottom && isAtBottom {
                        scrollToBottom(proxy: proxy, delay: false)
                    } else if isNewAtBottom {
                        hasNewMessages = true
                    }
                    lastSeenLineNumber = newLast
                    lastSeenCount = turns.count
                }
            }
            .onChange(of: currentMatchPosition) {
                guard !searchMatchIndices.isEmpty,
                      currentMatchPosition < searchMatchIndices.count else { return }
                let idx = searchMatchIndices[currentMatchPosition]
                if turns.contains(where: { $0.index == idx }) {
                    scrollToCurrentMatch(proxy: proxy, delay: false)
                } else {
                    pendingMatchScroll = true
                    onLoadAroundTurn?(idx)
                }
            }
            .onChange(of: pendingMessage) {
                if pendingMessage != nil {
                    scrollToBottom(proxy: proxy, delay: false)
                }
            }
            .onAppear {
                lastSeenCount = turns.count
                lastSeenLineNumber = turns.last?.lineNumber
                isAtBottom = true
            }
            .onChange(of: turns.first?.lineNumber) {
                // Distinguish card change (last also changed) from load-more (last unchanged)
                let lastUnchanged = turns.last?.lineNumber == lastSeenLineNumber
                if lastUnchanged {
                    // Load-more prepended earlier turns — scroll to preserved position
                    lastSeenCount = turns.count
                    if let anchor = firstVisibleLineNumber {
                        proxy.scrollTo(anchor, anchor: .top)
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                            proxy.scrollTo(anchor, anchor: .top)
                        }
                    }
                    isLoadingMore = false
                } else {
                    // Card changed — reset and scroll
                    lastSeenLineNumber = nil
                    lastSeenCount = 0
                    isAtBottom = true
                    hasNewMessages = false
                    isLoadingMore = false
                    scrollToBottom(proxy: proxy, delay: true)
                }
            }
            .task(id: tmuxSessionName) {
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
                    if newBusy {
                        lastBusyDetected = .now
                    }
                    // Don't flip to not-busy while a pending message exists —
                    // Claude hasn't processed the prompt yet, tmux just hasn't caught up.
                    if newBusy != isBusyFromPane && (newBusy || pendingMessage == nil) {
                        isBusyFromPane = newBusy
                    }
                    // Adaptive polling: fast when busy or recently busy, slow when idle.
                    // - Busy/pending/recently busy: 250ms for responsive indicator
                    // - Idle (>10s since last busy): 3s to save CPU
                    // The 10s cooldown prevents slow polling during brief idle gaps
                    // between tool calls (Claude pauses briefly between each tool).
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
            .onChange(of: pendingMessage) {
                // Kick the pane poll to immediately check busy state after sending
                if pendingMessage != nil {
                    pollKick += 1
                }
            }
            .overlay(alignment: .bottom) {
                if hasNewMessages {
                    Button {
                        proxy.scrollTo("bottom-spacer", anchor: .bottom)
                        hasNewMessages = false
                        isAtBottom = true
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
            .animation(.easeInOut(duration: 0.2), value: hasNewMessages)
            .onReceive(NotificationCenter.default.publisher(for: .chatCardExpanded)) { _ in
                if isAtBottom {
                    // Multiple delayed attempts to catch layout changes from card expansion.
                    // The expanded content renders asynchronously, so we need to retry.
                    proxy.scrollTo("bottom-spacer", anchor: .bottom)
                    for delay in [0.05, 0.15, 0.3] {
                        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                            proxy.scrollTo("bottom-spacer", anchor: .bottom)
                        }
                    }
                }
            }
        }
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

    private func scrollToCurrentMatch(proxy: ScrollViewProxy, delay: Bool) {
        guard !searchMatchIndices.isEmpty,
              currentMatchPosition < searchMatchIndices.count else { return }
        let idx = searchMatchIndices[currentMatchPosition]
        guard let turn = turns.first(where: { $0.index == idx }) else { return }
        let lineNum = turn.lineNumber
        if delay {
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(80))
                withAnimation(.easeInOut(duration: 0.2)) {
                    proxy.scrollTo(lineNum, anchor: .center)
                }
            }
        } else {
            withAnimation(.easeInOut(duration: 0.2)) {
                proxy.scrollTo(lineNum, anchor: .center)
            }
        }
    }

    private func triggerLoadMore() {
        guard !isLoadingMore else { return }
        isLoadingMore = true
        // Remember the first visible turn so we can scroll back to it after prepend
        firstVisibleLineNumber = turns.first?.lineNumber
        onLoadMore?()
    }

    private func scrollToBottom(proxy: ScrollViewProxy, delay: Bool) {
        if delay {
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(50))
                proxy.scrollTo("bottom-spacer", anchor: .bottom)
            }
        } else {
            proxy.scrollTo("bottom-spacer", anchor: .bottom)
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

    func body(content: Content) -> some View {
        content.onScrollGeometryChange(for: Bool.self, of: { geo in
            geo.contentOffset.y + geo.containerSize.height >= geo.contentSize.height - 30
        }, action: { _, newAtBottom in
            isAtBottom = newAtBottom
            if newAtBottom { hasNewMessages = false }
        })
    }
}

/// Detects when the user scrolls within 300pt of the top.
private struct ScrollNearTopDetector: ViewModifier {
    @Binding var isNearTop: Bool

    func body(content: Content) -> some View {
        content.onScrollGeometryChange(for: Bool.self, of: { geo in
            geo.contentOffset.y < 300
        }, action: { _, newNearTop in
            isNearTop = newNearTop
        })
    }
}
