import SwiftUI
import AppKit
import KanbanCodeCore

// MARK: - Force dark scrollbar on the history view

struct DarkScrollbarModifier: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async {
            view.enclosingScrollView?.scrollerStyle = .overlay
            view.enclosingScrollView?.appearance = NSAppearance(named: .darkAqua)
        }
        return view
    }
    func updateNSView(_ nsView: NSView, context: Context) {}
}

struct SessionHistoryView: View {
    let turns: [ConversationTurn]
    let isLoading: Bool
    var checkpointMode: Bool = false
    var hasMoreTurns: Bool = false
    var isLoadingMore: Bool = false
    var assistant: CodingAssistant = .claude
    var onCancelCheckpoint: (() -> Void)?
    var onSelectTurn: ((ConversationTurn) -> Void)?
    var onLoadMore: (() -> Void)?
    var onLoadAroundTurn: ((Int) -> Void)?
    var sessionPath: String?

    @State private var hoveredTurnIndex: Int?
    @State private var isCmdHeld = false
    @State private var cmdMonitor: Any?
    @State private var isAtBottom = true
    @State private var showSearch = false
    @State private var searchText = ""
    @State private var activeQuery = ""  // debounced, min 2 chars
    @State private var searchMatchIndices: [Int] = []  // all found match turn indices (ascending)
    @State private var currentMatchPosition: Int = 0   // index into searchMatchIndices, 0 = most recent (last)
    @State private var searchDebounceTask: Task<Void, Never>?
    @State private var searchScanTask: Task<Void, Never>?
    @State private var isSearchScanning = false
    @State private var isNearTop = false
    @State private var autoLoadEnabled = false
    @State private var autoLoadEnableTask: Task<Void, Never>?
    @State private var scrollState = ScrollState()
    @State private var pendingMatchScroll = false  // scroll to match after turns load from navigation
    @FocusState private var isSearchFieldFocused: Bool

    private var currentMatchTurnIndex: Int? {
        guard showSearch, !searchMatchIndices.isEmpty, currentMatchPosition < searchMatchIndices.count else { return nil }
        return searchMatchIndices[currentMatchPosition]
    }

