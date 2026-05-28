# Архитектура Kanban Code

Перевод и адаптация [`docs/architecture.md`](docs/architecture.md) и [`CLAUDE.md`](CLAUDE.md) для русскоязычных контрибьюторов.

Документ объясняет, как устроено ядро приложения, почему выбран Elm-подобный однонаправленный поток данных, и какие подводные камни Swift 6 надо знать, чтобы не получить креш на ровном месте.

---

## Зачем такая архитектура

До переписывания приложение имело **два источника правды**: in-memory `BoardState.cards` и `links.json` на диске через `CoordinationStore`. На состояние писали **5 независимых писателей** параллельно. Симптомы:

- карточки прыгали между колонками,
- терминалы исчезали,
- при быстром создании появлялись дубли.

Каждая заплатка порождала новые edge cases. Решение — лёгкий стор в духе Elm/Redux: все мутации состояния идут через одну чистую функцию-редьюсер. **Это не TCA** (The Composable Architecture от Point-Free), а ~400 строк своего кода с теми же базовыми гарантиями.

---

## Основные компоненты

### `AppState` (struct)

Единственный источник правды. Все данные доски живут здесь.

```
AppState
├── links: [String: Link]                // cardId → Link (карточки)
├── sessions: [String: Session]          // sessionId → Session
├── activityMap: [String: ActivityState] // sessionId → активность
├── tmuxSessions: Set<String>            // активные tmux-сессии
├── selectedCardId: String?
├── selectedProjectPath: String?
├── configuredProjects: [Project]
├── error: String?
└── computed: cards, filteredCards, visibleColumns
```

### `Action` (enum)

Исчерпывающий список того, что может произойти. Любое изменение состояния начинается с диспатча action-а.

- **UI-действия:** `createManualTask`, `createTerminal`, `launchCard`, `resumeCard`, `moveCard`, `renameCard`, `archiveCard`, `deleteCard`, `selectCard`, `unlinkFromCard`, `killTerminal`, `addBranchToCard`, `addIssueLinkToCard`, `addExtraTerminal`
- **Завершение асинхронных операций:** `launchCompleted`, `launchFailed`, `resumeCompleted`, `resumeFailed`, `terminalCreated`, `terminalFailed`
- **Фоновые:** `reconciled` (один атомарный апдейт после скана)
- **Настройки:** `setError`, `setSelectedProject`, `setLoading`

### `Reducer` (чистая функция)

Сигнатура: `(inout AppState, Action) -> [Effect]`

- Синхронная. Без `async`. Без сайд-эффектов.
- Полностью тестируется: дай состояние и action → проверь новое состояние и список эффектов.
- Работает на `@MainActor` (тот же поток, что и UI) — никаких гонок между мутациями.

### `Effect` (enum) + `EffectHandler` (actor)

Сайд-эффекты, объявленные редьюсером, исполняются асинхронно через `EffectHandler`:

- `persistLinks`, `upsertLink`, `removeLink` — дисковый I/O
- `createTmuxSession`, `killTmuxSession` — управление терминалом
- `deleteSessionFile`, `cleanupTerminalCache` — очистка
- `updateSessionIndex` — метаданные сессий

### `BoardStore` (`@Observable @MainActor`)

Главный стор, который связывает всё вместе:

```swift
func dispatch(_ action: Action) {
    let effects = Reducer.reduce(state: &state, action: action)
    for effect in effects {
        Task { await effectHandler.execute(effect, dispatch: dispatch) }
    }
}
```

Также есть `reconcile()` — асинхронный метод, который делает полный discovery (сессии, tmux, worktree, PR) и диспатчит `.reconciled(result)`.

---

## Ключевые файлы

