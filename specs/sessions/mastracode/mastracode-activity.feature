Feature: Mastracode Activity Detection
  As a developer running Mastracode sessions
  I want Kanban Code to detect when Mastracode is active or idle
  So that the board updates automatically with status indicators

  Background:
    Given the Kanban Code application is running
    And the Mastracode LibSQL database is located at the system path
    And a Mastracode session is linked to a card

  # ── Database Polling ──

  @integration
  Scenario: Detect activity from database modification time
    Given the Mastracode database file (`db.sqlite` or `.wal`) was modified less than 2 minutes ago
    When the Mastracode activity detector polls
    Then it should emit a `SessionUpdate` for the active thread
    And `isThinking` should be true

  @integration
  Scenario: Detect idle state from older modification time
    Given the Mastracode database file was modified more than 5 minutes ago
    When the Mastracode activity detector polls
    Then it should not emit a `SessionUpdate`

  # ── Active Thread Resolution ──

  @integration
  Scenario: Correlate activity with a specific session
    Given the Mastracode database was recently modified
    And a query to the `messages` table reveals the latest message belongs to "thread_123"
    And "thread_123" is linked to card "kanban-5"
    When the Mastracode activity detector polls
    Then the `SessionUpdate` should only target session "thread_123"

  # ── Edge Cases ──

  @unit
  Scenario: Database file missing during polling
    Given the Mastracode database file does not exist
    When the Mastracode activity detector polls
    Then it should fail silently and not emit any updates

  @integration
  Scenario: Multiple Mastracode sessions active
    Given the database was recently modified
    And queries show new messages for both "thread_A" and "thread_B"
    When the Mastracode activity detector polls
    Then it should emit updates for both sessions
