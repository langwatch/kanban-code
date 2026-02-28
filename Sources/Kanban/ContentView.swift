import SwiftUI
import KanbanCore

struct ContentView: View {
    @State private var boardState: BoardState
    @State private var orchestrator: BackgroundOrchestrator
    @State private var showSearch = false
    @State private var showNewTask = false
    private let coordinationStore: CoordinationStore

    init() {
        let discovery = ClaudeCodeSessionDiscovery()
        let coordination = CoordinationStore()
        let state = BoardState(discovery: discovery, coordinationStore: coordination)
        let orch = BackgroundOrchestrator(
            discovery: discovery,
            coordinationStore: coordination,
            tmux: TmuxAdapter()
        )

        _boardState = State(initialValue: state)
        _orchestrator = State(initialValue: orch)
        self.coordinationStore = coordination
    }

    var body: some View {
        ZStack {
            BoardView(state: boardState)

            if showSearch {
                Color.black.opacity(0.3)
                    .ignoresSafeArea()
                    .onTapGesture { showSearch = false }

                SearchOverlay(
                    isPresented: $showSearch,
                    cards: boardState.cards,
                    onSelectCard: { card in
                        boardState.selectedCardId = card.id
                    }
                )
                .padding(40)
                .transition(.opacity.combined(with: .scale(scale: 0.95)))
            }
        }
        .animation(.easeInOut(duration: 0.15), value: showSearch)
        .sheet(isPresented: $showNewTask) {
            NewTaskDialog(isPresented: $showNewTask) { title, description, projectPath in
                createManualTask(title: title, description: description, projectPath: projectPath)
            }
        }
        .task {
            await boardState.refresh()
            orchestrator.start()
        }
        .task(id: "refresh-timer") {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(30))
                guard !Task.isCancelled else { break }
                await boardState.refresh()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .kanbanToggleSearch)) { _ in
            showSearch.toggle()
        }
        .onReceive(NotificationCenter.default.publisher(for: .kanbanNewTask)) { _ in
            showNewTask = true
        }
        .background {
            Button("") { showSearch.toggle() }
                .keyboardShortcut("k", modifiers: .command)
                .hidden()
        }
    }

    private func createManualTask(title: String, description: String, projectPath: String?) {
        let link = Link(
            sessionId: UUID().uuidString,
            projectPath: projectPath,
            column: .backlog,
            name: title,
            source: .manual
        )
        Task {
            try? await coordinationStore.upsertLink(link)
            await boardState.refresh()
        }
    }
}
