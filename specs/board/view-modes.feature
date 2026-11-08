Feature: Board View Modes
  As a developer managing many Claude Code sessions
  I want to switch between kanban and list layouts
  So that I can use the presentation that fits the task at hand

  Background:
    Given the Kanban Code application is running
    And I have at least one visible card on the board

  @e2e
  Scenario: Switch from kanban to list view
    Given the board is shown in kanban view
    When I switch the board to list view
    Then the sidebar lists the cards the way the phone does
    And sections run Pinned, Live, Waiting, In Progress, In Review, Done, then Backlog last
    And Live holds every card whose assistant session runs now, working ones first
    And each other section holds the cards of its column that are not live or pinned
    And All Sessions is not listed; the kanban view keeps it

  @unit
  Scenario: Empty sections are left out of the sidebar
    Given the board is shown in list view
    And no card is in review
    Then there is no "In Review" section
    But the "Backlog" section is always shown, to drop and refresh tasks

  @e2e
  Scenario: Collapse a section in list view
    Given the board is shown in list view
    When I collapse the "Backlog" section
    Then the "Backlog" section header should remain visible
    And its cards should be hidden until I expand it again

  @e2e
  Scenario: Arrow keys follow the sidebar
    Given the board is shown in list view and a card is selected
    When I press the down arrow
    Then the next card down the sidebar is selected, across sections
    And left and right jump to the previous or next section

  @e2e
  Scenario: Clicking the full section header toggles collapse
    Given the board is shown in list view
    When I click anywhere in the "Live" section header
    Then the "Live" section should toggle between collapsed and expanded

  @integration
  Scenario: Backlog refresh control remains separate from collapse
    Given the board is shown in list view
    And the "Backlog" workflow section is expanded
    When I click the refresh control in the "Backlog" section header
    Then the backlog should refresh
    And the "Backlog" section should remain expanded

  @e2e
  Scenario: Selected card survives a view mode change
    Given I have selected a card on the board
    When I switch between kanban view and list view
    Then the same card should remain selected
    And the card detail inspector should continue showing that card

  @e2e
  Scenario: View mode persists across relaunch
    Given I switch the board to list view
    When I quit and relaunch Kanban Code
    Then the board should reopen in list view

  # The pinned rail is the only child of the horizontal board that grows
  # with its content. A rail taller than the window vertically centers the
  # whole board: column headers and the first cards of every column end up
  # above the screen, and the board looks cut off no matter where you scroll.
  Scenario: A tall pinned rail scrolls instead of lifting the board
    Given the board is shown in kanban view
    And more cards are pinned than fit the window height
    Then the pinned rail should scroll on its own
    And every column header should stay visible at the top of its column
    And the first card of each column should start below the toolbar
