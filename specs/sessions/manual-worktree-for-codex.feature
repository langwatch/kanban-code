Feature: Manual worktree creation for agents without native worktree support

  Agents like Codex CLI and Gemini CLI don't have a `--worktree` flag.
  Kanban Code should create git worktrees manually before launching these agents,
  launch them cd'd into the worktree directory, track the worktree as "manual",
  and clean it up when the card is archived/deleted.

  Background:
    Given a project at "/tmp/my-app" that is a git repository
    And the user has Codex enabled as a coding assistant
    And the project has a clean working tree on branch "main"

  @unit
  Scenario: Launch dialog shows "Create worktree" for Codex
    Given a card with assistant "codex" and no existing worktree
    When the launch confirmation dialog is shown
    Then the "Create worktree" checkbox is visible
    And the "Branch name" text field appears when the checkbox is enabled

  @unit
  Scenario: Launch dialog shows "Create worktree" for Gemini
    Given a card with assistant "gemini" and no existing worktree
    When the launch confirmation dialog is shown
    Then the "Create worktree" checkbox is visible

  @unit
  Scenario: WorktreeLink tracks manual worktrees
    Given a WorktreeLink with path "/tmp/my-app/.worktrees/feature-auth" and branch "feature-auth"
    When isManual is set to true
    Then encoding and decoding preserves the isManual flag

  @integration
  Scenario: Codex card launches in a manually-created worktree
    Given a card with assistant "codex" and worktreeName "feature-auth"
    And the user has "Create worktree" enabled
    When the card is launched
    Then a git worktree is created at "<projectPath>/.worktrees/feature-auth" on branch "feature-auth"
    And the tmux session is launched with cd to the worktree directory
    And the card's worktreeLink has path "<projectPath>/.worktrees/feature-auth"
    And the card's worktreeLink has branch "feature-auth"
    And the card's worktreeLink has isManual = true

  @integration
  Scenario: Codex card launches without worktree when checkbox is disabled
    Given a card with assistant "codex" and worktreeName nil
    And the user has "Create worktree" disabled
    When the card is launched
    Then no git worktree is created
    And the tmux session is launched with cd to the project root
    And the card's worktreeLink is nil

  @integration
  Scenario: Manual worktree is cleaned up on card archive
    Given a card with assistant "codex" and a manual worktreeLink at "/tmp/my-app/.worktrees/feature-auth"
    When the card is archived
    Then the git worktree at "/tmp/my-app/.worktrees/feature-auth" is removed
    And the worktreeLink is cleared from the card

  @integration
  Scenario: Manual worktree is cleaned up on card delete
    Given a card with assistant "codex" and a manual worktreeLink at "/tmp/my-app/.worktrees/feature-auth"
    When the card is deleted
    Then the git worktree at "/tmp/my-app/.worktrees/feature-auth" is removed

  @integration
  Scenario: Codex resumes inside the worktree directory
    Given a card with assistant "codex" and worktreeLink at "/tmp/my-app/.worktrees/feature-auth"
    When the card is resumed
    Then the resume command cd's into "/tmp/my-app/.worktrees/feature-auth"

  @unit
  Scenario: GitWorktreeAdapter creates worktree with custom base directory
    Given a repo root at "/tmp/my-app"
    When createWorktree is called with name "feature-auth"
    Then the worktree is created at "/tmp/my-app/.worktrees/feature-auth"
    And the branch is "feature-auth"

  @unit
  Scenario: Worktree cleanup handles both .worktrees/ and .claude/worktrees/ paths
    Given a worktree path "/tmp/my-app/.worktrees/feature-auth"
    When removeWorktree is called
    Then the repo root is derived as "/tmp/my-app"
    And git worktree remove is executed successfully

  @unit
  Scenario: effectiveCreateWorktree is true for Codex when conditions are met
    Given assistant is "codex"
    And isGitRepo is true
    And createWorktree checkbox is true
    And isResume is false
    And hasExistingWorktree is false
    Then effectiveCreateWorktree returns true
