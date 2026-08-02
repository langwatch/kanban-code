Feature: Drag and Drop
  As a developer using Kanban Code
  I want to manually move cards between columns via drag and drop
  So that I can override automation when I know better

  Background:
    Given the Kanban Code application is running

  @e2e
  Scenario: Drag card between columns in board view
    Given a card "Fix login bug" is in "In Progress"
    And the board is shown in kanban view
    When I drag the card to "Requires Attention"
    Then the card should move to "Requires Attention"
    And the move should be recorded as a manual override
    And automation should still be able to move it back when state changes

  @e2e
  Scenario: Drag card between workflow sections in list view
    Given a card "Fix login bug" is in "In Progress"
    And the board is shown in list view
    When I drag the card to the "Requires Attention" workflow section
    Then the card should move to "Requires Attention"
    And the move should be recorded as a manual override
    And the same card should appear in the "Requires Attention" section

  @integration
  Scenario: Drag card to All Sessions (manual archive)
    Given a card is in "In Progress"
    When I drag it to "All Sessions"
    Then the card should be archived
    And it should not auto-return based on session age
    And a flag "manuallyArchived" should be set in the coordination file

  @integration
  Scenario: Drag card from All Sessions to Backlog
    Given a card is in "All Sessions"
    When I drag it to "Backlog"
    Then it should appear in "Backlog"
    And the "manuallyArchived" flag should be cleared

  @integration
  Scenario: Invalid drop target is rejected before drop
    Given a card without a pull request is in "Requires Attention"
    When I drag the card toward "In Review"
    Then the "In Review" drop target should show a "not allowed" indicator
    And dropping the card there should leave it in "Requires Attention"
    And no manual override should be recorded

  @e2e
  Scenario: Visual feedback during drag
    When I start dragging a card
    Then the card should show a drag ghost with reduced opacity
    And valid drop columns should highlight
    And invalid drop targets should show a "not allowed" indicator

  @integration
  Scenario: Drag cancelled
    When I start dragging a card
    And I release it outside any column
    Then the card should animate back to its original position
    And no state changes should occur

  @integration
  Scenario: Reorder cards within a workflow status
    Given the "Backlog" column has 5 cards
    When I drag the 3rd card above the 1st card
    Then the card order should update within the column
    And the new order should persist
    And the same order should be shown in both board and list view

  Scenario: A reorder is not undone by a reconcile already in flight
    Given background reconciliation read the board before the drag
    When I drag a card to a new position within its column
    And that reconciliation finishes afterwards
    Then the card should stay where I dropped it
    And the same should hold for reordering pinned cards
