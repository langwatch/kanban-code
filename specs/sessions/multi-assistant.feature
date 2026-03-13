Feature: Multi-Coding-Assistant Support
  As a developer using multiple AI coding assistants
  I want Kanban Code to manage sessions from any supported assistant
  So that I can use whichever tool fits each task

  Background:
    Given the Kanban Code application is running

  # ── CodingAssistant Enum ──

  @unit
  Scenario: Known coding assistants
    Then the following coding assistants should be supported:
      | ID          | Display Name  | CLI Command | Session Storage                          |
      | claude      | Claude Code   | claude      | ~/.claude/projects                       |
      | gemini      | Gemini CLI    | gemini      | ~/.gemini/tmp                            |
      | mastracode  | Mastra Code   | mastracode  | ~/Library/Application Support/mastracode |

  @unit
  Scenario: Assistant capabilities
    Then each assistant should declare its capabilities:
      | Assistant   | Worktree Support | Image Upload | Auto-Approve Flag              | Resume Flag    |
      | claude      | true             | true         | --dangerously-skip-permissions | --resume       |
      | gemini      | false            | false        | --yolo                         | --resume       |
      | mastracode  | false            | false        | /yolo                          | project-scoped |

  @unit
  Scenario: Assistant prompt characters
    Then each assistant should have a known prompt character for ready detection:
      | Assistant | Prompt Character  |
      | claude    | ❯                 |
      | gemini    | Type your message |

  @unit
  Scenario: Mastracode prompt markers are configured
    Then assistant "mastracode" should have a non-empty promptCharacter
    And assistant "mastracode" should have a non-empty historyPromptSymbol

  # ── Card Assistant Identity ──

  @unit
  Scenario: Cards store their assistant type
    Given a card is created with assistant "mastracode"
    Then the card's Link should have assistant field set to "mastracode"

  @unit
  Scenario: Backward compatibility for cards without assistant
    Given an existing card JSON has no "assistant" field
    When it is decoded
    Then its effectiveAssistant should default to "claude"

  @integration
  Scenario: Cards persist assistant through JSON round-trip
    Given a card with assistant "mastracode" is saved to links.json
    When links.json is loaded
    Then the card's assistant should be "mastracode"

  # ── Session Discovery Tags ──

  @integration
  Scenario: Discovered Claude sessions are tagged
    Given sessions exist under ~/.claude/projects/
    When the composite discovery runs
    Then those sessions should have assistant = "claude"

  @integration
  Scenario: Discovered Gemini sessions are tagged
    Given sessions exist under ~/.gemini/tmp/<project>/chats/
    When the composite discovery runs
    Then those sessions should have assistant = "gemini"

  @integration
  Scenario: Discovered Mastracode sessions are tagged
    Given sessions exist in the Mastracode database for the current project
    When the composite discovery runs
    Then those sessions should have assistant = "mastracode"

  @integration
  Scenario: Composite discovery preserves all assistant identities
    Given 3 Claude sessions, 2 Gemini sessions, and 1 Mastracode session exist
    When the composite discovery runs
    Then all 6 sessions should be returned
    And they should be sorted by modification time (newest first)

  # ── Settings ──

  @integration
  Scenario: Global default assistant setting persists Mastracode
    Given the user sets defaultAssistant to "mastracode" in settings
    When settings are saved and reloaded
    Then defaultAssistant should be "mastracode"

  @unit
  Scenario: Default assistant backward compatibility
    Given settings.json has no "defaultAssistant" field
    When settings are loaded
    Then defaultAssistant should be nil (defaulting to claude)
