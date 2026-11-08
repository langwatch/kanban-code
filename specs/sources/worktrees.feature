Feature: Git Worktrees of Cards
  As a developer using git worktrees for Claude Code sessions
  I want the worktree of each card linked to it
  So that I can track the lifecycle of work branches (worktree → PR → merge → cleanup)
  A worktree no card uses gets no card of its own.

  Background:
    Given the Kanban Code application is running
    And the user has configured at least one project
    And the project has a git repository with worktrees

  # ── Discovery ──

  Scenario: A worktree no card uses gets no card
    Given project "LangWatch" has effectiveRepoRoot "/Users/me/Projects/langwatch"
    And the repo has worktrees:
      | Path                                          | Branch                        |
      | /Users/me/Projects/langwatch                  | main                          |
      | .../langwatch/.worktrees/feat-encrypt-keys     | feat/encrypt-provider-keys    |
    And no card has the branch "feat/encrypt-provider-keys"
    When the board refreshes
    Then no card is created for the worktree

  Scenario: Multiple projects scanned for worktrees
    Given projects are configured:
      | Path                                    |
      | /Users/me/Projects/langwatch            |
      | /Users/me/Projects/scenario             |
    When the board refreshes
    Then worktrees from BOTH repos are matched to the cards of each project

  # ── 1:1 Mapping ──

  Scenario: Session discovered first, worktree discovered later
    Given a session card exists with gitBranch = "feat/login" (no worktreeLink)
    When the worktree scan discovers a worktree with branch "feat/login"
    Then the worktreeLink should be SET on the existing session card
    And no other card should be created

  Scenario: Two sessions on the same worktree branch
    Given a session "s1" exists with worktreeLink.branch = "feat/login"
    And a session "s2" also exists with gitBranch = "feat/login"
    When the worktree scan discovers the worktree for "feat/login"
    Then both session cards should have worktreeLink.branch = "feat/login"
    And both should be separate cards (two sessions, one branch)

  # ── PR Matching ──

  Scenario: Worktree card gets PR linked automatically
    Given a card exists with worktree branch "feat/encrypt-provider-keys"
    And a merged PR exists with headRefName = "feat/encrypt-provider-keys"
    When the board refreshes with PR data
    Then the card's prLinks should contain the merged PR
    And the card should be in the "Done" column

  Scenario: Worktree with merged PR appears in Done
    Given cards have worktree branches that all have merged PRs
    When the board refreshes
    Then those cards should appear in the "Done" column
    And the cards should show the PR badge with merged status

  # ── Worktree Cleanup ──

  Scenario: Cleanup worktree button on worktree cards
    Given a card has the worktree of branch "feat/encrypt-keys"
    When I open the card detail
    Then a "Remove Worktree" button should appear in the actions menu
    When I click "Remove Worktree"
    Then `git worktree remove` should run for that worktree path
    And the worktreeLink should be cleared from the card

  Scenario: Dead worktree link is cleaned up automatically
    Given a card has worktreeLink.path = "/path/to/deleted-worktree"
    And the path no longer exists on disk (worktree was deleted externally)
    When the board refreshes with worktree scanning enabled
    Then the worktreeLink should be cleared from the card
    Unless manualOverrides.worktreePath is true
