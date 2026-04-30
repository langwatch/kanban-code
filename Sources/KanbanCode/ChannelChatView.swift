import SwiftUI
import AppKit
import KanbanCodeCore
import MarkdownUI

/// Last message's rendered height — used as the "near bottom" threshold so
/// images / tall messages don't prematurely turn off auto-scroll. Reported
/// via GeometryReader on whichever row is currently last.
private struct LastMessageHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 80
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

struct ChannelPullRequestReference: Identifiable, Equatable {
    let id: String
    let number: Int
    let url: URL?
    let status: PRStatus?
    let unresolvedThreads: Int
    let title: String?
    let handle: String
    let cardId: String
}

struct ChannelSearchQuery: Equatable {
    var bodyQuery: String
    var fromQuery: String?

    var isEmpty: Bool {
        bodyQuery.isEmpty && (fromQuery?.isEmpty ?? true)
    }

    static func parse(_ raw: String) -> ChannelSearchQuery {
        let tokens = raw.split(whereSeparator: \.isWhitespace).map(String.init)
        var bodyTokens: [String] = []
        var fromQuery: String?

        for token in tokens {
            let lower = token.lowercased()
            if lower.hasPrefix("from:@") {
                fromQuery = String(token.dropFirst("from:@".count))
            } else if lower.hasPrefix("from:") {
                fromQuery = String(token.dropFirst("from:".count))
                    .trimmingCharacters(in: CharacterSet(charactersIn: "@"))
            } else {
                bodyTokens.append(token)
            }
        }

        return ChannelSearchQuery(
            bodyQuery: bodyTokens.joined(separator: " "),
            fromQuery: fromQuery
        )
    }
}

// MARK: - Cmd+click URL helpers (shared by channel + DM chats)

/// Regex matching http(s) URLs. Stops at whitespace / common punctuation
/// closers so trailing `)` or `.` don't get captured as part of the URL.
private let chatURLRegex: NSRegularExpression? = {
    try? NSRegularExpression(pattern: "https?://[^\\s<>\"'\\])*]*[^\\s<>\"'\\]).,:;!?]")
}()

private let chatPullRequestRefRegex: NSRegularExpression? = {
    try? NSRegularExpression(
        pattern: #"(?<![&/a-zA-Z0-9\[(\]])(?:[a-zA-Z0-9_.-]+/[a-zA-Z0-9_.-]+)?#\d+(?![^\[]*\])"#,
        options: []
    )
}()

/// Apply `.link = url` attributes to every URL occurrence in `attr`. Only
/// called when the user is cmd+hovering the line — plain text otherwise so
/// `.textSelection` keeps working normally.
private func applyChatURLLinks(to attr: inout AttributedString, linkColor: Color = .init(red: 0.45, green: 0.65, blue: 1.0)) {
    guard let regex = chatURLRegex else { return }
    let text = String(attr.characters)
    let matches = regex.matches(in: text, range: NSRange(text.startIndex..., in: text))
    for match in matches {
        guard let range = Range(match.range, in: text),
              let url = URL(string: String(text[range])) else { continue }
        let startOff = text.distance(from: text.startIndex, to: range.lowerBound)
        let endOff = text.distance(from: text.startIndex, to: range.upperBound)
        let chars = attr.characters
        let attrStart = chars.index(chars.startIndex, offsetBy: startOff)
        let attrEnd = chars.index(chars.startIndex, offsetBy: endOff)
        attr[attrStart..<attrEnd].link = url
        attr[attrStart..<attrEnd].foregroundColor = linkColor
        attr[attrStart..<attrEnd].underlineStyle = .single
    }
}

private func applyChatPullRequestLinks(
    to attr: inout AttributedString,
    urlForNumber: (Int) -> URL?,
    linkColor: Color = .blue
) {
    guard let regex = chatPullRequestRefRegex else { return }
    let text = String(attr.characters)
    let nsText = text as NSString
    let matches = regex.matches(in: text, range: NSRange(location: 0, length: nsText.length))
    for match in matches {
        guard let textRange = Range(match.range, in: text) else { continue }
        let ref = nsText.substring(with: match.range)
        guard let hashIndex = ref.firstIndex(of: "#"),
              let number = Int(ref[ref.index(after: hashIndex)...]) else { continue }

        let prefix = String(ref[ref.startIndex..<hashIndex])
        let url: URL?
        if prefix.isEmpty {
            url = urlForNumber(number)
        } else {
            url = URL(string: "https://github.com/\(prefix)/pull/\(number)")
        }
        guard let url else { continue }

        let startOff = text.distance(from: text.startIndex, to: textRange.lowerBound)
        let endOff = text.distance(from: text.startIndex, to: textRange.upperBound)
        let chars = attr.characters
        let attrStart = chars.index(chars.startIndex, offsetBy: startOff)
        let attrEnd = chars.index(chars.startIndex, offsetBy: endOff)
        attr[attrStart..<attrEnd].link = url
        attr[attrStart..<attrEnd].foregroundColor = linkColor
        attr[attrStart..<attrEnd].underlineStyle = .single
    }
}

/// Render a chat message body with:
///   • Markdown — block-level constructs (headings, code fences, tables,
///     blockquotes) go through MarkdownUI so they actually render as such;
///     everything else uses the lighter AttributedString(markdown:) path so
///     text selection works smoothly across bubbles.
///   • URL linkification — cmd+hover over the line activates the links,
///     same UX as the rest of the app.
///   • Truncation — messages longer than `truncationLimit` get clipped to a
///     "Show more" button so one novel-length post can't dominate the
///     scrollback (same pattern as the card-detail chat view).
private struct ChatMessageBody: View {
    let text: String
    let isCmdHeld: Bool
    var urlForPullRequestNumber: (Int) -> URL? = { _ in nil }
    @State private var hovered = false
    @State private var expanded = false
    @State private var selectionEnabled = false
    @State private var selectionActivationToken = 0

    /// Chosen to match ChatMessageView.textTruncationLimit (4 KB). At the
    /// default font, that's roughly 50 lines — long enough that a normal
    /// reply is never clipped, short enough that a pasted design doc or
    /// LLM "thinking out loud" dump doesn't eat the whole scroll.
    private static let truncationLimit = 4_000
    private static let selectionRetentionSeconds: UInt64 = 10 * 60

