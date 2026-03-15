Feature: Embedded Terminal Emulator
  As a developer viewing sessions on the Kanban Code board
  I want a native terminal emulator embedded in each card's detail view
  So that I can interact with Claude Code without leaving the app

  Background:
    Given the Kanban Code application is running

  # ── Terminal Display ──

  Scenario: Opening a session's terminal
    Given a session card exists in "In Progress"
    When I click on the card
    Then a detail panel should open
    And it should contain a full terminal emulator
    And the terminal should be connected to the associated tmux session

  Scenario: Terminal is a first-class native component
    When the terminal is rendered
    Then it should use a native terminal emulator component (not a web view)
    And it should support:
      | Feature           | Required |
      | 256 colors        | yes      |
      | True color (24b)  | yes      |
      | Unicode/emoji     | yes      |
      | Mouse events      | yes      |
      | Alternate screen  | yes      |
      | Scrollback buffer | yes      |
      | Selection/copy    | yes      |
      | Paste             | yes      |
      | Font ligatures    | yes      |
    And rendering should be GPU-accelerated

  Scenario: Terminal connects to tmux session
    Given a session is linked to tmux session "feat-login"
    When I open the terminal view
    Then it should run `tmux attach-session -t feat-login`
    And I should see the current tmux output
    And I should be able to type and interact

  Scenario: Terminal shows tmux session attached elsewhere indicator
    Given a tmux session is already attached in another terminal
    When I view it in Kanban Code
    Then it should still show the output (tmux allows multiple clients)
    Or it should show "Session attached elsewhere" with option to force-attach

  # ── Terminal without tmux ──

  Scenario: No tmux session shows two action buttons
    Given a card has no tmuxLink
    When I open the terminal tab
    Then it should show "No tmux session attached"
    And two buttons should be visible:
      | Button           | Icon          | Style            | Action                           |
      | Resume Claude    | play.fill     | borderedProminent| Resumes claude session in tmux   |
      | New Terminal     | terminal      | bordered         | Creates a plain shell in tmux    |

  Scenario: Resume Claude from no-tmux state
    Given a card has sessionLink (sessionId = "abc-123") but no tmuxLink
    When I click "Resume Claude"
    Then a new tmux session should be created immediately
    And `claude --resume abc-123` should execute inside it
    And the card should move to "In Progress" IMMEDIATELY (before async completes)
    And the terminal tab should show the tmux session
    And the tmux tab should be labeled "Claude" with brain icon

  Scenario: New Terminal from no-tmux state
    Given a card has no tmuxLink
    When I click "New Terminal"
    Then a new tmux session should be created with a plain shell (no claude command)
    And the card should gain a tmuxLink immediately
    And the terminal tab should show the new tmux session
    And the tmux tab should be labeled "Shell" with terminal icon (not "Claude")

  # ── Terminal Tab Independence ──
  #
  # The Claude (primary) tab and extra shell tabs are independent.
  # Killing one should never affect the others. The Claude tab is
  # always present in the tab bar when any terminal exists.

  Scenario: Claude tab is always present in the tab bar
    Given a card has a tmuxLink (any terminal exists)
    When I view the terminal tab bar
    Then the "Claude" tab should always be present
    And its content depends on the primary session state:
      | State              | Content                                    |
      | Primary alive      | Live terminal connected to primary session  |
      | Primary launching  | "Starting session…" spinner + Stop button   |
      | Primary dead       | "Claude session ended" + Resume button      |

  Scenario: Killing Claude tab preserves extra terminals
    Given a card has primary tmux session "proj-abc" and extras ["proj-abc-sh1"]
    When I click X on the "Claude" tab
    Then only "proj-abc" tmux session should be killed
    And "proj-abc-sh1" should remain alive
    And the tab bar should still be visible with "sh1" tab
    And the "Claude" tab should show "Resume" button
    Because tmuxLink is preserved with isPrimaryDead = true

  Scenario: Killing extra terminal preserves Claude
    Given a card has primary tmux session "proj-abc" and extras ["proj-abc-sh1"]
    When I click X on the "sh1" tab
    Then only "proj-abc-sh1" tmux session should be killed
    And "proj-abc" should remain alive
    And the Claude tab should still show the live terminal

  Scenario: Killing last extra while Claude is dead removes tmuxLink
    Given a card has primary dead and extras ["proj-abc-sh1"]
    When I click X on the "sh1" tab
    Then both primary and extras are gone
    And tmuxLink should be set to nil
    And the terminal view should show "No tmux session attached"

  Scenario: Resume Claude when extras exist
    Given a card has primary dead and extras ["proj-abc-sh1"]
    When I click "Resume Claude" on the Claude tab
    Then a new primary tmux session should be created
    And extras should be preserved
    And the Claude tab should show the new terminal
    And the "sh1" tab should remain accessible

  Scenario: Creating extra terminal when Claude is dead
    Given a card has primary dead (no live Claude session)
    When I click the terminal icon button (terminal) to create a new terminal
    Then a new extra terminal should be created
    And it should appear as a new tab in the tab bar

  Scenario: Reconciler detects primary crash with extras alive
    Given a card has primary tmux session "proj-abc" and extras ["proj-abc-sh1"]
    And the primary tmux session crashes or is killed externally
    When the next reconciliation cycle runs
    Then tmuxLink should be preserved (not cleared)
    And isPrimaryDead should be set to true
    And the Claude tab should show "Resume" button
    And the "sh1" tab should remain functional

  # ── Cancel Launch ──

  Scenario: Cancel a launching session
    Given a card has isLaunching = true and a tmux session is being created
    When I click the "Stop" button on the launching spinner
    Then isLaunching should be cleared
    And the pre-created tmux session should be killed
    And the Claude tab should show "Resume" button

  Scenario: Session without tmux shows history
    Given a session "abc-123" has no linked tmux session
    When I open the card's detail view
    Then it should show the session history (conversation transcript)
    And a "Resume" button should be available
    And the resume command should be copyable

  Scenario: Switching between terminal and history tabs
    Given a session has both a tmux session and a transcript
    Then the detail view should have tabs:
      | Tab        | Content                          |
      | Terminal   | Live tmux terminal               |
      | History    | Conversation transcript          |
      | Checkpoint | Checkpoint management            |

  # ── Resume from Terminal ──

  Scenario: Resume a session without tmux
    Given a session "abc-123" has been silent for > 5 minutes
    And no running process is detected for this session
    When I click "Resume in terminal"
    Then a new tmux session should be created
    And `claude --resume abc-123` should execute inside it
    And the terminal should attach to the new tmux session
    And the card should move to "In Progress"

  Scenario: Resume gives command to copy
    Given a session "abc-123" has no tmux session
    When I click "Copy resume command"
    Then `claude --resume abc-123` should be copied to clipboard
    And a toast should confirm "Copied"

  Scenario: Checking for running process before resume
    Given a session "abc-123" appears idle
    When I click "Resume"
    Then it should first check if a Claude process exists:
      | Check                    | Method                           |
      | Process search           | ps aux | grep session-id         |
      | tmux pane check          | tmux list-panes in linked session|
    And if a process is found, warn: "A Claude process may still be running"
    And offer to kill it before resuming

  # ── Terminal Tab Labels ──

  Scenario: Claude session tab shows "Claude" with brain icon
    Given a card's primary tmux session was created by launching/resuming Claude
    And the tmuxLink has isShellOnly = false (default)
    When I view the terminal tab bar
    Then the primary tab should show brain icon + "Claude"
    And extra shell sessions should show terminal icon + "sh1", "sh2", etc.

  Scenario: Shell-only session tab shows "Shell" with terminal icon
    Given a card's primary tmux session was created via "New Terminal" (plain shell)
    And the tmuxLink has isShellOnly = true
    When I view the terminal tab bar
    Then the primary tab should show terminal icon + "Shell"
    And it should NOT show brain icon or "Claude"

  # ── Terminal Reattachment ──

  Scenario: Terminal reattaches when drawer closes and reopens
    Given a card has an active tmux session with terminal output
    When I close the card detail drawer
    And I reopen the card detail drawer
    Then the terminal should reconnect to the same tmux session
    And the tmux scrollback buffer should be preserved
    Because tmux sessions persist independently of the UI

  Scenario: Terminal view does not terminate tmux on close
    Given a card's terminal is showing an active tmux session
    When the drawer is closed (SwiftUI inspector dismissed)
    Then the tmux CLIENT process should be terminated (the attach)
    But the tmux SERVER session should continue running
    And reopening should reattach with full scrollback

  # ── Terminal Performance ──

  Scenario: Terminal renders at native speed
    Given the terminal is displaying rapid output (e.g., test runner)
    Then rendering should maintain 60fps
    And there should be no visible lag between output and display

  Scenario: Large scrollback doesn't degrade performance
    Given a terminal with 10,000 lines of scrollback
    When I scroll through the history
    Then scrolling should be smooth
    And memory usage should be bounded

  # ── Copy tmux attach command ──

  Scenario: Copy tmux command for external terminal
    Given a session is linked to tmux session "feat-login"
    When I click "Copy tmux command"
    Then `tmux attach-session -t feat-login` should be copied to clipboard
    And I can paste it in iTerm, Terminal.app, or any terminal
