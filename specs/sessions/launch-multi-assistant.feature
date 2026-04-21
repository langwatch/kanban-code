Feature: Launch Sessions with Multiple Assistants
  As a developer choosing between Claude Code, Gemini CLI, and Codex CLI
  I want to launch tasks with my preferred assistant
  So that each task uses the right tool

  Background:
    Given the Kanban Code application is running
    And Claude Code, Gemini CLI, and Codex CLI are installed

  # ── Launch Command Construction ──

  Scenario: Launch Claude Code session
    Given I create a task with assistant "claude"
    And project path "/Users/rchaves/Projects/remote/kanban"
    And skipPermissions is true
    When the launch command is built
    Then the command should be "claude --dangerously-skip-permissions"

  Scenario: Launch Gemini CLI session
    Given I create a task with assistant "gemini"
    And project path "/Users/rchaves/Projects/remote/kanban"
    And skipPermissions is true
    When the launch command is built
    Then the command should be "gemini --yolo"

  Scenario: Launch Codex CLI session
    Given I create a task with assistant "codex"
    And project path "/Users/rchaves/Projects/remote/kanban"
    And skipPermissions is true
    When the launch command is built
    Then the command should be "codex --dangerously-bypass-approvals-and-sandbox --no-alt-screen"

  Scenario: Launch Claude with worktree
    Given I create a task with assistant "claude"
    And worktreeName is "feature-x"
    When the launch command is built
    Then the command should include "--worktree feature-x"

  Scenario: Launch Gemini ignores worktree (not supported)
    Given I create a task with assistant "gemini"
    And worktreeName is "feature-x"
    When the launch command is built
    Then the command should NOT include "--worktree"
    # Gemini CLI does not support worktrees

  Scenario: Launch Codex ignores worktree (not supported)
    Given I create a task with assistant "codex"
    And worktreeName is "feature-x"
    When the launch command is built
    Then the command should NOT include "--worktree"
    # Codex CLI does not support Kanban-managed worktrees

  Scenario: Custom command override bypasses assistant logic
    Given a commandOverride of "aider --model gpt-4"
    When the launch command is built
    Then the command should be "aider --model gpt-4" regardless of assistant

  # ── Tmux Session Naming ──

  Scenario: Claude tmux session name for new launch
    Given assistant is "claude" and cardId is "card_abc123"
    And projectPath is "/Users/rchaves/Projects/remote/kanban"
    When a new session is launched
    Then the tmux session name should be "kanban-card_abc123"

  Scenario: Claude tmux session name for resume
    Given assistant is "claude" and sessionId is "abcdef12-3456-7890"
    When the session is resumed
    Then the tmux session name should be "claude-abcdef12"

  Scenario: Gemini tmux session name for resume
    Given assistant is "gemini" and sessionId is "1250be89-48ad-4418"
    When the session is resumed
    Then the tmux session name should be "gemini-1250be89"

  Scenario: Codex tmux session name for resume
    Given assistant is "codex" and sessionId is "019da64f-874c-7a03-bde4-7660c09931f2"
    When the session is resumed
    Then the tmux session name should be "codex-019da64f"

  # ── Resume Command ──

  Scenario: Resume Claude session
    Given a card with assistant "claude" and sessionId "abcdef12-3456-7890"
    When resume is triggered
    Then the command should be "claude --resume abcdef12-3456-7890"

  Scenario: Resume Gemini session by UUID
    Given a card with assistant "gemini" and sessionId "1250be89-48ad-4418-bec4-1f40afead50e"
    When resume is triggered
    Then the command should be "gemini --resume 1250be89-48ad-4418-bec4-1f40afead50e"

  Scenario: Resume Codex session by UUID
    Given a card with assistant "codex" and sessionId "019da64f-874c-7a03-bde4-7660c09931f2"
    When resume is triggered
    Then the command should be "codex resume --no-alt-screen 019da64f-874c-7a03-bde4-7660c09931f2"

  Scenario: Resume with skipPermissions for Claude
    Given a card with assistant "claude" and skipPermissions is true
    When resume is triggered
    Then the command should include "--dangerously-skip-permissions"

  Scenario: Resume with skipPermissions for Gemini
    Given a card with assistant "gemini" and skipPermissions is true
    When resume is triggered
    Then the command should include "--yolo"

  Scenario: Resume with skipPermissions for Codex
    Given a card with assistant "codex" and skipPermissions is true
    When resume is triggered
    Then the command should include "--dangerously-bypass-approvals-and-sandbox"

  # ── Ready Detection ──

  Scenario: Detect Claude is ready in tmux pane
    Given the tmux pane output contains "❯"
    When checking if assistant "claude" is ready
    Then isReady should return true

  Scenario: Detect Gemini is ready in tmux pane
    Given the tmux pane output contains "Type your message"
    When checking if assistant "gemini" is ready
    Then isReady should return true

  Scenario: Detect Codex is ready in tmux pane
    Given the tmux pane output contains "›"
    When checking if assistant "codex" is ready
    Then isReady should return true

  Scenario: Claude prompt character does not trigger Gemini ready
    Given the tmux pane output contains "❯" but NOT "Type your message"
    When checking if assistant "gemini" is ready
    Then isReady should return false

  Scenario: Gemini prompt character does not trigger Claude ready
    Given the tmux pane output contains "Type your message" but NOT "❯"
    When checking if assistant "claude" is ready
    Then isReady should return false

  Scenario: Codex prompt character does not trigger Claude ready
    Given the tmux pane output contains "›" but NOT "❯"
    When checking if assistant "claude" is ready
    Then isReady should return false

  # ── Image Sending ──

  Scenario: Images are sent for Claude sessions
    Given a card with assistant "claude"
    And 2 images are attached
    When the session is launched
    Then images should be sent via bracketed paste after Claude is ready

  Scenario: Images are NOT sent for Gemini sessions
    Given a card with assistant "gemini"
    And 2 images are attached
    When the session is launched
    Then images should NOT be sent (supportsImageUpload = false)
    And the text prompt should still be sent

  Scenario: Images are NOT sent for Codex sessions
    Given a card with assistant "codex"
    And 2 images are attached
    When the session is launched
    Then images should NOT be sent (supportsImageUpload = false)
    And the text prompt should still be sent

  # ── Environment Variables ──

  Scenario: KANBAN_CODE_* env vars are set for all assistants
    Given any assistant is being launched
    When the launch command includes extraEnv
    Then KANBAN_CODE_CARD_ID and KANBAN_CODE_SESSION_ID should be set
    # These are assistant-agnostic

  Scenario: SHELL override works for all assistants
    Given shellOverride is "/bin/zsh"
    When any assistant is launched
    Then "SHELL=/bin/zsh" should be prepended to the command
