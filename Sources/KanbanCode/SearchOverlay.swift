import SwiftUI
import KanbanCodeCore

struct SearchOverlay: View {
    @Binding var isPresented: Bool
    let cards: [KanbanCodeCard]
    let sessionStore: SessionStore
    var onSelectCard: (KanbanCodeCard) -> Void = { _ in }
    var onResumeCard: (KanbanCodeCard) -> Void = { _ in }
    var onForkCard: (KanbanCodeCard) -> Void = { _ in }
    var onCheckpointCard: (KanbanCodeCard) -> Void = { _ in }
    var channels: [Channel] = []
    /// Map from channel name → last-opened timestamp (bumped on drawer selection).
    /// Sorted alongside `card.link.lastOpenedAt` so the palette orders both by
    /// recency-of-attention.
    var channelLastOpened: [String: Date] = [:]
    /// Map from channel name → last message timestamp. Used only for the
    /// "3m ago" subtitle on the channel row.
    var channelLastActivity: [String: Date] = [:]
    var onSelectChannel: (String) -> Void = { _ in }

    // Command palette actions
    var commands: [CommandItem] = []
    var initialQuery: String = ""
    var deepSearchTrigger: Bool = false

    /// Snapshot of cards at open time — avoids re-rendering when store reconciles.
    @State private var snapshotCards: [KanbanCodeCard] = []
    @State private var cardSearchIndex: [CardSearchIndexItem] = []
    @State private var query = ""
    @State private var searchResults: [SearchResultItem] = []
    @State private var filteredItems: [RecentItem] = []
    @State private var isDeepSearching = false
    @State private var selectedId: String?
    @State private var searchTask: Task<Void, Never>?
    @State private var searchGeneration = 0
    @State private var focusRequestToken = 0
    @FocusState private var isSearchFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            searchFieldBar
            Divider()
            resultsSection
        }
        .frame(maxWidth: 600, maxHeight: 500)
        .glassOverlay()
        .onAppear(perform: handleAppear)
        .onExitCommand { isPresented = false }
        .onKeyPress(.downArrow) { moveSelection(by: 1); return .handled }
        .onKeyPress(.upArrow) { moveSelection(by: -1); return .handled }
        .onKeyPress(.return) { handleReturn(); return .handled }
        .onChange(of: deepSearchTrigger) { Task { await deepSearch() } }
        .onChange(of: query) { _, newValue in handleQueryChange(newValue) }
    }

    private static let scrollTopId = "search-top-anchor"

    private var resultsSection: some View {
        ScrollViewReader { proxy in
            ScrollView {
                // Lazy, because a query can produce 80 quick results or a deep
                // search a screenful of snippet rows. An eager stack rebuilds
                // every one of them on each incremental scroll update, which is
                // what made trackpad scrolling crawl while dragging the scroller
                // (far fewer, larger updates) stayed smooth.
                LazyVStack(alignment: .leading, spacing: 4) {
                    Color.clear.frame(height: 0).id(Self.scrollTopId)
                    if isCommandMode {
                        commandsView
                    } else if query.isEmpty {
                        recentCardsView
                    } else if !searchResults.isEmpty {
                        deepSearchResultsView
                    } else if !isDeepSearching {
                        filteredCardsView
                    }
                }
                .padding(8)
            }
            .onChange(of: selectedId) { _, newId in
                if let newId {
                    withAnimation { proxy.scrollTo(newId, anchor: .center) }
                }
            }
            .onChange(of: query) {
                proxy.scrollTo(Self.scrollTopId, anchor: .top)
            }
        }
    }

    private var deepSearchResultsView: some View {
        ForEach(searchResults) { result in
            SearchResultRow(result: result, queryTerms: queryTerms, isHighlighted: result.id == selectedId)
                .onTapGesture {
                    if let card = result.card {
                        onSelectCard(card)
                        isPresented = false
                    }
                }
                .contextMenu {
                    if let card = result.card {
                        searchCardContextMenu(for: card)
                    }
                }
        }
    }

    private func handleAppear() {
        snapshotCards = cards  // Freeze cards at open time
        cardSearchIndex = cards.map(CardSearchIndexItem.init(card:))
        requestSearchFocus()
        if !initialQuery.isEmpty {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                query = initialQuery
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.02) {
                    requestSearchFocus()
                    moveCursorToEnd()
                }
            }
        }
        if initialQuery.isEmpty {
            // Second item = "the thing before what's currently open" — Enter jumps back.
            let merged = mergedRecent
            if merged.count >= 2 {
                selectedId = merged[1].id
            } else {
                selectedId = merged.first?.id
            }
        }
    }

    private func handleReturn() {
        if selectedId != nil {
            selectCurrentItem()
        } else {
            Task { await deepSearch() }
        }
    }

    private func handleQueryChange(_ newValue: String) {
        updateFilter(newValue)
        if newValue.hasPrefix(">") {
            filteredItems = []
            selectedId = filteredCommands.first?.id
        } else if !newValue.isEmpty {
            let cards = computeFilteredCards(query: newValue)
            let items = computeFilteredItems(query: newValue, cards: cards)
            filteredItems = items
            selectedId = items.first?.id
        } else {
            filteredItems = []
            let merged = mergedRecent
            selectedId = merged.count >= 2 ? merged[1].id : merged.first?.id
        }
    }

    private var isCommandMode: Bool { query.hasPrefix(">") }

    private var commandQuery: String {
        guard isCommandMode else { return "" }
        return String(query.dropFirst()).trimmingCharacters(in: .whitespaces).lowercased()
    }

    private var filteredCommands: [CommandItem] {
        let q = commandQuery
        if q.isEmpty { return commands }
        return commands.filter { $0.title.lowercased().contains(q) }
    }

    private var recentSortedCards: [KanbanCodeCard] {
        snapshotCards.sorted {
            let t0 = $0.link.lastOpenedAt ?? $0.link.lastActivity ?? $0.link.updatedAt
            let t1 = $1.link.lastOpenedAt ?? $1.link.lastActivity ?? $1.link.updatedAt
            return t0 > t1
        }
    }

    /// Single merged list of channels + cards, sorted by recency-of-attention
    /// (last opened) so Cmd+K → Enter returns the user to whatever drawer they
    /// were last in, regardless of whether that was a chat or a card.
    enum RecentItem: Identifiable {
        case channel(Channel, opened: Date?, lastActivity: Date?)
        case card(KanbanCodeCard)

        var id: String {
            switch self {
            case .channel(let ch, _, _): return "channel:\(ch.name)"
            case .card(let c): return c.id
            }
        }

        var sortKey: Date {
            switch self {
            case .channel(_, let opened, let activity):
                return opened ?? activity ?? .distantPast
            case .card(let c):
                return c.link.lastOpenedAt ?? c.link.lastActivity ?? c.link.updatedAt
            }
        }
    }

    private var mergedRecent: [RecentItem] {
        let cardItems = snapshotCards.map(RecentItem.card)
        let channelItems = channels.map {
            RecentItem.channel($0, opened: channelLastOpened[$0.name], lastActivity: channelLastActivity[$0.name])
        }
        return (cardItems + channelItems).sorted { $0.sortKey > $1.sortKey }
    }

    private var queryTerms: [String] {
        SessionSearchQuery(query).snippetTerms
    }

    private var searchFieldBar: some View {
        HStack {
            Image(systemName: "magnifyingglass")
                .font(.app(.title3))
                .foregroundStyle(.secondary)
            TextField("Search or type > for commands...", text: $query)
                .textFieldStyle(.plain)
                .font(.app(.title3))
                .focused($isSearchFocused)
                .background(SearchTextFieldFocusBridge(trigger: focusRequestToken))

            if isDeepSearching {
                ProgressView()
                    .controlSize(.small)
            }

            if !query.isEmpty {
                deepSearchHint
            }

            Button("Esc") {
                isPresented = false
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
        .padding(16)
    }

    private var deepSearchHint: some View {
        HStack(spacing: 4) {
            Text("⌘↩ deep search")
                .font(.app(.caption))
                .foregroundStyle(.tertiary)

            Button(action: { query = "" }) {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.borderless)
        }
    }

    /// All visible item IDs in current order
    private var visibleIds: [String] {
        if isCommandMode {
            return filteredCommands.map(\.id)
        } else if query.isEmpty {
            return Array(mergedRecent.prefix(24)).map(\.id)
        } else if !searchResults.isEmpty {
            return searchResults.map(\.id)
        } else {
            return filteredItems.map(\.id)
        }
    }

    private static let maxQuickResults = 80

    /// When the user types a query, match against channel names + card fields and
    /// interleave both in a single recency-ordered list. This is materialized
    /// during query changes so selection and rendering use the same snapshot.
    private func computeFilteredItems(query: String, cards: [KanbanCodeCard]) -> [RecentItem] {
        let channelMatches = matchedChannelsForQuery(query).map {
            RecentItem.channel($0, opened: channelLastOpened[$0.name], lastActivity: channelLastActivity[$0.name])
        }
        let cardMatches = cards.map(RecentItem.card)
        return Array((channelMatches + cardMatches).sorted { $0.sortKey > $1.sortKey }.prefix(Self.maxQuickResults))
    }

    private func moveSelection(by offset: Int) {
        let ids = visibleIds
        guard !ids.isEmpty else { return }

        if let currentId = selectedId, let currentIdx = ids.firstIndex(of: currentId) {
            let newIdx = currentIdx + offset
            if newIdx < 0 {
                // Up past first item — deselect (allows Enter for deep search)
                selectedId = nil
            } else {
                selectedId = ids[min(newIdx, ids.count - 1)]
            }
        } else {
            selectedId = offset > 0 ? ids.first : ids.last
        }
    }

    private func selectCurrentItem() {
        guard let currentId = selectedId else { return }

        // Channels share the "channel:<name>" id scheme everywhere.
        if currentId.hasPrefix("channel:") {
            let name = String(currentId.dropFirst("channel:".count))
            onSelectChannel(name)
            isPresented = false
            return
        }

        if isCommandMode {
            if let cmd = filteredCommands.first(where: { $0.id == currentId }) {
                cmd.action()
                isPresented = false
            }
        } else if !searchResults.isEmpty {
            if let result = searchResults.first(where: { $0.id == currentId }),
               let card = result.card {
                onSelectCard(card)
                isPresented = false
            }
        } else if let card = snapshotCards.first(where: { $0.id == currentId }) {
            onSelectCard(card)
            isPresented = false
        } else if !query.isEmpty {
            // No match — trigger deep search
            Task { await deepSearch() }
        }
    }

    private var recentCardsView: some View {
        Group {
            Text("Recent")
                .font(.app(.caption))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 8)
                .padding(.top, 4)

            ForEach(Array(mergedRecent.prefix(24))) { item in
                mergedItemRow(item, queryTerms: [])
            }
        }
    }

    @ViewBuilder
    private func mergedItemRow(_ item: RecentItem, queryTerms: [String]) -> some View {
        switch item {
        case .channel(let ch, _, let lastActivity):
            let id = "channel:\(ch.name)"
            ChannelSearchRow(channel: ch, lastActivity: lastActivity, isHighlighted: id == selectedId)
                .id(id)
                .onTapGesture {
                    onSelectChannel(ch.name)
                    isPresented = false
                }
        case .card(let card):
            let cardId = card.id
            SearchCardRow(card: card, queryTerms: queryTerms, isHighlighted: cardId == selectedId)
                .id(cardId)
                .onTapGesture {
                    onSelectCard(card)
                    isPresented = false
                }
                .contextMenu { searchCardContextMenu(for: card) }
        }
    }

    private var commandsView: some View {
        Group {
            Text("Commands")
                .font(.app(.caption))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 8)
                .padding(.top, 4)

            let cmds = filteredCommands
            if cmds.isEmpty {
                Text("No matching commands")
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity)
                    .padding(.top, 20)
            } else {
                ForEach(cmds) { cmd in
                    CommandRow(command: cmd, isHighlighted: cmd.id == selectedId)
                        .id(cmd.id)
                        .onTapGesture {
                            cmd.action()
                            isPresented = false
                        }
                }
            }
        }
    }

    private var filteredCardsView: some View {
        Group {
            if filteredItems.isEmpty {
                VStack(spacing: 8) {
                    Text("No matches")
                        .foregroundStyle(.secondary)
                    Text("Press Enter to deep search .jsonl files")
                        .font(.app(.caption))
                        .foregroundStyle(.tertiary)
                }
                .frame(maxWidth: .infinity)
                .padding(.top, 20)
            } else {
                ForEach(filteredItems) { item in
                    mergedItemRow(item, queryTerms: queryTerms)
                }
            }
        }
    }

    private func matchedChannelsForQuery(_ rawQuery: String) -> [Channel] {
        let q = rawQuery.trimmingCharacters(in: .whitespaces).lowercased()
            .replacingOccurrences(of: "#", with: "")
        guard !q.isEmpty else { return [] }
        return channels.filter { $0.name.contains(q) }
    }

    private func computeFilteredCards(query: String) -> [KanbanCodeCard] {
        let terms = query.lowercased().components(separatedBy: .whitespaces).filter { !$0.isEmpty }
        guard !terms.isEmpty else { return [] }

        return cardSearchIndex
            .compactMap { item -> (KanbanCodeCard, Double)? in
                var score = 0.0
                for term in terms {
                    let s = Self.termScore(
                        term,
                        titleWords: item.titleWords,
                        title: item.title,
                        projectWords: item.projectWords,
                        project: item.project,
                        branch: item.branch,
                        other: item.other
                    )
                    if s > 0 {
                        score += s
                    } else if term.count >= 2, Self.fuzzyInitials(term, words: item.titleWords) {
                        score += 10 // "kp" → Kanban Projects
                    } else {
                        return nil
                    }
                }

                if item.isActiveColumn { score += 20 }

                // Recency bonus: up to +5 for very recent, decaying over 7 days
                let age = Date.now.timeIntervalSince(item.lastActive)
                let maxAge: TimeInterval = 7 * 24 * 3600
                if age < maxAge {
                    score += 5.0 * (1.0 - age / maxAge)
                }

                return (item.card, score)
            }
            .sorted { $0.1 > $1.1 }
            .map(\.0)
    }

    /// Score a single search term against card fields.
    /// Word-start matches score much higher than mid-word matches.
    private static func termScore(_ term: String, titleWords: [String], title: String, projectWords: [String], project: String, branch: String, other: String) -> Double {
        // Title: word-start match (best)
        for word in titleWords {
            if word == term { return 15 }       // exact word
            if word.hasPrefix(term) { return 12 } // word prefix
        }
        if title.contains(term) { return 6 }   // mid-word substring

        // Project: word-start match
        for word in projectWords {
            if word == term { return 8 }
            if word.hasPrefix(term) { return 7 }
        }
        if project.contains(term) { return 4 }

        // Branch / other
        if branch.contains(term) { return 3 }
        if other.contains(term) { return 1 }
        return 0
    }

    /// Check if each character of `term` matches the first letter of consecutive words.
    /// e.g. "kp" matches ["kanban", "projects"], "kl3" matches ["kanban", "loop", "3"]
    private static func fuzzyInitials(_ term: String, words: [String]) -> Bool {
        var i = term.startIndex
        for word in words {
            guard i < term.endIndex else { break }
            if let first = word.first, first == term[i] {
                i = term.index(after: i)
            }
        }
        return i == term.endIndex
    }

    @ViewBuilder
    private func searchCardContextMenu(for card: KanbanCodeCard) -> some View {
        Button {
            onResumeCard(card)
            isPresented = false
        } label: {
            Label("Resume Session", systemImage: "play.fill")
        }
        .disabled(card.link.sessionLink == nil)

        Button {
            onForkCard(card)
            isPresented = false
        } label: {
            Label("Fork Session", systemImage: "arrow.branch")
        }
        .disabled(card.link.sessionLink?.sessionPath == nil)

        Button {
            onCheckpointCard(card)
            isPresented = false
        } label: {
            Label("Checkpoint / Restore", systemImage: "clock.arrow.circlepath")
        }
        .disabled(card.link.sessionLink?.sessionPath == nil)
    }

    private func moveCursorToEnd() {
        guard let window = NSApp.keyWindow,
              let fieldEditor = window.fieldEditor(false, for: nil) as? NSTextView else { return }
        fieldEditor.setSelectedRange(NSRange(location: fieldEditor.string.count, length: 0))
    }

    private func requestSearchFocus() {
        isSearchFocused = true
        focusRequestToken += 1
        DispatchQueue.main.async { isSearchFocused = true }
    }

    private func updateFilter(_ query: String) {
        // Cancel any in-progress deep search when query changes, but keep the
        // handle. Cancellation is cooperative, so the scan is still winding
        // down through its open files; dropping the reference here lets the
        // next keystroke start a second full-corpus scan beside the first, and
        // the two then compete for the same disk.
        searchTask?.cancel()
        searchResults = []
        isDeepSearching = false
    }

    private func deepSearch() async {
        guard !query.isEmpty else { return }

        // Cancel previous search and wait for it to stop. Waiting is a suspension
        // point, so a third keystroke can start its own search meanwhile; without
        // the generation check both would run and the older one would no longer
        // be tracked in searchTask, making it impossible to cancel.
        searchGeneration += 1
        let generation = searchGeneration
        if let old = searchTask {
            old.cancel()
            _ = await old.value
            guard generation == searchGeneration else { return }
            searchTask = nil
        }

        let currentQuery = query
        let currentCards = snapshotCards
        let t0 = ContinuousClock.now
        KanbanCodeLog.info("search", "deepSearch START query='\(currentQuery)' cards=\(currentCards.count)")

        let searchQuery = SessionSearchQuery(currentQuery)

        // Build path→card lookup once, preserving a search order that checks
        // direct PR matches and active/recent cards before archived history.
        var cardByPath: [String: KanbanCodeCard] = [:]
        var orderedPaths: [String] = []
        var seenPaths: Set<String> = []
        for card in currentCards.sorted(by: { lhs, rhs in
            deepSearchPriority(lhs, query: searchQuery) > deepSearchPriority(rhs, query: searchQuery)
        }) {
            if let p = card.link.sessionLink?.sessionPath ?? card.session?.jsonlPath {
                cardByPath[p] = card
                if seenPaths.insert(p).inserted {
                    orderedPaths.append(p)
                }
            }
        }

        let task = Task { @MainActor in
            isDeepSearching = true
            defer {
                isDeepSearching = false
                KanbanCodeLog.info("search", "deepSearch END query='\(currentQuery)' elapsed=\(t0.duration(to: .now)) cancelled=\(Task.isCancelled)")
            }

            let paths = orderedPaths
            KanbanCodeLog.info("search", "deepSearch: \(paths.count) session paths to search")

            do {
                try await sessionStore.searchSessionsStreaming(
                    query: currentQuery, paths: paths
                ) { [cardByPath] results in
                    let maxScore = results.first?.score ?? 1.0
                    searchResults = results.map { result in
                        SearchResultItem(
                            id: result.sessionPath,
                            card: cardByPath[result.sessionPath],
                            score: result.score,
                            maxScore: maxScore,
                            snippets: result.snippets
                        )
                    }
                }
            } catch is CancellationError {
                KanbanCodeLog.info("search", "deepSearch cancelled after \(t0.duration(to: .now))")
            } catch {
                KanbanCodeLog.error("search", "deepSearch error: \(error)")
            }
        }
        searchTask = task
        await task.value
    }

    private func deepSearchPriority(_ card: KanbanCodeCard, query: SessionSearchQuery) -> Double {
        var score = 0.0

        if !query.prNumbers.isEmpty {
            let linkedPRs = Set(card.link.prLinks.map { String($0.number) })
            if query.prNumbers.contains(where: linkedPRs.contains) {
                score += 10_000
            }
        }

        switch card.column {
        case .inReview: score += 600
        case .inProgress: score += 500
        case .waiting: score += 400
        case .done: score += 300
        case .backlog: score += 200
        case .allSessions: score += 0
        }

        let recency = card.link.lastActivity ?? card.link.updatedAt
        score += recency.timeIntervalSince1970 / 1_000_000_000
        return score
    }
}

