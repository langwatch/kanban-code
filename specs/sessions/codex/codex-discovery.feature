Feature: Discover Codex CLI Sessions
  As a developer using Codex CLI
  I want Kanban Code to discover Codex session files
  So that Codex work appears on the board like Claude and Gemini work

  Background:
    Given Codex CLI is installed
    And the Kanban Code application is running

  Scenario: Discover nested Codex JSONL sessions
    Given a Codex session file exists at "~/.codex/sessions/2026/04/19/rollout-019da64f.jsonl"
    And the file contains a "session_meta" record with id "019da64f-874c-7a03-bde4-7660c09931f2"
    And the file contains at least one user or assistant "response_item"
    When Codex session discovery runs
    Then a session should be returned with id "019da64f-874c-7a03-bde4-7660c09931f2"
    And the session should have assistant "codex"
    And the session path should point to the JSONL file

  Scenario: Read project metadata from session_meta
    Given a Codex session_meta payload contains cwd "/Users/rchaves/Projects/kanban"
    And git.branch "feature/codex"
    When the session is discovered
    Then projectPath should be "/Users/rchaves/Projects/kanban"
    And gitBranch should be "feature/codex"

  Scenario: Use Codex session_index thread names
    Given "~/.codex/session_index.jsonl" contains:
      | id                                      | thread_name          |
      | 019da64f-874c-7a03-bde4-7660c09931f2   | Fix login with Codex |
    When the matching session is discovered
    Then the session name should be "Fix login with Codex"

  Scenario: Ignore empty interactive launches
    Given a Codex JSONL file contains only "session_meta"
    When Codex session discovery runs
    Then that file should not produce a board card

  Scenario: Discover old flat session files
    Given a Codex JSONL file exists directly under "~/.codex/sessions"
    When Codex session discovery runs
    Then it should be included with nested session files
