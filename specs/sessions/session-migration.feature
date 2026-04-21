Feature: Session Migration Between Assistants
  As a developer who started a task in one assistant
  I want to migrate the conversation to another assistant
  So that I can continue work with a different tool

  Background:
    Given the Kanban Code application is running

  # ── Export ──

  Scenario: Export Claude session as text
    Given a card with assistant "claude" and a session with 10 turns
    When "Migrate to Gemini CLI" is triggered
    Then the conversation should be exported as plain text
    And user messages should be prefixed with "User:"
    And assistant messages should be prefixed with "Assistant:"

  Scenario: Tool calls are summarized as text
    Given a Claude session turn contains a tool_use block for "Edit" with file "src/main.ts"
    When exported as text
    Then the tool call should appear as a text summary like "[Tool: Edit src/main.ts]"
    And the raw tool JSON should NOT be included
    # Tool call JSON structures differ between assistants and could break parsing

  Scenario: Thinking blocks are included as text
    Given a Claude session turn contains a thinking block
    When exported as text
    Then the thinking text should be included (prefixed with "Thinking:")

  # ── Import ──

  Scenario: Create Gemini session from exported text
    Given an exported conversation text from a Claude session
    When importing into Gemini format
    Then a new JSON session file should be created at ~/.gemini/tmp/<project>/chats/
    And it should contain user messages with content: [{"text": "..."}]
    And assistant text should be stored as gemini message content strings

  Scenario: Create Claude session from exported Gemini text
    Given an exported conversation text from a Gemini session
    When importing into Claude format
    Then a new .jsonl file should be created in ~/.claude/projects/<encoded>/
    And each line should be a valid JSON object with Claude's schema

  Scenario: Create Codex session from exported assistant text
    Given exported conversation turns from a Claude or Gemini session
    When importing into Codex format
    Then a new JSONL file should be created under ~/.codex/sessions/YYYY/MM/DD/
    And the first line should be a "session_meta" record with the new session id
    And user messages should be stored as "response_item" messages with "input_text"
    And assistant messages should be stored as "response_item" messages with "output_text"

  # ── Card Update ──

  Scenario: Card is updated after migration
    Given a card with assistant "claude" is migrated to "gemini"
    Then the card's assistant should change to "gemini"
    And a new sessionLink should point to the new Gemini session file
    And the old Claude sessionLink should be removed

  Scenario: Card is updated after migration to Codex
    Given a card with assistant "gemini" is migrated to "codex"
    Then the card's assistant should change to "codex"
    And a new sessionLink should point to the new Codex JSONL session file
    And the old Gemini sessionLink should be removed

  Scenario: Card retains other links after migration
    Given a card with a worktreeLink and prLinks
    When the session is migrated to another assistant
    Then worktreeLink and prLinks should be preserved unchanged

  # ── Warnings ──

  Scenario: Migration shows loss warning
    Given a card with a Claude session containing tool calls
    When "Migrate to Gemini CLI" is clicked
    Then a confirmation dialog should appear
    And it should warn that tool calls will be converted to text summaries
    And it should warn that the migration cannot be undone

  Scenario: Migration of session with images warns about image loss
    Given a Claude session contains image attachments
    When migrating to Gemini
    Then the warning should mention that images will not be transferred

  # ── Edge Cases ──

  Scenario: Migration of empty session
    Given a card with a session containing 0 turns
    When migration is attempted
    Then it should show "Nothing to migrate" and not proceed

  Scenario: Migration when target assistant is not installed
    Given a card with assistant "claude"
    And Gemini CLI is not installed
    When "Migrate to Gemini CLI" is shown
    Then the button should be disabled with tooltip "Gemini CLI not installed"

  # ── Copy as Text Alternative ──

  Scenario: Copy conversation as text to clipboard
    Given a card with a session
    When "Copy conversation as text" is clicked
    Then the full exported text should be placed on the clipboard
    And a confirmation toast should appear