private struct CardSearchIndexItem {
    let card: KanbanCodeCard
    let title: String
    let project: String
    let branch: String
    let other: String
    let titleWords: [String]
    let projectWords: [String]
    let isActiveColumn: Bool
    let lastActive: Date

    init(card: KanbanCodeCard) {
        self.card = card
        title = card.displayTitle.lowercased()
        project = (card.projectName ?? "").lowercased()
        branch = (card.link.worktreeLink?.branch ?? "").lowercased()
        let prText = card.link.prLinks
            .map { pr in
                ["pr #\(pr.number)", "#\(pr.number)", "pull/\(pr.number)", pr.url, pr.title]
                    .compactMap { $0 }
                    .joined(separator: " ")
            }
            .joined(separator: " ")
        other = "\(card.link.projectPath ?? "") \(card.session?.firstPrompt ?? "") \(card.link.promptBody ?? "") \(card.link.sessionLink?.sessionId ?? "") \(card.link.id) \(prText)".lowercased()
        titleWords = title.split { !$0.isLetter && !$0.isNumber }.map(String.init)
        projectWords = project.split { !$0.isLetter && !$0.isNumber }.map(String.init)
        isActiveColumn = [.inProgress, .waiting, .inReview, .done].contains(card.column)
        lastActive = card.link.lastActivity ?? card.link.updatedAt
    }
}