| Файл | Роль |
|------|------|
| `Sources/KanbanCodeCore/UseCases/BoardStore.swift` | AppState, Action, Reducer, BoardStore |
| `Sources/KanbanCodeCore/UseCases/EffectHandler.swift` | Асинхронное исполнение эффектов |
| `Sources/KanbanCodeCore/Domain/Entities/Link.swift` | Сущность карточки (есть `isLaunching: Bool?`) |
| `Sources/KanbanCode/ContentView.swift` | Главная вьюха — диспатчит action-ы, запускает async-флоу launch/resume |
| `Sources/KanbanCode/BoardView.swift` | Колонки доски — читает из `store.state`, диспатчит move/rename/archive |
| `Sources/KanbanCode/CardDetailView.swift` | Панель карточки — читает данные, диспатчит через колбэки |
| `Sources/KanbanCodeCore/UseCases/BackgroundOrchestrator.swift` | Только уведомления и поллинг активности (колонки больше не трогает) |
| `Tests/KanbanCodeCoreTests/ReducerTests.swift` | Чистые тесты редьюсера |

---

## Поток данных

```
Действие пользователя / таймер / hook-событие
        │
        ▼
  store.dispatch(.action)
        │
        ▼
  Reducer.reduce(state, action)         ← чистая, синхронная, @MainActor
        │                │
        ▼                ▼
  state замутирован   [Effect]-ы возвращены
                         │
                         ▼
               EffectHandler.execute()  ← async, actor-isolated
                         │
                         ▼
                  disk / tmux / cleanup
                         │
                         ▼ (если нужен completion-action)
               store.dispatch(.completed)
```

---

## Защита от гонок

### Флаг `isLaunching`

Когда карточка запускается или резюмится, редьюсер ставит `isLaunching = true`. Фоновая реконсиляция (`.reconciled`) **пропускает** любую карточку с `isLaunching == true` — это не даёт карточке прыгать между колонками, пока асинхронная работа ещё не закончилась.

```
dispatch(.resumeCard)      → column = .inProgress, isLaunching = true
dispatch(.reconciled)      → ПРОПУСКАЕТ эту карточку (isLaunching защищает)
dispatch(.resumeCompleted) → isLaunching = nil, карточка остаётся в .inProgress
```

### Именование терминалов

Терминалы используют имя `"card-{id.prefix(12)}"` вместо имени проекта — это предотвращает коллизии между карточками одного проекта.

### `createTerminal` не меняет колонку

Редьюсер на `.createTerminal` ставит `tmuxLink` с `isShellOnly: true`, но **не** меняет колонку. Shell-терминал — это не работающий Claude, карточка остаётся там, где была.

---

## Чем это отличается от TCA

Это **не** TCA (The Composable Architecture от Point-Free). Ключевые различия:

| Фича | Наш стор | TCA |
|------|----------|-----|
| Dependency injection | Параметры init | Система `@Dependency` |
| Скоупинг стора | Передаём `store.state` напрямую | `Store.scope()` + `ViewStore` |
| Отмена эффектов | Обычные `Task` | Сложный лайфсайкл эффектов |
| Состояние навигации | `@State` во вьюхах | Управляется в редьюсере |
| Зависимости пакетов | Нет | `swift-composable-architecture` |
| Размер кода | ~400 строк | Целый фреймворк |

Для нашего кейса (одноэкранное приложение, ~25 action-ов, главная проблема — гонки) лёгкий подход даёт те же гарантии без кривой обучения TCA.

---

## Тестирование редьюсера

Тесты редьюсера — чистые и быстрые: ни диска, ни async, ни моков.

```swift
@Test func resumeCardNoBounce() {
    var state = stateWith([waitingCard])

    // Пользователь резюмит карточку
    Reducer.reduce(state: &state, action: .resumeCard(cardId: "card1"))
    #expect(state.links["card1"]?.column == .inProgress)
    #expect(state.links["card1"]?.isLaunching == true)

    // Фоновая реконсиляция срабатывает — НЕ должна перебить
    Reducer.reduce(state: &state, action: .reconciled(result))
    #expect(state.links["card1"]?.column == .inProgress) // всё ещё защищено
}
```

Запуск всех тестов:

```bash
swift test
```

---

## Критично: DispatchSource + @MainActor → креш

SwiftUI-вьюхи имеют изоляцию `@MainActor`. В Swift 6 замыкания, созданные внутри `@MainActor`-методов, **наследуют** эту изоляцию. Если обработчик события `DispatchSource` выполняется на фоновой GCD-очереди, runtime срабатывает ассерт и **крешит** приложение (`EXC_BREAKPOINT` в `_dispatch_assert_queue_fail`).

