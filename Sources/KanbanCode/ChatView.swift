import SwiftUI
import KanbanCodeCore
import MarkdownUI

// MARK: - Chat View

private let chatMaxWidth: CGFloat = 720
private let userBubbleMaxWidth: CGFloat = 504

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
    var onFork: (() -> Void)?
    var onCheckpoint: ((ConversationTurn) -> Void)?
    @Binding var draftText: String
    @Binding var draftImages: [Data]

    @State private var isBusyFromPane = false
    @State private var dismissedBusy = false
    @Binding var pendingMessage: String?

    /// Use pane output as ground truth, falling back to hook state only if no tmux session.
    /// Also optimistically show busy when a pending message was just sent.
    private var isAssistantBusy: Bool {
        if dismissedBusy { return false }
        if pendingMessage != nil { return true }
        if tmuxSessionName != nil { return isBusyFromPane }
        return activityState == .activelyWorking
    }

    private func clearPendingIfMatched() {
        guard let pending = pendingMessage else { return }
        let prefix = String(pending.prefix(40))
        let hasMatch = turns.contains { turn in
            turn.role == "user" && turn.contentBlocks.contains {
                if case .text = $0.kind { return $0.text.contains(prefix) }
                return false
            }
        }
        if hasMatch {
            pendingMessage = nil
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            ZStack(alignment: .bottom) {
                ChatMessageList(
                    turns: turns,
                    assistant: assistant,
                    hasMoreTurns: hasMoreTurns,
                    tmuxSessionName: tmuxSessionName,
                    isBusyFromPane: $isBusyFromPane,
                    pendingMessage: pendingMessage,
                    onLoadMore: onLoadMore,
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
                        .frame(maxWidth: chatMaxWidth, alignment: .leading)
                        Spacer(minLength: 0)
                    }
                    .padding(.bottom, 2)
                }
            }

            ChatInputBar(
                assistant: assistant,
                isReady: !isAssistantBusy,
                cardId: cardId,
                onSend: { text, images in
                    pendingMessage = text
                    onSendPrompt(text, images)
                },
                onQueuePrompt: onQueuePrompt,
                text: $draftText,
                pastedImages: $draftImages
            )
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
    var pendingMessage: String?
    var onLoadMore: (() -> Void)?
    var onFork: (() -> Void)?
    var onCheckpoint: ((ConversationTurn) -> Void)?
    var onSendAnswer: ((String) -> Void)?

    @State private var isAtBottom = true
    @State private var hasNewMessages = false
    @State private var lastSeenCount = 0
    @State private var lastSeenLineNumber: Int?

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 0) {
                    if hasMoreTurns {
                        ProgressView()
                            .controlSize(.small)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 8)
                            .onAppear { onLoadMore?() }
                    }

                    let groupInfo = Self.computeGroupInfo(turns: turns)
                    let toolResults = Self.computeToolResults(turns: turns)
                    let turnGroups = Self.groupConsecutiveToolTurns(turns: turns)

                    ForEach(turnGroups.indices, id: \.self) { gi in
                        let group = turnGroups[gi]
                        if group.count > 1 {
                            // Multiple consecutive tool-only turns — single shared bubble
                            let toolTurns = group.filter { $0.role == "assistant" }
                            VStack(alignment: .leading, spacing: 2) {
                                ForEach(toolTurns.indices, id: \.self) { ti in
                                    ChatMessageView(
                                        turn: toolTurns[ti],
                                        assistant: assistant,
                                        toolResultMap: toolResults[toolTurns[ti].lineNumber] ?? [:],
                                        isLastInGroup: false,
                                        onCopy: { text in
                                            NSPasteboard.general.clearContents()
                                            NSPasteboard.general.setString(text, forType: .string)
                                        },
                                        onFork: onFork,
                                        onCheckpoint: onCheckpoint,
                                        onSendAnswer: onSendAnswer,
                                        suppressBackground: true
                                    )
                                    .equatable()
                                    .id(toolTurns[ti].lineNumber)
                                }
                            }
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
                                onSendAnswer: onSendAnswer
                            )
                            .equatable()
                            .id(turn.lineNumber)
                            .padding(.vertical, 4)
                            .onAppear {
                                if turn.lineNumber == turns.last?.lineNumber {
                                    isAtBottom = true
                                    hasNewMessages = false
                                }
                            }
                            .onDisappear {
                                if turn.lineNumber == turns.last?.lineNumber {
                                    isAtBottom = false
                                }
                            }
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
            }
            .onChange(of: turns.last?.lineNumber) {
                // New message at bottom — auto-scroll or show pill
                guard let newLast = turns.last?.lineNumber else { return }
                let isInitial = lastSeenLineNumber == nil
                if isInitial || (newLast != lastSeenLineNumber && (isAtBottom || isInitial)) {
                    scrollToBottom(proxy: proxy, delay: isInitial)
                } else if newLast != lastSeenLineNumber {
                    hasNewMessages = true
                }
                lastSeenLineNumber = newLast
                lastSeenCount = turns.count
            }
            .onChange(of: pendingMessage) {
                if pendingMessage != nil {
                    scrollToBottom(proxy: proxy, delay: false)
                }
            }
            .onAppear {
                // Scroll to bottom on appear/re-appear
                lastSeenCount = turns.count
                lastSeenLineNumber = turns.last?.lineNumber
                isAtBottom = true
                scrollToBottom(proxy: proxy, delay: true)
            }
            .onChange(of: turns.first?.lineNumber) {
                // Card changed — reset and scroll
                lastSeenLineNumber = nil
                lastSeenCount = 0
                isAtBottom = true
                hasNewMessages = false
                scrollToBottom(proxy: proxy, delay: true)
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
                    // Don't flip to not-busy while a pending message exists —
                    // Claude hasn't processed the prompt yet, tmux just hasn't caught up.
                    if newBusy != isBusyFromPane && (newBusy || pendingMessage == nil) {
                        isBusyFromPane = newBusy
                    }
                    // Wait up to 5s, but re-check immediately if pollKick changes
                    let kickBefore = pollKick
                    for _ in 0..<50 {
                        try? await Task.sleep(for: .milliseconds(100))
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
        }
    }

    private func scrollToBottom(proxy: ScrollViewProxy, delay: Bool) {
        Task { @MainActor in
            // Multiple attempts with increasing delays — LazyVStack needs time to render
            for ms in (delay ? [50, 150, 300] : [0]) {
                if ms > 0 { try? await Task.sleep(for: .milliseconds(ms)) }
                proxy.scrollTo("bottom-spacer", anchor: .bottom)
            }
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

// MARK: - Chat Message View

struct ChatMessageView: View, Equatable {
    let turn: ConversationTurn
    let assistant: CodingAssistant
    var toolResultMap: [String: ContentBlock] = [:]
    var isLastInGroup: Bool = true
    var onCopy: ((String) -> Void)?
    var onFork: (() -> Void)?
    var onCheckpoint: ((ConversationTurn) -> Void)?
    var onSendAnswer: ((String) -> Void)?
    var suppressBackground: Bool = false
    @State private var isHovered = false

    nonisolated static func == (lhs: ChatMessageView, rhs: ChatMessageView) -> Bool {
        lhs.turn.lineNumber == rhs.turn.lineNumber &&
        lhs.turn.contentBlocks.count == rhs.turn.contentBlocks.count &&
        lhs.isLastInGroup == rhs.isLastInGroup &&
        lhs.assistant == rhs.assistant
    }

    private var hasContent: Bool {
        if turn.role == "user" {
            // User turns: only show if they have visible text (not just tool_result blocks)
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

    /// Text content of this turn for copy.
    private var turnText: String {
        return turn.contentBlocks
            .filter { if case .text = $0.kind { return true }; return false }
            .map(\.text).joined(separator: "\n")
    }

    var body: some View {
        if hasContent {
            if suppressBackground {
                // Inside a grouped tool box — no centering wrapper, no frame constraint
                assistantMessage
            } else {
                HStack {
                    Spacer(minLength: 0)
                    VStack(alignment: turn.role == "user" ? .trailing : .leading, spacing: 4) {
                        if turn.role == "user" {
                            userBubble
                        } else {
                            assistantMessage
                        }

                        if isLastInGroup {
                            messageActions
                        }
                    }
                    .frame(maxWidth: chatMaxWidth, alignment: turn.role == "user" ? .trailing : .leading)
                    .contentShape(Rectangle())
                    .onHover { isHovered = $0 }
                    Spacer(minLength: 0)
                }
            }
        }
    }

    // MARK: User bubble

    private var isInterruption: Bool {
        turn.contentBlocks.contains { block in
            if case .text = block.kind {
                return block.text.contains("[Request interrupted by user")
            }
            return false
        }
    }

    private var userBubble: some View {
        VStack(alignment: .trailing, spacing: 4) {
            ForEach(turn.contentBlocks.indices, id: \.self) { i in
                let block = turn.contentBlocks[i]
                if case .text = block.kind {
                    if block.text.contains("[Request interrupted by user") {
                        // Render interruption as plain italic text, no bubble
                        Text(block.text)
                            .font(.app(.caption))
                            .italic()
                            .foregroundStyle(.secondary)
                    } else if block.text.hasPrefix("📎") {
                        Text(block.text)
                            .font(.app(.caption))
                            .foregroundStyle(.secondary)
                    } else {
                        Text(block.text)
                            .font(.app(.body))
                            .textSelection(.enabled)
                    }
                }
            }
        }
        .padding(.horizontal, isInterruption ? 0 : 14)
        .padding(.vertical, isInterruption ? 4 : 10)
        .background {
            if !isInterruption {
                RoundedRectangle(cornerRadius: 18)
                    .fill(Color.primary.opacity(0.06))
            }
        }
        .frame(maxWidth: userBubbleMaxWidth, alignment: .trailing)
    }

    // MARK: Assistant message

    private var assistantMessage: some View {
        let pairedBlocks = pairToolResults()
        // Build a flat list of rendered items, tagging each as tool or not
        let items: [(isToolUse: Bool, paired: PairedBlock)] = pairedBlocks.compactMap { paired in
            switch paired.block.kind {
            case .toolResult: return nil
            case .text:
                let trimmed = paired.block.text.trimmingCharacters(in: .whitespacesAndNewlines)
                if trimmed.isEmpty { return nil }
                return (false, paired)
            case .toolUse: return (true, paired)
            default: return (false, paired)
            }
        }
        // Group consecutive tool uses
        let groups = items.reduce(into: [(isToolGroup: Bool, items: [(isToolUse: Bool, paired: PairedBlock)])]()) { groups, item in
            if item.isToolUse, let last = groups.last, last.isToolGroup {
                groups[groups.count - 1].items.append(item)
            } else {
                groups.append((isToolGroup: item.isToolUse, items: [item]))
            }
        }

        return VStack(alignment: .leading, spacing: 6) {
            ForEach(groups.indices, id: \.self) { gi in
                let group = groups[gi]
                if group.isToolGroup {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(group.items.indices, id: \.self) { ti in
                            if ti > 0 { Divider().padding(.leading, 8) }
                            if case .toolUse(let name, _, _) = group.items[ti].paired.block.kind {
                                ToolCallCard(
                                    name: name,
                                    displayText: group.items[ti].paired.block.text,
                                    rawInputJSON: group.items[ti].paired.block.rawInputJSON,
                                    resultText: group.items[ti].paired.resultBlock?.text,
                                    showBackground: false
                                )
                            }
                        }
                    }
                    .background {
                        if !suppressBackground {
                            RoundedRectangle(cornerRadius: 8)
                                .fill(Color.primary.opacity(0.04))
                                .padding(.leading, -8)
                        }
                    }
                } else {
                    blockView(group.items[0].paired)
                }
            }
        }
    }

    @ViewBuilder
    private func blockView(_ paired: PairedBlock) -> some View {
        switch paired.block.kind {
        case .text:
            let trimmed = paired.block.text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                if trimmed.containsMarkdown {
                    Markdown(trimmed)
                        .markdownTheme(chatMarkdownTheme)
                        .textSelection(.enabled)
                } else {
                    Text(trimmed)
                        .font(.system(size: 13))
                        .textSelection(.enabled)
                }
            }
        case .toolUse(let name, _, _):
            ToolCallCard(
                name: name,
                displayText: paired.block.text,
                rawInputJSON: paired.block.rawInputJSON,
                resultText: paired.resultBlock?.text,
                showBackground: !suppressBackground
            )
        case .toolResult:
            EmptyView()
        case .thinking:
            ThinkingCard(text: paired.block.text)
        case .planModeEnter:
            Text("Entered plan mode")
                .font(.app(.caption))
                .italic()
                .foregroundStyle(.tertiary)
        case .planModeExit(let plan):
            PlanModeExitCard(plan: plan, resultText: paired.resultBlock?.text, onAnswer: onSendAnswer)
        case .askUserQuestion(let questions, _):
            AskUserQuestionCard(
                questions: questions,
                resultText: paired.resultBlock?.text,
                onAnswer: onSendAnswer
            )
        case .agentCall(let description, let subagentType, _):
            AgentCallCard(
                description: description,
                subagentType: subagentType,
                resultText: paired.resultBlock?.text,
                rawInputJSON: paired.block.rawInputJSON
            )
        }
    }

    // MARK: Pair tool results

    private struct PairedBlock {
        let block: ContentBlock
        var resultBlock: ContentBlock?
    }

    private func pairToolResults() -> [PairedBlock] {
        var paired = turn.contentBlocks.map { PairedBlock(block: $0) }

        // Use precomputed tool result map (no allTurns lookup needed)
        for (i, block) in turn.contentBlocks.enumerated() {
            let blockId: String?
            switch block.kind {
            case .toolUse(_, _, let id): blockId = id
            case .askUserQuestion(_, let id): blockId = id
            case .agentCall(_, _, let id): blockId = id
            case .planModeExit: blockId = nil // paired by position, not ID
            case .planModeEnter: blockId = nil
            default: blockId = nil
            }
            if let useId = blockId, let result = toolResultMap[useId] {
                paired[i].resultBlock = result
            }
        }

        return paired
    }

    // MARK: Actions (below message, visible on hover)

    @State private var showCopyCheck = false
    private var messageActions: some View {
        HStack(spacing: 4) {
            // Copy
            ActionButton(
                icon: showCopyCheck ? "checkmark" : "doc.on.doc",
                help: "Copy text"
            ) {
                onCopy?(turnText)
                showCopyCheck = true
                Task { @MainActor in
                    try? await Task.sleep(for: .seconds(2))
                    showCopyCheck = false
                }
            }

            // Checkpoint
            if let onCheckpoint {
                ActionButton(icon: "clock.arrow.circlepath", help: "Checkpoint") {
                    onCheckpoint(turn)
                }
            }

            // Fork
            if onFork != nil {
                ActionButton(icon: "arrow.branch", help: "Fork") {
                    onFork?()
                }
            }
        }
        .opacity(isHovered ? 1 : 0)
        .frame(height: 20)
    }
}

// MARK: - Action Button (with hover/active feedback)

private struct ActionButton: View {
    let icon: String
    var help: String = ""
    let action: () -> Void
    @State private var isHovered = false
    @State private var isPressed = false

    var body: some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 11))
                .foregroundStyle(isPressed ? .primary : .secondary)
                .frame(width: 24, height: 20)
                .background(
                    RoundedRectangle(cornerRadius: 4)
                        .fill(isPressed ? Color.primary.opacity(0.1) : (isHovered ? Color.primary.opacity(0.06) : Color.clear))
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .simultaneousGesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in isPressed = true }
                .onEnded { _ in isPressed = false }
        )
        .help(help)
    }
}