    var body: some View {
        if isLoading {
            VStack {
                ProgressView()
                    .controlSize(.small)
                Text("Loading conversation...")
                    .font(.app(.caption))
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if turns.isEmpty {
            VStack {
                Image(systemName: "text.bubble")
                    .font(.app(.title2))
                    .foregroundStyle(.tertiary)
                Text("No conversation history")
                    .font(.app(.caption))
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ZStack(alignment: .top) {
                Color(white: 0.08)
                    .ignoresSafeArea()

                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(alignment: .leading, spacing: 0) {
                            if checkpointMode {
                                checkpointBanner
                            }

                            // Spacer so content isn't hidden under the search bar.
                            // Always present to avoid content shift on dismiss.
                            Color.clear.frame(height: showSearch ? 36 : 0)

                            // Loading indicator for auto-loaded earlier turns
                            if hasMoreTurns && isLoadingMore {
                                HStack(spacing: 4) {
                                    ProgressView()
                                        .controlSize(.mini)
                                    Text("Loading history…")
                                        .font(.app(.caption))
                                }
                                .foregroundStyle(.white.opacity(0.5))
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 6)
                            }

                            VStack(alignment: .leading, spacing: 2) {
                                ForEach(turns, id: \.index) { turn in
                                    TurnBlockView(
                                        turn: turn,
                                        checkpointMode: checkpointMode,
                                        isHovered: hoveredTurnIndex == turn.index,
                                        isDimmed: checkpointMode && hoveredTurnIndex != nil && turn.index > hoveredTurnIndex!,
                                        highlightText: activeQuery.isEmpty ? nil : activeQuery,
                                        isCurrentMatch: currentMatchTurnIndex == turn.index,
                                        isCmdHeld: isCmdHeld,
                                        assistant: assistant
                                    )
                                    .id(turn.index)
                                    .overlay {
                                        if checkpointMode {
                                            Color.clear
                                                .contentShape(Rectangle())
                                                .onTapGesture { onSelectTurn?(turn) }
                                                .onHover { isHovering in
                                                    hoveredTurnIndex = isHovering ? turn.index : nil
                                                }
                                        }
                                    }
                                }
                                Color.clear.frame(height: 30).id("bottom-anchor")
                            }
                            .padding(.top, 8)
                            .padding(.horizontal, 12)
                        }
                        .background(DarkScrollbarModifier())
                        .background(ScrollBottomDetector(isAtBottom: $isAtBottom))
                        .background(NearTopDetector(isNearTop: $isNearTop))
                        .background(ScrollViewCapture(scrollState: scrollState))
                    }
                    .onAppear {
                        scrollToBottom(proxy: proxy, force: true)
                        armAutoLoad()
                    }
                    .onChange(of: sessionPath) {
                        autoLoadEnabled = false
                        scrollState.stopPreserving()
                        armAutoLoad()
                    }
                    .onChange(of: turns.count) {
                        if scrollState.isPreserving {
                            // ScrollState observer handles position — don't interfere
                        } else if activeQuery.isEmpty {
                            scrollToBottom(proxy: proxy)
                        } else if pendingMatchScroll {
                            // Only scroll when we explicitly loaded turns for search navigation
                            pendingMatchScroll = false
                            scrollToCurrentMatch(proxy: proxy, delay: true)
                        }
                    }
                    .onChange(of: isNearTop) {
                        if isNearTop && hasMoreTurns && !isLoadingMore && autoLoadEnabled && activeQuery.isEmpty {
                            scrollState.captureAndPreserve()
                            onLoadMore?()
                        }
                    }
                    .onChange(of: isLoadingMore) {
                        // When a load finishes, check if still near top and should load more
                        if !isLoadingMore && isNearTop && hasMoreTurns && autoLoadEnabled && activeQuery.isEmpty {
                            scrollState.captureAndPreserve()
                            onLoadMore?()
                        }
                    }
                    .onChange(of: currentMatchPosition) {
                        guard !searchMatchIndices.isEmpty,
                              currentMatchPosition < searchMatchIndices.count else { return }
                        let idx = searchMatchIndices[currentMatchPosition]
                        if turns.contains(where: { $0.index == idx }) {
                            scrollToCurrentMatch(proxy: proxy, delay: false)
                        } else {
                            // Turn not loaded — load it, pendingMatchScroll triggers scroll after
                            pendingMatchScroll = true
                            onLoadAroundTurn?(idx)
                        }
                    }
                }

                // Search overlay
                if showSearch {
                    searchBar
                }
            }
            .background {
                // Hidden buttons for keyboard shortcuts
                Button("") {
                    showSearch = true
                    isSearchFieldFocused = true
                }
                .keyboardShortcut("f", modifiers: .command)
                .hidden()

                // Escape is handled via .onKeyPress on the TextField
                // so it takes priority over the drawer's Escape handler.
            }
            .onAppear {
                cmdMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { event in
                    let cmd = event.modifierFlags.contains(.command)
                    if cmd != isCmdHeld { isCmdHeld = cmd }
                    return event
                }
            }
            .onDisappear {
                if let monitor = cmdMonitor {
                    NSEvent.removeMonitor(monitor)
                    cmdMonitor = nil
                }
                isCmdHeld = false
            }
        }
    }

    // MARK: - Search bar

