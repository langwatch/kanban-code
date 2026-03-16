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
    var onSendPrompt: (String, [String]) -> Void = { _, _ in }
    var onLoadMore: (() -> Void)?
    var onFork: (() -> Void)?
    var onCheckpoint: ((ConversationTurn) -> Void)?
    @Binding var draftText: String
    @Binding var draftImages: [Data]

    @State private var isBusyFromPane = false
    @State private var dismissedBusy = false
    @Binding var pendingMessage: String?

    /// Use pane output as ground truth, falling back to hook state only if no tmux session.
    private var isAssistantBusy: Bool {
        if dismissedBusy { return false }
        if tmuxSessionName != nil { return isBusyFromPane }
        return activityState == .activelyWorking
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
                    onCheckpoint: onCheckpoint
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
                onSend: { text, images in
                    pendingMessage = text
                    onSendPrompt(text, images)
                },
                text: $draftText,
                pastedImages: $draftImages
            )
        }
        .onChange(of: turns.count) {
            // Clear pending message when a new user turn arrives
            if let pending = pendingMessage {
                if turns.last(where: { $0.role == "user" })?.contentBlocks.contains(where: {
                    if case .text = $0.kind { return $0.text.contains(pending.prefix(50)) }
                    return false
                }) == true {
                    pendingMessage = nil
                }
            }
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
    var pendingMessage: String?
    var onLoadMore: (() -> Void)?
    var onFork: (() -> Void)?
    var onCheckpoint: ((ConversationTurn) -> Void)?

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

                    ForEach(turns, id: \.lineNumber) { turn in
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
                            onCheckpoint: onCheckpoint
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

                    // Optimistic pending message (sending...)
                    if let pending = pendingMessage {
                        HStack {
                            Spacer(minLength: 0)
                            HStack(spacing: 8) {
                                ProgressView()
                                    .controlSize(.small)
                                Text(pending)
                                    .font(.app(.body))
                            }
                            .padding(.horizontal, 14)
                            .padding(.vertical, 10)
                            .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 18))
                            .opacity(0.5)
                            .frame(maxWidth: userBubbleMaxWidth, alignment: .trailing)
                            .frame(maxWidth: chatMaxWidth, alignment: .trailing)
                            Spacer(minLength: 0)
                        }
                        .padding(.vertical, 4)
                        .id("pending")
                    }

                    // Bottom spacer for scroll anchor
                    Color.clear.frame(height: 8)
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
                    if newBusy != isBusyFromPane {
                        isBusyFromPane = newBusy
                    }
                    try? await Task.sleep(for: .seconds(5))
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
                case .toolUse: return true
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
            case .toolUse: return true
            case .toolResult: return false // shown inline under tool calls
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
        VStack(alignment: .leading, spacing: 6) {
            let pairedBlocks = pairToolResults()

            ForEach(pairedBlocks.indices, id: \.self) { i in
                let paired = pairedBlocks[i]
                switch paired.block.kind {
                case .text:
                    if paired.block.text.containsMarkdown {
                        Markdown(paired.block.text)
                            .markdownTheme(chatMarkdownTheme)
                            .textSelection(.enabled)
                    } else {
                        Text(paired.block.text)
                            .font(.system(size: 13))
                            .textSelection(.enabled)
                    }
                case .toolUse(let name, _, _):
                    ToolCallCard(
                        name: name,
                        displayText: paired.block.text,
                        rawInputJSON: paired.block.rawInputJSON,
                        resultText: paired.resultBlock?.text
                    )
                case .toolResult:
                    EmptyView() // results are shown inline under their tool call
                case .thinking:
                    ThinkingCard(text: paired.block.text)
                }
            }
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
            if case .toolUse(_, _, let id) = block.kind, let useId = id {
                if let result = toolResultMap[useId] {
                    paired[i].resultBlock = result
                }
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
    @State private var isExpanded = false

    nonisolated static func == (lhs: ToolCallCard, rhs: ToolCallCard) -> Bool {
        lhs.name == rhs.name && lhs.displayText == rhs.displayText && lhs.rawInputJSON == rhs.rawInputJSON
    }

    private func parseSummary() -> (action: String, target: String) {
        let path = extractField("file_path").map { ($0 as NSString).lastPathComponent } ?? ""
        switch name {
        case "Edit": return ("Edit", path)
        case "Write": return ("Write", path)
        case "Read": return ("Read", path)
        case "Bash":
            let cmd = extractField("command") ?? extractField("description") ?? ""
            return ("Bash", String(cmd.prefix(80)))
        case "Grep":
            let pattern = extractField("pattern") ?? ""
            let inPath = extractField("path").map { " in \(($0 as NSString).lastPathComponent)" } ?? ""
            return ("Grep", "\"\(pattern)\"\(inPath)")
        case "Glob":
            return ("Glob", extractField("pattern") ?? "")
        case "Agent":
            return ("Agent", extractField("description") ?? String((extractField("prompt") ?? "").prefix(60)))
        default:
            return (name, "")
        }
    }

    private func extractField(_ key: String) -> String? {
        guard let data = rawInputJSON,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let value = json[key] as? String else { return nil }
        return value
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button { isExpanded.toggle() } label: {
                HStack(spacing: 5) {
                    let (action, target) = parseSummary()
                    Text(action).fontWeight(.bold)
                    Text(target).lineLimit(1)
                    if resultText != nil || rawInputJSON != nil {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 10))
                            .rotationEffect(.degrees(isExpanded ? 90 : 0))
                            .foregroundStyle(.tertiary)
                    }
                }
                .font(.app(.callout))
                .foregroundStyle(.primary)
                .padding(.horizontal, 8)
                .padding(.leading, 0)
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
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.primary.opacity(0.04))
                .padding(.leading, -8)
        )
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
    var onSend: (String, [String]) -> Void = { _, _ in }

    @Binding var text: String
    @Binding var pastedImages: [Data]
    @FocusState private var isFocused: Bool

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

            HStack(alignment: .bottom, spacing: 10) {
                PromptEditor(
                    text: $text,
                    font: .systemFont(ofSize: 13),
                    placeholder: "Message \(assistant.displayName)...",
                    maxHeight: 200,
                    onSubmit: send,
                    onImagePaste: { data in pastedImages.append(data) }
                )
                .focused($isFocused)
                .frame(minHeight: 24)
                .fixedSize(horizontal: false, vertical: true)

                Button(action: send) {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.system(size: 24))
                        .foregroundStyle(canSend ? Color.primary : Color.primary.opacity(0.2))
                }
                .buttonStyle(.plain)
                .disabled(!canSend)
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
