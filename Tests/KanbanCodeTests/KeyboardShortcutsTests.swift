import Testing
import SwiftUI
@testable import KanbanCode

@Suite("Keyboard Shortcuts")
struct KeyboardShortcutsTests {
    @Test("resume uses command-return and view toggle uses command-shift-return")
    func resumeAndToggleShortcutsDoNotConflict() {
        #expect(AppShortcut.resumeAssistant.key == .return)
        #expect(AppShortcut.resumeAssistant.modifiers == .command)
        #expect(AppShortcut.resumeAssistant.displayString == "⌘↩")

        #expect(AppShortcut.toggleExpanded.key == .return)
        #expect(AppShortcut.toggleExpanded.modifiers == [.command, .shift])
        #expect(AppShortcut.toggleExpanded.displayString == "⇧⌘↩")
    }

    @Test("resume is active only for selected ended assistant session")
    func resumeActiveOnlyForEndedAssistantSession() {
        #expect(AppShortcut.resumeAssistant.isActive(in: AppShortcutContext(
            paletteOpen: false,
            detailOpen: true,
            expandedDetail: false,
            promptEditorFocused: false,
            canResumeAssistant: true
        )))

        #expect(!AppShortcut.resumeAssistant.isActive(in: AppShortcutContext(
            paletteOpen: false,
            detailOpen: true,
            expandedDetail: false,
            promptEditorFocused: false,
            canResumeAssistant: false
        )))
    }
}
