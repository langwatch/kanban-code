Feature: Read Codex CLI Transcripts
  As a developer reviewing a Codex session
  I want Kanban Code to parse Codex JSONL transcript records
  So that chat history, search, checkpoint, and migration workflows work

  Background:
    Given a Codex JSONL transcript exists

  Scenario: Parse user and assistant messages
    Given the transcript contains "response_item" message payloads
    And a user message has content type "input_text"
    And an assistant message has content type "output_text"
    When CodexSessionStore.readTranscript reads the file
    Then it should return user and assistant ConversationTurn records
    And text previews should use the message text

  Scenario: Parse reasoning summaries
    Given the transcript contains a "response_item" with payload.type "reasoning"
    And the reasoning payload has a "summary" text block
    When the transcript is read
    Then the reasoning should be rendered as a thinking content block
    And consecutive assistant content should be merged into one assistant turn

  Scenario: Parse function calls and outputs
    Given the transcript contains a "function_call" response item
    And the function_call has call_id "call-1", name "exec_command", and JSON arguments
    And a later "function_call_output" has call_id "call-1"
    When the transcript is read
    Then the assistant turn should include a toolUse block named "exec_command"
    And the assistant turn should include a toolResult block linked to "call-1"

  Scenario: Checkpoint truncates at a Codex turn line
    Given a Codex transcript has 5 JSONL records
    And the selected ConversationTurn has lineNumber 3
    When checkpoint restore is confirmed
    Then Kanban should back up the original file with ".bkp"
    And rewrite the transcript with only the first 3 JSONL records

  Scenario: Search indexes Codex text and tool output
    Given Codex session files contain text matching "login validation"
    When deep search runs for "login validation"
    Then CodexSessionStore should return matching SearchResult entries
    And snippets should be labelled "You" for user turns or "Codex" for assistant turns

  Scenario: Migrate to Codex format
    Given conversation turns from Claude or Gemini are migrated to Codex
    When CodexSessionStore.writeSession is called
    Then a native Codex JSONL file should be written under "~/.codex/sessions/YYYY/MM/DD"
    And a "session_meta" line should contain the new Codex session id
    And "~/.codex/session_index.jsonl" should receive a thread_name entry
