Feature: Card Lifecycle with Multiple Assistants
  As a developer using multiple coding assistants
  I want cards to work the same regardless of assistant
  So that my board workflow is consistent

  Background:
    Given the Kanban Code application is running

  # ── Card Creation ──

  Scenario: Create task with Claude stores assistant on card
    Given I create a new task and select assistant "claude"
    When the card is created
    Then card.assistant should be "claude"
    And card.effectiveAssistant should be "claude"

  Scenario: Create task with Gemini stores assistant on card
    Given I create a new task and select assistant "gemini"
    When the card is created
    Then card.assistant should be "gemini"

  Scenario: Create task with Codex stores assistant on card
    Given I create a new task and select assistant "codex"
    When the card is created
    Then card.assistant should be "codex"

  Scenario: Discovered Claude session creates card with assistant
    Given a new Claude session is discovered during reconciliation
    When a card is created for it
    Then card.assistant should be "claude"

  Scenario: Discovered Gemini session creates card with assistant
    Given a new Gemini session is discovered during reconciliation
    When a card is created for it
    Then card.assistant should be "gemini"

  Scenario: Discovered Codex session creates card with assistant
    Given a new Codex session is discovered during reconciliation
    When a card is created for it
    Then card.assistant should be "codex"

  # ── Column Movement ──

  Scenario: Gemini card moves to In Progress on launch
    Given a Gemini card in Backlog
    When it is launched
    Then it should move to In Progress

  Scenario: Gemini card moves to Waiting when idle
    Given a Gemini card in In Progress
    And the Gemini session file hasn't been modified for 5 minutes
    When activity polling runs
    Then the card should move to Waiting

  Scenario: Codex card moves to Waiting when idle
    Given a Codex card in In Progress
    And the Codex session file hasn't been modified for 5 minutes
    When activity polling runs
    Then the card should move to Waiting

  Scenario: Column movement rules are assistant-agnostic
    Then the same column transition rules should apply to Claude, Gemini, and Codex cards

  # ── Reconciliation ──

  Scenario: Reconciler matches Gemini session to existing card
    Given a card with assistant "gemini" and sessionId "abc-123"
    And Gemini discovery finds a session with id "abc-123"
    When reconciliation runs
    Then the session should be matched to the existing card
    And no duplicate card should be created

  Scenario: Reconciler matches Codex session to existing card
    Given a card with assistant "codex" and sessionId "019da64f-874c-7a03-bde4-7660c09931f2"
    And Codex discovery finds a session with id "019da64f-874c-7a03-bde4-7660c09931f2"
    When reconciliation runs
    Then the session should be matched to the existing card
    And no duplicate card should be created

  Scenario: Assistant sessions with same project don't conflict
    Given a Claude session for project "/Users/rchaves/Projects/kanban"
    And a Gemini session for the same project
    And a Codex session for the same project
    When reconciliation runs
    Then each should get its own card
    And they should NOT be merged

  # ── Persist and Load ──

  Scenario: Card with assistant survives app restart
    Given a card with assistant "gemini" is saved to links.json
    When the app restarts and loads links.json
    Then the card should have assistant "gemini"

  Scenario: Codex card survives app restart
    Given a card with assistant "codex" is saved to links.json
    When the app restarts and loads links.json
    Then the card should have assistant "codex"

  Scenario: Legacy card without assistant field loads as claude
    Given links.json contains a card without "assistant" key
    When loaded
    Then card.assistant should be nil
    And card.effectiveAssistant should be "claude"

  # ── Queued Prompts ──

  Scenario: Queued prompt sent to Gemini session
    Given a Gemini card with a queued prompt "fix the tests"
    And the Gemini session is in Waiting state
    When the queued prompt is auto-sent
    Then it should be sent via tmux bracketed paste to the Gemini session

  Scenario: Queued prompt sent to Codex session
    Given a Codex card with a queued prompt "fix the tests"
    And the Codex session is in Waiting state
    When the queued prompt is auto-sent
    Then it should be sent via tmux bracketed paste to the Codex session

  Scenario: Queued prompt with images on Gemini card
    Given a Gemini card with a queued prompt and attached images
    When the prompt is auto-sent
    Then images should be skipped (Gemini doesn't support image upload)
    And the text prompt should still be sent

  Scenario: Queued prompt with images on Codex card
    Given a Codex card with a queued prompt and attached images
    When the prompt is auto-sent
    Then images should be skipped (Codex doesn't support image upload)
    And the text prompt should still be sent

  # ── Kill on Quit ──

  Scenario: All assistant sessions are killed on quit
    Given cards with Claude, Gemini, and Codex tmux sessions
    When the app quits
    Then all tmux sessions should be killed regardless of assistant type
