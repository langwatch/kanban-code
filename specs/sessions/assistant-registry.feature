Feature: Coding Assistant Registry
  As the Kanban Code system
  I want a registry that maps assistants to their adapters
  So that the correct adapter is used for each operation

  Background:
    Given the Kanban Code application is running

  # ── Registration ──

  Scenario: Register Claude adapters
    When Claude adapters are registered
    Then registry.discovery(for: .claude) should return ClaudeCodeSessionDiscovery
    And registry.detector(for: .claude) should return ClaudeCodeActivityDetector
    And registry.store(for: .claude) should return ClaudeCodeSessionStore

  Scenario: Register Gemini adapters
    When Gemini adapters are registered
    Then registry.discovery(for: .gemini) should return GeminiSessionDiscovery
    And registry.detector(for: .gemini) should return GeminiActivityDetector
    And registry.store(for: .gemini) should return GeminiSessionStore

  Scenario: Register Codex adapters
    When Codex adapters are registered
    Then registry.discovery(for: .codex) should return CodexSessionDiscovery
    And registry.detector(for: .codex) should return CodexActivityDetector
    And registry.store(for: .codex) should return CodexSessionStore

  Scenario: Only installed assistants are registered
    Given Gemini CLI is not installed
    Then registry.available should only contain [.claude]
    And registry.discovery(for: .gemini) should return nil

  Scenario: All assistants registered
    Given Claude, Gemini, and Codex are installed
    Then registry.available should contain [.claude, .gemini, .codex]

  # ── Composite Discovery ──

  Scenario: Composite discovery merges all sources
    Given Claude discovery finds sessions [A, B, C]
    And Gemini discovery finds sessions [D, E]
    And Codex discovery finds sessions [F]
    When composite discovery runs
    Then it should return [A, B, C, D, E, F] sorted by modification time

  Scenario: Composite discovery handles one source failing
    Given Claude discovery succeeds with sessions [A, B]
    And Gemini discovery throws an error
    When composite discovery runs
    Then it should still return [A, B] from Claude
    And log the Gemini error

  Scenario: Composite discovery with no registered assistants
    Given no assistants are registered
    When composite discovery runs
    Then it should return an empty list

  # ── Composite Activity Detector ──

  Scenario: Route hook event to Claude detector
    Given a HookEvent with sessionId matching a "claude" session
    When the composite detector handles it
    Then ClaudeCodeActivityDetector.handleHookEvent should be called

  Scenario: Route poll to correct detectors
    Given session paths include Claude, Gemini, and Codex sessions
    When composite detector polls activity
    Then each session's path should be polled by its assistant's detector

  Scenario: Unknown assistant session is skipped
    Given a session path that matches no registered assistant
    When the composite detector polls
    Then that session should be skipped (not crash)

  # ── Store Resolution ──

  Scenario: Read transcript uses correct store
    Given a card with assistant "gemini" and a session path
    When readTranscript is called
    Then GeminiSessionStore.readTranscript should handle it

  Scenario: Read Codex transcript uses Codex store
    Given a card with assistant "codex" and a session path
    When readTranscript is called
    Then CodexSessionStore.readTranscript should handle it

  Scenario: Search sessions uses all stores
    Given Claude, Gemini, and Codex stores are registered
    When searchSessions is called
    Then all stores should be searched
    And results should be merged and sorted by score
