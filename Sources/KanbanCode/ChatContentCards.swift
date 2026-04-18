import SwiftUI
import KanbanCodeCore
import MarkdownUI

// MARK: - Tool Call Card

struct ToolCallCard: View, Equatable {
    let name: String
    let displayText: String
    let rawInputJSON: Data?
    var resultText: String?
    var showBackground: Bool = true
    /// When true, the card starts expanded. Resets to false when user manually toggles.
    var autoExpand: Bool = false
    @State private var isExpanded = false
    @State private var userToggled = false

    nonisolated static func == (lhs: ToolCallCard, rhs: ToolCallCard) -> Bool {
        lhs.name == rhs.name && lhs.displayText == rhs.displayText && lhs.rawInputJSON == rhs.rawInputJSON && lhs.autoExpand == rhs.autoExpand
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
            Button {
                isExpanded.toggle()
                userToggled = true
                if isExpanded { NotificationCenter.default.post(name: .chatCardExpanded, object: nil) }
            } label: {
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
        .onChange(of: autoExpand) {
            if !userToggled {
                isExpanded = autoExpand
                if autoExpand { NotificationCenter.default.post(name: .chatCardExpanded, object: nil) }
            }
        }
        .onAppear {
            if autoExpand && !userToggled {
                isExpanded = true
                NotificationCenter.default.post(name: .chatCardExpanded, object: nil)
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
    private static let truncationLimit = 2_000
    @State private var isExpanded = false
    @State private var showFullText = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button { isExpanded.toggle(); if isExpanded { NotificationCenter.default.post(name: .chatCardExpanded, object: nil) } } label: {
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
                let truncated = !showFullText && text.count > Self.truncationLimit
                let display = truncated ? String(text.prefix(Self.truncationLimit)) : text
                Text(display)
                    .font(.app(.caption))
                    .foregroundStyle(.secondary)
                    .padding(.top, 4)
                    .textSelection(.enabled)
                if truncated {
                    Button {
                        showFullText = true
                    } label: {
                        Text("Show more (\(text.count / 1024)KB)")
                            .font(.app(.caption2))
                            .foregroundStyle(Color.accentColor)
                    }
                    .buttonStyle(.plain)
                    .padding(.top, 2)
                }
            }
        }
    }
}

// MARK: - Plan Mode Exit Card

struct PlanModeExitCard: View {
    let plan: String
    let resultText: String?
    var onAnswer: ((String) -> Void)?
    var tmuxSessionName: String?
    @State private var isExpanded = false
    @State private var selectedOption: Int?
    @State private var paneOptions: [String] = []
    @State private var didLoadOptions = false

    private var isAnswered: Bool { resultText != nil }

    private var approvalStatus: String? {
        guard let r = resultText else { return nil }
        if r.contains("approved") { return "Approved" }
        if r.contains("rejected") || r.contains("doesn't want") { return "Rejected" }
        return nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button { isExpanded.toggle(); if isExpanded { NotificationCenter.default.post(name: .chatCardExpanded, object: nil) } } label: {
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

            // Interactive approval — options read from tmux pane
            if !isAnswered && !paneOptions.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(Array(paneOptions.enumerated()), id: \.offset) { idx, option in
                        Button {
                            selectedOption = idx
                            onAnswer?(String(idx + 1))
                        } label: {
                            HStack(spacing: 8) {
                                if selectedOption == idx {
                                    ProgressView().controlSize(.mini)
                                        .frame(width: 20)
                                } else {
                                    Text("\(idx + 1).")
                                        .foregroundStyle(.secondary)
                                        .frame(width: 20, alignment: .trailing)
                                }
                                Text(option)
                            }
                            .font(.app(.callout))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(8)
                            .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.03)))
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .disabled(selectedOption != nil)
                    }
                }
                .padding(.horizontal, 8)
                .padding(.bottom, 8)
            } else if !isAnswered && !didLoadOptions {
                ProgressView().controlSize(.small)
                    .frame(maxWidth: .infinity)
                    .padding(8)
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.primary.opacity(0.04))
                .padding(.leading, -8)
        )
        .task {
            guard !isAnswered, let session = tmuxSessionName else {
                didLoadOptions = true
                return
            }
            // Poll the pane until we find options (they may appear with a slight delay)
            let tmux = TmuxAdapter()
            for attempt in 0..<10 {
                if let output = try? await tmux.capturePane(sessionName: session) {
                    let opts = PaneOutputParser.parsePlanOptions(from: output)
                    if !opts.isEmpty {
                        paneOptions = opts
                        didLoadOptions = true
                        KanbanCodeLog.info("plan", "Found \(opts.count) plan options on attempt \(attempt + 1)")
                        return
                    }
                    if attempt == 9 {
                        // Log last 500 chars of pane output for debugging
                        let tail = String(output.suffix(500))
                        KanbanCodeLog.info("plan", "No plan options found after 10 attempts. Pane tail: \(tail)")
                    }
                }
                try? await Task.sleep(for: .milliseconds(500))
            }
            didLoadOptions = true
        }
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
            Button { isExpanded.toggle(); if isExpanded { NotificationCenter.default.post(name: .chatCardExpanded, object: nil) } } label: {
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
                let isSelected: Bool = {
                    guard isAnswered, let result = resultText?.trimmingCharacters(in: .whitespacesAndNewlines) else { return false }
                    // Prefer exact match, fall back to contains for wrapped responses
                    return result == option.label || result.hasPrefix(option.label) || result.hasSuffix(option.label)
                }()

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

/// Visual style for `ChatInputBar`.
/// - `.card`: original chat-mode design used inside a card's chat drawer. Pill container
///   with shadow, floating bottom-right buttons (queue + send), context-usage donut,
///   message-history recall, Cmd+Enter queue dialog.
/// - `.irc`: compact single-row IRC-style composer used in channel / DM chat. No queued
///   prompts, no usage donut, no history recall. Expands vertically as the user types
///   newlines (shift+enter). Send button glued to the right of the editor. Image paste
///   still works.
enum ChatInputStyle {
    case card
    case irc
}

struct ChatInputBar: View {
    var style: ChatInputStyle = .card
    let assistant: CodingAssistant?
    let isReady: Bool
    var cardId: String = ""
    var placeholderOverride: String? = nil
    var contextUsage: ContextUsage?
    var userMessageHistory: [String] = [] // Most recent first
    /// Optional list of handles (without leading `@`) available for @-mention completion.
    /// Used only in `.irc` style; channels pass members, DMs pass the other party.
    var mentionCandidates: [String] = []
    var onSend: (String, [String]) -> Void = { _, _ in }
    var onQueuePrompt: ((String, Bool, [String]) -> Void)?
    var onEscape: (() -> Void)?

    @Binding var text: String
    @Binding var pastedImages: [Data]
    @FocusState private var isFocused: Bool
    @State private var showQueueDialog = false
    @State private var historyIndex: Int = -1 // -1 = current draft, 0 = last sent, 1 = second to last...
    @State private var savedDraft: String = "" // Draft text before history recall
    /// Active @mention query (the partial handle after the last `@`), or nil when
    /// the user is not currently typing a mention.
    @State private var mentionQuery: String? = nil

    private var canSend: Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var resolvedPlaceholder: String {
        if let p = placeholderOverride { return p }
        if let a = assistant { return "Message \(a.displayName)..." }
        return "Message"
    }

    @ViewBuilder
    var body: some View {
        switch style {
        case .card: cardBody
        case .irc:  ircBody
        }
    }

    // IRC: borderless editor + trailing send button inside a single invisible
    // container. Images (when pasted) stack above. No queue / donut / history.
    private var ircBody: some View {
        HStack(alignment: .bottom, spacing: 6) {
            VStack(spacing: 0) {
                if !pastedImages.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 6) {
                            ForEach(Array(pastedImages.enumerated()), id: \.element) { index, data in
                                ChatImageThumbnail(imageData: data) {
                                    pastedImages.remove(at: index)
                                }
                            }
                        }
                    }
                    .padding(.bottom, 4)
                }
                PromptEditor(
                    text: $text,
                    font: .systemFont(ofSize: 13),
                    placeholder: resolvedPlaceholder,
                    maxHeight: 160,
                    identity: cardId,
                    onSubmit: send,
                    onImagePaste: { data in pastedImages.append(data) },
                    onEscape: onEscape
                )
                .focused($isFocused)
                .frame(minHeight: 24)
                .fixedSize(horizontal: false, vertical: true)
            }
            Button(action: send) {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.system(size: 22))
                    .foregroundStyle(canSend ? Color.primary : Color.primary.opacity(0.2))
            }
            .buttonStyle(.plain)
            .disabled(!canSend)
        }
        .padding(10)
        .overlay(alignment: .bottomLeading) {
            if !mentionCandidates.isEmpty, let query = mentionQuery {
                let matches = Self.filteredMentionMatches(query: query, candidates: mentionCandidates)
                if !matches.isEmpty {
                    MentionSuggestionList(matches: matches) { handle in
                        insertMention(handle)
                    }
                    .offset(y: -4)
                    .alignmentGuide(.bottom) { $0[.top] }
                }
            }
        }
        .onChange(of: text) { _, newValue in
            mentionQuery = Self.activeMentionQuery(in: newValue)
        }
        .onAppear { focusInput() }
    }

    // Original card-chat composer (unchanged).
    private var cardBody: some View {
        VStack(spacing: 6) {
            ZStack(alignment: .bottomTrailing) {
                VStack(spacing: 0) {
                    // Image thumbnails inside the prompt box
                    if !pastedImages.isEmpty {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 6) {
                                ForEach(Array(pastedImages.enumerated()), id: \.element) { index, data in
                                    ChatImageThumbnail(imageData: data) {
                                        pastedImages.remove(at: index)
                                    }
                                }
                            }
                            .padding(.horizontal, 6)
                        }
                        .padding(.top, 6)
                        .padding(.bottom, 4)
                    }

                PromptEditor(
                    text: $text,
                    font: .systemFont(ofSize: 13),
                    placeholder: resolvedPlaceholder,
                    maxHeight: 160,
                    identity: cardId,
                    onSubmit: send,
                    onCmdSubmit: onQueuePrompt != nil ? { showQueueDialog = true } : nil,
                    onUpArrowAtStart: { recallHistoryUp() },
                    onDownArrowAtStart: { recallHistoryDown() },
                    onImagePaste: { data in pastedImages.append(data) },
                    onEscape: onEscape
                )
                .focused($isFocused)
                .frame(minHeight: 24)
                .fixedSize(horizontal: false, vertical: true)
                // Extra bottom padding so text never overlaps the floating buttons
                .padding(.bottom, 30)
                } // end VStack (images + editor)

                HStack(alignment: .center, spacing: 12) {
                    if let contextUsage {
                        ContextDonutView(usage: contextUsage)
                    }

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
                assistant: assistant ?? .claude,
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

    // MARK: - @-mention autocompletion

    /// Scan `text` for the last `@<partial>` token where the `@` is at the
    /// start of the string or preceded by whitespace, and return `<partial>`
    /// (empty string is fine — "@" alone opens the picker). Returns nil if
    /// the text isn't currently inside a mention token.
    /// Intentionally checks the trailing segment, which matches the typical
    /// "typing at the end" pattern; cursor-aware detection would need a
    /// PromptEditor callback and is not implemented in this minimal version.
    static func activeMentionQuery(in text: String) -> String? {
        guard let atIdx = text.lastIndex(of: "@") else { return nil }
        // Everything after @ must be handle-valid — no spaces, newlines, etc.
        let after = text[text.index(after: atIdx)...]
        for c in after where !(c.isLetter || c.isNumber || c == "_" || c == "-") {
            return nil
        }
        // @ must be at start-of-string or preceded by whitespace/punctuation
        if atIdx > text.startIndex {
            let prev = text[text.index(before: atIdx)]
            if !(prev.isWhitespace || prev.isPunctuation) { return nil }
        }
        return String(after)
    }

    static func filteredMentionMatches(query: String, candidates: [String]) -> [String] {
        let q = query.lowercased()
        if q.isEmpty { return candidates }
        return candidates.filter { $0.lowercased().hasPrefix(q) }
    }

    /// Replace the trailing `@<partial>` with `@<handle> ` and dismiss the picker.
    private func insertMention(_ handle: String) {
        guard let atIdx = text.lastIndex(of: "@") else { return }
        text = String(text[..<atIdx]) + "@\(handle) "
        mentionQuery = nil
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
        historyIndex = -1
        savedDraft = ""
    }

    private func recallHistoryUp() -> String? {
        let nextIndex = historyIndex + 1
        guard nextIndex < userMessageHistory.count else { return nil }
        if historyIndex == -1 { savedDraft = text }
        historyIndex = nextIndex
        return userMessageHistory[nextIndex]
    }

    private func recallHistoryDown() -> String? {
        guard historyIndex >= 0 else { return nil }
        historyIndex -= 1
        if historyIndex == -1 {
            return savedDraft
        }
        return userMessageHistory[historyIndex]
    }
}

// MARK: - @-mention suggestion list

/// Floating popover listing handles that match the current @-mention query.
/// Click-to-insert (no keyboard nav in this first pass).
struct MentionSuggestionList: View {
    let matches: [String]
    let onSelect: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(matches.prefix(6)), id: \.self) { handle in
                Button {
                    onSelect(handle)
                } label: {
                    HStack(spacing: 6) {
                        Text("@\(handle)")
                            .font(.app(.body))
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .background(Color.clear)
                .onHover { _ in /* hover highlight handled by system if needed */ }
            }
        }
        .frame(minWidth: 140, maxWidth: 260, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(Color(nsColor: .controlBackgroundColor))
                .shadow(radius: 4, y: 2)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(Color.primary.opacity(0.08), lineWidth: 0.5)
        )
    }
}