**Так делать НЕЛЬЗЯ** (крешится в рантайме, без warning-а на компиляции):

```swift
// Внутри SwiftUI View (она @MainActor)
func startWatcher() {
    let source = DispatchSource.makeFileSystemObjectSource(
        fd: fd, eventMask: .write, queue: .global())
    source.setEventHandler {
        // КРЕШ: это замыкание наследует @MainActor,
        // но исполняется на фоновой очереди
        NotificationCenter.default.post(name: .myEvent, object: nil)
    }
}
```

**Правильно** — вынести в `nonisolated`-контекст:

```swift
// Вариант A: nonisolated static-фабрика
private nonisolated static func makeSource(fd: Int32) -> DispatchSourceFileSystemObject {
    let source = DispatchSource.makeFileSystemObjectSource(
        fd: fd, eventMask: .write, queue: .global())
    source.setEventHandler {
        NotificationCenter.default.post(name: .myEvent, object: nil)
    }
    source.resume()
    return source
}

// Вариант B: nonisolated async-функция с AsyncStream
private nonisolated func watchFile(path: String) async {
    let source = DispatchSource.makeFileSystemObjectSource(...)
    let events = AsyncStream<Void> { continuation in
        source.setEventHandler { continuation.yield() }
        source.setCancelHandler { continuation.finish() }
        source.resume()
    }
    for await _ in events {
        NotificationCenter.default.post(name: .myEvent, object: nil)
    }
}
```

Правило применимо к **любому** GCD-колбэку (`setEventHandler`, `setCancelHandler`, `DispatchQueue.global().async`), вызванному из `@MainActor`-контекста.

---

## Тулбар (macOS 26 Liquid Glass)

Тулбар использует SwiftUI `.toolbar` с `ToolbarSpacer` (macOS 26+) для отдельных glass-пилюль:

- **`.navigation`** = левая сторона. Все элементы сливаются в **одну** пилюлю (спейсеры не помогают).
- **`.principal`** = центр. Отдельная пилюля от navigation.
- **`.primaryAction`** = правая сторона. `ToolbarSpacer(.fixed)` **создаёт** отдельные пилюли здесь.
- Для элементов внутри `.navigation`, которым нужна своя пилюля, используй `Menu` (не `Text`): menu маппится в `NSPopUpButton`, который получает отдельный glass автоматически.

---

## Правила работы со стором (не нарушать)

1. **Никогда** не мутируй `AppState` напрямую из вьюх.
2. **Никогда** не пиши в `CoordinationStore` из вьюх — всегда диспатч action-а.
3. Любой новый сайд-эффект — это новый `Effect`-кейс + ветка в `EffectHandler`. Не запускай `Task` прямо во вьюхе.
4. Если карточка может оказаться в полусломанном состоянии во время асинхронной операции — поставь `isLaunching = true` в редьюсере и не забудь снять в `.completed`/`.failed`.

---

## Конвенциональные коммиты

Используй [Conventional Commits](https://www.conventionalcommits.org/). Release-please на их основе автоматически генерит CHANGELOG.

- `feat: add dark mode` — новая фича (минорный bump)
- `fix: correct session dedup` — баг-фикс (патч)
- `perf: speed up branch discovery` — производительность (патч)
- `refactor: extract hook manager` — рефакторинг (скрыто из changelog)
- `docs: update README` — документация (скрыто)
- `chore: bump deps` — обслуживание (скрыто)
- `feat!: redesign board layout` — breaking change (мажорный bump)

---

## Где искать креши и логи

- macOS crash reports: `~/Library/Logs/DiagnosticReports/KanbanCode-*.ips`
- Логи приложения: `~/.kanban-code/logs/kanban-code.log`
- Настройки пользователя: `~/.kanban-code/settings.json`
- Карточки и связи: `~/.kanban-code/links.json`

---

## Легаси: `BoardState.swift`

`BoardState.swift` оставлен как мёртвый код — UI его не использует. `BoardStateIntegrationTests` всё ещё гоняют его в регрессионных целях. Можно удалить в следующем cleanup-проходе.