    private var linksActive: Bool { isCmdHeld && hovered }
    private var isTruncated: Bool { text.count > Self.truncationLimit && !expanded }
    private var displayText: String {
        isTruncated ? String(text.prefix(Self.truncationLimit)) : text
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            messageContent
            if isTruncated {
                Button { expanded = true } label: {
                    Text("Show more (\(text.count / 1024) KB)")
                        .font(.app(.caption))
                        .foregroundStyle(Color.accentColor)
                        .padding(.vertical, 2)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.borderless)
                .help("Expand the full message")
            }
        }
        .onHover { isHovered in
            hovered = isHovered
            if isHovered { activateSelectionWindow() }
        }
    }

    @ViewBuilder
    private var messageContent: some View {
        if displayText.containsBlockMarkdown {
            if selectionEnabled {
                Markdown(displayText)
                    .markdownTheme(chatMarkdownTheme)
                    .textSelection(.enabled)
            } else {
                Markdown(displayText)
                    .markdownTheme(chatMarkdownTheme)
            }
        } else {
            if selectionEnabled {
                Text(inlineAttributed)
                    .font(.app(.body))
                    .textSelection(.enabled)
            } else {
                Text(inlineAttributed)
                    .font(.app(.body))
            }
        }
    }

    private func activateSelectionWindow() {
        selectionEnabled = true
        selectionActivationToken += 1
        let token = selectionActivationToken
        Task {
            try? await Task.sleep(nanoseconds: Self.selectionRetentionSeconds * 1_000_000_000)
            await MainActor.run {
                if selectionActivationToken == token && !hovered {
                    selectionEnabled = false
                }
            }
        }
    }

    /// Parse `displayText` as inline markdown (bold, italic, links, inline code)
    /// and layer our own cmd+hover URL linkification on top. Falls back to plain
    /// text if the parser chokes.
    private var inlineAttributed: AttributedString {
        let parsed = try? AttributedString(
            markdown: displayText,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        )
        var attr = parsed ?? AttributedString(displayText)
        applyChatPullRequestLinks(to: &attr, urlForNumber: urlForPullRequestNumber)
        if linksActive { applyChatURLLinks(to: &attr) }
        return attr
    }
}

/// Compact card-style tile representing a channel in kanban-board / list modes.
struct ChannelTile: View {
    let channel: Channel
    let onlineCount: Int
    let lastMessageAt: Date?
    let lastMessageBody: String?
    let isSelected: Bool
    let unreadCount: Int
    let onOpen: () -> Void
    var onDelete: (() -> Void)? = nil
    var onRename: (() -> Void)? = nil

    private var timestampText: String {
        guard let ts = lastMessageAt else { return "—" }
        let secs = Date().timeIntervalSince(ts)
        switch secs {
        case ..<60: return "just now"
        case ..<3600: return "\(Int(secs / 60))m ago"
        case ..<86400: return "\(Int(secs / 3600))h ago"
        default: return "\(Int(secs / 86400))d ago"
        }
    }

    private var hasUnread: Bool { unreadCount > 0 }

    var body: some View {
        Button(action: onOpen) {
            HStack(spacing: 8) {
                Image(systemName: "number")
                    .font(.app(.caption))
                    .foregroundStyle(hasUnread ? Color.accentColor : .secondary)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(channel.name)
                            .font(.app(.body, weight: hasUnread ? .bold : .medium))
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                        if hasUnread {
                            Text("\(unreadCount)")
                                .font(.app(.caption, weight: .bold))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 0.5)
                                .background(Capsule().fill(Color.accentColor))
                        }
                    }
                    if let preview = lastMessageBody, !preview.isEmpty {
                        Text(preview)
                            .font(.app(.caption))
                            .foregroundStyle(hasUnread ? .secondary : .tertiary)
                            .lineLimit(1)
                    } else {
                        Text("\(onlineCount)/\(channel.members.count) online")
                            .font(.app(.caption))
                            .foregroundStyle(.tertiary)
                    }
                }
                Spacer(minLength: 4)
                Text(timestampText)
                    .font(.app(.caption))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(isSelected ? Color.accentColor.opacity(0.12) : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu {
            if let onRename {
                Button { onRename() } label: {
                    Label("Rename #\(channel.name)", systemImage: "pencil")
                }
            }
            if let onDelete {
                Button(role: .destructive) {
                    onDelete()
                } label: {
                    Label("Delete #\(channel.name)", systemImage: "trash")
                }
            }
        }
    }
}

/// Slack-like full chat view for a single channel.
struct ChannelChatView: View {
    let channel: Channel
    let messages: [ChannelMessage]
    let onlineByHandle: [String: Bool]
    var onSend: (String, [String]) -> Void = { _, _ in }
    var onClose: () -> Void = {}
    var onCopyDMCommand: (ChannelMember) -> Void = { _ in }
    var onOpenDM: (ChannelMember) -> Void = { _ in }
    var onOpenCard: (String) -> Void = { _ in }
    var onOpenPullRequest: (URL) -> Void = { NSWorkspace.shared.open($0) }
    /// Right-click → "Remove @<handle> from #<channel>". Used to evict dead
    /// agents whose tmux session is gone so their slot frees up for a new
    /// link (no more `_2` handles on rejoin).
    var onKickMember: (ChannelMember) -> Void = { _ in }
    /// Optional map from handle → activity state (working/idle/needsAttention). Used to
    /// decorate each member chip with a status glyph.
    var activityByHandle: [String: ActivityState] = [:]
    /// The local user's handle (no cardId). Messages from this handle render with
    /// a distinct color + a full-width tinted row background so the user can
    /// spot their own messages at a glance.
    var myHandle: String = ""
    var pullRequests: [ChannelPullRequestReference] = []
    var pullRequestBaseURLsByCardId: [String: String] = [:]
    /// Two-way binding for the draft message. Held by the parent (store) so it
    /// survives drawer switches — avoids losing in-progress typing when the
    /// user jumps to another channel/card and comes back.
    @Binding var draft: String
    /// Optional share controller. When present, a globe button in the header
    /// opens the share dialog and an active share is shown as a banner
    /// below the header. When nil, all share UI is hidden.
    var shareController: ChannelShareController? = nil

    @State private var pastedImages: [Data] = []
    @State private var rosterExpanded = false
    @State private var isNearBottom: Bool = true
    @State private var unseenNewCount: Int = 0
    @State private var distanceFromBottom: CGFloat = 0
    @State private var isCmdHeld: Bool = false
    @State private var cmdMonitor: Any?
    @State private var lastMessageHeight: CGFloat = 80
    @State private var showingShareDialog: Bool = false
    @State private var showSearch = false
    @State private var searchText = ""
    @State private var activeQuery = ""
    @State private var searchMatchMessageIds: [String] = []
    @State private var currentMatchPosition = 0
    @State private var searchFromSelectedIndex = 0
    @State private var searchDebounceTask: Task<Void, Never>?
    @State private var retainedMessages: [ChannelMessage] = []
    @FocusState private var inputFocused: Bool
    @FocusState private var isSearchFieldFocused: Bool

    private static let retainedScrollbackLimit = 2_000

    private var displayedMessages: [ChannelMessage] {
        retainedMessages.isEmpty ? messages : retainedMessages
    }

