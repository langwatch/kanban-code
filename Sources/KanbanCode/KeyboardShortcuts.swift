import SwiftUI
import KanbanCodeCore

// MARK: - App Context

/// Derived from AppState — shortcuts check these flags to decide whether to fire.
struct AppShortcutContext {
    var paletteOpen: Bool
    var detailOpen: Bool
    var expandedDetail: Bool
    var terminalTabActive: Bool
    var promptEditorFocused: Bool

    init(from state: AppState, terminalTabActive: Bool = false) {
        self.paletteOpen = state.paletteOpen
        self.detailOpen = state.selectedCardId != nil
        self.expandedDetail = state.detailExpanded
        self.terminalTabActive = terminalTabActive
        self.promptEditorFocused = state.promptEditorFocused
    }
}

// MARK: - Shortcut Definitions

/// All keyboard shortcuts in the app, centralized.
/// Each shortcut has a key, modifiers, and a `when` condition.
enum AppShortcut: CaseIterable {
    // Palette
    case openPaletteK           // Cmd+K
    case openPaletteP           // Cmd+P
    case openCommandMode        // Cmd+Shift+P

    // Global actions
    case newTask                // Cmd+N
    case openSettings           // Cmd+,

    // Detail panel
    case toggleExpanded         // Cmd+Enter (only when palette closed)
    case toggleSidebar          // Cmd+B (only in expanded mode, palette closed)
    case newTerminal            // Cmd+T (only when detail open on terminal tab, palette closed)
    case navigateBack           // Cmd+[ (only in expanded mode, palette closed)
    case navigateForward        // Cmd+] (only in expanded mode, palette closed)

    // Palette-specific
    case deepSearch             // Cmd+Enter (only when palette open)

    // Chat
    case stopAssistant          // Escape (when prompt focused in chat mode)

    // Browser
    case browserReload          // Cmd+R (when browser tab active)
    case browserFocusAddress    // Cmd+L (when browser tab active)
    case reopenClosedTab        // Cmd+Shift+T (reopen last closed browser/terminal tab)

    // Board
    case deselect               // Escape
    case deleteCard             // Delete
    case deleteCardForward      // Fn+Delete

    // Projects
    case project1, project2, project3, project4, project5
    case project6, project7, project8, project9

    static var allCases: [AppShortcut] {
        [.openPaletteK, .openPaletteP, .openCommandMode,
         .newTask, .openSettings,
         .toggleExpanded, .toggleSidebar, .newTerminal, .navigateBack, .navigateForward, .deepSearch,
         .stopAssistant, .browserReload, .browserFocusAddress, .reopenClosedTab,
         .deselect, .deleteCard, .deleteCardForward,
         .project1, .project2, .project3, .project4, .project5,
         .project6, .project7, .project8, .project9]
    }

    var key: KeyEquivalent {
        switch self {
        case .openPaletteK: return "k"
        case .openPaletteP: return "p"
        case .openCommandMode: return "p"
        case .newTask: return "n"
        case .openSettings: return ","
        case .toggleExpanded, .deepSearch: return .return
        case .toggleSidebar: return "b"
        case .newTerminal: return "t"
        case .navigateBack: return "["
        case .navigateForward: return "]"
        case .browserReload: return "r"
        case .browserFocusAddress: return "l"
        case .reopenClosedTab: return "t"
        case .stopAssistant: return .escape
        case .deselect: return .escape
        case .deleteCard: return .delete
        case .deleteCardForward: return .deleteForward
        case .project1: return "1"
        case .project2: return "2"
        case .project3: return "3"
        case .project4: return "4"
        case .project5: return "5"
        case .project6: return "6"
        case .project7: return "7"
        case .project8: return "8"
        case .project9: return "9"
        }
    }

    var modifiers: EventModifiers {
        switch self {
        case .openPaletteK, .openPaletteP: return .command
        case .openCommandMode: return [.command, .shift]
        case .newTask, .openSettings: return .command
        case .toggleExpanded, .deepSearch: return .command
        case .toggleSidebar: return .command
        case .newTerminal: return .command
        case .navigateBack, .navigateForward: return .command
        case .browserReload, .browserFocusAddress: return .command
        case .reopenClosedTab: return [.command, .shift]
        case .stopAssistant: return []
        case .deselect, .deleteCard, .deleteCardForward: return []
        case .project1, .project2, .project3, .project4, .project5,
             .project6, .project7, .project8, .project9: return .command
        }
    }

    /// Human-readable shortcut string derived from key + modifiers (e.g. "⌘N").
    var displayString: String {
        var parts = ""
        if modifiers.contains(.control) { parts += "⌃" }
        if modifiers.contains(.option) { parts += "⌥" }
        if modifiers.contains(.shift) { parts += "⇧" }
        if modifiers.contains(.command) { parts += "⌘" }

        let keyStr: String
        switch key {
        case .return: keyStr = "↩"
        case .escape: keyStr = "⎋"
        case .delete: keyStr = "⌫"
        case .deleteForward: keyStr = "⌦"
        case .space: keyStr = "␣"
        default: keyStr = String(key.character).uppercased()
        }
        return parts + keyStr
    }

    /// Whether this shortcut should be active given the current context.
    func isActive(in ctx: AppShortcutContext) -> Bool {
        switch self {
        // Palette open/close works everywhere
        case .openPaletteK, .openPaletteP, .openCommandMode,
             .newTask, .openSettings:
            return true

        // Toggle between kanban and expanded+sidebar mode
        case .toggleExpanded:
            return !ctx.paletteOpen && !ctx.promptEditorFocused

        // Toggle sidebar in expanded (list) mode
        case .toggleSidebar:
            return ctx.expandedDetail && !ctx.paletteOpen

        // New terminal only when detail is open on terminal tab AND palette is closed
        case .newTerminal:
            return ctx.detailOpen && ctx.terminalTabActive && !ctx.paletteOpen

        case .navigateBack, .navigateForward:
            return ctx.expandedDetail && !ctx.paletteOpen && !ctx.promptEditorFocused

        // Deep search only when palette is open
        case .deepSearch:
            return ctx.paletteOpen

        // Stop assistant: only when prompt editor is focused (chat mode)
        case .stopAssistant:
            return ctx.promptEditorFocused && !ctx.paletteOpen

        // Browser shortcuts: detail panel open, not in palette.
        // The action handlers themselves check if a browser tab is selected.
        case .browserReload, .browserFocusAddress:
            return ctx.detailOpen && !ctx.paletteOpen && !ctx.promptEditorFocused

        // Reopen last closed tab: whenever detail is open.
        case .reopenClosedTab:
            return ctx.detailOpen && !ctx.paletteOpen && !ctx.promptEditorFocused

        // Board shortcuts only when palette is closed
        case .deselect, .deleteCard, .deleteCardForward:
            return !ctx.paletteOpen

        // Project switching works everywhere (palette auto-closes)
        case .project1, .project2, .project3, .project4, .project5,
             .project6, .project7, .project8, .project9:
            return true
        }
    }

    var projectIndex: Int? {
        switch self {
        case .project1: return 0
        case .project2: return 1
        case .project3: return 2
        case .project4: return 3
        case .project5: return 4
        case .project6: return 5
        case .project7: return 6
        case .project8: return 7
        case .project9: return 8
        default: return nil
        }
    }
}
