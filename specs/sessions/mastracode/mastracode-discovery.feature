Feature: Mastracode Session Discovery
  As a developer using Mastracode
  I want Kanban Code to discover my Mastracode sessions
  So that they appear on the board alongside Claude and Gemini sessions

  Background:
    Given the Kanban Code application is running
    And Mastracode is installed
    And a LibSQL database exists at the system-specific application support path

  # ── Project Scoping ──

  @unit
  Scenario: Read threads scoped to git remote URL
    Given the current project has the git remote URL "git@github.com:langwatch/kanban-code.git"
    And the Mastracode database contains a thread mapped to that URL
    When Mastracode session discovery queries the database
    Then it should retrieve that thread as a Kanban Session
    And its projectPath should match the current project

  @unit
  Scenario: Read threads scoped to absolute path fallback
    Given the current project has no git remote URL
    And the current project path is "/Users/dev/my-project"
    And the Mastracode database contains a thread mapped to "/Users/dev/my-project"
    When Mastracode session discovery queries the database
    Then it should retrieve that thread as a Kanban Session

  # ── Session Querying ──

  @integration
  Scenario: Parse session metadata from database rows
    Given a Mastracode database contains a thread:
      | ThreadID | Title          | CreatedAt           | UpdatedAt           |
      | thread_1 | Fix API errors | 2026-03-09T10:00:00 | 2026-03-09T10:05:00 |
    When the Mastracode session discovery runs
    Then 1 session should be discovered
    And it should have assistant = "mastracode"
    And id = "thread_1"
    And name = "Fix API errors"

  @unit
  Scenario: Exclude empty threads
    Given the Mastracode database contains a thread "thread_2" with 0 messages
    When Mastracode session discovery runs
    Then "thread_2" should not appear in the results

  # ── Edge Cases ──

  @unit
  Scenario: Missing or uninitialized database
    Given the Mastracode database file does not exist (first run)
    When Mastracode session discovery runs
    Then it should return an empty session list without crashing

  @unit
  Scenario: SQLite database locked
    Given the Mastracode CLI is actively writing and the database returns SQLITE_BUSY
    When Mastracode session discovery runs
    Then it should retry gracefully or return the last known state