    private var currentMatchMessageId: String? {
        guard showSearch, !searchMatchMessageIds.isEmpty,
              currentMatchPosition < searchMatchMessageIds.count else { return nil }
        return searchMatchMessageIds[currentMatchPosition]
    }

    private var activeSearchFromQuery: String? {
        Self.activeFromQuery(in: searchText)
    }

    private var searchFromMatches: [String] {
        guard let query = activeSearchFromQuery else { return [] }
        return Self.filteredFromHandles(
            query: query,
            candidates: searchHandleCandidates,
            myHandle: myHandle
        )
    }

    private var searchHandleCandidates: [String] {
        var seen: Set<String> = []
        var out: [String] = []
        func append(_ handle: String) {
            let trimmed = handle.trimmingCharacters(in: CharacterSet(charactersIn: "@").union(.whitespacesAndNewlines))
            guard !trimmed.isEmpty else { return }
            let key = trimmed.lowercased()
            guard seen.insert(key).inserted else { return }
            out.append(trimmed)
        }
        append("me")
        append(myHandle)
        for member in channel.members { append(member.handle) }
        for message in displayedMessages { append(message.from.handle) }
        return out
    }

    private var activelyWorkingMembers: [ChannelMember] {
        channel.members.filter { member in
            activityByHandle[member.handle] == .activelyWorking
        }
    }

    private var activelyWorkingMemberIds: [String] {
        activelyWorkingMembers.map(\.id)
    }

    var body: some View {
        ZStack(alignment: .top) {
            VStack(spacing: 0) {
                header
                shareBanner
                if rosterExpanded { rosterRow }
                Divider()
                messageList
                Divider()
                composer
            }
            if showSearch {
                channelSearchBar
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .background {
            Button("") {
                showSearch = true
                isSearchFieldFocused = true
            }
            .keyboardShortcut("f", modifiers: .command)
            .hidden()
        }
        .onAppear {
            cmdMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { event in
                let cmd = event.modifierFlags.contains(.command)
                if cmd != isCmdHeld { isCmdHeld = cmd }
                return event
            }
        }
        .onDisappear {
            searchDebounceTask?.cancel()
            if let m = cmdMonitor {
                NSEvent.removeMonitor(m)
                cmdMonitor = nil
            }
            isCmdHeld = false
        }
        .sheet(isPresented: $showingShareDialog) {
            ChannelShareDialog(
                isPresented: $showingShareDialog,
                channelName: channel.name
            ) { duration in
                guard let ctrl = shareController else { return }
                Task { _ = try? await ctrl.start(channel: channel.name, duration: duration) }
            }
        }
    }

    /// Banner directly beneath the header reflecting share state.
    @ViewBuilder
    private var shareBanner: some View {
        if let ctrl = shareController {
            switch ctrl.phase(for: channel.name) {
            case .idle:
                EmptyView()
            case .starting:
                ChannelShareStartingBanner()
            case .active(let share):
                ChannelShareBanner(share: share) {
                    // onCopy: optional toast hook could go here later.
                } onStop: {
                    Task { await ctrl.stop(channel: channel.name) }
                }
            case .failed(let message):
                ChannelShareFailedBanner(message: message) {
                    Task { await ctrl.stop(channel: channel.name) }
                }
            }
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "number")
                .foregroundStyle(.secondary)
            Text(channel.name)
                .font(.app(.title3, weight: .semibold))
            Text("·")
                .foregroundStyle(.tertiary)
            Button {
                withAnimation(.easeInOut(duration: 0.15)) { rosterExpanded.toggle() }
            } label: {
                HStack(spacing: 4) {
                    Circle().fill(Color.green).frame(width: 6, height: 6)
                        .opacity(onlineCountValue > 0 ? 1 : 0.3)
                    Text("\(onlineCountValue)/\(channel.members.count)")
                        .font(.app(.caption))
                        .foregroundStyle(.secondary)
                    Image(systemName: rosterExpanded ? "chevron.up" : "chevron.down")
                        .font(.app(.caption))
                        .foregroundStyle(.tertiary)
                }
            }
            .buttonStyle(.plain)
            .help("Show members")
            if !pullRequests.isEmpty {
                prStrip
            }
            Spacer()
            if shareController != nil {
                shareButton
            }
            Button(action: onClose) {
                Image(systemName: "xmark.circle.fill")
                    .font(.app(.body))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Close channel")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private var prStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(pullRequests) { ref in
                    Button {
                        if let url = ref.url {
                            onOpenPullRequest(url)
                        }
                    } label: {
                        PRBadge(
                            status: ref.status,
                            prNumber: ref.number,
                            unresolvedThreads: ref.unresolvedThreads
                        )
                    }
                    .buttonStyle(.plain)
                    .disabled(ref.url == nil)
                    .help(prHelp(ref))
                }
            }
        }
        .frame(maxWidth: 360)
    }

    private func prHelp(_ ref: ChannelPullRequestReference) -> String {
        var parts = ["PR #\(ref.number)", "@\(ref.handle)"]
        if let title = ref.title, !title.isEmpty {
            parts.append(title)
        }
        if ref.url == nil {
            parts.append("No GitHub URL recorded yet")
        }
        return parts.joined(separator: " - ")
    }

