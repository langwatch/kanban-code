Feature: Headless agent session reconciliation (CLI)
  As an operator running Kanban Code headless on a server (no macOS app)
  I want long-lived agent sessions defined declaratively and reconciled idempotently
  So that sessions are stable, survive reboots, and never get duplicated

  Background:
    Given an agents config listing agents by readable slug, each with target repos
    And canonical repo clones are provisioned and kept clean + current externally (not by Kanban Code)

  Scenario: Stable identity is derived from the readable slug
    When the reconciler computes the identity for an agent slug
    Then the Claude session id is a deterministic UUIDv5 of the slug
    And the same slug always yields the same session id
    And the session display name (--name), tmux session name, kanban card name and worktree name are all the slug

  Scenario: First reconcile launches once
    Given no tmux session, card, or worktree exists for the agent
    When the reconciler runs
    Then a per-agent git worktree of each target repo is created from the canonical clone
    And a tmux session named after the slug is created
    And Claude is launched with "--session-id <uuid> --name <slug>" in the workspace
    And a card linking the session and tmux session is written to links.json

  Scenario: Re-running while healthy is a true no-op
    Given the agent is already running and healthy
    When the reconciler runs again
    Then no second tmux session, card, or worktree is created
    And the live Claude session is left running and is not restarted
    And links.json is not rewritten when nothing meaningful changed

  Scenario: A dead session is resumed, not started fresh
    Given the card and worktree still exist but the tmux session was killed
    And a transcript for the session id exists on disk
    When the reconciler runs
    Then a tmux session is recreated
    And Claude is started with "--resume <uuid>" in the existing worktree
    And prior conversation history is preserved

  Scenario: Kanban Code does not clean or clone repos
    Given a canonical clone is missing
    When the reconciler runs for that agent
    Then it fails loudly rather than cloning the repo
    And the reconciler never stashes, pulls, or resets any repo (that is the deployer's IaC job)

  Scenario: The working directory is always a worktree
    When Claude is launched for an agent
    Then its working directory is the per-agent workspace of worktrees
    And it is never the canonical clone, so the agent cannot dirty that clone

  Scenario: Adding an agent provisions only the new one
    Given two agents are configured and only the first is running
    When the reconciler runs
    Then the second agent is launched and the first is left untouched

  Scenario: Pruning tears down a de-configured agent
    Given an agent is running whose workspace is the managed path but whose slug is no longer configured
    When the reconciler runs with pruning enabled
    Then that agent's tmux session is killed, its card is archived, and its workspace is removed
    And cards whose worktree path is not the managed path are never touched