    private var searchBar: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.app(.caption))
                .foregroundStyle(.white.opacity(0.5))

            TextField("Search history...", text: $searchText, prompt: Text("Search history...").foregroundStyle(.white.opacity(0.3)))
                .textFieldStyle(.plain)
                .font(.app(.caption, design: .monospaced))
                .foregroundStyle(.white)
                .focused($isSearchFieldFocused)
                .onKeyPress(.escape) { dismissSearch(); return .handled }
                .onSubmit { navigateSearch(forward: false) }  // Enter goes upward (reverse search)
                .onChange(of: searchText) { scheduleSearch() }

            if !activeQuery.isEmpty {
                if isSearchScanning {
                    ProgressView()
                        .controlSize(.mini)
                        .tint(.white.opacity(0.5))

                    if !searchMatchIndices.isEmpty {
                        Text("\(searchMatchIndices.count) found…")
                            .font(.app(.caption2))
                            .foregroundStyle(.white.opacity(0.4))
                    }
                } else if searchMatchIndices.isEmpty {
                    Text("0 results")
                        .font(.app(.caption2))
                        .foregroundStyle(.white.opacity(0.4))
                } else {
                    Text("\(searchMatchIndices.count - currentMatchPosition)/\(searchMatchIndices.count)")
                        .font(.app(.caption2))
                        .foregroundStyle(.white.opacity(0.6))

                    Button { navigateSearch(forward: false) } label: {
                        Image(systemName: "chevron.up")
                            .font(.app(.caption2))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.white.opacity(0.6))

                    Button { navigateSearch(forward: true) } label: {
                        Image(systemName: "chevron.down")
                            .font(.app(.caption2))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.white.opacity(0.6))
                }
            }

            Button { dismissSearch() } label: {
                Image(systemName: "xmark")
                    .font(.app(.caption2))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.white.opacity(0.5))
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Color(white: 0.15))
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .padding(.horizontal, 12)
        .padding(.top, 6)
        .environment(\.colorScheme, .dark)
    }

    private func scheduleSearch() {
        searchDebounceTask?.cancel()

        // Clear immediately if empty
        if searchText.isEmpty {
            activeQuery = ""
            searchMatchIndices = []
            currentMatchPosition = 0
            searchScanTask?.cancel()
            isSearchScanning = false
            return
        }

        // Require at least 2 chars
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

                // Update match count display periodically (no position/scroll changes)
                if matches.count == 1 || matches.count % 50 == 0 {
                    searchMatchIndices = matches
                }
            }

            guard !Task.isCancelled else { return }

            // Final update — set position to most recent match, triggering scroll
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
        // Ensure the target match turn is loaded
        let targetIndex = searchMatchIndices[currentMatchPosition]
        if !turns.contains(where: { $0.index == targetIndex }) {
            onLoadAroundTurn?(targetIndex)
        }
    }

    private func dismissSearch() {
        searchDebounceTask?.cancel()
        searchScanTask?.cancel()
        isSearchScanning = false
        showSearch = false
        isSearchFieldFocused = false
        searchText = ""
        activeQuery = ""  // removes highlights
        // Don't clear searchMatchIndices/currentMatchPosition — they're harmless
        // when hidden, and clearing them would trigger onChange scroll handlers.
    }

    private var checkpointBanner: some View {
        HStack(spacing: 8) {
            Image(systemName: "clock.arrow.circlepath")
                .foregroundStyle(.orange)
            Text("Click a turn to restore to. Everything after will be removed.")
                .font(.app(.caption))
                .foregroundStyle(.white.opacity(0.8))
            Spacer()
            Button {
                onCancelCheckpoint?()
            } label: {
                Image(systemName: "xmark")
                    .font(.app(.caption))
                    .foregroundStyle(.white.opacity(0.6))
            }
            .buttonStyle(.borderless)
            .help("Cancel checkpoint mode")
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.orange.opacity(0.15))
    }

    private func scrollToCurrentMatch(proxy: ScrollViewProxy, delay: Bool) {
        guard !searchMatchIndices.isEmpty,
              currentMatchPosition < searchMatchIndices.count else { return }
        let idx = searchMatchIndices[currentMatchPosition]
        guard turns.contains(where: { $0.index == idx }) else { return }
        if delay {
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(80))
                withAnimation(.easeInOut(duration: 0.2)) {
                    proxy.scrollTo(idx, anchor: .center)
                }
            }
        } else {
            withAnimation(.easeInOut(duration: 0.2)) {
                proxy.scrollTo(idx, anchor: .center)
            }
        }
    }

    private func armAutoLoad() {
        autoLoadEnableTask?.cancel()
        autoLoadEnableTask = Task {
            try? await Task.sleep(for: .milliseconds(500))
            if !Task.isCancelled {
                autoLoadEnabled = true
            }
        }
    }

    private func scrollToBottom(proxy: ScrollViewProxy, force: Bool = false) {
        guard activeQuery.isEmpty else { return }
        guard force || isAtBottom else { return }
        // Use a task with small delay so layout completes first,
        // then scroll twice to handle late layout updates
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(50))
            proxy.scrollTo("bottom-anchor", anchor: .bottom)
            try? await Task.sleep(for: .milliseconds(100))
            proxy.scrollTo("bottom-anchor", anchor: .bottom)
        }
    }
}