    /// Header action: start / manage a public share. Label + icon reflects state.
    @ViewBuilder
    private var shareButton: some View {
        let phase = shareController?.phase(for: channel.name) ?? .idle
        let isActive = { if case .active = phase { return true } else { return false } }()
        let isStarting = { if case .starting = phase { return true } else { return false } }()

        Button {
            if isActive {
                Task { await shareController?.stop(channel: channel.name) }
            } else if !isStarting {
                showingShareDialog = true
            }
        } label: {
            HStack(spacing: 4) {
                if isStarting {
                    ProgressView().controlSize(.mini)
                } else {
                    Image(systemName: "antenna.radiowaves.left.and.right")
                        .font(.app(.caption))
                }
                Text(isActive ? "Sharing" : "Live Share")
                    .font(.app(.caption, weight: .medium))
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .foregroundStyle(isActive ? Color.white : .primary)
            .background(
                Capsule()
                    .fill(isActive ? Color.green : Color.secondary.opacity(0.12))
            )
        }
        .buttonStyle(.plain)
        .disabled(isStarting)
        .help(isActive
              ? "Channel is publicly shared — click to stop"
              : "Share this channel via a public URL")
    }

    private var onlineCountValue: Int {
        channel.members.reduce(0) { acc, m in
            acc + ((onlineByHandle[m.handle] ?? false) ? 1 : 0)
        }
    }

    private var rosterRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(channel.members) { m in
                    memberChip(m)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 6)
        }
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.4))
    }

    private func memberChip(_ m: ChannelMember) -> some View {
        let online = onlineByHandle[m.handle] ?? false
        let activity = activityByHandle[m.handle]
        return HStack(spacing: 5) {
            Circle().fill(online ? Color.green : Color.secondary.opacity(0.35))
                .frame(width: 7, height: 7)
            if activity == .activelyWorking {
                ProgressView()
                    .controlSize(.mini)
                    .help("@\(m.handle) is actively working")
            } else if let glyph = activityGlyph(activity) {
                Image(systemName: glyph.name)
                    .font(.app(.caption))
                    .foregroundStyle(glyph.color)
                    .help(glyph.label)
            }
            if let cardId = m.cardId {
                Button { onOpenCard(cardId) } label: {
                    Text("@\(m.handle)")
                        .font(.app(.caption))
                        .foregroundStyle(online ? Color.primary : .secondary)
                }
                .buttonStyle(.plain)
                .help("Open card details for @\(m.handle)")
            } else {
                Text("@\(m.handle)")
                    .font(.app(.caption))
                    .foregroundStyle(online ? Color.primary : .secondary)
            }
            if m.cardId != nil {
                Button { onOpenDM(m) } label: {
                    Image(systemName: "message")
                        .font(.app(.caption))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("Open direct message with @\(m.handle)")

                Button { onCopyDMCommand(m) } label: {
                    Image(systemName: "doc.on.clipboard")
                        .font(.app(.caption))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.tertiary)
                .help("Copy `kanban dm @\(m.handle) ...` command")
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Capsule().fill(Color.secondary.opacity(0.08)))
        .contextMenu {
            Button(role: .destructive) {
                onKickMember(m)
            } label: {
                Label("Remove @\(m.handle) from #\(channel.name)", systemImage: "person.badge.minus")
            }
            .help("Evicts the member from the channel. Use this for dead agents so a new link doesn't have to join as @\(m.handle)_2.")
        }
    }

    private var hasRealMessages: Bool {
        displayedMessages.contains(where: { $0.type == .message })
    }

    @ViewBuilder
    private var workingParticipantsList: some View {
        if !activelyWorkingMembers.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(activelyWorkingMembers) { member in
                    workingParticipantRow(member)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .accessibilityElement(children: .combine)
            .help(activelyWorkingMembers.map { "@\($0.handle) is actively working" }.joined(separator: "\n"))
        }
    }

    private func workingParticipantRow(_ member: ChannelMember) -> some View {
        Button {
            if let cardId = member.cardId {
                onOpenCard(cardId)
            }
        } label: {
            HStack(spacing: 10) {
                ProgressView()
                    .controlSize(.small)
                Text("@\(member.handle) is working")
                    .font(.app(.callout))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(member.cardId == nil)
        .help(member.cardId == nil
              ? "@\(member.handle) is actively working"
              : "Open card details for @\(member.handle)")
    }

    private var messageList: some View {
        ScrollViewReader { proxy in
            ZStack(alignment: .bottom) {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        if !hasRealMessages { emptyState }
                        let lastId = displayedMessages.last?.id
                        ForEach(displayedMessages) { m in
                            messageRow(m, mine: isMine(m))
                                .id(m.id)
                                .overlay {
                                    if currentMatchMessageId == m.id {
                                        RoundedRectangle(cornerRadius: 6)
                                            .stroke(Color.accentColor.opacity(0.75), lineWidth: 1.5)
                                            .padding(.horizontal, 4)
                                            .allowsHitTesting(false)
                                    }
                                }
                                .background {
                                    if m.id == lastId {
                                        GeometryReader { geo in
                                            Color.clear.preference(
                                                key: LastMessageHeightKey.self,
                                                value: geo.size.height
                                            )
                                        }
                                    }
                                }
                        }
                        workingParticipantsList
                        Color.clear.frame(height: 4).id("__bottom__")
                    }
                    .padding(.vertical, 12)
                }
                .onPreferenceChange(LastMessageHeightKey.self) { h in
                    lastMessageHeight = h
                }
                .onScrollGeometryChange(for: CGFloat.self) { geo in
                    let maxScroll = max(0, geo.contentSize.height - geo.containerSize.height)
                    return max(0, maxScroll - geo.contentOffset.y)
                } action: { _, distance in
                    distanceFromBottom = distance
                }
                // Track whether the user is reading near the bottom. Threshold
                // = max(80, last-message-height + 40): if the last message is
                // a tall image, users scrolled anywhere within it still count
                // as "near bottom" and get auto-scroll on new messages.
                .onScrollGeometryChange(for: Bool.self) { geo in
                    let maxScroll = max(0, geo.contentSize.height - geo.containerSize.height)
                    let threshold = max(80, lastMessageHeight + 40)
                    return (maxScroll - geo.contentOffset.y) < threshold
                } action: { _, nearBottom in
                    isNearBottom = nearBottom
                    if nearBottom { unseenNewCount = 0 }
                }
                .onChange(of: messages) { old, new in
                    let latestChanged = old.last?.id != new.last?.id
                    syncDisplayedMessages(preserveExisting: !isNearBottom)
                    if isNearBottom {
                        withAnimation(.easeOut(duration: 0.15)) {
                            proxy.scrollTo("__bottom__", anchor: .bottom)
                        }
                    } else if latestChanged {
                        unseenNewCount += max(1, new.count - old.count)
                    }
                    if showSearch, !activeQuery.isEmpty {
                        runSearch(scrollToMostRecent: false)
                    }
                }
                .onChange(of: activelyWorkingMemberIds) { old, new in
                    let newlyWorking = Set(new).subtracting(Set(old))
                    let insertedRows = max(1, new.count - old.count)
                    let expectedInsertedHeight = CGFloat(insertedRows) * 34 + 36
                    let shouldFollow = !newlyWorking.isEmpty
                        && (isNearBottom || distanceFromBottom <= expectedInsertedHeight + 48)
                    if shouldFollow {
                        withAnimation(.easeOut(duration: 0.15)) {
                            proxy.scrollTo("__bottom__", anchor: .bottom)
                        }
                        Task { @MainActor in
                            try? await Task.sleep(for: .milliseconds(50))
                            proxy.scrollTo("__bottom__", anchor: .bottom)
                        }
                    }
                }
                .onChange(of: isNearBottom) { _, nearBottom in
                    if nearBottom {
                        syncDisplayedMessages(preserveExisting: false)
                    }
                }
                .onChange(of: currentMatchPosition) {
                    scrollToCurrentSearchMatch(proxy)
                }
                .onChange(of: searchMatchMessageIds) {
                    scrollToCurrentSearchMatch(proxy)
                }
                // `.onAppear` alone doesn't scroll to the real bottom — the
                // LazyVStack hasn't realized rows yet, so the scrollable height
                // is still 0 and `scrollTo` settles mid-content. Call it once
                // synchronously, then again on the next two runloop ticks to
                // catch post-layout heights.
                .task(id: channel.name) {
                    unseenNewCount = 0
                    isNearBottom = true
                    syncDisplayedMessages(preserveExisting: false)
                    proxy.scrollTo("__bottom__", anchor: .bottom)
                    try? await Task.sleep(for: .milliseconds(16))
                    proxy.scrollTo("__bottom__", anchor: .bottom)
                    try? await Task.sleep(for: .milliseconds(100))
                    proxy.scrollTo("__bottom__", anchor: .bottom)
                }

                if unseenNewCount > 0 {
                    Button {
                        unseenNewCount = 0
                        withAnimation(.easeOut(duration: 0.2)) {
                            proxy.scrollTo("__bottom__", anchor: .bottom)
                        }
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "arrow.down")
                            Text("\(unseenNewCount) new message\(unseenNewCount == 1 ? "" : "s")")
                                .font(.app(.caption, weight: .medium))
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(Capsule().fill(Color.accentColor))
                        .foregroundStyle(.white)
                        .shadow(radius: 4, y: 2)
                    }
                    .buttonStyle(.plain)
                    .padding(.bottom, 10)
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
                }
            }
            .animation(.easeInOut(duration: 0.15), value: unseenNewCount)
        }
    }

    private var channelSearchBar: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .font(.app(.caption))
                    .foregroundStyle(.secondary)

                TextField("Search channel...", text: $searchText)
                    .textFieldStyle(.plain)
                    .font(.app(.callout))
                    .focused($isSearchFieldFocused)
                    .onKeyPress(.escape) { dismissSearch(); return .handled }
                    .onKeyPress(.downArrow) { moveSearchFromSelection(by: 1) ? .handled : .ignored }
                    .onKeyPress(.upArrow) { moveSearchFromSelection(by: -1) ? .handled : .ignored }
                    .onKeyPress(.tab) { acceptSearchFromSuggestion() ? .handled : .ignored }
                    .onSubmit {
                        if !acceptSearchFromSuggestion() {
                            navigateSearch(forward: false)
                        }
                    }
                    .onChange(of: searchText) {
                        searchFromSelectedIndex = 0
                        scheduleSearch()
                    }

                if !activeQuery.isEmpty {
                    if searchMatchMessageIds.isEmpty {
                        Text("0 results")
                            .font(.app(.caption2))
                            .foregroundStyle(.secondary)
                    } else {
                        Text("\(searchMatchMessageIds.count - currentMatchPosition)/\(searchMatchMessageIds.count)")
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

            if activeSearchFromQuery != nil, !searchFromMatches.isEmpty {
                MentionSuggestionList(
                    matches: searchFromMatches,
                    selectedIndex: searchFromSelectedIndex,
                    onHover: { idx in searchFromSelectedIndex = idx }
                ) { handle in
                    replaceActiveFromQuery(with: handle)
                }
                .fixedSize()
                .padding(.leading, 24)
                .transition(.opacity)
            }
        }
        .padding(.leading, 16)
        .padding(.trailing, 52)
        .padding(.top, 6)
        .zIndex(1)
    }

    private func scheduleSearch() {
        searchDebounceTask?.cancel()
        let trimmed = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            activeQuery = ""
            searchMatchMessageIds = []
            currentMatchPosition = 0
            return
        }
        guard trimmed.count >= 2 else { return }
        searchDebounceTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(180))
            guard !Task.isCancelled else { return }
            activeQuery = trimmed
            runSearch(scrollToMostRecent: true)
        }
    }

    private func runSearch(scrollToMostRecent: Bool) {
        let query = activeQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        let parsed = ChannelSearchQuery.parse(query)
        guard !parsed.isEmpty else {
            searchMatchMessageIds = []
            currentMatchPosition = 0
            return
        }

        let matches = displayedMessages.filter { message in
            messageMatchesSearch(message, parsed: parsed)
        }.map(\.id)

        searchMatchMessageIds = matches
        if matches.isEmpty {
            currentMatchPosition = 0
        } else if scrollToMostRecent {
            currentMatchPosition = matches.count - 1
        } else {
            currentMatchPosition = min(currentMatchPosition, matches.count - 1)
        }
    }

    private func syncDisplayedMessages(preserveExisting: Bool) {
        guard preserveExisting else {
            retainedMessages = messages
            return
        }
        var merged = retainedMessages.isEmpty ? messages : retainedMessages
        var indexById: [String: Int] = [:]
        indexById.reserveCapacity(merged.count + messages.count)
        for (index, message) in merged.enumerated() {
            indexById[message.id] = index
        }
        for message in messages {
            if let index = indexById[message.id] {
                merged[index] = message
            } else {
                indexById[message.id] = merged.count
                merged.append(message)
            }
        }
        if merged.count > Self.retainedScrollbackLimit {
            merged = Array(merged.suffix(Self.retainedScrollbackLimit))
        }
        retainedMessages = merged
    }

    private func messageSearchText(_ message: ChannelMessage) -> String {
        "@\(message.from.handle)\n\(message.body)"
    }

    private func messageMatchesSearch(_ message: ChannelMessage, parsed: ChannelSearchQuery) -> Bool {
        if let fromQuery = parsed.fromQuery,
           !Self.handleMatchesFromQuery(handle: message.from.handle, query: fromQuery, myHandle: myHandle) {
            return false
        }

        guard !parsed.bodyQuery.isEmpty else { return true }
        if parsed.fromQuery != nil {
            return message.body.localizedCaseInsensitiveContains(parsed.bodyQuery)
        }
        return messageSearchText(message).localizedCaseInsensitiveContains(parsed.bodyQuery)
    }

    static func handleMatchesFromQuery(handle: String, query: String, myHandle: String) -> Bool {
        let trimmed = query.trimmingCharacters(in: CharacterSet(charactersIn: "@").union(.whitespacesAndNewlines))
        guard !trimmed.isEmpty else { return true }
        if trimmed.caseInsensitiveCompare("me") == .orderedSame {
            return !myHandle.isEmpty && handle.caseInsensitiveCompare(myHandle) == .orderedSame
        }
        return ChatInputBar.handleMatches(query: trimmed, candidate: handle)
    }

    static func activeFromQuery(in text: String) -> String? {
        guard let range = activeFromTokenRange(in: text) else { return nil }
        let token = String(text[range])
        let lower = token.lowercased()
        guard lower.hasPrefix("from:@") else { return nil }
        let queryStart = token.index(token.startIndex, offsetBy: "from:@".count)
        let query = token[queryStart...]
        for c in query where !(c.isLetter || c.isNumber || c == "_" || c == "-") {
            return nil
        }
        return String(query)
    }

    static func filteredFromHandles(query: String, candidates: [String], myHandle: String) -> [String] {
        let unique = candidates.reduce(into: [String]()) { acc, handle in
            let key = handle.lowercased()
            if !acc.contains(where: { $0.lowercased() == key }) {
                acc.append(handle)
            }
        }
        let matches = ChatInputBar.filteredMentionMatches(query: query, candidates: unique)
        if query.isEmpty || ChatInputBar.handleMatches(query: query, candidate: "me") {
            return matches
        }
        return matches.filter { handle in
            if handle.caseInsensitiveCompare("me") == .orderedSame {
                return !myHandle.isEmpty
            }
            return true
        }
    }

    private func moveSearchFromSelection(by delta: Int) -> Bool {
        guard activeSearchFromQuery != nil, !searchFromMatches.isEmpty else { return false }
        let capped = min(searchFromMatches.count, 6)
        searchFromSelectedIndex = (searchFromSelectedIndex + delta + capped) % capped
        return true
    }

    private func acceptSearchFromSuggestion() -> Bool {
        guard activeSearchFromQuery != nil, !searchFromMatches.isEmpty else { return false }
        let visible = Array(searchFromMatches.prefix(6))
        let idx = max(0, min(searchFromSelectedIndex, visible.count - 1))
        replaceActiveFromQuery(with: visible[idx])
        return true
    }

    private func replaceActiveFromQuery(with handle: String) {
        guard let range = Self.activeFromTokenRange(in: searchText) else { return }
        searchText.replaceSubrange(range, with: "from:@\(handle) ")
        searchFromSelectedIndex = 0
        activeQuery = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        runSearch(scrollToMostRecent: true)
    }

    private static func activeFromTokenRange(in text: String) -> Range<String.Index>? {
        guard let lastWhitespace = text.lastIndex(where: \.isWhitespace) else {
            return text.lowercased().hasPrefix("from:@") ? text.startIndex..<text.endIndex : nil
        }
        let tokenStart = text.index(after: lastWhitespace)
        let token = text[tokenStart...]
        return token.lowercased().hasPrefix("from:@") ? tokenStart..<text.endIndex : nil
    }

    private func navigateSearch(forward: Bool) {
        guard !searchMatchMessageIds.isEmpty else { return }
        if forward {
            currentMatchPosition = (currentMatchPosition + 1) % searchMatchMessageIds.count
        } else {
            currentMatchPosition = (currentMatchPosition - 1 + searchMatchMessageIds.count) % searchMatchMessageIds.count
        }
    }

    private func dismissSearch() {
        searchDebounceTask?.cancel()
        showSearch = false
        isSearchFieldFocused = false
        searchText = ""
        activeQuery = ""
        searchMatchMessageIds = []
        currentMatchPosition = 0
        searchFromSelectedIndex = 0
    }

    private func scrollToCurrentSearchMatch(_ proxy: ScrollViewProxy) {
        guard let id = currentMatchMessageId else { return }
        withAnimation(.easeInOut(duration: 0.2)) {
            proxy.scrollTo(id, anchor: .center)
        }
    }

    private var emptyState: some View {
        VStack(alignment: .center, spacing: 10) {
            Image(systemName: "number")
                .font(.system(size: 36))
                .foregroundStyle(.quaternary)
            Text("#\(channel.name)")
                .font(.app(.title3, weight: .semibold))
            Text("\(channel.members.count) member\(channel.members.count == 1 ? "" : "s") · no messages yet")
                .font(.app(.caption))
                .foregroundStyle(.secondary)
            Text("Say hello below. Everyone in the channel will receive it in their tmux session.")
                .font(.app(.caption))
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 48)
    }

    /// True if the message came from the local user (no cardId + handle matches).
    private func isMine(_ m: ChannelMessage) -> Bool {
        guard !myHandle.isEmpty, m.type == .message else { return false }
        return m.from.cardId == nil && m.from.handle == myHandle
    }

    private func messageRow(_ m: ChannelMessage, mine: Bool) -> some View {
        let style: Color = {
            switch m.type {
            case .join, .leave, .system: return .secondary
            case .message: return .primary
            }
        }()
        let prefix: String = {
            switch m.type {
            case .message: return "@\(m.from.handle)"
            default: return ""
            }
        }()
        // `.green` reads like a self-mention against the default `.blue` used
        // for everyone else. Opacity knocks it down a touch so it doesn't fight
        // the message body for attention.
        let handleColor: Color = mine ? .green.opacity(0.9) : .blue.opacity(0.85)
        return VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                if !prefix.isEmpty {
                    if let cardId = m.from.cardId {
                        Button { onOpenCard(cardId) } label: {
                            Text(prefix)
                                .font(.app(.body, weight: .semibold))
                                .foregroundStyle(handleColor)
                        }
                        .buttonStyle(.plain)
                        .help("Open card details for \(prefix)")
                    } else {
                        Text(prefix)
                            .font(.app(.body, weight: .semibold))
                            .foregroundStyle(handleColor)
                    }
                }
                ChatMessageBody(
                    text: m.body,
                    isCmdHeld: isCmdHeld,
                    urlForPullRequestNumber: { urlForPullRequest(number: $0, from: m) }
                )
                    .environment(\.openURL, OpenURLAction { url in
                        onOpenPullRequest(url)
                        return .handled
                    })
                    .foregroundStyle(style)
                Spacer(minLength: 6)
                Text(shortTime(m.ts))
                    .font(.app(.caption))
                    .foregroundStyle(.tertiary)
            }
            if let imgs = m.imagePaths, !imgs.isEmpty {
                ChatMessageImages(paths: imgs)
                    .padding(.leading, prefix.isEmpty ? 0 : 4)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(mine ? Color.primary.opacity(0.045) : Color.clear)
        .contextMenu {
            Button {
                Self.copyToPasteboard(m.body)
            } label: {
                Label("Copy Message", systemImage: "doc.on.doc")
            }
        }
    }

    private func urlForPullRequest(number: Int, from message: ChannelMessage) -> URL? {
        let senderRefs = pullRequests.filter { $0.cardId == message.from.cardId }
        if let url = senderRefs.first(where: { $0.number == number })?.url {
            return url
        }
        if let url = pullRequests.first(where: { $0.number == number })?.url {
            return url
        }
        if let cardId = message.from.cardId,
           let base = pullRequestBaseURLsByCardId[cardId] {
            return URL(string: GitRemoteResolver.prURL(base: base, number: number))
        }
        let uniqueBases = Set(pullRequestBaseURLsByCardId.values)
        if uniqueBases.count == 1, let base = uniqueBases.first {
            return URL(string: GitRemoteResolver.prURL(base: base, number: number))
        }
        return nil
    }

    private struct ActivityGlyph { let name: String; let color: Color; let label: String }

    private func activityGlyph(_ state: ActivityState?) -> ActivityGlyph? {
        guard let state else { return nil }
        switch state {
        case .activelyWorking:
            return ActivityGlyph(name: "waveform", color: .orange, label: "working")
        case .needsAttention:
            return ActivityGlyph(name: "exclamationmark.circle.fill", color: .yellow, label: "needs attention")
        case .idleWaiting:
            return ActivityGlyph(name: "moon.zzz", color: .secondary, label: "idle")
        case .ended, .stale:
            return nil
        }
    }

    private func shortTime(_ d: Date) -> String {
        DateFormatter.hm.string(from: d)
    }

    private static func copyToPasteboard(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    private var composer: some View {
        ChatInputBar(
            style: .irc,
            assistant: nil,
            isReady: true,
            cardId: "channel:\(channel.name)",
            placeholderOverride: "Message #\(channel.name)",
            mentionCandidates: channel.members.map { $0.handle },
            onSend: { body, imagePaths in onSend(body, imagePaths) },
            text: $draft,
            pastedImages: $pastedImages
        )
    }
}