// MARK: - Tool Call Card

struct ToolCallCard: View, Equatable {
    let name: String
    let displayText: String
    let rawInputJSON: Data?
    var resultText: String?
    var showBackground: Bool = true
    @State private var isExpanded = false

    nonisolated static func == (lhs: ToolCallCard, rhs: ToolCallCard) -> Bool {
        lhs.name == rhs.name && lhs.displayText == rhs.displayText && lhs.rawInputJSON == rhs.rawInputJSON
    }

    private func parseSummary() -> (action: String, target: String, additions: Int?, deletions: Int?, replaceAll: Bool) {
        let path = extractField("file_path").map { ($0 as NSString).lastPathComponent } ?? ""
        switch name {
        case "Edit":
            let oldStr = extractField("old_string") ?? ""
            let newStr = extractField("new_string") ?? ""
            let oldLines = oldStr.isEmpty ? 0 : oldStr.components(separatedBy: "\n").count
            let newLines = newStr.isEmpty ? 0 : newStr.components(separatedBy: "\n").count
            let replaceAll = extractBoolField("replace_all")
            return ("Edit", path, newLines, oldLines, replaceAll)
        case "Write": return ("Write", path, nil, nil, false)
        case "Read": return ("Read", path, nil, nil, false)
        case "Bash":
            let cmd = extractField("command") ?? extractField("description") ?? ""
            return ("Bash", String(cmd.prefix(80)), nil, nil, false)
        case "Grep":
            let pattern = extractField("pattern") ?? ""
            let inPath = extractField("path").map { " in \(($0 as NSString).lastPathComponent)" } ?? ""
            return ("Grep", "\"\(pattern)\"\(inPath)", nil, nil, false)
        case "Glob":
            return ("Glob", extractField("pattern") ?? "", nil, nil, false)
        case "Agent":
            return ("Agent", extractField("description") ?? String((extractField("prompt") ?? "").prefix(60)), nil, nil, false)
        case "WebFetch":
            let url = extractField("url") ?? ""
            let short = URL(string: url)?.host ?? url.prefix(60).description
            return ("WebFetch", short, nil, nil, false)
        case "WebSearch":
            return ("WebSearch", extractField("query") ?? "", nil, nil, false)
        default:
            return (name, "", nil, nil, false)
        }
    }

