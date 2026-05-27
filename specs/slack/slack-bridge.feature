Feature: Bidirectional Slack bridge for agent observability and steering
  As a team member
  I want each headless agent mirrored into a Slack channel I can read and post into
  So that anyone can follow, unblock, steer, or give feedback to an agent

  Background:
    Given a Slack app installed via manifest with Socket Mode enabled
    And one Slack bot backs all agent channels
    And each agent maps to exactly one channel by channel id
    And the bridge runs on the box and connects to Slack over a websocket (no public webhook)

  Scenario: Agent activity is mirrored to Slack
    When the agent produces an assistant message
    Then it is posted to the agent's channel
    When the agent runs a tool call
    Then a compact human-readable line is posted, e.g. "Bash(npm test)", "Read(.../path)", "Edit(...)"
    And consecutive assistant lines (thinking + reply) are merged into one logical message
    And tool results are summarized rather than dumped in full

  Scenario: Automated prompts are mirrored and marked, human relays are not
    When the runtime auto-sends a queued prompt (e.g. an auto-compact warning) to the agent
    Then that prompt is posted to the channel prefixed with "[SYSTEM MESSAGE]"
    When a scheduled nudge is delivered to the agent
    Then that nudge is posted to the channel prefixed with "[SYSTEM MESSAGE]"
    When a human's Slack message is relayed into the agent
    Then it is NOT re-posted by the bridge (it already appears as that person's Slack message)
    And so the "[SYSTEM MESSAGE]" marker only ever appears on system-originated traffic, letting a reader tell injected prompts apart from the agent's own replies

  Scenario: A team member steers the agent from Slack
    Given a team member posts a message in the agent's channel
    When the bridge receives the Slack message event
    Then the message text is sent into the agent's tmux session as a user prompt
    And messages the bridge itself posted (bot messages) are ignored to avoid loops

  Scenario: Multiple people observe and steer the same agent
    Given several team members are in the channel
    Then all of them see the same agent activity
    And any of them can post a steering message, delivered to the agent in order

  Scenario: Formatting reuses Kanban Code chat-rendering lessons
    Then assistant text, tool_use, tool_result, thinking, plan-mode and ask-user-question blocks
      are parsed from the transcript the same way the Kanban Code chat view parses them
    And long content is truncated for Slack readability