/// Thumbnails for attached images rendered below a chat message.
/// Tapping a thumbnail opens a `Quick Look` preview via NSWorkspace.
struct ChatMessageImages: View {
    let paths: [String]

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(Array(paths.enumerated()), id: \.offset) { _, path in
                    if let img = NSImage(contentsOfFile: path) {
                        Button {
                            NSWorkspace.shared.open(URL(fileURLWithPath: path))
                        } label: {
                            Image(nsImage: img)
                                .resizable()
                                .aspectRatio(contentMode: .fill)
                                .frame(width: 140, height: 96)
                                .clipShape(RoundedRectangle(cornerRadius: 6))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 6)
                                        .strokeBorder(Color.secondary.opacity(0.2), lineWidth: 1)
                                )
                        }
                        .buttonStyle(.plain)
                        .help((path as NSString).lastPathComponent)
                    }
                }
            }
        }
    }
}

/// Direct-message chat view — 1:1 conversation with another participant.
struct DMChatView: View {
    let other: ChannelParticipant
    let messages: [ChannelMessage]
    let onlineForOther: Bool
    var onSend: (String, [String]) -> Void = { _, _ in }
    var onClose: () -> Void = {}
    var onOpenCard: (String) -> Void = { _ in }
    /// Local user's handle, used to tint this side's messages. See ChannelChatView.
    var myHandle: String = ""
    @Binding var draft: String

