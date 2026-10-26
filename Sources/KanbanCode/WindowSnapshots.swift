import AppKit
import KanbanCodeCore

/// Screenshots for agents that drive the app without screen recording or
/// accessibility rights. With KANBAN_CODE_SNAPSHOT_DIR set, the app reads
/// `<dir>/commands` every half second, deletes it and runs its lines:
///
///     select <cardId>                       selects a card
///     conversation <cardId> <id|main>       opens a conversation, or Main
///     rename <cardId> <id>                  opens a conversation's rename sheet, as its sidebar menu does
///     wait <seconds>                        waits before the next line
///     snap <name>                           writes <dir>/<name>.png per window
///     send <cardId> <id> <text...>          sends a message in a conversation, as its composer does
///     drop <cardId> <png path>              drops an image on the window
///     state <cardId>                        logs the focused view and the open conversation's draft
///     chatview on|off                       shows Main as the chat or the terminal
///     paste <png path>                      presses Cmd+V with the image on the clipboard,
///                                           then puts the clipboard's text back
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
        case ("rename", 3):
            ConversationActions.rename(cardId: words[1], conversationId: words[2])
        case ("wait", 2):
            try? await Task.sleep(for: .seconds(Double(words[1]) ?? 1))
        case ("snap", 2):
            snap(name: words[1], dir: dir)
        case ("send", let count) where count >= 4:
            ConversationActions.send(cardId: words[1], conversationId: words[2],
                                     text: words[3...].joined(separator: " "), imagePaths: [])
            KanbanCodeLog.info("snapshots", "sent in \(words[2]): card known \(store.state.links[words[1]] != nil), "
                + "outbox \(store.state.conversationOutbox[words[1]]?.count ?? 0), queue \(store.state.links[words[1]]?.queuedPrompts?.count ?? 0)")
        case ("state", 2):
            let responder = NSApp.keyWindow?.firstResponder ?? NSApp.windows.first?.firstResponder
            var line = "first responder: \(responder.map { String(describing: type(of: $0)) } ?? "none")"
            if let text = responder as? NSTextView { line += " holding \(text.string.debugDescription)" }
            if let conversationId = store.state.openConversations[words[1]] {
                let draft = ConversationDrafts.shared.draft(cardId: words[1], conversationId: conversationId)
                line += "; \(conversationId) draft: \(draft.text.debugDescription), \(draft.images.count) image(s)"
            }
            KanbanCodeLog.info("snapshots", line)
        case ("chatview", 2):
            UserDefaults.standard.set(words[1] == "on", forKey: "preferChatView")
        case ("drop", 3):
            guard let data = FileManager.default.contents(atPath: words[2]) else { return }
            if let conversationId = store.state.openConversations[words[1]] {
                ConversationDrafts.shared.addImage(data, cardId: words[1], conversationId: conversationId)
            }
        case ("paste", 2):
            guard let data = FileManager.default.contents(atPath: words[1]),
                  let window = NSApp.keyWindow ?? NSApp.windows.first(where: \.isVisible),
                  let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command, timestamp: 0,
                                               windowNumber: window.windowNumber, context: nil, characters: "v",
                                               charactersIgnoringModifiers: "v", isARepeat: false, keyCode: 9) else { return }
            let pasteboard = NSPasteboard.general
            let saved = pasteboard.string(forType: .string)
            pasteboard.clearContents()
            pasteboard.setData(data, forType: .png)
            NSApp.sendEvent(event)
            try? await Task.sleep(for: .milliseconds(300))
            pasteboard.clearContents()
            if let saved { pasteboard.setString(saved, forType: .string) }
        default:
            KanbanCodeLog.warn("snapshots", "unknown command: \(words.joined(separator: " "))")
        }
    }

    private static func snap(name: String, dir: String) {
        let windows = NSApp.windows.filter { $0.contentView != nil && $0.frame.width > 300 && $0.frame.height > 200 }
        // A window that is closed or behind another app draws nothing until it is on screen.
        for window in windows where !window.isVisible { window.orderFrontRegardless() }
        for (index, window) in windows.enumerated() {
            guard let view = window.contentView?.superview ?? window.contentView,
                  let png = layerPNG(of: view) ?? cachedPNG(of: view) else { continue }
            let file = index == 0 ? "\(name).png" : "\(name)-\(index).png"
            try? png.write(to: URL(fileURLWithPath: dir).appendingPathComponent(file))
        }
        KanbanCodeLog.info("snapshots", "\(name): \(windows.count) window(s)")
    }

    /// Renders the layer tree, which holds what SwiftUI draws; `cacheDisplay`
    /// leaves those parts blank. The sidebar's glass list stays blank either way.
    private static func layerPNG(of view: NSView) -> Data? {
        guard let layer = view.layer else { return nil }
        let scale = view.window?.backingScaleFactor ?? 2
        let width = Int(view.bounds.width * scale), height = Int(view.bounds.height * scale)
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.scaleBy(x: scale, y: scale)
        layer.render(in: context)
        guard let image = context.makeImage() else { return nil }
        return NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])
    }

    private static func cachedPNG(of view: NSView) -> Data? {
        guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return nil }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        return bitmap.representation(using: .png, properties: [:])
    }
}
