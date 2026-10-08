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

  Scenario: A workspace the runtime has never seen is settled before it starts
    Given a runtime that stops to ask about a directory the first time it starts in one
    And a workspace that runtime has no answer for
    When the reconciler starts its session
    Then the workspace is recorded as trusted before the process starts
    And the session comes up ready instead of waiting on the question
    # A headless agent has nobody to answer it, so its first launch in a fresh
    # workspace sat on the question until a person opened the pane. It grants
    # the runtime nothing it does not already have: agents launch with the
    # sandbox off.

  Scenario: An answer the operator already gave is kept
    Given the operator has already ruled on that workspace
    When the reconciler starts a session in it
    Then that answer is left as it is, trusted or not

  Scenario: A runtime with no name flag is named once it is up
    Given the agent's runtime takes no session name at launch
    When the reconciler starts its session
    Then it waits for the runtime to show it will accept a command
    And it renames the session to the slug, before any prompt is sent
    And the name reaches everything that reads the runtime's own session list
    # Codex is that runtime. Claude takes --name and needs none of this.

  Scenario: A runtime that never comes up is left unnamed
    Given a started session that does not show it will accept a command
    When the reconciler waits for it
    Then nothing is typed into that session and the launch still succeeds
    # A command typed blind sits in the composer and rides out with the
    # agent's first real prompt. An unnamed session costs a label; a
    # corrupted first prompt costs the turn.

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

  Scenario: An agent can run on a rush host instead of tmux
    Given agents.yaml sets "host: rush" at the top level or on the agent
    And the agent's runtime is claude
    When the reconciler runs for a new agent
    Then it runs "rush session start --agent claude --session-id <uuid> --name <slug> --permission-mode bypassPermissions --json"
    And the host carries the metas kanban_session=rush-<host id>, kanban_agent=<slug> and kanban_card=<card id>
    And the card's session name is "rush-<host id>", where the host id is the first eight hex digits of the session id
    # Rush keeps several Claude accounts signed in and moves a session to
    # another one when the current account runs low.

  Scenario: A Codex agent asked to run on rush stays on tmux
    Given an agent with runtime codex and "host: rush"
    When the config is parsed
    Then the agent runs on tmux and a warning names it

  Scenario: A rush host that is running or resting is never restarted
    Given the agent's rush host is running, or resting after its turn
    When the reconciler runs again
    Then no host is started and links.json is not rewritten
    # A resting host wakes on the next message sent to it.

  Scenario: A dead rush host with a transcript is resumed
    Given the agent's rush host is stopped
    And a transcript for the session id exists on disk
    When the reconciler runs
    Then it runs "rush session start --session-id <uuid> --resume"

  Scenario: Moving an agent between tmux and rush leaves one process
    Given an agent running in tmux
    When its host is changed to rush and the reconciler runs
    Then the tmux session is killed before the rush host starts
    And the same card now names the rush host
    When its host is changed back to tmux and the reconciler runs
    Then the rush host is stopped and the card names the tmux session again

  Scenario: The Slack bridge reaches an agent through its card
    Given an agent whose card names a rush host
    When a person writes in the agent's channel
    Then the message is sent to the rush host, not to a tmux session named after the slug
    And when the host is blocked on a question, the message answers it with "rush session answer"
    And the question itself is posted to the channel as text, since rush does not report its options