// MARK: - Turn rendering

struct TurnBlockView: View {
    let turn: ConversationTurn
    var checkpointMode: Bool = false
    var isHovered: Bool = false
    var isDimmed: Bool = false
    var highlightText: String? = nil
    var isCurrentMatch: Bool = false
    var isCmdHeld: Bool = false
    var assistant: CodingAssistant = .claude


    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            if turn.role == "user" {
                userTurnView
            } else {
                assistantTurnView
            }
        }
        .opacity(isDimmed ? 0.3 : 1.0)
        .padding(.vertical, 4)
        .padding(.horizontal, 6)
        .background(
            RoundedRectangle(cornerRadius: 4)
                .fill(turnBackground)
        )
        .overlay {
            if isCurrentMatch {
                RoundedRectangle(cornerRadius: 4).stroke(Color.orange.opacity(0.7), lineWidth: 2)
            } else if isSearchMatch {
                RoundedRectangle(cornerRadius: 4).stroke(Color.yellow.opacity(0.3), lineWidth: 1)
            }
        }
        .scaleEffect(isCurrentMatch ? 1.02 : 1.0)
        .animation(.easeInOut(duration: 0.15), value: isCurrentMatch)
        .contentShape(Rectangle())
    }

    private var isSearchMatch: Bool {
        guard let query = highlightText?.lowercased(), !query.isEmpty else { return false }
        return turn.textPreview.lowercased().contains(query)
            || turn.contentBlocks.contains { $0.text.lowercased().contains(query) }
    }

    private var turnBackground: Color {
        if isHovered && checkpointMode {
            return Color.orange.opacity(0.1)
        }
        if isCurrentMatch {
            return Color.orange.opacity(0.12)
        }
        if isSearchMatch {
            return Color.yellow.opacity(0.08)
        }
        if turn.role == "user" {
            let textBlocks = turn.contentBlocks.filter { if case .text = $0.kind { true } else { false } }
            if !textBlocks.isEmpty {
                return Color(white: 0.15)
            }
        }
        return .clear
    }

    // MARK: - User turn

    private var userTurnView: some View {
        VStack(alignment: .leading, spacing: 1) {
            let textBlocks = turn.contentBlocks.filter { if case .text = $0.kind { true } else { false } }
            let toolResults = turn.contentBlocks.filter { if case .toolResult = $0.kind { true } else { false } }

            if !textBlocks.isEmpty {
                ForEach(textBlocks.indices, id: \.self) { i in
                    LinkableLine(isCmdHeld: isCmdHeld) { linksActive in
                        HStack(alignment: .top, spacing: 0) {
                            if i == 0 {
                                Text("\(assistant.historyPromptSymbol) ")
                                    .font(.app(.caption, design: .monospaced))
                                    .foregroundStyle(.green)
                                    .fontWeight(.bold)
                            } else {
                                Text("  ")
                                    .font(.app(.caption, design: .monospaced))
                            }
                            styledText(textBlocks[i].text, color: .white, linksActive: linksActive)
                                .font(.app(.caption, design: .monospaced))
                                .textSelection(.enabled)
                        }
                    }
                }
            } else if !toolResults.isEmpty {
                ForEach(toolResults.indices, id: \.self) { i in
                    toolResultLine(toolResults[i])
                }
            } else {
                LinkableLine(isCmdHeld: isCmdHeld) { linksActive in
                    HStack(alignment: .top, spacing: 0) {
                        Text("\(assistant.historyPromptSymbol) ")
                            .font(.app(.caption, design: .monospaced))
                            .foregroundStyle(.green)
                            .fontWeight(.bold)
                        styledText(turn.textPreview, color: .white, linksActive: linksActive)
                            .font(.app(.caption, design: .monospaced))
                            .textSelection(.enabled)
                    }
                }
            }
        }
    }

    // MARK: - Assistant turn

    private var assistantTurnView: some View {
        VStack(alignment: .leading, spacing: 1) {
            if turn.contentBlocks.isEmpty {
                // Fallback for old data without content blocks
                LinkableLine(isCmdHeld: isCmdHeld) { linksActive in
                    HStack(alignment: .top, spacing: 0) {
                        Text("● ")
                            .font(.app(.caption, design: .monospaced))
                            .foregroundStyle(.white)
                        styledText(turn.textPreview, color: Color(white: 0.85), linksActive: linksActive)
                            .font(.app(.caption, design: .monospaced))
                            .textSelection(.enabled)
                            .lineLimit(20)
                    }
                }
            } else {
                ForEach(turn.contentBlocks.indices, id: \.self) { i in
                    let block = turn.contentBlocks[i]
                    switch block.kind {
                    case .text:
                        textBlockView(block.text, isFirst: i == 0 || !isTextBlock(at: i - 1))
                    case .toolUse(let name, _):
                        toolUseLine(name: name, displayText: block.text)
                    case .toolResult:
                        toolResultLine(block)
                    case .thinking:
                        thinkingLine(block.text)
                    }
                }
            }
        }
    }

    private func isTextBlock(at index: Int) -> Bool {
        guard index >= 0, index < turn.contentBlocks.count else { return false }
        if case .text = turn.contentBlocks[index].kind { return true }
        return false
    }

    // MARK: - Highlighted text helper

    private func styledText(_ text: String, color: Color, linksActive: Bool = false) -> Text {
        var result = AttributedString(text)
        result.foregroundColor = color

        // Search highlighting
        if let query = highlightText?.lowercased(), !query.isEmpty {
            let lowerText = text.lowercased()
            var pos = lowerText.startIndex
            let hlBg: Color = isCurrentMatch ? .orange.opacity(0.5) : .yellow.opacity(0.35)
            let hlFg: Color = isCurrentMatch ? .orange : .yellow
            while let range = lowerText.range(of: query, range: pos..<lowerText.endIndex) {
                if let attrStart = AttributedString.Index(range.lowerBound, within: result),
                   let attrEnd = AttributedString.Index(range.upperBound, within: result) {
                    result[attrStart..<attrEnd].backgroundColor = hlBg
                    result[attrStart..<attrEnd].foregroundColor = hlFg
                }
                pos = range.upperBound
            }
        }

        // Make URLs clickable when cmd+hovering
        if linksActive {
            Self.addURLLinks(to: &result, in: text)
        }

        return Text(result)
    }

    private static let urlRegex: NSRegularExpression? = {
        try? NSRegularExpression(pattern: "https?://[^\\s<>\"'\\])*]*[^\\s<>\"'\\]).,:;!?]")
    }()

    private static func addURLLinks(to attr: inout AttributedString, in text: String) {
        guard let regex = urlRegex else { return }
        let matches = regex.matches(in: text, range: NSRange(text.startIndex..., in: text))
        for match in matches {
            guard let range = Range(match.range, in: text),
                  let attrStart = AttributedString.Index(range.lowerBound, within: attr),
                  let attrEnd = AttributedString.Index(range.upperBound, within: attr),
                  let url = URL(string: String(text[range])) else { continue }
            attr[attrStart..<attrEnd].link = url
            attr[attrStart..<attrEnd].foregroundColor = .init(red: 0.45, green: 0.65, blue: 1.0)
            attr[attrStart..<attrEnd].underlineStyle = .single
        }
    }

    // MARK: - Text block

    private func textBlockView(_ text: String, isFirst: Bool) -> some View {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return LinkableLine(isCmdHeld: isCmdHeld) { linksActive in
            HStack(alignment: .top, spacing: 0) {
                if isFirst {
                    Text("● ")
                        .font(.app(.caption, design: .monospaced))
                        .foregroundStyle(.white)
                } else {
                    Text("  ")
                        .font(.app(.caption, design: .monospaced))
                }
                styledText(trimmed, color: Color(white: 0.85), linksActive: linksActive)
                    .font(.app(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .lineLimit(30)
            }
        }
    }

    // MARK: - Tool use line

    private func toolUseLine(name: String, displayText: String) -> some View {
        LinkableLine(isCmdHeld: isCmdHeld) { linksActive in
            HStack(alignment: .top, spacing: 0) {
                Text("  ● ")
                    .font(.app(.caption, design: .monospaced))
                    .foregroundStyle(.green)
                styledText(name, color: .green.opacity(0.8), linksActive: linksActive)
                    .font(.app(.caption, design: .monospaced))
                if displayText != name {
                    let args = displayText.hasPrefix(name) ? String(displayText.dropFirst(name.count)) : "(\(displayText))"
                    styledText(args, color: Color(white: 0.5), linksActive: linksActive)
                        .font(.app(.caption, design: .monospaced))
                        .lineLimit(2)
                }
            }
        }
    }

    // MARK: - Tool result line

    private func toolResultLine(_ block: ContentBlock) -> some View {
        LinkableLine(isCmdHeld: isCmdHeld) { linksActive in
            HStack(alignment: .top, spacing: 0) {
                Text("  ⎿ ")
                    .font(.app(.caption, design: .monospaced))
                    .foregroundStyle(Color(white: 0.35))
                styledText(block.text, color: Color(white: 0.35), linksActive: linksActive)
                    .font(.app(.caption, design: .monospaced))
                    .lineLimit(3)
            }
        }
    }

    // MARK: - Thinking line

    private func thinkingLine(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 0) {
            Text("  ∴ ")
                .font(.app(.caption, design: .monospaced))
                .foregroundStyle(Color(white: 0.3))
            Text("Thinking...")
                .font(.app(.caption2, design: .monospaced))
                .foregroundStyle(Color(white: 0.3))
                .italic()
        }
    }

}

