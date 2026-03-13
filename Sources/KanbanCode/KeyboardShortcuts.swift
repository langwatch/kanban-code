import SwiftUI
import KanbanCodeCore

// MARK: - App Context

/// Derived from AppState — shortcuts check these flags to decide whether to fire.
struct AppShortcutContext {
    var paletteOpen: Bool
    var detailOpen: Bool
    var expandedDetail: Bool
    var terminalTabActive: Bool

    init(from state: AppState, terminalTabActive: Bool = false) {
        self.paletteOpen = state.paletteOpen
        self.detailOpen = state.selectedCardId != nil
        self.expandedDetail = state.detailExpanded
        self.terminalTabActive = terminalTabActive
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

    // Detail panel
    case toggleExpanded         // Cmd+Enter (only when detail open, palette closed)
    case newTerminal            // Cmd+T (only when detail open on terminal tab, palette closed)

    // Palette-specific
    case deepSearch             // Cmd+Enter (only when palette open)

    // Board
    case deselect               // Escape
    case deleteCard             // Delete
    case deleteCardForward      // Fn+Delete

    // Projects
    case project1, project2, project3, project4, project5
    case project6, project7, project8, project9

    static var allCases: [AppShortcut] {
        [.openPaletteK, .openPaletteP, .openCommandMode,
         .toggleExpanded, .newTerminal, .deepSearch,
         .deselect, .deleteCard, .deleteCardForward,
         .project1, .project2, .project3, .project4, .project5,
         .project6, .project7, .project8, .project9]
    }

    var key: KeyEquivalent {
        switch self {
        case .openPaletteK: return "k"
        case .openPaletteP: return "p"
        case .openCommandMode: return "p"
        case .toggleExpanded, .deepSearch: return .return
        case .newTerminal: return "t"
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
        case .toggleExpanded, .deepSearch: return .command
        case .newTerminal: return .command
        case .deselect, .deleteCard, .deleteCardForward: return []
        case .project1, .project2, .project3, .project4, .project5,
             .project6, .project7, .project8, .project9: return .command
        }
    }

    /// Whether this shortcut should be active given the current context.
    func isActive(in ctx: AppShortcutContext) -> Bool {
        switch self {
        // Palette open/close works everywhere
        case .openPaletteK, .openPaletteP, .openCommandMode:
            return true

        // Expand detail only when detail is open AND palette is closed
        case .toggleExpanded:
            return ctx.detailOpen && !ctx.paletteOpen

        // New terminal only when detail is open on terminal tab AND palette is closed
        case .newTerminal:
            return ctx.detailOpen && ctx.terminalTabActive && !ctx.paletteOpen

        // Deep search only when palette is open
        case .deepSearch:
            return ctx.paletteOpen

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