struct SearchResultItem: Identifiable {
    let id: String
    let card: KanbanCodeCard?
    let score: Double
    let maxScore: Double
    let snippets: [String]
}

struct SearchCardRow: View {
    let card: KanbanCodeCard
    let queryTerms: [String]
    var isHighlighted: Bool = false

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 3) {
                HighlightedText(text: card.displayTitle, terms: queryTerms)
                    .font(.app(.body))
                    .lineLimit(1)

                HStack(spacing: 6) {
                    AssistantIcon(assistant: card.link.effectiveAssistant)
                        .frame(width: 10, height: 10)
                        .opacity(0.6)

                    if let project = card.projectName {
                        Text(project)
                            .font(.app(.caption))
                            .foregroundStyle(.secondary)
                    }

                    CardBadgesRow(card: card)

                    Text(card.relativeTime)
                        .font(.app(.caption))
                        .foregroundStyle(.tertiary)
                }
            }
            Spacer()
            HStack(spacing: 4) {
                Circle()
                    .fill(card.column.accentColor)
                    .frame(width: 7, height: 7)
                Text(card.column.displayName)
                    .font(.app(.caption2))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Capsule().fill(Color.secondary.opacity(0.15)))
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .contentShape(Rectangle())
        .background(isHighlighted ? Color.accentColor.opacity(0.18) : Color.clear, in: RoundedRectangle(cornerRadius: 6))
        .overlay {
            if isHighlighted {
                RoundedRectangle(cornerRadius: 6)
                    .stroke(Color.accentColor.opacity(0.45), lineWidth: 1)
            }
        }
    }
}

