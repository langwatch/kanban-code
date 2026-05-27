Feature: Headless runtime engine (no macOS app)
  As an operator running agents headless on a server
  I want the always-on engine (hooks, auto-send, auto-compaction) to run as a daemon
  So that agents keep working forever without the macOS Kanban Code app open

  Background:
    Given the headless kanban daemon is running on the box
    And Claude Code hooks and the statusline script are installed for the agents

  Scenario: Hooks are installed headlessly
    When the daemon installs hooks
    Then ~/.claude/settings.json registers Stop, Notification, SessionStart, SessionEnd and UserPromptSubmit hooks pointing at ~/.kanban-code/hook.sh
    And a statusline command writes context usage to ~/.kanban-code/context/<sessionId>.json
    And hook events are appended to ~/.kanban-code/hook-events.jsonl
    And re-installing is idempotent (no duplicate hook entries)

  Scenario: Queued prompts auto-send when the agent goes idle
    Given a prompt is queued for an agent with sendAutomatically true
    When the agent emits a Stop hook event and no user prompt arrives shortly after
    Then the queued prompt is sent to the agent's tmux session
    And it is removed from the queue

  Scenario: A recent user prompt pauses auto-send
    Given a prompt is queued for an agent
    When a UserPromptSubmit event is recorded shortly after the Stop
    Then the queued prompt is not auto-sent (a human or relay is already driving)

  Scenario: Auto-compaction protects long-running sessions
    Given an agent has been running for a long time
    When its current context usage crosses 500k tokens
    Then a prompt instructing it to self-compact is queued
    When usage crosses the hard threshold (750k)
    Then "/compact" is sent to the agent automatically
    And a stale self-compact warning is dropped if context already dropped back below its threshold

  Scenario: The session runs forever across compactions
    Given the agent has compacted multiple times
    Then the same Claude session id is retained
    And the agent continues without a human restart

  Scenario: Reboot and resume survival
    Given the box reboots, wakes from hibernate, or a spot instance is reclaimed and restored
    When the box finishes booting
    Then reconcile-on-boot resumes every configured agent with "--resume <uuid>"
    And the daemon is restarted by the service manager