    private func extractField(_ key: String) -> String? {
        guard let data = rawInputJSON,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let value = json[key] as? String else { return nil }
        return value
    }

    private func extractBoolField(_ key: String) -> Bool {
        guard let data = rawInputJSON,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let value = json[key] as? Bool else { return false }
        return value
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button { isExpanded.toggle() } label: {
                HStack(spacing: 5) {
                    let (action, target, additions, deletions, replaceAll) = parseSummary()
                    Text(action).fontWeight(.bold)
                    Text(target).lineLimit(1)
                    if let add = additions, let del = deletions {
                        Text("· \(replaceAll ? "all" : "1 edit")")
                            .foregroundStyle(.tertiary)
                        Text("+\(add)").foregroundStyle(Color(red: 0.2, green: 0.65, blue: 0.3))
                        Text("-\(del)").foregroundStyle(Color(red: 0.85, green: 0.25, blue: 0.25))
                    }
                    if resultText != nil || rawInputJSON != nil {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 10))
                            .rotationEffect(.degrees(isExpanded ? 90 : 0))
                            .foregroundStyle(.tertiary)
                    }
                }
                .font(.app(.callout))
                .foregroundStyle(.primary)
                .padding(.trailing, 8)
                .padding(.vertical, 7)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if isExpanded {
                expandedContent
                    .padding(.horizontal, 8)
                    .padding(.leading, 0)
                    .padding(.bottom, 8)
                    .frame(maxWidth: chatMaxWidth)
            }
        }
        .background {
            if showBackground {
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.primary.opacity(0.04))
                    .padding(.leading, -8)
            }
        }
    }

    @ViewBuilder
    private var expandedContent: some View {
        VStack(alignment: .leading, spacing: 6) {
            if name == "Edit", let data = rawInputJSON,
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                let oldStr = json["old_string"] as? String ?? ""
                let newStr = json["new_string"] as? String ?? ""
                if !oldStr.isEmpty || !newStr.isEmpty {
                    SimpleDiffView(
                        oldText: oldStr,
                        newText: newStr,
                        filePath: extractField("file_path") ?? ""
                    )
                }
            }

            if name == "Bash", let cmd = extractField("command") {
                Text(cmd)
                    .font(.system(.caption, design: .monospaced))
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color(white: 0.12), in: RoundedRectangle(cornerRadius: 6))
                    .foregroundStyle(.white)
            }

            if let result = resultText, !result.isEmpty {
                Text(result)
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(20)
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.primary.opacity(0.03), in: RoundedRectangle(cornerRadius: 6))
            }
        }
    }
}

