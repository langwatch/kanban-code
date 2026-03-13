Feature: Mastracode Session Transcript Reading
  As a developer viewing Mastracode session history
  I want to read Mastracode session transcripts in the history view
  So that I can review the actions taken by Mastracode

  Background:
    Given the Kanban Code application is running
    And a Mastracode thread exists in the LibSQL database

  # ── Message Type Mapping ──

  @unit
  Scenario: User messages are mapped correctly
    Given a row in the messages table with role "user" and content "analyze this file"
    When the transcript is read
    Then a ConversationTurn with role "user" and text "analyze this file" should be produced

  @unit
  Scenario: Assistant messages are mapped correctly
    Given a row in the messages table with role "assistant" and content "I found the issue."
    When the transcript is read
    Then a ConversationTurn with role "assistant" and text "I found the issue." should be produced

  # ── Tool Calls ──

  @unit
  Scenario: Tool calls are parsed from JSON strings in the database
    Given a message row contains a tool call block:
      """
      [{"type": "tool_call", "name": "grep_search", "args": {"pattern": "auth"}}]
      """
    When the transcript is read
    Then the ConversationTurn should include a toolUse content block for "grep_search"

  @unit
  Scenario: Tool results are mapped to the corresponding tool calls
    Given a subsequent message row contains a tool result block for "grep_search"
    When the transcript is read
    Then the result should be appended to the previous toolUse content block

  # ── Fork Session ──

  @integration
  Scenario: Forking a Mastracode session duplicates rows in LibSQL
    Given a Mastracode thread "thread_A" with 5 messages
    When the session is forked to a new card "card_B"
    Then a new thread ID should be generated
    And the 5 messages should be duplicated in the database under the new thread ID
    And the new thread should be mapped to the current project

  # ── Search Sessions ──

  @integration
  Scenario: Search within Mastracode sessions via SQLite full-text query
    Given the database contains a message with text "React context bug"
    When searching for "context"
    Then the session containing that text should be returned with snippets