/// Wraps a line view with per-line hover tracking for cmd+click URL opening.
private struct LinkableLine<Content: View>: View {
    let isCmdHeld: Bool
    @ViewBuilder let content: (_ linksActive: Bool) -> Content
    @State private var isHovered = false

    var body: some View {
        content(isCmdHeld && isHovered)
            .onHover { isHovered = $0 }
    }
}

// MARK: - Scroll position detector

/// Observes the enclosing NSScrollView to detect whether the user is scrolled to the bottom.
/// When at bottom, auto-scroll is enabled. When the user scrolls up, auto-scroll stops.
/// Scrolling back to bottom re-enables it.
private struct ScrollBottomDetector: NSViewRepresentable {
    @Binding var isAtBottom: Bool

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async {
            guard let scrollView = view.enclosingScrollView else { return }
            let clipView = scrollView.contentView
            clipView.postsBoundsChangedNotifications = true
            NotificationCenter.default.addObserver(
                context.coordinator,
                selector: #selector(Coordinator.boundsChanged(_:)),
                name: NSView.boundsDidChangeNotification,
                object: clipView
            )
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(isAtBottom: $isAtBottom)
    }

    @MainActor class Coordinator: NSObject {
        private var isAtBottom: Binding<Bool>

        init(isAtBottom: Binding<Bool>) {
            self.isAtBottom = isAtBottom
        }

