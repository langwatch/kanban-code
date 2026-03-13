Feature: Assistant Picker in Task Creation
  As a developer creating new tasks
  I want to choose which coding assistant to use
  So that each task runs with the right tool

  Background:
    Given the Kanban Code application is running

  # ── New Task Dialog ──

  @integration
  Scenario: Assistant picker is shown in new task dialog
    When the New Task dialog opens
    Then an assistant picker should be visible
    And it should list all installed assistants

  @integration
  Scenario: Default assistant from settings
    Given settings.defaultAssistant is "mastracode"
    When the New Task dialog opens
    Then the assistant picker should default to "Mastra Code"

  @integration
  Scenario: Default to Claude when no setting
    Given settings.defaultAssistant is nil
    When the New Task dialog opens
    Then the assistant picker should default to "Claude Code"

  @integration
  Scenario: Only installed assistants are shown
    Given Claude Code is installed but Gemini CLI and Mastra Code are not
    When the New Task dialog opens
    Then only "Claude Code" should appear in the picker
    And the picker should be disabled (single option)

  @integration
  Scenario: All installed assistants are shown
    Given Claude Code, Gemini CLI, and Mastra Code are installed
    When the New Task dialog opens
    Then "Claude Code", "Gemini CLI", and "Mastra Code" should appear in the picker

  # ── Capability-Based UI ──

  @integration
  Scenario: Worktree toggle disabled for Gemini
    Given assistant "gemini" is selected in the picker
    Then the "Create worktree" toggle should be disabled
    And it should show a tooltip "Gemini CLI does not support worktrees"

  @integration
  Scenario: Worktree toggle enabled for Claude
    Given assistant "claude" is selected in the picker
    Then the "Create worktree" toggle should be enabled

  @integration
  Scenario: Worktree toggle disabled for Mastra Code
    Given assistant "mastracode" is selected in the picker
    Then the "Create worktree" toggle should be disabled
    And it should show a tooltip "Mastra Code does not support worktrees"

  @integration
  Scenario: Image paste disabled for Gemini
    Given assistant "gemini" is selected
    When the user tries to paste an image (Cmd+V)
    Then the image should NOT be added

  @integration
  Scenario: Image paste enabled for Claude
    Given assistant "claude" is selected
    When the user pastes an image (Cmd+V)
    Then the image chip should appear

  @integration
  Scenario: Image paste disabled for Mastra Code
    Given assistant "mastracode" is selected
    When the user tries to paste an image (Cmd+V)
    Then the image should NOT be added

  @integration
  Scenario: Skip-permissions label adapts to assistant
    Given assistant "claude" is selected
    Then the checkbox should show "--dangerously-skip-permissions"
    When assistant is switched to "gemini"
    Then the checkbox should show "--yolo"
    When assistant is switched to "mastracode"
    Then the checkbox should show "/yolo"

  # ── Command Preview ──

  @integration
  Scenario: Command preview shows Claude command
    Given assistant "claude" and skipPermissions true
    Then the command preview should show "claude --dangerously-skip-permissions"

  @integration
  Scenario: Command preview shows Gemini command
    Given assistant "gemini" and skipPermissions true
    Then the command preview should show "gemini --yolo"

  @integration
  Scenario: Command preview shows Mastra Code command
    Given assistant "mastracode" and skipPermissions true
    Then the command preview should show "mastracode /yolo"

  @integration
  Scenario: Command preview updates when switching assistant
    Given the command preview shows "claude --dangerously-skip-permissions"
    When the user switches to "gemini"
    Then the preview should update to "gemini --yolo"
    When the user switches to "mastracode"
    Then the preview should update to "mastracode /yolo"

  # ── Launch Confirmation Dialog ──

  @integration
  Scenario: Launch confirmation shows correct assistant
    Given a card with assistant "gemini" is being launched
    When the Launch Confirmation dialog appears
    Then the command preview should use "gemini" not "claude"
    And the worktree toggle should be disabled

  @integration
  Scenario: Resume confirmation shows correct assistant
    Given a card with assistant "claude" is being resumed
    When the Launch Confirmation dialog appears
    Then the command preview should use "claude --resume <sessionId>"

  @integration
  Scenario: Resume confirmation for Mastra Code omits a resume flag
    Given a card with assistant "mastracode" is being resumed
    When the Launch Confirmation dialog appears
    Then the command preview should use "mastracode" not "mastracode --resume <sessionId>"

  # ── Queued Prompts ──

  @integration
  Scenario: Queued prompt dialog respects Gemini image support
    Given a card with assistant "gemini" has a queued prompt
    When editing the queued prompt
    Then image paste should be disabled in the prompt editor

  @integration
  Scenario: Queued prompt dialog respects Mastra Code image support
    Given a card with assistant "mastracode" has a queued prompt
    When editing the queued prompt
    Then image paste should be disabled in the prompt editor
