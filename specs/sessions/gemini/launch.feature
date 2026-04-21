Feature: Launch and Resume Gemini CLI Sessions
  As a developer using Gemini CLI
  I want to launch and resume Gemini sessions from the Kanban board
  So that I can manage Gemini tasks like Claude tasks

  Background:
    Given the Kanban Code application is running
    And Gemini CLI is installed

  # ── Launch ──

  Scenario: Launch Gemini with auto-approve
    Given I create a task with assistant "gemini" and skipPermissions true
    When the launch command is built
    Then it should be "gemini --yolo"

  Scenario: Launch Gemini without auto-approve
    Given I create a task with assistant "gemini" and skipPermissions false
    When the launch command is built
    Then it should be "gemini"

  Scenario: Worktree flag is not passed to Gemini
    Given I create a task with assistant "gemini" and worktreeName "feat-x"
    When the launch command is built
    Then the command should NOT contain "--worktree"

  # ── Resume ──

  Scenario: Resume Gemini session by UUID
    Given a Gemini card with sessionId "1250be89-48ad-4418-bec4-1f40afead50e"
    When resume is triggered
    Then the command should be "gemini --resume 1250be89-48ad-4418-bec4-1f40afead50e"

  Scenario: Resume Gemini with auto-approve
    Given a Gemini card with skipPermissions true
    When resume is triggered
    Then the command should include "--yolo"

  # ── Ready Detection ──

  Scenario: Detect Gemini ready prompt
    Given tmux capture-pane output contains "Type your message"
    When checking isReady for assistant "gemini"
    Then it should return true

  Scenario: Gemini not ready yet (loading)
    Given tmux capture-pane output shows "Loading..." with no "Type your message"
    When checking isReady for assistant "gemini"
    Then it should return false

  # ── Prompt Sending ──

  Scenario: Send prompt to Gemini via bracketed paste
    Given a Gemini session is ready ("Type your message" detected)
    When a text prompt is sent
    Then it should be sent via tmux bracketed paste
    # This preserves special characters that Gemini otherwise treats as commands

  # ── Image Upload ──

  Scenario: Image upload is disabled for Gemini
    Given a card with assistant "gemini"
    Then supportsImageUpload should be false
    And images should not be sent even if attached
