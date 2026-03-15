import Testing
@testable import KanbanCode

@Suite("ToolbarVisibility")
struct ToolbarVisibilityTests {
    // MARK: - Normal mode (not expanded)

    @Test("Normal mode: shows board controls, view picker, inspector toggle")
    func normalMode() {
        let v = ToolbarVisibility(isExpandedDetail: false, showBoardInExpanded: false, hasSelectedCard: true)
        #expect(v.showBoardControls == true)
        #expect(v.showViewModePicker == true)
        #expect(v.showInspectorToggle == true)
        #expect(v.showExpandedCardInfo == false)
    }

    @Test("Normal mode without card: no expanded card info, inspector toggle still visible")
    func normalModeNoCard() {
        let v = ToolbarVisibility(isExpandedDetail: false, showBoardInExpanded: false, hasSelectedCard: false)
        #expect(v.showBoardControls == true)
        #expect(v.showInspectorToggle == true)
        #expect(v.showExpandedCardInfo == false)
    }

    // MARK: - Expanded mode, sidebar closed

    @Test("Expanded, sidebar closed: shows board controls; hides view picker, inspector toggle")
    func expandedSidebarClosed() {
        let v = ToolbarVisibility(isExpandedDetail: true, showBoardInExpanded: false, hasSelectedCard: true)
        #expect(v.showBoardControls == true)
        #expect(v.showViewModePicker == false)
        #expect(v.showInspectorToggle == false)
        #expect(v.showExpandedCardInfo == true)
    }

    // MARK: - Expanded mode, sidebar open

    @Test("Expanded, sidebar open: hides board controls (they're in sidebar toolbar)")
    func expandedSidebarOpen() {
        let v = ToolbarVisibility(isExpandedDetail: true, showBoardInExpanded: true, hasSelectedCard: true)
        #expect(v.showBoardControls == false)
        #expect(v.showViewModePicker == false)
        #expect(v.showInspectorToggle == false)
        #expect(v.showExpandedCardInfo == true)
    }

    // MARK: - Edge cases

    @Test("Expanded without card: no expanded card info")
    func expandedNoCard() {
        let v = ToolbarVisibility(isExpandedDetail: true, showBoardInExpanded: false, hasSelectedCard: false)
        #expect(v.showExpandedCardInfo == false)
    }
}
