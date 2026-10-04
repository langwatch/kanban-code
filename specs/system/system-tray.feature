Feature: System Tray and Amphetamine Integration
  As a developer running Claude Code sessions
  I want my Mac to stay awake while Claude is working
  So that long-running tasks don't get interrupted by sleep

  Background:
    Given the Kanban Code application is running

  # ── Secondary App Pattern ──
  # (Learned from cc-amphetamine: Electron as secondary app, Amphetamine trigger)

  Scenario: Secondary tray app spins up when Claude is active
    Given at least one Claude session is in "In Progress"
    When the background process detects active work
    Then a secondary system tray app should be spawned
    And it should appear in the menu bar with the Kanban Code icon
    And Amphetamine should detect it as a running application

  Scenario: Tray app process name for Amphetamine
    Given the secondary tray app is running
    Then it should appear in Activity Monitor with a recognizable name
    And Amphetamine should be configurable to trigger on this process

  Scenario: Tray app shows active session count
    Given 3 Claude sessions are active
    When I look at the menu bar
    Then the tray icon should indicate activity (e.g., small badge or animation)
    And clicking it should show a dropdown with:
      | Item                          |
      | "3 active sessions"           |
      | Session #1: <name> (project)  |
      | Session #2: <name> (project)  |
      | Session #3: <name> (project)  |
      | ---                           |
      | Open Kanban Code                   |
      | Exit                          |

  Scenario: Tray app disappears when no sessions active
    Given all Claude sessions have ended or timed out
    When the polling loop detects zero active sessions
    Then the tray app should exit
    And the menu bar icon should disappear
    And Amphetamine should detect the process is gone and allow sleep

  # ── Polling and Lifecycle ──

  Scenario: Polling for active sessions
    Given the tray app is running
    Then it should poll the coordination file every 5 seconds
    And check for sessions with recent activity
    And update the tray icon/menu accordingly

  Scenario: Session timeout
    Given the tray app is polling
    And a session's last_activity is older than the configured timeout (default 15 min)
    Then that session should be considered inactive
    And if no other sessions are active, the tray app should exit

  Scenario: Multiple concurrent sessions
    Given sessions #1 and #2 are both active
    When session #1 times out
    Then the tray app should remain running for session #2
    And the menu should update to show only 1 active session

  # ── Race Condition Prevention ──
  # (Learned from cc-amphetamine: .starting lock, PID validation)

  Scenario: Preventing duplicate tray app spawns
    Given two Claude sessions start simultaneously
    When both try to spawn the tray app
    Then only one tray app should start
    And the startup lock should prevent the second spawn
    And the lock file should use exclusive create (O_EXCL)

  Scenario: PID validation for existing tray app
    Given a PID file exists from a previous run
    When checking if the tray app is running
    Then the PID should be validated:
      | Check                    | Method                              |
      | Process exists           | kill(pid, 0) signal check           |
      | Correct process          | ps -p pid shows the right command   |
    And if the PID is stale (wrong process), it should be cleaned up

  # ── Integration with Main App ──

  Scenario: Tray app can open main Kanban Code window
    Given the tray app is running and the main app is minimized
    When I click "Open Kanban Code" in the tray menu
    Then the main Kanban Code window should come to the foreground

  Scenario: Tray app runs independently of main window
    Given the main Kanban Code window is closed
    And Claude sessions are still active
    Then the tray app should continue running
    And the menu bar icon should remain visible
    And it should still keep the Mac awake via Amphetamine

  # ── A card used from the phone ──

  Scenario: A phone request to a card on this Mac keeps it awake
    Given no session is working on this Mac
    When the phone asks for a card this Mac owns
    Then the Mac takes a power assertion that holds it awake for 10 minutes after the last such request
    And the helper app runs for the same time
    And the hold ends by itself

  Scenario Outline: What does not count
    When <caller> calls <route>
    Then the Mac is not held awake

    Examples:
      | caller                                 | route                         |
      | a paired master, for its own sync      | the board, links or events    |
      | a paired master, mirroring transcripts | a card's raw transcript       |
      | an agent token                         | a card's transcript or prompt |
      | the phone                              | the board or the events       |

  Scenario: A paired master passing on the phone's request
    Given the phone asks the box for a card this Mac owns
    When the box forwards the request
    Then the request says it is for the human
    And the Mac is held awake

  Scenario: The setting turns it off
    Given "Stay awake while a card on this Mac is used from the phone" is off
    When the phone asks for a card this Mac owns
    Then no power assertion is taken

  # ── Edge Cases ──

  Scenario: Amphetamine not installed
    Given Amphetamine is not installed
    Then the tray app should still function
    And a hint should appear: "Install Amphetamine to prevent sleep during long tasks"
    And the tray icon should still show active session status

  Scenario: macOS permission for tray icon
    Given the app doesn't have notification permission
    Then the tray icon should still work
    And only push notification features should be degraded