struct SearchResultRow: View {
    let result: SearchResultItem
    let queryTerms: [String]
    var isHighlighted: Bool = false

    var body: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    if let card = result.card {
                        HighlightedText(text: card.displayTitle, terms: queryTerms, fuzzyInitials: false)
                            .font(.app(.body))
                            .lineLimit(1)
                    } else {
                        Text((result.id as NSString).lastPathComponent)
                            .font(.app(.body))
                            .lineLimit(1)
                    }
                    Spacer()
                }

                // Snippets (up to 3)
                ForEach(Array(result.snippets.enumerated()), id: \.offset) { _, snippet in
                    HighlightedText(text: snippet, terms: queryTerms, fuzzyInitials: false)
                        .font(.app(.caption))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }

            // Relevance bar — horizontal, thick, right side
            let ratio = result.maxScore > 0 ? result.score / result.maxScore : 0
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 3)
                    .fill(Color.secondary.opacity(0.1))
                RoundedRectangle(cornerRadius: 3)
                    .fill(Color.accentColor.opacity(0.5))
                    .frame(width: 50 * ratio)
            }
            .frame(width: 50, height: 14)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .contentShape(Rectangle())
        .background(isHighlighted ? Color.accentColor.opacity(0.2) : Color.clear, in: RoundedRectangle(cornerRadius: 6))
        .overlay {
            if isHighlighted {
                RoundedRectangle(cornerRadius: 6)
                    .stroke(Color.accentColor.opacity(0.45), lineWidth: 1)
            }
        }
    }
}