    @State private var pastedImages: [Data] = []
    @State private var isNearBottom: Bool = true
    @State private var unseenNewCount: Int = 0
    @State private var isCmdHeld: Bool = false
    @State private var cmdMonitor: Any?
    @State private var lastMessageHeight: CGFloat = 80
    @State private var retainedMessages: [ChannelMessage] = []
    @FocusState private var inputFocused: Bool

    private static let retainedScrollbackLimit = 2_000

    private var displayedMessages: [ChannelMessage] {
        retainedMessages.isEmpty ? messages : retainedMessages
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            messageList
            Divider()
            composer
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear {
            cmdMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { event in
                let cmd = event.modifierFlags.contains(.command)
                if cmd != isCmdHeld { isCmdHeld = cmd }
                return event
            }
        }
        .onDisappear {
            if let m = cmdMonitor {
                NSEvent.removeMonitor(m)
                cmdMonitor = nil
            }
            isCmdHeld = false
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "message.fill")
                .foregroundStyle(.secondary)
            if let cardId = other.cardId {
                Button { onOpenCard(cardId) } label: {
                    Text("@\(other.handle)")
                        .font(.app(.title3, weight: .semibold))
                }
                .buttonStyle(.plain)
                .help("Open card details for @\(other.handle)")
            } else {
                Text("@\(other.handle)")
                    .font(.app(.title3, weight: .semibold))
            }
            Circle().fill(onlineForOther ? Color.green : Color.secondary.opacity(0.35))
                .frame(width: 7, height: 7)
            Text(onlineForOther ? "online" : "offline")
                .font(.app(.caption))
                .foregroundStyle(.tertiary)
            Spacer()
            Button(action: onClose) {
                Image(systemName: "xmark.circle.fill")
                    .font(.app(.body))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private var messageList: some View {
        ScrollViewReader { proxy in
            ZStack(alignment: .bottom) {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        if displayedMessages.isEmpty {
                            Text("No messages yet. Say hello.")
                                .font(.app(.caption))
                                .foregroundStyle(.tertiary)
                                .padding(.vertical, 24)
                                .frame(maxWidth: .infinity, alignment: .center)
                        }
                        let lastId = displayedMessages.last?.id
                        ForEach(displayedMessages) { m in
                            let mine = !myHandle.isEmpty
                                && m.from.cardId == nil
                                && m.from.handle == myHandle
                            VStack(alignment: .leading, spacing: 4) {
                                HStack(alignment: .firstTextBaseline, spacing: 8) {
                                    let prefix = "@\(m.from.handle)"
                                    if let cardId = m.from.cardId {
                                        Button { onOpenCard(cardId) } label: {
                                            Text(prefix)
                                                .font(.app(.body, weight: .semibold))
                                                .foregroundStyle(mine ? Color.green.opacity(0.9) : Color.blue.opacity(0.85))
                                        }
                                        .buttonStyle(.plain)
                                        .help("Open card details for \(prefix)")
                                    } else {
                                        Text(prefix)
                                            .font(.app(.body, weight: .semibold))
                                            .foregroundStyle(mine ? Color.green.opacity(0.9) : Color.blue.opacity(0.85))
                                    }
                                    ChatMessageBody(text: m.body, isCmdHeld: isCmdHeld)
                                    Spacer(minLength: 6)
                                    Text(DateFormatter.hm.string(from: m.ts))
                                        .font(.app(.caption))
                                        .foregroundStyle(.tertiary)
                                }
                                if let imgs = m.imagePaths, !imgs.isEmpty {
                                    ChatMessageImages(paths: imgs)
                                }
                            }
                            .padding(.horizontal, 12)
                            .padding(.vertical, 4)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(mine ? Color.primary.opacity(0.045) : Color.clear)
                            .contextMenu {
                                Button {
                                    Self.copyToPasteboard(m.body)
                                } label: {
                                    Label("Copy Message", systemImage: "doc.on.doc")
                                }
                            }
                            .id(m.id)
                            .background {
                                if m.id == lastId {
                                    GeometryReader { geo in
                                        Color.clear.preference(
                                            key: LastMessageHeightKey.self,
                                            value: geo.size.height
                                        )
                                    }
                                }
                            }
                        }
                        Color.clear.frame(height: 4).id("__dm_bottom__")
                    }
                    .padding(.vertical, 12)
                }
                .onPreferenceChange(LastMessageHeightKey.self) { h in
                    lastMessageHeight = h
                }
                .onScrollGeometryChange(for: Bool.self) { geo in
                    let maxScroll = max(0, geo.contentSize.height - geo.containerSize.height)
                    let threshold = max(80, lastMessageHeight + 40)
                    return (maxScroll - geo.contentOffset.y) < threshold
                } action: { _, nearBottom in
                    isNearBottom = nearBottom
                    if nearBottom { unseenNewCount = 0 }
                }
                .onChange(of: messages) { old, new in
                    let latestChanged = old.last?.id != new.last?.id
                    syncDisplayedMessages(preserveExisting: !isNearBottom)
                    if isNearBottom {
                        withAnimation(.easeOut(duration: 0.15)) {
                            proxy.scrollTo("__dm_bottom__", anchor: .bottom)
                        }
                    } else if latestChanged {
                        unseenNewCount += max(1, new.count - old.count)
                    }
                }
                .onChange(of: isNearBottom) { _, nearBottom in
                    if nearBottom {
                        syncDisplayedMessages(preserveExisting: false)
                    }
                }
                .task(id: other.handle) {
                    unseenNewCount = 0
                    isNearBottom = true
                    syncDisplayedMessages(preserveExisting: false)
                    proxy.scrollTo("__dm_bottom__", anchor: .bottom)
                    try? await Task.sleep(for: .milliseconds(16))
                    proxy.scrollTo("__dm_bottom__", anchor: .bottom)
                    try? await Task.sleep(for: .milliseconds(100))
                    proxy.scrollTo("__dm_bottom__", anchor: .bottom)
                }

                if unseenNewCount > 0 {
                    Button {
                        unseenNewCount = 0
                        withAnimation(.easeOut(duration: 0.2)) {
                            proxy.scrollTo("__dm_bottom__", anchor: .bottom)
                        }
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "arrow.down")
                            Text("\(unseenNewCount) new message\(unseenNewCount == 1 ? "" : "s")")
                                .font(.app(.caption, weight: .medium))
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(Capsule().fill(Color.accentColor))
                        .foregroundStyle(.white)
                        .shadow(radius: 4, y: 2)
                    }
                    .buttonStyle(.plain)
                    .padding(.bottom, 10)
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
                }
            }
            .animation(.easeInOut(duration: 0.15), value: unseenNewCount)
        }
    }

    private var composer: some View {
        ChatInputBar(
            style: .irc,
            assistant: nil,
            isReady: true,
            cardId: "dm:\(other.handle)",
            placeholderOverride: "Message @\(other.handle)",
            mentionCandidates: [other.handle],
            onSend: { body, imagePaths in onSend(body, imagePaths) },
            text: $draft,
            pastedImages: $pastedImages
        )
    }

    private func syncDisplayedMessages(preserveExisting: Bool) {
        guard preserveExisting else {
            retainedMessages = messages
            return
        }
        var merged = retainedMessages.isEmpty ? messages : retainedMessages
        var indexById: [String: Int] = [:]
        indexById.reserveCapacity(merged.count + messages.count)
        for (index, message) in merged.enumerated() {
            indexById[message.id] = index
        }
        for message in messages {
            if let index = indexById[message.id] {
                merged[index] = message
            } else {
                indexById[message.id] = merged.count
                merged.append(message)
            }
        }
        if merged.count > Self.retainedScrollbackLimit {
            merged = Array(merged.suffix(Self.retainedScrollbackLimit))
        }
        retainedMessages = merged
    }

    private static func copyToPasteboard(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

private extension DateFormatter {
    static let hm: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "HH:mm"; return f
    }()
}

