import SwiftUI
import KanbanCodeCore
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
    @Binding var expandedTextBlocks: Set<String>
    @State private var isHovered = false

    /// Max characters to render before truncating with "Show more".
    /// 4KB is enough for a long message without freezing SwiftUI layout.
    private static let textTruncationLimit = 4_000

    nonisolated static func == (lhs: ChatMessageView, rhs: ChatMessageView) -> Bool {
        lhs.turn.lineNumber == rhs.turn.lineNumber &&
        lhs.turn.contentBlocks.count == rhs.turn.contentBlocks.count &&
        lhs.isLastInGroup == rhs.isLastInGroup &&
        lhs.assistant == rhs.assistant &&
        lhs.highlightText == rhs.highlightText &&
        lhs.isCurrentMatch == rhs.isCurrentMatch &&
        lhs.sessionPath == rhs.sessionPath &&
        lhs.hasLastToolCall == rhs.hasLastToolCall
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

    private var isTaskNotification: Bool {
        turn.role == "user" && turn.contentBlocks.contains {
            if case .text = $0.kind { return $0.text.hasPrefix("✓ ") || $0.text.hasPrefix("⏳ ") }
            return false
        }
    }

    var body: some View {
        if hasContent {
            if isTaskNotification {
                // Task notification — centered system-style
                HStack {
                    Spacer(minLength: 0)
                    let text = turn.contentBlocks.first { if case .text = $0.kind { return true }; return false }?.text ?? ""
                    Text(text)
                        .font(.app(.caption))
                        .foregroundStyle(.tertiary)
                        .italic()
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
                            Text(block.text)
                                .font(.app(.caption))
                                .foregroundStyle(.secondary)
                                .italic()
                        } else if block.text.contains("[Request interrupted by user") {
                            Text(block.text)
                                .font(.app(.caption))
                                .italic()
                                .foregroundStyle(.secondary)
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
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(group.items.indices, id: \.self) { ti in
                            if ti > 0 { Divider().padding(.leading, 8) }
                            if case .toolUse(let name, _, _) = group.items[ti].paired.block.kind {
                                let isLast = hasLastToolCall && gi == groups.count - 1 && ti == group.items.count - 1
                                ToolCallCard(
                                    name: name,
                                    displayText: group.items[ti].paired.block.text,
                                    rawInputJSON: group.items[ti].paired.block.rawInputJSON,
                                    resultText: group.items[ti].paired.resultBlock?.text,
                                    showBackground: false,
                                    autoExpand: isLast
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
                truncatedTextBlock(trimmed, blockIndex: paired.index, font: .system(size: 13))
            }
        case .toolUse(let name, _, _):
            ToolCallCard(
                name: name,
                displayText: paired.block.text,
                rawInputJSON: paired.block.rawInputJSON,
                resultText: paired.resultBlock?.text,
                showBackground: !suppressBackground,
                autoExpand: hasLastToolCall && isLastBlock
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
            PlanModeExitCard(plan: plan, resultText: paired.resultBlock?.text, onAnswer: onSendAnswer, tmuxSessionName: tmuxSessionName)
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

    // MARK: - Large text truncation

    private func blockKey(_ blockIndex: Int) -> String {
        "\(turn.lineNumber)_\(blockIndex)"
    }

    private func isBlockExpanded(_ blockIndex: Int) -> Bool {
        expandedTextBlocks.contains(blockKey(blockIndex))
    }

    @ViewBuilder
    private func truncatedTextBlock(_ text: String, blockIndex: Int, font: Font) -> some View {
        let truncated = text.count > Self.textTruncationLimit && !isBlockExpanded(blockIndex)
        let display = truncated ? String(text.prefix(Self.textTruncationLimit)) : text
        if highlightText != nil {
            highlightedText(display)
                .font(font)
        } else if turn.role == "user" {
            Text(display)
                .font(font)
        } else {
            markdownText(display)
                .font(font)
                .lineSpacing(4)
        }
        if truncated {
            Button {
                expandedTextBlocks.insert(blockKey(blockIndex))
            } label: {
                Text("Show more (\(text.count / 1024)KB)")
                    .font(.app(.caption))
                    .foregroundStyle(Color.accentColor)
            }
            .buttonStyle(.plain)
        }
    }

    // MARK: - Markdown text rendering

    /// Renders markdown as native SwiftUI Text via AttributedString, enabling
    /// cross-paragraph and cross-bubble text selection. Falls back to plain text
    /// if markdown parsing fails.
    private func markdownText(_ text: String) -> Text {
        if let attributed = try? AttributedString(
            markdown: text,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        ) {
            return Text(attributed)
        }
        return Text(text)
    }

    // MARK: - Text highlighting for search

    private func highlightedText(_ text: String) -> Text {
        guard let query = highlightText?.lowercased(), !query.isEmpty else {
            return Text(text)
        }
        var attr = AttributedString(text)
        let lower = text.lowercased()
        var pos = lower.startIndex
        let hlBg: Color = isCurrentMatch ? .orange.opacity(0.4) : .yellow.opacity(0.3)
        while let range = lower.range(of: query, range: pos..<lower.endIndex) {
            let startOff = lower.distance(from: lower.startIndex, to: range.lowerBound)
            let endOff = lower.distance(from: lower.startIndex, to: range.upperBound)
            let chars = attr.characters
            let attrStart = chars.index(chars.startIndex, offsetBy: startOff)
            let attrEnd = chars.index(chars.startIndex, offsetBy: endOff)
            attr[attrStart..<attrEnd].backgroundColor = hlBg
            pos = range.upperBound
        }
        return Text(attr)
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
                loadedImage = nsImage
                // Show popover now that image is ready (if mouse is still over the chip)
                isHovering = true
            }
            isLoading = false
        }
    }
}

// MARK: - Markdown Detection

extension String {
    /// Quick check for markdown syntax to avoid expensive Markdown() rendering for plain text.
    var containsMarkdown: Bool {
        contains("**") || contains("```") || contains("# ") ||
        contains("[") || contains("- ") || contains("> ")
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