        @objc func boundsChanged(_ notification: Notification) {
            guard let clipView = notification.object as? NSClipView,
                  let documentView = clipView.documentView else { return }
            let contentHeight = documentView.frame.height
            let visibleHeight = clipView.bounds.height
            let scrollOffset = clipView.bounds.origin.y
            let threshold: CGFloat = 50
            let atBottom = scrollOffset + visibleHeight >= contentHeight - threshold
            if isAtBottom.wrappedValue != atBottom {
                DispatchQueue.main.async { [isAtBottom] in
                    isAtBottom.wrappedValue = atBottom
                }
            }
        }
    }
}

/// Continuously tracks whether the scroll view is near the top of its content.
/// Updates the binding whenever the near-top state changes.
private struct NearTopDetector: NSViewRepresentable {
    @Binding var isNearTop: Bool

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async {
            guard let scrollView = view.enclosingScrollView else { return }
            let clipView = scrollView.contentView
            clipView.postsBoundsChangedNotifications = true
            NotificationCenter.default.addObserver(
                context.coordinator,
                selector: #selector(Coordinator.boundsChanged(_:)),
                name: NSView.boundsDidChangeNotification,
                object: clipView
            )
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(isNearTop: $isNearTop)
    }

    @MainActor class Coordinator: NSObject {
        private var isNearTop: Binding<Bool>

