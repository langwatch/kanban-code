Feature: Launch and Resume Codex CLI Sessions
  As a developer using Codex CLI
  I want to launch and resume Codex sessions from the Kanban board
  So that Codex can be managed alongside Claude and Gemini

  Background:
    Given the Kanban Code application is running
    And Codex CLI is installed

  # ── Launch ──

  Scenario: Launch Codex with auto-approve
    Given I create a task with assistant "codex" and skipPermissions true
    When the launch command is built
    Then it should be "codex --dangerously-bypass-approvals-and-sandbox --no-alt-screen"

  Scenario: Launch Codex without auto-approve
    Given I create a task with assistant "codex" and skipPermissions false
    When the launch command is built
    Then it should be "codex --no-alt-screen"

  Scenario: Worktree flag is not passed to Codex
    Given I create a task with assistant "codex" and worktreeName "feat-x"
    When the launch command is built
    Then the command should NOT contain "--worktree"

  # ── Resume ──

  Scenario: Resume Codex session by UUID
    Given a Codex card with sessionId "019da64f-874c-7a03-bde4-7660c09931f2"
    When resume is triggered
    Then the command should be "codex resume --no-alt-screen 019da64f-874c-7a03-bde4-7660c09931f2"

  Scenario: Resume Codex with auto-approve
    Given a Codex card with skipPermissions true
    When resume is triggered
    Then the command should include "--dangerously-bypass-approvals-and-sandbox"
    And the command should include "--no-alt-screen"

  # ── Ready Detection ──

  Scenario: Detect Codex ready prompt
    Given tmux capture-pane output ends with "›"
    When checking isReady for assistant "codex"
    Then it should return true

  Scenario: Codex not ready yet
    Given tmux capture-pane output shows "Starting Codex..." with no "›"
    When checking isReady for assistant "codex"
    Then it should return false

  # ── Prompt Sending ──

  Scenario: Send prompt to Codex via bracketed paste
    Given a Codex session is ready ("›" detected)
    When a text prompt is sent
    Then it should be sent via tmux bracketed paste

  # ── Session Link Detection ──

  Scenario: Link new Codex session file after first prompt
    Given no Codex session file exists for the new card before launch
    And Codex writes a new JSONL file under "~/.codex/sessions"
    When Kanban polls for the new session
    Then it should parse the session id from "session_meta"
    And set the card sessionLink to the new JSONL path

  # ── Hooks and Images ──

  Scenario: Codex hooks are not offered
    Then supportsHooks should be false for Codex
    And Settings should not show an "Install Hooks" button for Codex

  Scenario: Image upload is disabled for Codex
    Given a card with assistant "codex"
    Then supportsImageUpload should be false
    And images should not be sent even if attached