// MARK: - Simple Diff View (always dark theme)

struct SimpleDiffView: View {
    let oldText: String
    let newText: String
    let filePath: String

    private var diffLines: [(text: String, isAdded: Bool, isRemoved: Bool)] {
        var result: [(String, Bool, Bool)] = []
        for line in oldText.components(separatedBy: "\n") { result.append((line, false, true)) }
        for line in newText.components(separatedBy: "\n") { result.append((line, true, false)) }
        return result
    }

    private var addedCount: Int { newText.isEmpty ? 0 : newText.components(separatedBy: "\n").count }
    private var removedCount: Int { oldText.isEmpty ? 0 : oldText.components(separatedBy: "\n").count }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Dark header
            HStack {
                Text((filePath as NSString).lastPathComponent)
                    .font(.system(.caption, design: .monospaced))
                    .fontWeight(.medium)
                    .foregroundStyle(.white.opacity(0.9))
                Spacer()
                Text("+\(addedCount) -\(removedCount)")
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.5))
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(Color(white: 0.18))

            // Diff lines on dark background
            VStack(alignment: .leading, spacing: 0) {
                ForEach(diffLines.indices, id: \.self) { i in
                    let line = diffLines[i]
                    Text((line.isRemoved ? "- " : "+ ") + line.text)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(line.isRemoved ? Color(red: 1, green: 0.4, blue: 0.4) : Color(red: 0.4, green: 0.9, blue: 0.4))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 1)
                        .background(line.isRemoved ? Color.red.opacity(0.12) : Color.green.opacity(0.1))
                }
            }
            .background(Color(white: 0.1))
        }
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}

