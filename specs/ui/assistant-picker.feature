Feature: Assistant Picker in Task Creation
  As a developer creating new tasks
  I want to choose which coding assistant to use
  So that each task runs with the right tool

  Background:
    Given the Kanban Code application is running

  # ── New Task Dialog ──

  Scenario: Assistant picker is shown in new task dialog
    When the New Task dialog opens
    Then an assistant picker should be visible
    And it should list all installed assistants

  Scenario: Default assistant from settings
    Given settings.defaultAssistant is "gemini"
    When the New Task dialog opens
    Then the assistant picker should default to "Gemini CLI"

  Scenario: Default to Claude when no setting
    Given settings.defaultAssistant is nil
    When the New Task dialog opens
    Then the assistant picker should default to "Claude Code"

  Scenario: Only installed assistants are shown
    Given Claude Code is installed but Gemini CLI is not
    When the New Task dialog opens
    Then only "Claude Code" should appear in the picker
    And the picker should be disabled (single option)

  Scenario: All assistants installed
    Given Claude Code, Gemini CLI, and Codex CLI are installed
    When the New Task dialog opens
    Then "Claude Code", "Gemini CLI", and "Codex CLI" should appear in the picker

  # ── Capability-Based UI ──

  Scenario: Worktree toggle disabled for Gemini
    Given assistant "gemini" is selected in the picker
    Then the "Create worktree" toggle should be disabled
    And it should show a tooltip "Gemini CLI does not support worktrees"

  Scenario: Worktree toggle disabled for Codex
    Given assistant "codex" is selected in the picker
    Then the "Create worktree" toggle should be disabled
    And it should show a tooltip "Codex CLI does not support worktrees"

  Scenario: Worktree toggle enabled for Claude
    Given assistant "claude" is selected in the picker
    Then the "Create worktree" toggle should be enabled

  Scenario: Image paste disabled for Gemini
    Given assistant "gemini" is selected
    When the user tries to paste an image (Cmd+V)
    Then the image should NOT be added
    # supportsImageUpload is false for Gemini

  Scenario: Image paste disabled for Codex
    Given assistant "codex" is selected
    When the user tries to paste an image (Cmd+V)
    Then the image should NOT be added
    # supportsImageUpload is false for Codex

  Scenario: Image paste enabled for Claude
    Given assistant "claude" is selected
    When the user pastes an image (Cmd+V)
    Then the image chip should appear

  Scenario: Skip-permissions label adapts to assistant
    Given assistant "claude" is selected
    Then the checkbox should show "--dangerously-skip-permissions"
    When assistant is switched to "gemini"
    Then the checkbox should show "--yolo"
    When assistant is switched to "codex"
    Then the checkbox should show "--dangerously-bypass-approvals-and-sandbox"

  # ── Command Preview ──

  Scenario: Command preview shows Claude command
    Given assistant "claude" and skipPermissions true
    Then the command preview should show "claude --dangerously-skip-permissions"

  Scenario: Command preview shows Gemini command
    Given assistant "gemini" and skipPermissions true
    Then the command preview should show "gemini --yolo"

  Scenario: Command preview shows Codex command
    Given assistant "codex" and skipPermissions true
    Then the command preview should show "codex --dangerously-bypass-approvals-and-sandbox --no-alt-screen"

  Scenario: Command preview updates when switching assistant
    Given the command preview shows "claude --dangerously-skip-permissions"
    When the user switches to "gemini"
    Then the preview should update to "gemini --yolo"
    When the user switches to "codex"
    Then the preview should update to "codex --dangerously-bypass-approvals-and-sandbox --no-alt-screen"

  # ── Launch Confirmation Dialog ──

  Scenario: Launch confirmation shows correct assistant
    Given a card with assistant "gemini" is being launched
    When the Launch Confirmation dialog appears
    Then the command preview should use "gemini" not "claude"
    And the worktree toggle should be disabled

  Scenario: Resume confirmation shows correct assistant
    Given a card with assistant "claude" is being resumed
    When the Launch Confirmation dialog appears
    Then the command preview should use "claude --resume <sessionId>"

  Scenario: Resume confirmation shows Codex subcommand
    Given a card with assistant "codex" is being resumed
    When the Launch Confirmation dialog appears
    Then the command preview should use "codex resume --no-alt-screen <sessionId>"

  # ── Queued Prompts ──

  Scenario: Queued prompt dialog respects card assistant for images
    Given a card with assistant "gemini" has a queued prompt
    When editing the queued prompt
    Then image paste should be disabled in the prompt editor

  Scenario: Queued prompt dialog disables images for Codex
    Given a card with assistant "codex" has a queued prompt
    When editing the queued prompt
    Then image paste should be disabled in the prompt editor
