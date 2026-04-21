Feature: Detect Codex CLI Activity
  As a developer monitoring Codex work
  I want Kanban Code to infer Codex activity from session files
  So that Codex cards move through the board without assistant hooks

  Background:
    Given a Codex card is linked to a Codex JSONL session file

  Scenario: Fresh Codex file is actively working
    Given the Codex session file was modified less than 2 minutes ago
    When activity polling runs
    Then the Codex card should be marked activelyWorking

  Scenario: Recently stopped Codex file needs attention
    Given the Codex session file was modified between 2 and 5 minutes ago
    When activity polling runs
    Then the Codex card should be marked needsAttention

  Scenario: Older Codex file is idle
    Given the Codex session file was modified between 5 minutes and 1 hour ago
    When activity polling runs
    Then the Codex card should be marked idleWaiting

  Scenario: Missing Codex file is ended
    Given the Codex session file no longer exists
    When activity polling runs
    Then the Codex card should be marked ended

  Scenario: Codex hook events are ignored
    Given a hook event is received for a Codex session id
    When CodexActivityDetector handles the event
    Then the hook should not change the Codex activity state
    And the next file poll should remain the source of truth
