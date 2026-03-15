import Testing
@testable import KanbanCode

@Suite("ToolbarVisibility")
struct ToolbarVisibilityTests {
    // MARK: - Normal mode (not expanded)

    @Test("Normal mode: all controls visible")
    func normalMode() {
        let v = ToolbarVisibility(isExpandedDetail: false, showBoardInExpanded: false, hasSelectedCard: true)
        #expect(v.showBoardControls == true)
        #expect(v.showViewModePicker == true)
        #expect(v.showInspectorToggle == true)
        #expect(v.showExpandedCardInfo == false)
    }

    @Test("Normal mode without card: no expanded card info")
    func normalModeNoCard() {
        let v = ToolbarVisibility(isExpandedDetail: false, showBoardInExpanded: false, hasSelectedCard: false)
        #expect(v.showBoardControls == true)
        #expect(v.showViewModePicker == true)
        #expect(v.showInspectorToggle == true)
        #expect(v.showExpandedCardInfo == false)
    }

    // MARK: - Expanded mode, sidebar closed

    @Test("Expanded, sidebar closed: board controls visible, picker and inspector visible, card info visible")
    func expandedSidebarClosed() {
        let v = ToolbarVisibility(isExpandedDetail: true, showBoardInExpanded: false, hasSelectedCard: true)
        #expect(v.showBoardControls == true)
        #expect(v.showViewModePicker == true)
        #expect(v.showInspectorToggle == true)
        #expect(v.showExpandedCardInfo == true)
    }

    // MARK: - Expanded mode, sidebar open

    @Test("Expanded, sidebar open: board controls hidden (in sidebar), picker and inspector still visible")
    func expandedSidebarOpen() {
        let v = ToolbarVisibility(isExpandedDetail: true, showBoardInExpanded: true, hasSelectedCard: true)
        #expect(v.showBoardControls == false)
        #expect(v.showViewModePicker == true)
        #expect(v.showInspectorToggle == true)
        #expect(v.showExpandedCardInfo == true)
    }

    // MARK: - Expanded without card

    @Test("Expanded without card: no expanded card info, inspector toggle still visible")
    func expandedNoCard() {
        let v = ToolbarVisibility(isExpandedDetail: true, showBoardInExpanded: true, hasSelectedCard: false)
        #expect(v.showExpandedCardInfo == false)
        #expect(v.showInspectorToggle == true)
        #expect(v.showViewModePicker == true)
    }
}