/// Dialog to create a new channel.
struct CreateChannelDialog: View {
    @Binding var isPresented: Bool
    var onCreate: (String) -> Void
    @State private var name: String = ""

    private var trimmed: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "#", with: "")
    }

    private var isValid: Bool {
        let n = trimmed
        guard !n.isEmpty, n.count <= 64 else { return false }
        let regex = try? NSRegularExpression(pattern: "^[a-z0-9][a-z0-9_-]{0,63}$")
        return regex?.firstMatch(in: n, range: NSRange(n.startIndex..., in: n)) != nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Create a channel")
                .font(.app(.title3, weight: .semibold))
            Text("Channels are shared rooms where agents in different tmux sessions can broadcast, DM, and coordinate.")
                .font(.app(.caption))
                .foregroundStyle(.secondary)
            HStack(spacing: 6) {
                Text("#").foregroundStyle(.secondary)
                TextField("general", text: $name)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { if isValid { submit() } }
            }
            Text("Letters, digits, underscore, and dash. 1–64 chars. Start with a letter or digit.")
                .font(.app(.caption))
                .foregroundStyle(.tertiary)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { isPresented = false }
                    .keyboardShortcut(.cancelAction)
                Button("Create") { submit() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!isValid)
            }
        }
        .padding(18)
        .frame(width: 420)
    }

    private func submit() {
        guard isValid else { return }
        onCreate(trimmed.lowercased())
        isPresented = false
    }
}

