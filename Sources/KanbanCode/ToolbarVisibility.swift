/// Pure-logic model determining which toolbar items are visible in each mode.
/// Extracted from ContentView so it can be unit-tested independently.
struct ToolbarVisibility {
    let isExpandedDetail: Bool
    let showBoardInExpanded: Bool
    let hasSelectedCard: Bool

    /// New task, refresh, dark mode, project selector — shown when sidebar is NOT visible.
    /// When the sidebar is open these controls live inline inside the sidebar.
    var showBoardControls: Bool {
        !(isExpandedDetail && showBoardInExpanded)
    }

    /// Kanban/list segmented picker — only in normal (non-expanded) mode.
    var showViewModePicker: Bool {
        !isExpandedDetail
    }

    /// Inspector toggle (sidebar.right) — only in non-expanded mode.
    /// In expanded mode the card detail IS the content, no inspector to toggle.
    var showInspectorToggle: Bool {
        !isExpandedDetail
    }

    /// Expanded card info (title, tab picker, contract, editor, actions).
    var showExpandedCardInfo: Bool {
        isExpandedDetail && hasSelectedCard
    }
}