// MARK: - Thinking Card

struct ThinkingCard: View {
    let text: String
    @State private var isExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button { isExpanded.toggle() } label: {
                HStack(spacing: 4) {
                    Text("Thought").fontWeight(.bold)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 10))
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                }
                .font(.app(.callout))
                .foregroundStyle(.tertiary)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if isExpanded {
                Text(text)
                    .font(.app(.caption))
                    .foregroundStyle(.secondary)
                    .padding(.top, 4)
                    .textSelection(.enabled)
            }
        }
    }
}

// MARK: - Plan Mode Exit Card

struct PlanModeExitCard: View {
    let plan: String
    let resultText: String?
    var onAnswer: ((String) -> Void)?
    @State private var isExpanded = false

    private var isAnswered: Bool { resultText != nil }

    private var approvalStatus: String? {
        guard let r = resultText else { return nil }
        if r.contains("approved") { return "Approved" }
        if r.contains("rejected") || r.contains("doesn't want") { return "Rejected" }
        return nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button { isExpanded.toggle() } label: {
                HStack(spacing: 5) {
                    Text("Plan").fontWeight(.bold)
                    if let status = approvalStatus {
                        Text(status)
                            .font(.app(.caption))
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(
                                status == "Approved"
                                    ? Color.green.opacity(0.15)
                                    : Color.red.opacity(0.15),
                                in: Capsule()
                            )
                            .foregroundStyle(status == "Approved" ? .green : .red)
                    } else if !isAnswered {
                        Text("Awaiting approval")
                            .font(.app(.caption))
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(Color.orange.opacity(0.15), in: Capsule())
                            .foregroundStyle(.orange)
                    }
                    Image(systemName: "chevron.right")
                        .font(.system(size: 10))
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                        .foregroundStyle(.tertiary)
                }
                .font(.app(.callout))
                .foregroundStyle(.primary)
                .padding(.horizontal, 8)
                .padding(.vertical, 7)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if isExpanded {
                Markdown(plan)
                    .markdownTheme(chatMarkdownTheme)
                    .textSelection(.enabled)
                    .padding(.horizontal, 8)
                    .padding(.bottom, 4)
            }

            // Interactive approval when waiting
            if !isAnswered {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(Array(planOptions.enumerated()), id: \.offset) { idx, option in
                        Button {
                            onAnswer?(String(idx + 1))
                        } label: {
                            HStack(spacing: 8) {
                                Text("\(idx + 1).")
                                    .foregroundStyle(.secondary)
                                    .frame(width: 20, alignment: .trailing)
                                Text(option)
                            }
                            .font(.app(.callout))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(8)
                            .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.03)))
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 8)
                .padding(.bottom, 8)
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.primary.opacity(0.04))
                .padding(.leading, -8)
        )
    }

    private var planOptions: [String] {
        ["Yes, clear context and bypass permissions",
         "Yes, and bypass permissions",
         "Yes, manually approve edits"]
    }
}