// MARK: - Context Usage Donut

struct ContextDonutView: View {
    let usage: ContextUsage
    @State private var isHovering = false

    private var fraction: Double { min(usage.usedPercentage / 100, 1.0) }

    private func formatTokens(_ count: Int) -> String {
        if count >= 1_000_000 { return String(format: "%.1fM", Double(count) / 1_000_000) }
        if count >= 1_000 { return String(format: "%.1fK", Double(count) / 1_000) }
        return "\(count)"
    }

    var body: some View {
        ZStack {
            Circle()
                .stroke(Color.primary.opacity(0.06), lineWidth: 2.5)
            Circle()
                .trim(from: 0, to: fraction)
                .stroke(Color.primary.opacity(0.25), style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
        .frame(width: 16, height: 16)
        .help("\(String(format: "%.0f", usage.usedPercentage))% context used")
        .onHover { isHovering = $0 }
        .popover(isPresented: $isHovering, arrowEdge: .top) {
            VStack(alignment: .leading, spacing: 4) {
                let currentTokens = Int(usage.usedPercentage / 100.0 * Double(usage.contextWindowSize))
                Text("\(String(format: "%.1f", usage.usedPercentage))% · \(formatTokens(currentTokens)) / \(formatTokens(usage.contextWindowSize)) context used")
                    .fontWeight(.medium)
                if let model = usage.model, !model.isEmpty {
                    Text(model)
                        .foregroundStyle(.secondary)
                }
                if let cost = usage.totalCostUsd, cost > 0 {
                    Text(String(format: "Cost: $%.2f", cost))
                        .foregroundStyle(.secondary)
                }
            }
            .font(.app(.caption))
            .padding(8)
        }
    }
}

// MARK: - Chat Image Thumbnail

struct ChatImageThumbnail: View {
    let imageData: Data
    let onRemove: () -> Void
    @State private var isHovering = false

    var body: some View {
        if let nsImage = NSImage(data: imageData) {
            ZStack(alignment: .topTrailing) {
                Image(nsImage: nsImage)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: 48, height: 48)
                    .clipShape(RoundedRectangle(cornerRadius: 6))

                Button(action: onRemove) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 14))
                        .foregroundStyle(.white)
                        .shadow(radius: 2)
                }
                .buttonStyle(.plain)
                .offset(x: 4, y: -4)
            }
            .onHover { isHovering = $0 }
            .popover(isPresented: $isHovering) {
                Image(nsImage: nsImage)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(maxWidth: 300, maxHeight: 300)
                    .padding(4)
            }
        }
    }
}