        init(isNearTop: Binding<Bool>) {
            self.isNearTop = isNearTop
        }

        @objc func boundsChanged(_ notification: Notification) {
            guard let clipView = notification.object as? NSClipView else { return }
            let scrollOffset = clipView.bounds.origin.y
            let nearTop = scrollOffset < 300
            if isNearTop.wrappedValue != nearTop {
                DispatchQueue.main.async { [isNearTop] in
                    isNearTop.wrappedValue = nearTop
                }
            }
        }
    }
}

/// Preserves scroll position when content is prepended at the top.
/// Tracks content height incrementally and adjusts the current scroll
/// offset by the delta on each frame change, so the visible content
/// stays in place even while the user is still scrolling. Auto-stops
/// after layout settles (no frame changes for 200ms).
@MainActor class ScrollState {
    weak var scrollView: NSScrollView?
    private var lastKnownHeight: CGFloat?
    private var observer: NSObjectProtocol?
    private var settleTimer: Timer?

    var isPreserving: Bool { observer != nil }

    func captureAndPreserve() {
        guard let sv = scrollView, let docView = sv.documentView else { return }

        // Cancel any pending auto-stop from a previous load
        settleTimer?.invalidate()
        settleTimer = nil

        if observer == nil {
            lastKnownHeight = docView.frame.height

            docView.postsFrameChangedNotifications = true
            observer = NotificationCenter.default.addObserver(
                forName: NSView.frameDidChangeNotification,
                object: docView,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.handleFrameChange() }
            }
        }
    }

    func stopPreserving() {
        settleTimer?.invalidate()
        settleTimer = nil
        if let obs = observer {
            NotificationCenter.default.removeObserver(obs)
            observer = nil
        }
        lastKnownHeight = nil
    }

    private func handleFrameChange() {
        guard let sv = scrollView,
              let prevHeight = lastKnownHeight else { return }

        let newHeight = sv.documentView?.frame.height ?? prevHeight
        let delta = newHeight - prevHeight
        lastKnownHeight = newHeight
        guard delta > 0 else { return }

        // Add the incremental height growth to the current scroll offset
        let currentOffset = sv.contentView.bounds.origin.y
        sv.contentView.setBoundsOrigin(NSPoint(x: 0, y: currentOffset + delta))
        sv.reflectScrolledClipView(sv.contentView)

        // Auto-stop after layout settles (no frame changes for 200ms)
        settleTimer?.invalidate()
        settleTimer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.stopPreserving() }
        }
    }
}

/// Grabs a reference to the enclosing NSScrollView for ScrollState.
private struct ScrollViewCapture: NSViewRepresentable {
    let scrollState: ScrollState

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async { [scrollState] in
            scrollState.scrollView = view.enclosingScrollView
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}