// MARK: - Agent Call Card

struct AgentCallCard: View {
    let description: String
    let subagentType: String?
    let resultText: String?
    let rawInputJSON: Data?
    @State private var isExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button { isExpanded.toggle() } label: {
                HStack(spacing: 5) {
                    Text("Agent").fontWeight(.bold)
                    if let type = subagentType {
                        Text(type)
                            .font(.app(.caption))
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(Color.accentColor.opacity(0.15), in: Capsule())
                    }
                    Text(description).lineLimit(1)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 10))
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                        .foregroundStyle(.tertiary)
                }
                .font(.app(.callout))
                .foregroundStyle(.primary)
                .padding(.horizontal, 8)
                .padding(.vertical, 7)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if isExpanded, let result = resultText, !result.isEmpty {
                Text(result)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .lineLimit(30)
                    .textSelection(.enabled)
                    .padding(.horizontal, 8)
                    .padding(.bottom, 8)
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.primary.opacity(0.04))
                .padding(.leading, -8)
        )
    }
}

// MARK: - Ask User Question Card

struct AskUserQuestionCard: View {
    let questions: [AskQuestion]
    let resultText: String?
    var onAnswer: ((String) -> Void)?

    private var isAnswered: Bool { resultText != nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(questions.indices, id: \.self) { i in
                questionView(questions[i])
            }

            if !isAnswered {
                Text("Waiting for response...")
                    .font(.app(.caption))
                    .italic()
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color.accentColor.opacity(0.04))
                .strokeBorder(Color.accentColor.opacity(0.12), lineWidth: 1)
        )
    }

    @ViewBuilder
    private func questionView(_ q: AskQuestion) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            if let header = q.header {
                Text(header)
                    .font(.app(.callout))
                    .fontWeight(.semibold)
            }
            Text(q.question)
                .font(.app(.body))

            ForEach(q.options.indices, id: \.self) { idx in
                let option = q.options[idx]
                let isSelected = isAnswered && (resultText?.contains(option.label) == true)

                Button {
                    if !isAnswered {
                        onAnswer?(option.label)
                    }
                } label: {
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                            .foregroundStyle(isSelected ? Color.accentColor : .secondary)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(option.label).fontWeight(.medium)
                            if let desc = option.description {
                                Text(desc)
                                    .foregroundStyle(.secondary)
                                    .font(.app(.caption))
                            }
                        }
                    }
                    .font(.app(.body))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
                    .background(
                        RoundedRectangle(cornerRadius: 8)
                            .fill(isSelected ? Color.accentColor.opacity(0.1) : Color.primary.opacity(0.03))
                    )
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(isAnswered)
                .opacity(isAnswered && !isSelected ? 0.4 : 1)
            }
        }
    }
}

