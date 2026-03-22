import SwiftUI
import KanbanCodeCore

struct CommandItem: Identifiable {
    let id: String
    let title: String
    let icon: String
    let shortcut: String?
    let action: () -> Void

    init(_ title: String, icon: String, shortcut: String? = nil, action: @escaping () -> Void) {
        self.id = "cmd:\(title)"
        self.title = title
        self.icon = icon
        self.shortcut = shortcut
        self.action = action
    }
}

struct SearchOverlay: View {
    @Binding var isPresented: Bool
    let cards: [KanbanCodeCard]
    let sessionStore: SessionStore
    var onSelectCard: (KanbanCodeCard) -> Void = { _ in }
    var onResumeCard: (KanbanCodeCard) -> Void = { _ in }
    var onForkCard: (KanbanCodeCard) -> Void = { _ in }
    var onCheckpointCard: (KanbanCodeCard) -> Void = { _ in }

    // Command palette actions
    var commands: [CommandItem] = []
    var initialQuery: String = ""
    var deepSearchTrigger: Bool = false

    /// Snapshot of cards at open time — avoids re-rendering when store reconciles.
    @State private var snapshotCards: [KanbanCodeCard] = []
    @State private var query = ""
    @State private var searchResults: [SearchResultItem] = []
    @State private var filteredCards: [KanbanCodeCard] = []
    @State private var isDeepSearching = false
    @State private var selectedId: String?
    @State private var searchTask: Task<Void, Never>?
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

    private var resultsSection: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 4) {
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
        isSearchFocused = true
        if !initialQuery.isEmpty {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                query = initialQuery
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.02) {
                    moveCursorToEnd()
                }
            }
        }
        if initialQuery.isEmpty {
            let sorted = recentSortedCards
            if sorted.count >= 2 {
                selectedId = sorted[1].id
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
            filteredCards = []
            selectedId = filteredCommands.first?.id
        } else if !newValue.isEmpty {
            filteredCards = computeFilteredCards(query: newValue)
            selectedId = filteredCards.first?.id
        } else {
            filteredCards = []
            let sorted = recentSortedCards
            selectedId = sorted.count >= 2 ? sorted[1].id : sorted.first?.id
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

    private var queryTerms: [String] {
        query.lowercased().components(separatedBy: .whitespaces).filter { !$0.isEmpty }
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
            return Array(recentSortedCards.prefix(20)).map(\.id)
        } else if !searchResults.isEmpty {
            return searchResults.map(\.id)
        } else {
            return filteredCards.map(\.id)
        }
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

        if isCommandMode {
            if let cmd = filteredCommands.first(where: { $0.id == currentId }) {
                cmd.action()
                isPresented = false
            }
        } else if query.isEmpty {
            if let card = recentSortedCards.prefix(20).first(where: { $0.id == currentId }) {
                onSelectCard(card)
                isPresented = false
            }
        } else if !searchResults.isEmpty {
            if let result = searchResults.first(where: { $0.id == currentId }),
               let card = result.card {
                onSelectCard(card)
                isPresented = false
            }
        } else {
            if let card = filteredCards.first(where: { $0.id == currentId }) {
                onSelectCard(card)
                isPresented = false
            } else {
                // No match — trigger deep search
                Task { await deepSearch() }
            }
        }
    }

    private var recentCardsView: some View {
        Group {
            Text("Recent")
                .font(.app(.caption))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 8)
                .padding(.top, 4)

            ForEach(Array(recentSortedCards.prefix(20))) { card in
                let cardId = card.id
                SearchCardRow(card: card, queryTerms: [], isHighlighted: cardId == selectedId)
                    .id(cardId)
                    .onTapGesture {
                        onSelectCard(card)
                        isPresented = false
                    }
                    .contextMenu { searchCardContextMenu(for: card) }
            }
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
            if filteredCards.isEmpty {
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
                ForEach(filteredCards) { card in
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
        }
    }

    private func computeFilteredCards(query: String) -> [KanbanCodeCard] {
        let terms = queryTerms
        guard !terms.isEmpty else { return [] }
        let activeColumns: Set<KanbanCodeColumn> = [.inProgress, .waiting, .inReview, .done]

        return snapshotCards
            .compactMap { card -> (KanbanCodeCard, Double)? in
                let title = card.displayTitle.lowercased()
                let project = (card.projectName ?? "").lowercased()
                let branch = (card.link.worktreeLink?.branch ?? "").lowercased()
                let other = "\(card.link.projectPath ?? "") \(card.session?.firstPrompt ?? "") \(card.link.promptBody ?? "") \(card.link.sessionLink?.sessionId ?? "") \(card.link.id)".lowercased()

                let titleWords = title.split { !$0.isLetter && !$0.isNumber }.map(String.init)
                let projectWords = project.split { !$0.isLetter && !$0.isNumber }.map(String.init)

                var score = 0.0
                for term in terms {
                    let s = Self.termScore(term, titleWords: titleWords, title: title, projectWords: projectWords, project: project, branch: branch, other: other)
                    if s > 0 {
                        score += s
                    } else if term.count >= 2, Self.fuzzyInitials(term, words: titleWords) {
                        score += 10 // "kp" → Kanban Projects
                    } else {
                        return nil
                    }
                }

                if activeColumns.contains(card.column) { score += 20 }

                // Recency bonus: up to +5 for very recent, decaying over 7 days
                let lastActive = card.link.lastActivity ?? card.link.updatedAt
                let age = Date.now.timeIntervalSince(lastActive)
                let maxAge: TimeInterval = 7 * 24 * 3600
                if age < maxAge {
                    score += 5.0 * (1.0 - age / maxAge)
                }

                return (card, score)
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

    private func updateFilter(_ query: String) {
        // Cancel any in-progress deep search when query changes
        searchTask?.cancel()
        searchTask = nil
        searchResults = []
        isDeepSearching = false
    }

    private func deepSearch() async {
        guard !query.isEmpty else { return }

        // Cancel previous search and wait for it to stop
        if let old = searchTask {
            old.cancel()
            _ = await old.value
            searchTask = nil
        }

        let currentQuery = query
        let currentCards = snapshotCards
        let t0 = ContinuousClock.now
        KanbanCodeLog.info("search", "deepSearch START query='\(currentQuery)' cards=\(currentCards.count)")

        // Build path→card lookup once
        var cardByPath: [String: KanbanCodeCard] = [:]
        for card in currentCards {
            if let p = card.link.sessionLink?.sessionPath ?? card.session?.jsonlPath {
                cardByPath[p] = card
            }
        }

        let task = Task { @MainActor in
            isDeepSearching = true
            defer {
                isDeepSearching = false
                KanbanCodeLog.info("search", "deepSearch END query='\(currentQuery)' elapsed=\(t0.duration(to: .now)) cancelled=\(Task.isCancelled)")
            }

            let paths = Array(cardByPath.keys)
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
        .background(
            isHighlighted ? Color.accentColor.opacity(0.1) : Color.clear,
            in: RoundedRectangle(cornerRadius: 6)
        )
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
        .background(
            isHighlighted ? Color.accentColor.opacity(0.15) : Color.clear,
            in: RoundedRectangle(cornerRadius: 6)
        )
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
        .background(
            isHighlighted ? Color.accentColor.opacity(0.1) : Color.clear,
            in: RoundedRectangle(cornerRadius: 6)
        )
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
