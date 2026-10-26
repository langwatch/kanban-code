import AppKit
import KanbanCodeCore

/// Screenshots for agents that drive the app without screen recording or
/// accessibility rights. With KANBAN_CODE_SNAPSHOT_DIR set, the app reads
/// `<dir>/commands` every half second, deletes it and runs its lines:
///
///     select <cardId>                       selects a card
///     conversation <cardId> <id|main>       opens a conversation, or Main
///     wait <seconds>                        waits before the next line
///     snap <name>                           writes <dir>/<name>.png per window
///
/// The app draws its own windows, so the PNGs need no system permission.
@MainActor
enum WindowSnapshots {
    static func start() {
        guard let dir = ProcessInfo.processInfo.environment["KANBAN_CODE_SNAPSHOT_DIR"], !dir.isEmpty else { return }
        KanbanCodeLog.info("snapshots", "reading commands from \(dir)/commands")
        Task { @MainActor in
            let path = (dir as NSString).appendingPathComponent("commands")
            while true {
                try? await Task.sleep(for: .milliseconds(500))
                guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { continue }
                try? FileManager.default.removeItem(atPath: path)
                for line in text.split(separator: "\n") {
                    await run(line.split(separator: " ").map(String.init), dir: dir)
                }
            }
        }
    }

    private static func run(_ words: [String], dir: String) async {
        let store = AppComposition.shared.store
        switch (words.first, words.count) {
        case ("select", 2):
            store.dispatch(.selectCard(cardId: words[1]))
        case ("conversation", 3):
            store.dispatch(.openConversation(cardId: words[1], conversationId: words[2] == "main" ? nil : words[2]))
        case ("wait", 2):
            try? await Task.sleep(for: .seconds(Double(words[1]) ?? 1))
        case ("snap", 2):
            snap(name: words[1], dir: dir)
        default:
            KanbanCodeLog.warn("snapshots", "unknown command: \(words.joined(separator: " "))")
        }
    }

    private static func snap(name: String, dir: String) {
        let windows = NSApp.windows.filter { $0.isVisible && $0.frame.width > 300 && $0.frame.height > 200 }
        for (index, window) in windows.enumerated() {
            guard let view = window.contentView?.superview ?? window.contentView,
                  let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { continue }
            view.cacheDisplay(in: view.bounds, to: bitmap)
            guard let png = bitmap.representation(using: .png, properties: [:]) else { continue }
            let file = index == 0 ? "\(name).png" : "\(name)-\(index).png"
            try? png.write(to: URL(fileURLWithPath: dir).appendingPathComponent(file))
        }
        KanbanCodeLog.info("snapshots", "\(name): \(windows.count) window(s)")
    }
}
