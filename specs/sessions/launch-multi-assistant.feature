Feature: Launch Sessions with Multiple Assistants
  As a developer choosing between coding assistants
  I want to launch tasks with my preferred assistant
  So that each task uses the right tool

  Background:
    Given the Kanban Code application is running
    And Claude Code, Gemini CLI, and Mastra Code are installed

  # ── Launch Command Construction ──

  @unit
  Scenario: Launch Claude Code session
    Given I create a task with assistant "claude"
    And project path "/Users/rchaves/Projects/remote/kanban"
    And skipPermissions is true
    When the launch command is built
    Then the command should be "claude --dangerously-skip-permissions"

  @unit
  Scenario: Launch Gemini CLI session
    Given I create a task with assistant "gemini"
    And project path "/Users/rchaves/Projects/remote/kanban"
    And skipPermissions is true
    When the launch command is built
    Then the command should be "gemini --yolo"

  @unit
  Scenario: Launch Mastracode session
    Given I create a task with assistant "mastracode"
    And project path "/Users/rchaves/Projects/remote/kanban"
    And skipPermissions is true
    When the launch command is built
    Then the command should be "mastracode /yolo"

  @unit
  Scenario: Launch Claude with worktree
    Given I create a task with assistant "claude"
    And worktreeName is "feature-x"
    When the launch command is built
    Then the command should include "--worktree feature-x"

  @unit
  Scenario: Launch Gemini ignores worktree (not supported)
    Given I create a task with assistant "gemini"
    And worktreeName is "feature-x"
    When the launch command is built
    Then the command should NOT include "--worktree"

  @unit
  Scenario: Launch Mastracode ignores worktree (not supported)
    Given I create a task with assistant "mastracode"
    And worktreeName is "feature-x"
    When the launch command is built
    Then the command should NOT include "--worktree"

  @unit
  Scenario: Custom command override bypasses assistant logic
    Given a commandOverride of "aider --model gpt-4"
    When the launch command is built
    Then the command should be "aider --model gpt-4" regardless of assistant

  # ── Tmux Session Naming ──

  @unit
  Scenario: Claude tmux session name for new launch
    Given assistant is "claude" and cardId is "card_abc123"
    And projectPath is "/Users/rchaves/Projects/remote/kanban"
    When a new session is launched
    Then the tmux session name should be "kanban-card_abc123"

  @unit
  Scenario: Claude tmux session name for resume
    Given assistant is "claude" and sessionId is "abcdef12-3456-7890"
    When the session is resumed
    Then the tmux session name should be "claude-abcdef12"

  @unit
  Scenario: Gemini tmux session name for resume
    Given assistant is "gemini" and sessionId is "1250be89-48ad-4418"
    When the session is resumed
    Then the tmux session name should be "gemini-1250be89"

  @unit
  Scenario: Mastracode tmux session name for resume
    Given assistant is "mastracode" and sessionId is "thread_abc123"
    When the session is resumed
    Then the tmux session name should be "mastracode-thread_a"

  # ── Resume Command ──

  @unit
  Scenario: Resume Claude session
    Given a card with assistant "claude" and sessionId "abcdef12-3456-7890"
    When resume is triggered
    Then the command should be "claude --resume abcdef12-3456-7890"

  @unit
  Scenario: Resume Gemini session by UUID
    Given a card with assistant "gemini" and sessionId "1250be89-48ad-4418-bec4-1f40afead50e"
    When resume is triggered
    Then the command should be "gemini --resume 1250be89-48ad-4418-bec4-1f40afead50e"

  @unit
  Scenario: Resume Mastracode session
    Given a card with assistant "mastracode" and sessionId "thread_abc123"
    When resume is triggered
    Then the command should be "mastracode"
    And it should NOT include "--resume"

  @unit
  Scenario: Resume with skipPermissions for Claude
    Given a card with assistant "claude" and skipPermissions is true
    When resume is triggered
    Then the command should include "--dangerously-skip-permissions"

  @unit
  Scenario: Resume with skipPermissions for Gemini
    Given a card with assistant "gemini" and skipPermissions is true
    When resume is triggered
    Then the command should include "--yolo"

  @unit
  Scenario: Resume with skipPermissions for Mastracode
    Given a card with assistant "mastracode" and skipPermissions is true
    When resume is triggered
    Then the command should include "/yolo"

  # ── Ready Detection ──

  @unit
  Scenario: Detect Claude is ready in tmux pane
    Given the tmux pane output contains "❯"
    When checking if assistant "claude" is ready
    Then isReady should return true

  @unit
  Scenario: Detect Gemini is ready in tmux pane
    Given the tmux pane output contains "Type your message"
    When checking if assistant "gemini" is ready
    Then isReady should return true

  @unit
  Scenario: Detect Mastracode is ready in tmux pane
    Given the tmux pane output contains the configured prompt string for assistant "mastracode"
    When checking if assistant "mastracode" is ready
    Then isReady should return true

  @unit
  Scenario: Claude prompt character does not trigger Gemini ready
    Given the tmux pane output contains "❯" but NOT "Type your message"
    When checking if assistant "gemini" is ready
    Then isReady should return false

  @unit
  Scenario: Gemini prompt character does not trigger Claude ready
    Given the tmux pane output contains "Type your message" but NOT "❯"
    When checking if assistant "claude" is ready
    Then isReady should return false

  # ── Image Sending ──

  @integration
  Scenario: Images are sent for Claude sessions
    Given a card with assistant "claude"
    And 2 images are attached
    When the session is launched
    Then images should be sent via bracketed paste after Claude is ready

  @integration
  Scenario: Images are NOT sent for Gemini sessions
    Given a card with assistant "gemini"
    And 2 images are attached
    When the session is launched
    Then images should NOT be sent (supportsImageUpload = false)
    And the text prompt should still be sent

  @integration
  Scenario: Images are NOT sent for Mastracode sessions
    Given a card with assistant "mastracode"
    And 2 images are attached
    When the session is launched
    Then images should NOT be sent (supportsImageUpload = false)
    And the text prompt should still be sent

  # ── Environment Variables ──

  @unit
  Scenario: KANBAN_CODE_* env vars are set for all assistants
    Given any assistant is being launched
    When the launch command includes extraEnv
    Then KANBAN_CODE_CARD_ID and KANBAN_CODE_SESSION_ID should be set

  @unit
  Scenario: SHELL override works for all assistants
    Given shellOverride is "/bin/zsh"
    When any assistant is launched
    Then "SHELL=/bin/zsh" should be prepended to the command