struct CommandRow: View {
    let command: CommandItem
    var isHighlighted: Bool = false

    var body: some View {
        HStack {
            Image(systemName: command.icon)
                .frame(width: 20)
                .foregroundStyle(.secondary)
            Text(command.title)
                .font(.app(.body))
            Spacer()
            if let shortcut = command.shortcut {
                Text(shortcut)
                    .font(.app(.caption))
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 4))
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .contentShape(Rectangle())
        .background(isHighlighted ? Color.accentColor.opacity(0.18) : Color.clear, in: RoundedRectangle(cornerRadius: 6))
        .overlay {
            if isHighlighted {
                RoundedRectangle(cornerRadius: 6)
                    .stroke(Color.accentColor.opacity(0.45), lineWidth: 1)
            }
        }
    }
}

/// Highlights query terms in text with yellow background.
struct HighlightedText: View {
    let text: String
    let terms: [String]
    var fuzzyInitials: Bool = true

    var body: some View {
        if terms.isEmpty {
            Text(text)
        } else {
            Text(attributedString)
        }
    }

    private var attributedString: AttributedString {
        var attr = AttributedString(text)
        let lower = text.lowercased()
        let words = lower.split { !$0.isLetter && !$0.isNumber }

        for term in terms {
            // Try substring matching first
            var foundSubstring = false
            var searchStart = lower.startIndex
            while let range = lower.range(of: term, range: searchStart..<lower.endIndex) {
                foundSubstring = true
                let attrStart = AttributedString.Index(range.lowerBound, within: attr)
                let attrEnd = AttributedString.Index(range.upperBound, within: attr)
                if let start = attrStart, let end = attrEnd {
                    attr[start..<end].backgroundColor = .yellow.opacity(0.3)
                }
                searchStart = range.upperBound
            }

            // Fall back to fuzzy initials highlighting (only for quick filter, not deep search)
            if fuzzyInitials && !foundSubstring && term.count >= 2 {
                var termIdx = term.startIndex
                for word in words {
                    guard termIdx < term.endIndex else { break }
                    if let first = word.first, first == term[termIdx] {
                        let charIdx = word.startIndex
                        let nextIdx = lower.index(after: charIdx)
                        if let attrStart = AttributedString.Index(charIdx, within: attr),
                           let attrEnd = AttributedString.Index(nextIdx, within: attr) {
                            attr[attrStart..<attrEnd].backgroundColor = .yellow.opacity(0.3)
                        }
                        termIdx = term.index(after: termIdx)
                    }
                }
            }
        }
        return attr
    }
}

