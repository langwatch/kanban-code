# Architecture: Elm-like Unidirectional State

## Why

The app had **two sources of truth** (in-memory `BoardState.cards` and on-disk `CoordinationStore` links.json) with **5 independent writers** racing against each other. This caused cards bouncing between columns, terminals disappearing, and duplicates appearing on rapid creation. Every band-aid fix introduced new edge cases.

The fix: a lightweight Elm/Redux-style store that serializes all state mutations through a pure reducer. Not TCA (The Composable Architecture) — just ~400 lines of our own code with the same core guarantees.

## Core Components

### `AppState` (struct)
Single source of truth. All board data lives here.

```
AppState
├── links: [String: Link]              // cardId → Link (the cards)
├── sessions: [String: Session]        // sessionId → Session
├── activityMap: [String: ActivityState] // sessionId → activity
├── tmuxSessions: Set<String>          // live tmux session names
├── selectedCardId: String?
├── selectedProjectPath: String?
├── configuredProjects: [Project]
├── error: String?
└── computed: cards, filteredCards, visibleColumns
```

### `Action` (enum)
Exhaustive list of everything that can happen. Every state change starts as an action dispatch.

- **UI actions**: `createManualTask`, `createTerminal`, `launchCard`, `resumeCard`, `moveCard`, `renameCard`, `archiveCard`, `deleteCard`, `selectCard`, `unlinkFromCard`, `killTerminal`, `addBranchToCard`, `addIssueLinkToCard`, `addExtraTerminal`
- **Async completions**: `launchCompleted`, `launchFailed`, `resumeCompleted`, `resumeFailed`, `terminalCreated`, `terminalFailed`
- **Background**: `reconciled` (single atomic update from discovery scan)
- **Settings**: `setError`, `setSelectedProject`, `setLoading`

### `Reducer` (pure function)
`(inout AppState, Action) -> [Effect]`

- Synchronous. No async. No side effects.
- Fully testable — give it state + action, check new state + effects.
- Runs on `@MainActor` (same thread as UI), so no races between mutations.

### `Effect` (enum) + `EffectHandler` (actor)
Side effects declared by the reducer, executed asynchronously by `EffectHandler`:

- `persistLinks`, `upsertLink`, `removeLink` — disk I/O
- `createTmuxSession`, `killTmuxSession` — terminal management
- `deleteSessionFile`, `cleanupTerminalCache` — cleanup
- `updateSessionIndex` — session metadata

### `BoardStore` (`@Observable @MainActor`)
The main store that ties it all together:

```swift
func dispatch(_ action: Action) {
    let effects = Reducer.reduce(state: &state, action: action)
    for effect in effects {
        Task { await effectHandler.execute(effect, dispatch: dispatch) }
    }
}
```

Also has `reconcile()` — async method that does full discovery (sessions, tmux, worktrees, PRs) and dispatches `.reconciled(result)`.

## Key Files

| File | Role |
|------|------|
| `KanbanCodeCore/UseCases/BoardStore.swift` | AppState, Action, Reducer, BoardStore |
| `KanbanCodeCore/UseCases/EffectHandler.swift` | Async effect execution |
| `KanbanCodeCore/Domain/Entities/Link.swift` | Card entity (has `isLaunching: Bool?`) |
| `Kanban/ContentView.swift` | Main view — dispatches actions, runs async launch/resume flows |
| `Kanban/BoardView.swift` | Board columns — reads from `store.state`, dispatches move/rename/archive |
| `Kanban/CardDetailView.swift` | Card detail panel — reads card data, dispatches via callbacks |
| `KanbanCodeCore/UseCases/BackgroundOrchestrator.swift` | Notifications + activity polling only (no more column updates) |
| `Tests/KanbanCodeCoreTests/ReducerTests.swift` | Pure reducer tests |

## Data Flow

```
User action / Timer / Hook event
        │
        ▼
  store.dispatch(.action)
        │
        ▼
  Reducer.reduce(state, action)     ← pure, sync, @MainActor
        │                │
        ▼                ▼
  state mutated     [Effect]s returned
                         │
                         ▼
               EffectHandler.execute()  ← async, actor-isolated
                         │
                         ▼
                  disk / tmux / cleanup
                         │
                         ▼ (if completion action needed)
               store.dispatch(.completed)
```

## Race Condition Prevention

### `isLaunching` flag
When a card is being launched or resumed, `isLaunching = true` is set in the reducer. Background reconciliation (`.reconciled` action) **skips** any card with `isLaunching == true`, preventing the card from bouncing between columns while async work completes.

```
dispatch(.resumeCard)     → column = .inProgress, isLaunching = true
dispatch(.reconciled)     → SKIPS this card (isLaunching protects it)
dispatch(.resumeCompleted)→ isLaunching = nil, card stays in .inProgress
```

### Terminal naming
Terminals use `"card-{id.prefix(12)}"` instead of project name, preventing collisions between cards in the same project.

### createTerminal doesn't change column
The `.createTerminal` reducer sets `tmuxLink` with `isShellOnly: true` but does **NOT** change the column. A shell terminal is not Claude working — the card stays where it was.

## How This Differs from TCA

This is NOT TCA (Point-Free's The Composable Architecture). Key differences:

| Feature | Our Store | TCA |
|---------|----------|-----|
| Dependency injection | Init params | `@Dependency` system |
| Store scoping | Pass `store.state` directly | `Store.scope()` + `ViewStore` |
| Effect cancellation | Simple Tasks | Sophisticated effect lifecycle |
| Navigation state | `@State` in views | Managed in reducer |
| Package dependency | None | `swift-composable-architecture` |
| Code size | ~400 lines | Framework |

For our use case (single-screen app, ~25 actions, core problem = race conditions), the lightweight approach gives the same guarantees without the learning curve.

## Testing the Reducer

Reducer tests are pure and fast — no disk, no async, no mocks needed:

```swift
@Test func resumeCardNoBounce() {
    var state = stateWith([waitingCard])

    // User resumes
    Reducer.reduce(state: &state, action: .resumeCard(cardId: "card1"))
    #expect(state.links["card1"]?.column == .inProgress)
    #expect(state.links["card1"]?.isLaunching == true)

    // Background reconciliation fires — should NOT override
    Reducer.reduce(state: &state, action: .reconciled(result))
    #expect(state.links["card1"]?.column == .inProgress) // still protected
}
```
