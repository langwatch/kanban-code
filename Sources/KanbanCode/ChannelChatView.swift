import SwiftUI
import AppKit
import KanbanCodeCore

/// Last message's rendered height — used as the "near bottom" threshold so
/// images / tall messages don't prematurely turn off auto-scroll. Reported
/// via GeometryReader on whichever row is currently last.
private struct LastMessageHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 80
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

// MARK: - Cmd+click URL helpers (shared by channel + DM chats)

/// Regex matching http(s) URLs. Stops at whitespace / common punctuation
/// closers so trailing `)` or `.` don't get captured as part of the URL.
private let chatURLRegex: NSRegularExpression? = {
    try? NSRegularExpression(pattern: "https?://[^\\s<>\"'\\])*]*[^\\s<>\"'\\]).,:;!?]")
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

/// Render `text` as a Text view whose URLs are clickable when the user
/// is holding cmd AND hovering over the line.
private struct ChatMessageBody: View {
    let text: String
    let isCmdHeld: Bool
    @State private var hovered = false

    private var linksActive: Bool { isCmdHeld && hovered }

    var body: some View {
        var attr = AttributedString(text)
        if linksActive {
            applyChatURLLinks(to: &attr)
        }
        return Text(attr)
            .font(.app(.body))
            .textSelection(.enabled)
            .onHover { hovered = $0 }
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
    /// Optional map from handle → activity state (working/idle/needsAttention). Used to
    /// decorate each member chip with a status glyph.
    var activityByHandle: [String: ActivityState] = [:]
    /// Two-way binding for the draft message. Held by the parent (store) so it
    /// survives drawer switches — avoids losing in-progress typing when the
    /// user jumps to another channel/card and comes back.
    @Binding var draft: String

    @State private var pastedImages: [Data] = []
    @State private var rosterExpanded = false
    @State private var isNearBottom: Bool = true
    @State private var unseenNewCount: Int = 0
    @State private var isCmdHeld: Bool = false
    @State private var cmdMonitor: Any?
    @State private var lastMessageHeight: CGFloat = 80
    @FocusState private var inputFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            header
            if rosterExpanded { rosterRow }
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
            Spacer()
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
            if let glyph = activityGlyph(activity) {
                Image(systemName: glyph.name)
                    .font(.app(.caption))
                    .foregroundStyle(glyph.color)
                    .help(glyph.label)
            }
            Text("@\(m.handle)")
                .font(.app(.caption))
                .foregroundStyle(online ? Color.primary : .secondary)
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
    }

    private var hasRealMessages: Bool {
        messages.contains(where: { $0.type == .message })
    }

    private var messageList: some View {
        ScrollViewReader { proxy in
            ZStack(alignment: .bottom) {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 6) {
                        if !hasRealMessages { emptyState }
                        let lastId = messages.last?.id
                        ForEach(messages) { m in
                            messageRow(m)
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
                        Color.clear.frame(height: 4).id("__bottom__")
                    }
                    .padding(12)
                    .textSelection(.enabled)
                }
                .onPreferenceChange(LastMessageHeightKey.self) { h in
                    lastMessageHeight = h
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
                .onChange(of: messages.count) { old, new in
                    if isNearBottom {
                        withAnimation(.easeOut(duration: 0.15)) {
                            proxy.scrollTo("__bottom__", anchor: .bottom)
                        }
                    } else if new > old {
                        unseenNewCount += (new - old)
                    }
                }
                // `.onAppear` alone doesn't scroll to the real bottom — the
                // LazyVStack hasn't realized rows yet, so the scrollable height
                // is still 0 and `scrollTo` settles mid-content. Call it once
                // synchronously, then again on the next two runloop ticks to
                // catch post-layout heights.
                .task(id: channel.name) {
                    unseenNewCount = 0
                    isNearBottom = true
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

    private func messageRow(_ m: ChannelMessage) -> some View {
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
        return VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                if !prefix.isEmpty {
                    Text(prefix)
                        .font(.app(.body, weight: .semibold))
                        .foregroundStyle(.blue.opacity(0.85))
                }
                ChatMessageBody(text: m.body, isCmdHeld: isCmdHeld)
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
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return f.string(from: d)
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
    @Binding var draft: String

    @State private var pastedImages: [Data] = []
    @State private var isNearBottom: Bool = true
    @State private var unseenNewCount: Int = 0
    @State private var isCmdHeld: Bool = false
    @State private var cmdMonitor: Any?
    @State private var lastMessageHeight: CGFloat = 80
    @FocusState private var inputFocused: Bool

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
            Text("@\(other.handle)")
                .font(.app(.title3, weight: .semibold))
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
                    LazyVStack(alignment: .leading, spacing: 6) {
                        if messages.isEmpty {
                            Text("No messages yet. Say hello.")
                                .font(.app(.caption))
                                .foregroundStyle(.tertiary)
                                .padding(.vertical, 24)
                                .frame(maxWidth: .infinity, alignment: .center)
                        }
                        let lastId = messages.last?.id
                        ForEach(messages) { m in
                            VStack(alignment: .leading, spacing: 4) {
                                HStack(alignment: .firstTextBaseline, spacing: 8) {
                                    Text("@\(m.from.handle)")
                                        .font(.app(.body, weight: .semibold))
                                        .foregroundStyle(.blue.opacity(0.85))
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
                    .padding(12)
                    .textSelection(.enabled)
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
                .onChange(of: messages.count) { old, new in
                    if isNearBottom {
                        withAnimation(.easeOut(duration: 0.15)) {
                            proxy.scrollTo("__dm_bottom__", anchor: .bottom)
                        }
                    } else if new > old {
                        unseenNewCount += (new - old)
                    }
                }
                .task(id: other.handle) {
                    unseenNewCount = 0
                    isNearBottom = true
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