struct ChannelSearchRow: View {
    let channel: Channel
    var lastActivity: Date? = nil
    let isHighlighted: Bool

    private var relativeTime: String? {
        guard let ts = lastActivity else { return nil }
        let secs = Date().timeIntervalSince(ts)
        switch secs {
        case ..<60: return "just now"
        case ..<3600: return "\(Int(secs / 60))m ago"
        case ..<86400: return "\(Int(secs / 3600))h ago"
        default: return "\(Int(secs / 86400))d ago"
        }
    }

    // Mirrors `SearchCardRow`: two-line layout, title on top, metadata
    // (icon + member count + time) on a secondary line.
    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 3) {
                Text("#\(channel.name)")
                    .font(.app(.body))
                    .lineLimit(1)

                HStack(spacing: 6) {
                    Image(systemName: "number")
                        .font(.app(.caption))
                        .foregroundStyle(.secondary)
                        .opacity(0.6)

                    Text("\(channel.members.count) member\(channel.members.count == 1 ? "" : "s")")
                        .font(.app(.caption))
                        .foregroundStyle(.secondary)

                    if let rel = relativeTime {
                        Text(rel)
                            .font(.app(.caption))
                            .foregroundStyle(.tertiary)
                    }
                }
            }
            Spacer()
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .contentShape(Rectangle())
        .background(isHighlighted ? Color.accentColor.opacity(0.18) : Color.clear, in: RoundedRectangle(cornerRadius: 6))
        .overlay {
            if isHighlighted {
                RoundedRectangle(cornerRadius: 6)
                    .stroke(Color.accentColor.opacity(0.45), lineWidth: 1)
            }
        }
    }
}

private struct SearchTextFieldFocusBridge: NSViewRepresentable {
    let trigger: Int

    func makeNSView(context: Context) -> NSView {
        NSView(frame: .zero)
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        _ = trigger
        let delays: [TimeInterval] = [0.0, 0.05, 0.15, 0.35]
        for delay in delays {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                focusSearchField(from: nsView)
            }
        }
    }

    private func focusSearchField(from view: NSView) {
        guard let window = view.window,
              let field = findSearchField(in: window.contentView) else { return }
        window.makeFirstResponder(field)
        if let editor = window.fieldEditor(false, for: field) as? NSTextView {
            editor.setSelectedRange(NSRange(location: editor.string.count, length: 0))
        }
    }

    private func findSearchField(in view: NSView?) -> NSTextField? {
        guard let view else { return nil }
        if let field = view as? NSTextField,
           field.placeholderString == "Search or type > for commands..." {
            return field
        }
        for subview in view.subviews {
            if let found = findSearchField(in: subview) {
                return found
            }
        }
        return nil
    }
}
