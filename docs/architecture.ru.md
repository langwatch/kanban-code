# Архитектура: однонаправленный поток состояния в стиле Elm

## Зачем

В приложении было **два источника истины** (`BoardState.cards` в памяти и ссылки на диске в `CoordinationStore` / links.json), а также **5 независимых писателей**, конкурирующих друг с другом. Из-за этого карточки прыгали между колонками, терминалы пропадали, а при быстром создании появлялись дубликаты. Каждая «заплатка» порождала новые краевые случаи.

Решение — лёгкий store в стиле Elm/Redux, который сериализует все мутации состояния через чистый редьюсер. Это не TCA (The Composable Architecture), а свой код примерно на ~400 строк с теми же базовыми гарантиями.

## Основные компоненты

### `AppState` (struct)
Единственный источник истины. Все данные доски живут здесь.

```
AppState
├── links: [String: Link]              // cardId → Link (карточки)
├── sessions: [String: Session]        // sessionId → Session
├── activityMap: [String: ActivityState] // sessionId → активность
├── tmuxSessions: Set<String>          // имена живых tmux-сессий
├── selectedCardId: String?
├── selectedProjectPath: String?
├── configuredProjects: [Project]
├── error: String?
└── computed: cards, filteredCards, visibleColumns
```

### `Action` (enum)
Исчерпывающий список всего, что может произойти. Любое изменение состояния начинается с диспатча action'а.

- **UI-действия**: `createManualTask`, `createTerminal`, `launchCard`, `resumeCard`, `moveCard`, `renameCard`, `archiveCard`, `deleteCard`, `selectCard`, `unlinkFromCard`, `killTerminal`, `addBranchToCard`, `addIssueLinkToCard`, `addExtraTerminal`
- **Завершения асинхронных операций**: `launchCompleted`, `launchFailed`, `resumeCompleted`, `resumeFailed`, `terminalCreated`, `terminalFailed`
- **Фоновые**: `reconciled` (одно атомарное обновление из discovery-сканирования)
- **Настройки**: `setError`, `setSelectedProject`, `setLoading`

### `Reducer` (чистая функция)
`(inout AppState, Action) -> [Effect]`

- Синхронный. Без async. Без побочных эффектов.
- Полностью тестируемый — дайте ему state + action и проверьте новый state + effects.
- Выполняется на `@MainActor` (та же нить, что и UI), поэтому гонок между мутациями нет.

### `Effect` (enum) + `EffectHandler` (actor)
Побочные эффекты декларируются редьюсером и выполняются асинхронно через `EffectHandler`:

- `persistLinks`, `upsertLink`, `removeLink` — дисковый I/O
- `createTmuxSession`, `killTmuxSession` — управление терминалами
- `deleteSessionFile`, `cleanupTerminalCache` — очистка
- `updateSessionIndex` — метаданные сессий

### `BoardStore` (`@Observable @MainActor`)
Главный store, связывающий всё вместе:

```swift
func dispatch(_ action: Action) {
    let effects = Reducer.reduce(state: &state, action: action)
    for effect in effects {
        Task { await effectHandler.execute(effect, dispatch: dispatch) }
    }
}
```

Также есть `reconcile()` — async-метод, выполняющий полное обнаружение (sessions, tmux, worktrees, PR) и диспатчащий `.reconciled(result)`.

## Ключевые файлы

| Файл | Роль |
|------|------|
| `KanbanCodeCore/UseCases/BoardStore.swift` | AppState, Action, Reducer, BoardStore |
| `KanbanCodeCore/UseCases/EffectHandler.swift` | Асинхронное выполнение эффектов |
| `KanbanCodeCore/Domain/Entities/Link.swift` | Сущность карточки (есть `isLaunching: Bool?`) |
| `Kanban/ContentView.swift` | Главное view — диспатчит action'ы, запускает async-флоу launch/resume |
| `Kanban/BoardView.swift` | Колонки доски — читают `store.state`, диспатчат move/rename/archive |
| `Kanban/CardDetailView.swift` | Панель деталей карточки — читает данные, диспатчит через callbacks |
| `KanbanCodeCore/UseCases/BackgroundOrchestrator.swift` | Только нотификации и поллинг активности (без обновлений колонок) |
| `Tests/KanbanCodeCoreTests/ReducerTests.swift` | Тесты чистого редьюсера |

## Поток данных

```
Действие пользователя / Таймер / Hook-событие
        │
        ▼
  store.dispatch(.action)
        │
        ▼
  Reducer.reduce(state, action)     ← чистый, синхронный, @MainActor
        │                │
        ▼                ▼
  state изменён     возвращены [Effect]
                         │
                         ▼
               EffectHandler.execute()  ← async, изолированный actor
                         │
                         ▼
                  диск / tmux / очистка
                         │
                         ▼ (если нужен action завершения)
               store.dispatch(.completed)
```

## Предотвращение гонок

### Флаг `isLaunching`
Когда карточка запускается или возобновляется, редьюсер выставляет `isLaunching = true`. Фоновая реконсиляция (`.reconciled`) **пропускает** карточки с `isLaunching == true`, благодаря чему карточка не прыгает между колонками, пока выполняется async-работа.

```
dispatch(.resumeCard)     → column = .inProgress, isLaunching = true
dispatch(.reconciled)     → ПРОПУСКАЕТ эту карточку (isLaunching защищает её)
dispatch(.resumeCompleted)→ isLaunching = nil, карточка остаётся в .inProgress
```

### Именование терминалов
Терминалы используют `"card-{id.prefix(12)}"` вместо имени проекта, что исключает коллизии между карточками в одном и том же проекте.

### createTerminal не меняет колонку
Редьюсер `.createTerminal` устанавливает `tmuxLink` с `isShellOnly: true`, но **не** меняет колонку. Shell-терминал — это не работа Claude, поэтому карточка остаётся там, где была.

## Чем это отличается от TCA

Это **не** TCA (The Composable Architecture от Point-Free). Ключевые отличия:

| Возможность | Наш Store | TCA |
|-------------|-----------|-----|
| Инъекция зависимостей | Через init | Система `@Dependency` |
| Скоупинг store | Передаём `store.state` напрямую | `Store.scope()` + `ViewStore` |
| Отмена эффектов | Простые Task'и | Полноценный жизненный цикл эффектов |
| Состояние навигации | `@State` во views | Управляется в редьюсере |
| Зависимость пакета | Нет | `swift-composable-architecture` |
| Объём кода | ~400 строк | Фреймворк |

Для нашего случая (одно-экранное приложение, ~25 action'ов, основная проблема — гонки) лёгкий подход даёт те же гарантии без кривой обучения.

## Тестирование редьюсера

Тесты редьюсера чистые и быстрые — без диска, без async, без моков:

```swift
@Test func resumeCardNoBounce() {
    var state = stateWith([waitingCard])

    // Пользователь возобновляет
    Reducer.reduce(state: &state, action: .resumeCard(cardId: "card1"))
    #expect(state.links["card1"]?.column == .inProgress)
    #expect(state.links["card1"]?.isLaunching == true)

    // Срабатывает фоновая реконсиляция — НЕ должна перебить
    Reducer.reduce(state: &state, action: .reconciled(result))
    #expect(state.links["card1"]?.column == .inProgress) // всё ещё защищено
}
```

## Legacy: BoardState.swift

`BoardState.swift` оставлен как мёртвый код — ни один UI на него не ссылается. `BoardStateIntegrationTests` всё ещё используют его как регрессионные тесты. Можно удалить в одном из будущих проходов очистки.
