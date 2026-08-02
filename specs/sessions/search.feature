Feature: Session Search
  As a developer with hundreds of past sessions
  I want BM25 full-text search across all sessions
  So that I can find and resume any conversation

  Background:
    Given the Kanban Code application is running

  # ── Search Interface ──
  # (Learned from claude-resume: live filter + BM25 deep search)

  Scenario: Search bar is accessible from anywhere
    When I press Cmd+K (or a configurable shortcut)
    Then a search overlay should appear
    And the search input should be focused
    And I should be able to type immediately

  Scenario: Live filtering by metadata
    Given the search overlay is open
    When I type "langwatch auth"
    Then cards should be filtered instantly by:
      | Field          | Match Type    |
      | Session name   | substring     |
      | First prompt   | substring     |
      | Project name   | substring     |
      | Project path   | substring     |
      | Git branch     | substring     |
      | Custom name    | substring     |
    And multi-word queries should match terms independently
    And each term should be highlighted in results

  Scenario: Deep search via Enter
    Given I've typed "database migration" in the search bar
    When I press Enter
    Then a BM25 full-text search should run through .jsonl files
    And results should stream in ranked by relevance
    And each result should show:
      | Field         | Description                               |
      | Session name  | Title or first message                    |
      | Relevance bar | Visual indicator of BM25 score            |
      | Snippet       | Matching text excerpt with highlighting   |
      | Project       | Project name                              |
      | Time          | Last modified time                        |

  # ── BM25 Scoring ──
  # (Learned from claude-resume: k1=1.2, b=0.4, recency boost, prefix matching)

  Scenario: BM25 parameters
    Given the deep search is running
    Then scoring should use:
      | Parameter    | Value | Description                     |
      | k1           | 1.2   | Term frequency saturation       |
      | b            | 0.4   | Document length normalization   |
      | recency boost| yes   | Recent sessions score higher    |
    And partial terms should use prefix matching

  Scenario: Search streams results newest-first
    Given many .jsonl files exist
    When deep search runs
    Then files should be processed newest-first (by mtime)
    And results should appear incrementally as files are scored
    And the UI should update without blocking

  Scenario: A slow file never holds back a match found elsewhere
    Given a match is found in a small transcript
    And a much larger transcript is being scanned at the same time
    When the small transcript finishes
    Then its match should be delivered immediately
    And it should not wait for the larger transcript to finish
    And a fixed number of transcripts should stay in flight throughout

  Scenario: Multi-word highlighting in search results
    Given I search for "database migration v2"
    Then each term ("database", "migration", "v2") should be highlighted
    And overlapping highlight ranges should be merged
    And highlighting should work in both the card title and the snippet

  # ── Search Actions ──

  Scenario: Open a search result
    Given search results are displayed
    When I click on a result
    Then the session card should be focused/selected on the board
    And if the card is in "All Sessions", the column should be visible

  Scenario: Fork from search results
    Given I found an old session via search
    When I right-click and select "Fork"
    Then the fork operation should proceed
    And the new session should appear on the board

  Scenario: Resume from search results
    Given I found a session via search
    When I click "Resume"
    Then Claude should be resumed with that session ID
    And the session should move to "In Progress"

  Scenario: Checkpoint from search results
    Given I found a session via search
    When I select "Checkpoint"
    Then the checkpoint view should open for that session

  # ── Search Performance ──

  Scenario: Search across 1000+ sessions
    Given 1000 session .jsonl files exist
    When I perform a deep search
    Then the first results should appear within 500ms
    And the search should complete within 5 seconds
    And the UI should never freeze

  Scenario: Search cancellation
    Given a deep search is running
    When I press Escape
    Then the search should be cancelled
    And any partial results should be cleared
    And the search overlay should close

  Scenario: Search while typing
    Given I'm typing in the search bar
    When I modify the query
    Then the live filter should update immediately
    And any running deep search should be cancelled
    And a new deep search should start on Enter
    And the new search should wait for the cancelled one to stop scanning
    And two full-corpus scans should never run at the same time
