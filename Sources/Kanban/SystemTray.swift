import SwiftUI
import AppKit
import KanbanCore

/// Manages the menu bar status item (system tray).
/// Shows clawd icon when Claude sessions are actively working.
/// Amphetamine can be configured to detect this process to prevent sleep.
@MainActor
final class SystemTray: @unchecked Sendable {
    private var statusItem: NSStatusItem?
    private var menu: NSMenu?
    private weak var boardState: BoardState?

    func setup(boardState: BoardState) {
        self.boardState = boardState
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        // Use clawd icon as template image — load @2x for retina sharpness
        if let iconURL = Bundle.module.url(forResource: "clawd@2x", withExtension: "png", subdirectory: "Resources"),
           let image = NSImage(contentsOf: iconURL) {
            image.isTemplate = true
            image.size = NSSize(width: 18, height: 18) // logical size; 44px renders sharp on retina
            statusItem?.button?.image = image
        } else if let iconURL = Bundle.module.url(forResource: "clawd", withExtension: "png", subdirectory: "Resources"),
                  let image = NSImage(contentsOf: iconURL) {
            image.isTemplate = true
            image.size = NSSize(width: 18, height: 18)
            statusItem?.button?.image = image
        } else {
            // Fallback to SF Symbol
            statusItem?.button?.image = NSImage(systemSymbolName: "rectangle.3.group", accessibilityDescription: "Kanban")
            statusItem?.button?.image?.size = NSSize(width: 18, height: 18)
        }

        updateMenu()
        updateVisibility()
    }

    func update() {
        updateMenu()
        updateVisibility()
    }

    private func updateMenu() {
        let menu = NSMenu()

        if let state = boardState {
            let activeCards = state.cards(in: .inProgress)
            let attentionCards = state.cards(in: .requiresAttention)

            if !activeCards.isEmpty {
                menu.addItem(NSMenuItem.sectionHeader(title: "In Progress"))
                for card in activeCards.prefix(5) {
                    let item = NSMenuItem(title: card.displayTitle, action: nil, keyEquivalent: "")
                    if card.isActivelyWorking {
                        item.image = NSImage(systemSymbolName: "gear.circle.fill", accessibilityDescription: nil)
                    } else {
                        item.image = NSImage(systemSymbolName: "play.circle.fill", accessibilityDescription: nil)
                    }
                    menu.addItem(item)
                }
            }

            if !attentionCards.isEmpty {
                menu.addItem(NSMenuItem.separator())
                menu.addItem(NSMenuItem.sectionHeader(title: "Requires Attention"))
                for card in attentionCards.prefix(5) {
                    let item = NSMenuItem(title: card.displayTitle, action: nil, keyEquivalent: "")
                    item.image = NSImage(systemSymbolName: "exclamationmark.circle.fill", accessibilityDescription: nil)
                    menu.addItem(item)
                }
            }

            if activeCards.isEmpty && attentionCards.isEmpty {
                let item = NSMenuItem(title: "No active sessions", action: nil, keyEquivalent: "")
                item.isEnabled = false
                menu.addItem(item)
            }
        }

        menu.addItem(NSMenuItem.separator())

        let openItem = NSMenuItem(title: "Open Kanban", action: #selector(openMainWindow), keyEquivalent: "o")
        openItem.target = self
        menu.addItem(openItem)

        menu.addItem(NSMenuItem.separator())

        let quitItem = NSMenuItem(title: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quitItem)

        statusItem?.menu = menu
        self.menu = menu
    }

    @objc func openMainWindow() {
        NSApp.activate(ignoringOtherApps: true)
        NSApp.windows.first?.makeKeyAndOrderFront(nil)
    }

    /// Show tray icon only when there are In Progress sessions.
    private func updateVisibility() {
        guard let state = boardState else { return }
        let hasActive = state.cardCount(in: .inProgress) > 0
        statusItem?.isVisible = hasActive
    }
}
