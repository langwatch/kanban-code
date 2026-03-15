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

    @State private var isAtBottom = true
    @State private var hasNewMessages = false
    @State private var lastSeenCount = 0
    @State private var isBusyFromPane = false
    @State private var panePollTask: Task<Void, Never>?

    /// Use pane output as ground truth, falling back to hook state only if no tmux session.
    private var isAssistantBusy: Bool {
        if tmuxSessionName != nil { return isBusyFromPane }
        return activityState == .activelyWorking
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(spacing: 0) {
                        if hasMoreTurns {
                            ProgressView()
                                .controlSize(.small)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 8)
                                .onAppear { onLoadMore?() }
                        }

                        ForEach(turns, id: \.lineNumber) { turn in
                            ChatMessageView(
                                turn: turn,
                                assistant: assistant,
                                allTurns: turns,
                                onCopy: { text in
                                    NSPasteboard.general.clearContents()
                                    NSPasteboard.general.setString(text, forType: .string)
                                },
                                onFork: onFork,
                                onCheckpoint: onCheckpoint
                            )
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

                        if isAssistantBusy {
                            WorkingIndicator(assistant: assistant)
                                .frame(maxWidth: chatMaxWidth)
                                .frame(maxWidth: .infinity)
                                .id("working")
                        }
                    }
                    .padding(.horizontal, 16)
                }
                .defaultScrollAnchor(.bottom)
                .onChange(of: turns.count) {
                    if turns.count > lastSeenCount {
                        let isInitialLoad = lastSeenCount == 0
                        if isAtBottom || isInitialLoad {
                            let target = turns.last?.lineNumber
                            Task { @MainActor in
                                // Initial load needs a layout pass first
                                if isInitialLoad {
                                    try? await Task.sleep(for: .milliseconds(100))
                                }
                                if let target {
                                    proxy.scrollTo(target, anchor: .bottom)
                                }
                            }
                        } else {
                            hasNewMessages = true
                        }
                        lastSeenCount = turns.count
                    }
                }
                .onAppear {
                    lastSeenCount = turns.count
                    startPanePolling()
                }
                .overlay(alignment: .bottom) {
                    if hasNewMessages {
                        Button {
                            if let last = turns.last {
                                proxy.scrollTo(last.lineNumber, anchor: .bottom)
                            }
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

            // Input bar at bottom
            ChatInputBar(
                assistant: assistant,
                isReady: !isAssistantBusy,
                onSend: onSendPrompt,
                text: $draftText,
                pastedImages: $draftImages
            )
        }
    }

    private func startPanePolling() {
        panePollTask?.cancel()
        guard let session = tmuxSessionName else { return }
        panePollTask = Task {
            let tmux = TmuxAdapter()
            while !Task.isCancelled {
                do {
                    let output = try await tmux.capturePane(sessionName: session)
                    let ready = PaneOutputParser.isReady(output, assistant: assistant)
                    await MainActor.run { isBusyFromPane = !ready }
                } catch {
                    // Session might not exist yet
                }
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }
}

// MARK: - Chat Message View

struct ChatMessageView: View {
    let turn: ConversationTurn
    let assistant: CodingAssistant
    let allTurns: [ConversationTurn]
    var onCopy: ((String) -> Void)?
    var onFork: (() -> Void)?
    var onCheckpoint: ((ConversationTurn) -> Void)?
    @State private var isHovered = false

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

    /// Whether this is the last turn before the next *visible* turn of a different role.
    /// Skips hidden user turns (e.g. turns with only tool_result blocks).
    private var isLastInGroup: Bool {
        guard let idx = allTurns.firstIndex(where: { $0.lineNumber == turn.lineNumber }) else { return true }
        // Find the next turn that would actually be visible
        var nextIdx = allTurns.index(after: idx)
        while nextIdx < allTurns.endIndex {
            let next = allTurns[nextIdx]
            // Check if this turn would be visible (same logic as hasContent)
            let isVisible: Bool
            if next.role == "user" {
                isVisible = next.contentBlocks.contains {
                    if case .text = $0.kind { return !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
                    return false
                }
            } else {
                isVisible = next.contentBlocks.contains { block in
                    switch block.kind {
                    case .text: return !block.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    case .toolUse: return true
                    case .toolResult: return false
                    case .thinking: return !block.text.isEmpty
                    }
                }
            }
            if isVisible { return next.role != turn.role }
            nextIdx = allTurns.index(after: nextIdx)
        }
        return true // last visible turn overall
    }

    /// Collect all text from consecutive same-role turns ending at this turn.
    private var groupText: String {
        guard let idx = allTurns.firstIndex(where: { $0.lineNumber == turn.lineNumber }) else { return "" }
        var texts: [String] = []
        var i = idx
        while i >= allTurns.startIndex && allTurns[i].role == turn.role {
            let turnTexts = allTurns[i].contentBlocks
                .filter { if case .text = $0.kind { return true }; return false }
                .map(\.text)
            texts.insert(contentsOf: turnTexts, at: 0)
            if i == allTurns.startIndex { break }
            i = allTurns.index(before: i)
        }
        return texts.joined(separator: "\n\n")
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
                Spacer(minLength: 0)
            }
            .onHover { isHovered = $0 }
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

        if let nextTurn = allTurns.first(where: { $0.index == turn.index + 1 && $0.role == "user" }) {
            let results = nextTurn.contentBlocks.filter {
                if case .toolResult = $0.kind { return true }
                return false
            }
            for result in results {
                if case .toolResult(_, let toolUseId) = result.kind, let useId = toolUseId {
                    if let idx = paired.firstIndex(where: {
                        if case .toolUse(_, _, let id) = $0.block.kind { return id == useId }
                        return false
                    }) {
                        paired[idx].resultBlock = result
                    }
                }
            }
        }

        return paired
    }

    // MARK: Actions (below message, visible on hover)

    private var messageActions: some View {
        HStack(spacing: 8) {
            Button {
                onCopy?(groupText)
            } label: {
                Image(systemName: "doc.on.doc")
                    .font(.system(size: 11))
            }
            .buttonStyle(.borderless)
            .help("Copy text")

            if let onCheckpoint {
                Button { onCheckpoint(turn) } label: {
                    Image(systemName: "clock.arrow.circlepath")
                        .font(.system(size: 11))
                }
                .buttonStyle(.borderless)
                .help("Checkpoint")
            }

            if let onFork {
                Button { onFork() } label: {
                    Image(systemName: "arrow.branch")
                        .font(.system(size: 11))
                }
                .buttonStyle(.borderless)
                .help("Fork")
            }
        }
        .foregroundStyle(.secondary)
        .opacity(isHovered ? 1 : 0)
        // Always takes space (height) even when invisible
        .frame(height: 20)
    }
}

// MARK: - Tool Call Card

struct ToolCallCard: View {
    let name: String
    let displayText: String
    let rawInputJSON: Data?
    var resultText: String?
    @State private var isExpanded = false

    private func parseSummary() -> (action: String, target: String) {
        let path = extractField("file_path").map { ($0 as NSString).lastPathComponent } ?? ""
        switch name {
        case "Edit": return ("Edited", path)
        case "Write": return ("Created", path)
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
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if isExpanded {
                expandedContent
                    .padding(.horizontal, 10)
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
        .frame(maxWidth: chatMaxWidth + 80)
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
        contains("#") || contains("**") || contains("*") || contains("`") ||
        contains("[") || contains("- ") || contains("1. ") || contains("> ")
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
