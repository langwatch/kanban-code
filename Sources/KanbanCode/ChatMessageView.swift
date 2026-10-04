import SwiftUI
import KanbanCodeCore
import KanbanCodeRemoteKit
import MarkdownUI

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
    var highlightText: String? = nil
    var isCurrentMatch: Bool = false
    var sessionPath: String?
    var tmuxSessionName: String?
    var hasLastToolCall: Bool = false
    var githubBaseURL: String?
    /// Whether a run of tool calls in this message is behind the conversation
    /// rather than the one being worked on.
    var toolRunIsFinished: Bool = false
    @Binding var expandedTextBlocks: Set<String>
    @Binding var expandedToolRuns: Set<String>
    @State private var isHovered = false
    @State private var showsCompactionSummary = false

    /// A row is worth building again only when what it shows has changed.
    ///
    /// The transcript is re-read whenever the file grows, which during a run is
    /// several times a second, and every read hands the list a fresh array. Row
    /// by row the content is almost always the same one as before, and without
    /// this every one of them measures its text again to draw the same pixels.
    /// The callbacks are left out on purpose: they are rebuilt on every pass
    /// and never compare equal, and they close over the same turn this compares.
    nonisolated static func == (lhs: ChatMessageView, rhs: ChatMessageView) -> Bool {
        lhs.turn == rhs.turn
            && lhs.assistant == rhs.assistant
            && lhs.toolResultMap == rhs.toolResultMap
            && lhs.isLastInGroup == rhs.isLastInGroup
            && lhs.suppressBackground == rhs.suppressBackground
            && lhs.highlightText == rhs.highlightText
            && lhs.isCurrentMatch == rhs.isCurrentMatch
            && lhs.sessionPath == rhs.sessionPath
            && lhs.tmuxSessionName == rhs.tmuxSessionName
            && lhs.hasLastToolCall == rhs.hasLastToolCall
            && lhs.githubBaseURL == rhs.githubBaseURL
            && lhs.toolRunIsFinished == rhs.toolRunIsFinished
            && lhs.expandedTextBlocks == rhs.expandedTextBlocks
            && lhs.expandedToolRuns == rhs.expandedToolRuns
    }

    /// Max characters to render before truncating with "Show more".
    /// 4KB is enough for a long message without freezing SwiftUI layout.
    private static let textTruncationLimit = 4_000

    /// Text content of this turn for copy.
    private var turnText: String {
        return turn.contentBlocks
            .filter { if case .text = $0.kind { return true }; return false }
            .map(\.text).joined(separator: "\n")
    }

    /// The note this turn is when the harness wrote it: a compaction
    /// summary or the `/compact` command.
    private var harnessNote: HarnessNote? {
        turn.role == "user" ? HarnessNote.classify(turnText) : nil
    }

    private var isTaskNotification: Bool {
        turn.role == "user" && turn.contentBlocks.contains {
            if case .text = $0.kind { return $0.text.hasPrefix("✓ ") || $0.text.hasPrefix("⏳ ") }
            return false
        }
    }

    /// Whether this turn has visible content (used by ChatView to skip empty
    /// turns in ForEach). The rule lives in Core so the count on a collapsed
    /// range is the count of rows expanding it draws.
    static func turnHasContent(_ turn: ConversationTurn) -> Bool {
        turn.hasVisibleChatContent
    }

    var body: some View {
        RenderDiagnostics.measureView(
            "ChatMessageView.body",
            thresholdMs: 8,
            metadata: "role=\(turn.role) blocks=\(turn.contentBlocks.count) line=\(turn.lineNumber)"
        ) {
            if isTaskNotification {
                // Task notification — centered system-style
                HStack {
                    Spacer(minLength: 0)
                    let text = turn.contentBlocks.first { if case .text = $0.kind { return true }; return false }?.text ?? ""
                    truncatedSystemText(text, blockIndex: 0, color: .tertiaryLabelColor)
                        // Held to the same column as every other row. A long
                        // notification is still a message, and reading one that
                        // runs the full width of the window means tracking back
                        // across text nothing else crosses.
                        .frame(maxWidth: chatMaxWidth, alignment: .leading)
                    Spacer(minLength: 0)
                }
            } else if let note = harnessNote {
                HStack {
                    Spacer(minLength: 0)
                    harnessNoteView(note)
                        .frame(maxWidth: chatMaxWidth, alignment: .center)
                    Spacer(minLength: 0)
                }
            } else if suppressBackground {
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

    // MARK: Harness note

    /// A centered line; a compaction opens to its summary.
    @ViewBuilder
    private func harnessNoteView(_ note: HarnessNote) -> some View {
        switch note {
        case .compactCommand:
            Text(note.title)
                .font(.app(.caption))
                .foregroundStyle(.tertiary)
        case .compactionSummary:
            VStack(alignment: .center, spacing: 6) {
                Button {
                    showsCompactionSummary.toggle()
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "arrow.down.right.and.arrow.up.left")
                        Text(note.title)
                        Image(systemName: showsCompactionSummary ? "chevron.up" : "chevron.down")
                    }
                    .font(.app(.caption))
                    .foregroundStyle(.secondary)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(showsCompactionSummary ? "Hide the summary" : "Show the summary the session continues from")
                if showsCompactionSummary {
                    truncatedSystemText(turnText, blockIndex: 0, color: .secondaryLabelColor)
                        .frame(maxWidth: .infinity, alignment: .leading)
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
            // Image attachment chips with on-demand hover preview
            if turn.imageCount > 0 {
                HStack(spacing: 4) {
                    ForEach(0..<turn.imageCount, id: \.self) { i in
                        LazyImageChip(
                            index: i,
                            sessionPath: sessionPath,
                            byteOffset: turn.lineNumber
                        )
                    }
                }
            }
            // Text bubble
            VStack(alignment: .trailing, spacing: 4) {
                ForEach(turn.contentBlocks.indices, id: \.self) { i in
                    let block = turn.contentBlocks[i]
                    if case .text = block.kind {
                        if block.text.hasPrefix("✓ ") || block.text.hasPrefix("⏳ ") {
                            // Task notification — render as system-style message
                            truncatedSystemText(block.text, blockIndex: i, color: .secondaryLabelColor)
                        } else if block.text.contains("[Request interrupted by user") {
                            truncatedSystemText(block.text, blockIndex: i, color: .secondaryLabelColor)
                        } else {
                            truncatedTextBlock(block.text, blockIndex: i, font: .app(.body))
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
                    let runKey = "grp:\(turn.lineNumber):\(gi)"
                    let runIsOpen = expandedToolRuns.contains(runKey)
                    let collapses = CollapsedToolRunCard.collapses(
                        callCount: group.items.count,
                        isNewestRun: !toolRunIsFinished,
                        holdsSearchMatch: isCurrentMatch
                    )
                    VStack(alignment: .leading, spacing: 0) {
                        if collapses {
                            CollapsedToolRunCard(count: group.items.count, isExpanded: runIsOpen) {
                                if runIsOpen {
                                    expandedToolRuns.remove(runKey)
                                } else {
                                    expandedToolRuns.insert(runKey)
                                }
                            }
                        }
                        if !collapses || runIsOpen {
                        ForEach(group.items.indices, id: \.self) { ti in
                            if ti > 0 { Divider().padding(.leading, 8) }
                            if case .toolUse(let name, _, let toolUseId) = group.items[ti].paired.block.kind {
                                let isLast = hasLastToolCall && gi == groups.count - 1 && ti == group.items.count - 1
                                ToolCallCard(
                                    name: name,
                                    displayText: group.items[ti].paired.block.text,
                                    rawInputJSON: group.items[ti].paired.block.rawInputJSON,
                                    toolUseId: toolUseId,
                                    resultText: group.items[ti].paired.resultBlock?.text,
                                    showBackground: false,
                                    autoExpand: isLast,
                                    highlight: searchHighlight
                                )
                            }
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
                    let isLast = gi == groups.count - 1
                    blockView(group.items[0].paired, isLastBlock: isLast)
                }
            }
        }
    }

    @ViewBuilder
    private func blockView(_ paired: PairedBlock, isLastBlock: Bool = false) -> some View {
        switch paired.block.kind {
        case .text:
            let trimmed = paired.block.text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                truncatedTextBlock(trimmed, blockIndex: paired.index, font: .systemFont(ofSize: 13))
            }
        case .toolUse(let name, _, let toolUseId):
            ToolCallCard(
                name: name,
                displayText: paired.block.text,
                rawInputJSON: paired.block.rawInputJSON,
                toolUseId: toolUseId,
                resultText: paired.resultBlock?.text,
                showBackground: !suppressBackground,
                autoExpand: hasLastToolCall && isLastBlock,
                highlight: searchHighlight
            )
        case .toolResult:
            EmptyView()
        case .thinking:
            ThinkingCard(text: paired.block.text, highlight: searchHighlight)
        case .planModeEnter:
            Text("Entered plan mode")
                .font(.app(.caption))
                .italic()
                .foregroundStyle(.tertiary)
        case .planModeExit(let plan):
            PlanModeExitCard(plan: plan, resultText: paired.resultBlock?.text, onAnswer: onSendAnswer, tmuxSessionName: tmuxSessionName, highlight: searchHighlight)
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
                rawInputJSON: paired.block.rawInputJSON,
                highlight: searchHighlight
            )
        }
    }

    /// The search match to paint, shared by the message text and the cards.
    ///
    /// The scan matches on tool text as well as message text, so a card has to
    /// be able to show why the search stopped where it did.
    private var searchHighlight: ChatTextHighlight? {
        highlightText.map { .init(query: $0, isCurrentMatch: isCurrentMatch) }
    }

    // MARK: - Large text truncation

    private func blockKey(_ blockIndex: Int) -> String {
        "\(turn.lineNumber)_\(blockIndex)"
    }

    private func isBlockExpanded(_ blockIndex: Int) -> Bool {
        expandedTextBlocks.contains(blockKey(blockIndex))
    }

    /// Every text row goes through one text view, so a drag can run from one
    /// message into the next. Splitting these across different view types would
    /// break the selection at whichever rows took a different path.
    @ViewBuilder
    private func truncatedTextBlock(_ text: String, blockIndex: Int, font: NSFont) -> some View {
        let truncated = text.count > Self.textTruncationLimit && !isBlockExpanded(blockIndex)
        let rawDisplay = truncated ? String(text.prefix(Self.textTruncationLimit)) : text
        let display = (turn.role == "user" || highlightText != nil) ? rawDisplay : linkifyIssueRefs(rawDisplay)
        let content = textContent(display)
        ChatText(
            content: content,
            appearance: textAppearance(for: content, font: font),
            highlight: searchHighlight
        )
        if truncated {
            Button {
                expandedTextBlocks.insert(blockKey(blockIndex))
                NotificationCenter.default.post(name: .chatCardExpanded, object: nil)
            } label: {
                Text("Show more (\(text.count / 1024)KB)")
                    .font(.app(.caption))
                    .foregroundStyle(Color.accentColor)
                    .padding(.vertical, 4)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
        }
    }

    /// Which of the chat's text treatments a row takes.
    ///
    /// Search drops markdown entirely so matches can be highlighted over the
    /// raw text, and a message with no block syntax stays inline only, which
    /// leaves things like a leading dash as literal text.
    private func textContent(_ display: String) -> ChatTextContent {
        if highlightText != nil || turn.role == "user" { return .plain(display) }
        return display.containsBlockMarkdown ? .markdown(display) : .inlineMarkdown(display)
    }

    private func textAppearance(
        for content: ChatTextContent, font: NSFont
    ) -> ChatTextAppearance {
        // Only the inline path carries line spacing of its own; a markdown
        // message takes it from the theme, and the plain paths have none.
        let lineSpacing: CGFloat
        if case .inlineMarkdown = content { lineSpacing = 4 } else { lineSpacing = 0 }
        return .init(font: font, foregroundColor: .labelColor, lineSpacing: lineSpacing)
    }

    /// System-style rows (task notifications, interruptions) render raw text
    /// rather than markdown. They still need the same cap as everything else:
    /// a task notification can carry a whole transcript, and laying that out
    /// in one pass locks the view up.
    @ViewBuilder
    private func truncatedSystemText(
        _ text: String,
        blockIndex: Int,
        color: NSColor
    ) -> some View {
        let truncated = text.count > Self.textTruncationLimit && !isBlockExpanded(blockIndex)
        let display = truncated ? String(text.prefix(Self.textTruncationLimit)) : text
        VStack(alignment: .leading, spacing: 2) {
            ChatText(
                content: .plain(display),
                appearance: .init(
                    font: .app(.caption), foregroundColor: color, italic: true
                )
            )
            if truncated {
                Button {
                    expandedTextBlocks.insert(blockKey(blockIndex))
                } label: {
                    Text("Show more (\(text.count / 1024)KB)")
                        .font(.app(.caption))
                        .foregroundStyle(Color.accentColor)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.borderless)
            }
        }
    }

    // MARK: Pair tool results

    private struct PairedBlock {
        let index: Int
        let block: ContentBlock
        var resultBlock: ContentBlock?
    }

    private func pairToolResults() -> [PairedBlock] {
        var paired = turn.contentBlocks.enumerated().map { PairedBlock(index: $0.offset, block: $0.element) }

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

    private static let isoFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    private static let isoFormatterNoFrac: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()
    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "h:mm a"
        return f
    }()
    private static let dateTimeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "MMM d, h:mm a"
        return f
    }()

    private var formattedTimestamp: String? {
        guard let ts = turn.timestamp else { return nil }
        guard let date = Self.isoFormatter.date(from: ts)
                ?? Self.isoFormatterNoFrac.date(from: ts) else { return nil }
        if Calendar.current.isDateInToday(date) {
            return Self.timeFormatter.string(from: date)
        } else {
            return Self.dateTimeFormatter.string(from: date)
        }
    }

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

            if let ts = formattedTimestamp {
                Text(ts)
                    .font(.app(.caption2))
                    .foregroundStyle(.secondary)
            }
        }
        .opacity(isHovered ? 1 : 0)
        .frame(height: 20)
    }
}

// MARK: - Action Button (with hover/active feedback)

struct ActionButton: View {
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

// MARK: - Lazy Image Chip (loads on hover from JSONL)

/// Shows "Image #N" chip; loads the actual image from the JSONL on hover.
struct LazyImageChip: View {
    let index: Int
    let sessionPath: String?
    let byteOffset: Int

    @State private var isHovering = false
    @State private var loadedImage: NSImage?
    @State private var isLoading = false

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "photo")
                .font(.system(size: 12))
            Text("Image #\(index + 1)")
                .font(.app(.caption))
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Color.primary.opacity(0.06), in: Capsule())
        .foregroundStyle(.secondary)
        .onHover { hovering in
            if hovering && loadedImage == nil && !isLoading {
                loadImage()
            }
            if hovering && loadedImage != nil {
                isHovering = true
            }
            if !hovering {
                isHovering = false
            }
        }
        .popover(isPresented: Binding(
            get: { isHovering && loadedImage != nil },
            set: { if !$0 { isHovering = false } }
        )) {
            if let loadedImage {
                let size = loadedImage.size
                let scale = min(1.0, min(600.0 / max(size.width, 1), 400.0 / max(size.height, 1)))
                Image(nsImage: loadedImage)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(
                        width: size.width * scale,
                        height: size.height * scale
                    )
                    .padding(4)
            }
        }
    }

    private func loadImage() {
        guard let path = sessionPath else { return }
        isLoading = true
        Task {
            let images = try? await TranscriptReader.loadImagesAtOffset(from: path, byteOffset: byteOffset)
            if let data = images?[safe: index], let nsImage = NSImage(data: data) {
                if data.count >= 5 * 1024 * 1024 {
                    KanbanCodeLog.warn(
                        "memory-context",
                        "chat image decoded path=\((path as NSString).lastPathComponent) offset=\(byteOffset) index=\(index) bytes=\(data.count) points=\(Int(nsImage.size.width))x\(Int(nsImage.size.height))"
                    )
                }
                loadedImage = nsImage
                // Show popover now that image is ready (if mouse is still over the chip)
                isHovering = true
            }
            isLoading = false
        }
    }
}

// MARK: - GitHub Issue/PR Reference Linking

extension ChatMessageView {
    /// Regex matching owner/repo#123, repo#123 or bare #123 (not inside URLs or
    /// markdown links).
    private static let issueRefPattern: NSRegularExpression? = {
        try? NSRegularExpression(
            pattern: TerminalURLDetector.markdownIssueRefPattern, options: [])
    }()

    /// Convert GitHub issue/PR references in text to markdown links.
    /// `"see #123"` → `"see [#123](https://github.com/owner/repo/pull/123)"`
    /// `"langwatch/langwatch#2847"` → `"[langwatch/langwatch#2847](https://github.com/langwatch/langwatch/pull/2847)"`
    func linkifyIssueRefs(_ text: String) -> String {
        guard let regex = Self.issueRefPattern else { return text }
        let nsText = text as NSString
        let matches = regex.matches(in: text, range: NSRange(location: 0, length: nsText.length))
        guard !matches.isEmpty else { return text }

        var result = text
        // Process in reverse to preserve offsets
        for match in matches.reversed() {
            let ref = nsText.substring(with: match.range)
            guard
                let url = TerminalURLDetector.resolveIssueRef(ref, githubBaseURL: githubBaseURL)
            else { continue }
            let startIdx = text.index(text.startIndex, offsetBy: match.range.location)
            let endIdx = text.index(startIdx, offsetBy: match.range.length)
            result.replaceSubrange(startIdx..<endIdx, with: "[\(ref)](\(url))")
        }
        return result
    }
}

// MARK: - Markdown Detection

extension String {
    /// Quick check for markdown syntax to avoid expensive Markdown() rendering for plain text.
    var containsMarkdown: Bool {
        contains("**") || contains("```") || contains("# ") ||
        contains("[") || contains("- ") || contains("> ")
    }

    /// Check for block-level markdown that requires MarkdownUI (tables, code fences, headers).
    /// Inline-only content (bold, links) can use the lighter AttributedString renderer.
    var containsBlockMarkdown: Bool {
        contains("```") || contains("| ") || contains("# ") || contains("> ")
    }

    /// Check for lightweight inline markdown syntax. Keep this narrow so ordinary
    /// agent logs and handles don't pay the markdown parser cost.
    var containsInlineMarkdown: Bool {
        contains("**") || contains("`") || contains("[")
    }
}

// MARK: - Safe Array Subscript

extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
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
