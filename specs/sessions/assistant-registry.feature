Feature: Coding Assistant Registry
  As the Kanban Code system
  I want a registry that maps assistants to their adapters
  So that the correct adapter is used for each operation

  Background:
    Given the Kanban Code application is running

  # ── Registration ──

  @unit
  Scenario: Register Claude adapters
    When Claude adapters are registered
    Then registry.discovery(for: .claude) should return ClaudeCodeSessionDiscovery
    And registry.detector(for: .claude) should return ClaudeCodeActivityDetector
    And registry.store(for: .claude) should return ClaudeCodeSessionStore

  @unit
  Scenario: Register Gemini adapters
    When Gemini adapters are registered
    Then registry.discovery(for: .gemini) should return GeminiSessionDiscovery
    And registry.detector(for: .gemini) should return GeminiActivityDetector
    And registry.store(for: .gemini) should return GeminiSessionStore

  @unit
  Scenario: Register Mastracode adapters
    When Mastracode adapters are registered
    Then registry.discovery(for: .mastracode) should return MastracodeSessionDiscovery
    And registry.detector(for: .mastracode) should return MastracodeActivityDetector
    And registry.store(for: .mastracode) should return MastracodeSessionStore

  @unit
  Scenario: Only installed assistants are registered
    Given Gemini CLI and Mastra Code are not installed
    Then registry.available should only contain [.claude]
    And registry.discovery(for: .gemini) should return nil
    And registry.discovery(for: .mastracode) should return nil

  @unit
  Scenario: All installed assistants are registered
    Given Claude Code, Gemini CLI, and Mastra Code are installed
    Then registry.available should contain [.claude, .gemini, .mastracode]

  # ── Composite Discovery ──

  @integration
  Scenario: Composite discovery merges all registered sources
    Given Claude discovery finds sessions [A, B, C]
    And Gemini discovery finds sessions [D, E]
    And Mastracode discovery finds sessions [F]
    When composite discovery runs
    Then it should return [A, B, C, D, E, F] sorted by modification time

  @integration
  Scenario: Composite discovery handles one source failing
    Given Claude discovery succeeds with sessions [A, B]
    And Mastracode discovery throws an error
    When composite discovery runs
    Then it should still return [A, B] from Claude
    And log the Mastracode error

  @unit
  Scenario: Composite discovery with no registered assistants
    Given no assistants are registered
    When composite discovery runs
    Then it should return an empty list

  # ── Composite Activity Detector ──

  @unit
  Scenario: Route hook event to Claude detector
    Given a HookEvent with sessionId matching a "claude" session
    When the composite detector handles it
    Then ClaudeCodeActivityDetector.handleHookEvent should be called

  @integration
  Scenario: Route poll to correct detectors
    Given session paths include Claude, Gemini, and Mastracode sessions
    When the composite detector polls activity
    Then each session's path should be polled by its assistant's detector

  @unit
  Scenario: Unknown assistant session is skipped
    Given a session path that matches no registered assistant
    When the composite detector polls
    Then that session should be skipped (not crash)

  # ── Store Resolution ──

  @unit
  Scenario: Read transcript uses correct store
    Given a card with assistant "mastracode" and a session path
    When readTranscript is called
    Then MastracodeSessionStore.readTranscript should handle it

  @integration
  Scenario: Search sessions uses all stores
    Given Claude, Gemini, and Mastracode stores are registered
    When searchSessions is called
    Then all registered stores should be searched
    And results should be merged and sorted by score