// MARK: - Working Indicator

struct WorkingIndicator: View {
    let assistant: CodingAssistant

    var body: some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.small)
            Text("\(assistant.displayName) is working...")
                .font(.app(.callout))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 8)
    }
}

// MARK: - Chat Input Bar

struct ChatInputBar: View {
    let assistant: CodingAssistant
    let isReady: Bool
    var cardId: String = ""
    var onSend: (String, [String]) -> Void = { _, _ in }
    var onQueuePrompt: ((String, Bool, [String]) -> Void)?

    @Binding var text: String
    @Binding var pastedImages: [Data]
    @FocusState private var isFocused: Bool
    @State private var showQueueDialog = false

    private var canSend: Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        VStack(spacing: 6) {
            // Image chips
            if !pastedImages.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(pastedImages.indices, id: \.self) { i in
                            if let nsImage = NSImage(data: pastedImages[i]) {
                                ZStack(alignment: .topTrailing) {
                                    Image(nsImage: nsImage)
                                        .resizable()
                                        .aspectRatio(contentMode: .fill)
                                        .frame(width: 48, height: 48)
                                        .clipShape(RoundedRectangle(cornerRadius: 6))

                                    Button {
                                        pastedImages.remove(at: i)
                                    } label: {
                                        Image(systemName: "xmark.circle.fill")
                                            .font(.system(size: 14))
                                            .foregroundStyle(.white)
                                            .shadow(radius: 2)
                                    }
                                    .buttonStyle(.plain)
                                    .offset(x: 4, y: -4)
                                }
                            }
                        }
                    }
                    .padding(.horizontal, 16)
                }
            }

            ZStack(alignment: .bottomTrailing) {
                PromptEditor(
                    text: $text,
                    font: .systemFont(ofSize: 13),
                    placeholder: "Message \(assistant.displayName)...",
                    maxHeight: 160,
                    identity: cardId,
                    onSubmit: send,
                    onCmdSubmit: onQueuePrompt != nil ? { showQueueDialog = true } : nil,
                    onImagePaste: { data in pastedImages.append(data) }
                )
                .focused($isFocused)
                .frame(minHeight: 24)
                .fixedSize(horizontal: false, vertical: true)
                // Extra bottom padding so text never overlaps the floating buttons
                .padding(.bottom, 4)

                HStack(alignment: .center, spacing: 12) {
                    if onQueuePrompt != nil {
                        Button { showQueueDialog = true } label: {
                            Image(systemName: "text.badge.plus")
                                .font(.system(size: 18))
                                .foregroundStyle(canSend ? Color.primary.opacity(0.5) : Color.primary.opacity(0.15))
                        }
                        .buttonStyle(.plain)
                        .disabled(!canSend)
                        .help("Queue prompt")
                    }

                    Button(action: send) {
                        Image(systemName: "arrow.up.circle.fill")
                            .font(.system(size: 28))
                            .foregroundStyle(canSend ? Color.primary : Color.primary.opacity(0.2))
                    }
                    .buttonStyle(.plain)
                    .disabled(!canSend)
                }
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: 22)
                    .strokeBorder(Color.primary.opacity(isFocused ? 0.25 : 0.12), lineWidth: 1)
                    .background(RoundedRectangle(cornerRadius: 22).fill(Color(.controlBackgroundColor)))
                    .shadow(color: .black.opacity(isFocused ? 0.12 : 0.08), radius: isFocused ? 10 : 6, y: isFocused ? 4 : 3)
            )
            .animation(.easeInOut(duration: 0.15), value: isFocused)
        }
        .frame(maxWidth: chatMaxWidth + 40)
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 16)
        .padding(.top, 1)
        .padding(.bottom, 12)
        .sheet(isPresented: $showQueueDialog) {
            let existingImages: [ImageAttachment] = pastedImages.compactMap { ImageAttachment(data: $0) }
            let prefill = QueuedPrompt(body: text, sendAutomatically: true, imagePaths: nil)
            QueuedPromptDialog(
                isPresented: $showQueueDialog,
                existingPrompt: prefill,
                existingImages: existingImages,
                assistant: assistant,
                onSave: { body, sendAuto, images in
                    let imagePaths: [String] = images.compactMap { img in
                        var mutable = img
                        return try? mutable.saveToPersistent()
                    }
                    onQueuePrompt?(body, sendAuto, imagePaths)
                    text = ""
                    pastedImages = []
                }
            )
        }
        .onAppear { focusInput() }
    }

    private func focusInput() {
        isFocused = true
    }

    private func send() {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        // Save images to temp files for the prompt queue
        var imagePaths: [String] = []
        for data in pastedImages {
            let path = NSTemporaryDirectory() + "kanban-chat-\(UUID().uuidString).png"
            try? data.write(to: URL(fileURLWithPath: path))
            imagePaths.append(path)
        }
        onSend(trimmed, imagePaths)
        text = ""
        pastedImages = []
    }
}

// MARK: - Markdown Detection

private extension String {
    /// Quick check for markdown syntax to avoid expensive Markdown() rendering for plain text.
    var containsMarkdown: Bool {
        contains("**") || contains("```") || contains("# ") ||
        contains("[") || contains("- ") || contains("> ")
    }
}

// MARK: - Custom MarkdownUI Theme

@MainActor
let chatMarkdownTheme: Theme = .gitHub.text {
    ForegroundColor(.primary)
    FontSize(13)
}
.heading1 { configuration in
    configuration.label
        .markdownTextStyle { FontSize(13); FontWeight(.bold) }
        .padding(.bottom, 2)
}
.heading2 { configuration in
    configuration.label
        .markdownTextStyle { FontSize(13); FontWeight(.semibold) }
        .padding(.bottom, 2)
}
.heading3 { configuration in
    configuration.label
        .markdownTextStyle { FontSize(13); FontWeight(.medium) }
        .padding(.bottom, 2)
}
