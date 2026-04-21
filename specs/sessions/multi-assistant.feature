Feature: Multi-Coding-Assistant Support
  As a developer using multiple AI coding assistants (Claude Code, Gemini CLI, Codex CLI)
  I want Kanban Code to manage sessions from any supported assistant
  So that I can use whichever tool fits each task

  Background:
    Given the Kanban Code application is running

  # ── CodingAssistant Enum ──

  Scenario: Known coding assistants
    Then the following coding assistants should be supported:
      | ID      | Display Name  | CLI Command | Config Dir |
      | claude  | Claude Code   | claude      | .claude    |
      | gemini  | Gemini CLI    | gemini      | .gemini    |
      | codex   | Codex CLI     | codex       | .codex     |

  Scenario: Assistant capabilities
    Then each assistant should declare its capabilities:
      | Assistant | Worktree Support | Image Upload | Hooks Support | Auto-Approve Flag                         | Resume Flag |
      | claude    | true             | true         | true          | --dangerously-skip-permissions            | --resume    |
      | gemini    | false            | false        | true          | --yolo                                    | --resume    |
      | codex     | false            | false        | false         | --dangerously-bypass-approvals-and-sandbox | resume      |

  Scenario: Assistant prompt characters
    Then each assistant should have a known prompt character for ready detection:
      | Assistant | Prompt Character |
      | claude    | ❯                |
      | gemini    | Type your message |
      | codex     | ›                |

  # ── Card Assistant Identity ──

  Scenario: Cards store their assistant type
    Given a card is created with assistant "gemini"
    Then the card's Link should have assistant field set to "gemini"

  Scenario: Backward compatibility for cards without assistant
    Given an existing card JSON has no "assistant" field
    When it is decoded
    Then its effectiveAssistant should default to "claude"

  Scenario: Cards persist assistant through JSON round-trip
    Given a card with assistant "gemini" is saved to links.json
    When links.json is loaded
    Then the card's assistant should be "gemini"

  Scenario: Codex cards persist assistant through JSON round-trip
    Given a card with assistant "codex" is saved to links.json
    When links.json is loaded
    Then the card's assistant should be "codex"

  # ── Session Discovery Tags ──

  Scenario: Discovered Claude sessions are tagged
    Given sessions exist under ~/.claude/projects/
    When the composite discovery runs
    Then those sessions should have assistant = "claude"

  Scenario: Discovered Gemini sessions are tagged
    Given sessions exist under ~/.gemini/tmp/<project>/chats/
    When the composite discovery runs
    Then those sessions should have assistant = "gemini"

  Scenario: Discovered Codex sessions are tagged
    Given sessions exist under ~/.codex/sessions/
    When the composite discovery runs
    Then those sessions should have assistant = "codex"

  Scenario: Composite discovery merges all sources
    Given 3 Claude sessions and 2 Gemini sessions and 1 Codex session exist
    When the composite discovery runs
    Then all 6 sessions should be returned
    And they should be sorted by modification time (newest first)

  # ── Settings ──

  Scenario: Global default assistant setting
    Given the user sets defaultAssistant to "gemini" in settings
    When creating a new task
    Then the assistant picker should default to "gemini"

  Scenario: Default assistant backward compatibility
    Given settings.json has no "defaultAssistant" field
    When settings are loaded
    Then defaultAssistant should be nil (defaulting to claude)
