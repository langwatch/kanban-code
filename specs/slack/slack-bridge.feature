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

  Scenario: A prompt is mirrored only once the agent actually receives it
    When a prompt is injected into the agent (a scheduled nudge, a self-compact, an auto-sent queued prompt, or a manual kanban send on the box)
    Then it is NOT posted to the channel merely because the keystrokes were pasted into the tmux pane
    And it is posted only when the agent's UserPromptSubmit hook confirms the prompt was actually received
    And it is posted under the header ">>> Received user message" with the body in italics, using the exact text the agent received
    And so a paste that never becomes a submitted prompt (e.g. the session was mid-restart) is never falsely announced as received

  Scenario: Human relays from Slack are not echoed back
    When a human's Slack message is relayed into the agent
    Then the bridge records a skip-announce marker for that agent's session before pasting it
    And when the relayed prompt's UserPromptSubmit arrives, the daemon consumes the marker and does NOT re-post it (it already appears as that person's Slack message)
    And the marker is consumed by exactly one received prompt, so several rapid relays each suppress their own echo
    And the marker expires after a TTL, so a relay that never gets submitted cannot accidentally suppress a later automated prompt
    And so the marker only ever appears on injected prompts, letting a reader tell the agent's input apart from its own replies

  Scenario: A team member steers the agent from Slack
    Given a team member posts a message in the agent's channel
    When the bridge receives the Slack message event
    Then the message text is sent into the agent's tmux session as a user prompt
    And messages the bridge itself posted (bot messages) are ignored to avoid loops

  Scenario: An agent can announce to a team channel on request
    Given the agent is asked to announce something (e.g. a finished PR) in a shared channel like #dev
    When it runs "kanban slack post #dev <message>"
    Then the bot posts the message to that channel using its bot token
    And if the bot is not a member of the channel, the command fails with a clear "invite the bot" error instead of silently dropping it

  Scenario: Multiple people observe and steer the same agent
    Given several team members are in the channel
    Then all of them see the same agent activity
    And any of them can post a steering message, delivered to the agent in order

  Scenario: Formatting reuses Kanban Code chat-rendering lessons
    Then assistant text, tool_use, tool_result, thinking, plan-mode and ask-user-question blocks
      are parsed from the transcript the same way the Kanban Code chat view parses them
    And a command-style tool call (Bash, Read, TaskCreate, ...) is shown in a fenced ``` code block
    And emoji/prose tool labels (entered/exit plan mode, asking a question) are shown as plain text, not fenced
    And long content is truncated for Slack readability