/// Dialog to rename an existing channel.
struct RenameChannelDialog: View {
    @Binding var isPresented: Bool
    let currentName: String
    var onRename: (String) -> Void
    @State private var name: String = ""

    private var trimmed: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "#", with: "")
    }

    private var isValid: Bool {
        let n = trimmed
        guard !n.isEmpty, n.count <= 64, n.lowercased() != currentName.lowercased() else { return false }
        let regex = try? NSRegularExpression(pattern: "^[a-z0-9][a-z0-9_-]{0,63}$")
        return regex?.firstMatch(in: n.lowercased(), range: NSRange(n.startIndex..., in: n)) != nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Rename #\(currentName)")
                .font(.app(.title3, weight: .semibold))
            Text("Renames the channel across the UI and moves the message log to the new name. Members stay the same.")
                .font(.app(.caption))
                .foregroundStyle(.secondary)
            HStack(spacing: 6) {
                Text("#").foregroundStyle(.secondary)
                TextField(currentName, text: $name)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { if isValid { submit() } }
            }
            Text("Letters, digits, underscore, and dash. 1–64 chars. Start with a letter or digit.")
                .font(.app(.caption))
                .foregroundStyle(.tertiary)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { isPresented = false }
                    .keyboardShortcut(.cancelAction)
                Button("Rename") { submit() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!isValid)
            }
        }
        .padding(18)
        .frame(width: 420)
        .onAppear { name = currentName }
    }

    private func submit() {
        guard isValid else { return }
        onRename(trimmed.lowercased())
        isPresented = false
    }
}
