# Kanban Code – Claude Code Guidelines

## Build & Test

```bash
swift build          # build the app
swift test           # run all tests
make run-app         # build + launch the app
```

## Architecture

- **KanbanCodeCore** (`Sources/KanbanCodeCore/`) — pure Swift library, no UI. Domain entities, use cases, adapters.
- **KanbanCode** (`Sources/KanbanCode/`) — SwiftUI + AppKit macOS app. Views, toolbar, system tray.
- Deployment target: **macOS 15** (swift-tools-version 6.2). Use `#available` checks for newer APIs.
- **Elm-like unidirectional state** — see [`docs/architecture.md`](docs/architecture.md) for full details.
  - All state lives in `AppState` struct (single source of truth).
  - All mutations go through `store.dispatch(action)` → pure `Reducer` → async `Effect`s.
  - `isLaunching` flag on `Link` prevents background reconciliation from overriding cards mid-launch/resume.
  - Never mutate state directly or write to `CoordinationStore` from views — always dispatch an action.

## Critical: DispatchSource + @MainActor Crashes

SwiftUI Views are `@MainActor`. In Swift 6, closures formed inside `@MainActor` methods inherit that isolation. If a `DispatchSource` event handler runs on a background GCD queue, the runtime asserts and **crashes** (`EXC_BREAKPOINT` in `_dispatch_assert_queue_fail`).

**Never do this** (crashes at runtime, no compile-time warning):
```swift
// Inside a SwiftUI View (which is @MainActor)
func startWatcher() {
    let source = DispatchSource.makeFileSystemObjectSource(fd: fd, eventMask: .write, queue: .global())
    source.setEventHandler {
        // CRASH: this closure inherits @MainActor but runs on a background queue
        NotificationCenter.default.post(name: .myEvent, object: nil)
    }
}
```

**Always do this** — extract to a `nonisolated` context:
```swift
// Option A: nonisolated static factory
private nonisolated static func makeSource(fd: Int32) -> DispatchSourceFileSystemObject {
    let source = DispatchSource.makeFileSystemObjectSource(fd: fd, eventMask: .write, queue: .global())
    source.setEventHandler {
        NotificationCenter.default.post(name: .myEvent, object: nil)
    }
    source.resume()
    return source
}

// Option B: nonisolated async function with AsyncStream
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

This applies to **any** GCD callback (`setEventHandler`, `setCancelHandler`, `DispatchQueue.global().async`) called from a `@MainActor` context.

## Toolbar Layout

Toolbar uses SwiftUI `.toolbar` with standard spacing:

- **`.navigation`** placement = left side. All items merge into ONE group (spacers don't help).
- **`.principal`** placement = center. Separate from navigation.
- **`.primaryAction`** placement = right side.
- Use `Menu` (not `Text`) for items that need visual separation within `.navigation` — menus map to `NSPopUpButton` which gets separate styling automatically.

Note: `ToolbarSpacer` and Liquid Glass effects require macOS 26+ (unreleased). For macOS 15 compatibility, use standard toolbar layout.

## Commits

Use [Conventional Commits](https://www.conventionalcommits.org/) for all commit messages. Release-please uses these to generate changelogs automatically.

- `feat: add dark mode` — new feature (minor version bump)
- `fix: correct session dedup` — bug fix (patch version bump)
- `perf: speed up branch discovery` — performance (patch)
- `refactor: extract hook manager` — refactoring (hidden from changelog)
- `docs: update README` — documentation (hidden)
- `chore: bump deps` — maintenance (hidden)
- `feat!: redesign board layout` — breaking change (major version bump)

## Crash Logs

macOS crash reports: `~/Library/Logs/DiagnosticReports/KanbanCode-*.ips`
App logs: `~/.kanban-code/logs/kanban-code.log`
