Feature: Conversations inside one card
  As a human steering one long-running agent about many topics
  I want separate conversations with that agent, each with its own title and messages
  So that a topic waiting on my decision does not get lost far up in one long chat

  The card keeps one session. A conversation is a view over that session with its
  own message log; the untagged chat is "Main".

  Background:
    Given a card with a live Claude Code session, on rush or on tmux
    And the master that owns the card keeps its conversations in ~/.kanban-code/conversations/<cardId>.jsonl

  # ── Starting a conversation ─────────────────────────────────────────

  Scenario: Start a new conversation from the compose button
    When I press "New Conversation" next to "Queue Prompt" in the card toolbar
    Then a new conversation opens with an empty message list
    And it gets a two-word id such as "swift-otter"
    And it is listed under the card in the sidebar as "New conversation"

  Scenario: The first message asks the agent for a title
    Given a new conversation "swift-otter" with no title
    When I send "can we harden the vault next?" in it
    Then the session receives one prompt:
      """
      [conversation swift-otter, new] can we harden the vault next?
      (reply with: kanban reply swift-otter --title "<3-6 word title>" "<answer>")
      """
    And the prompt goes through the card's queue, journal and image path like any chat prompt
    And my message shows in the conversation at once

  Scenario: Later messages carry the title
    Given the conversation "swift-otter" has the title "Vault hardening"
    When I send "ok, do it" in it
    Then the session receives:
      """
      [conversation swift-otter "Vault hardening"] ok, do it
      (reply with: kanban reply swift-otter "<answer>")
      """

  # ── The agent replies ───────────────────────────────────────────────

  Scenario: The agent replies to a conversation
    When the agent runs `kanban reply swift-otter --title "Vault hardening" "Yes, starting with the lease tiers."`
    Then the reply shows as the agent's message in "swift-otter"
    And the conversation's title becomes "Vault hardening" in the sidebar, the chat header and on the phone
    And the reply does not show in another conversation

  Scenario: Long replies come from stdin
    When the agent runs `kanban reply swift-otter -` with markdown on stdin
    Then the whole markdown text is the reply

  Scenario: A reply to an unknown conversation is refused
    When the agent runs `kanban reply no-such-thing "hi"`
    Then the command fails and lists the card's conversations

  Scenario: Plain transcript text stays in Main
    Given the agent works on a prompt from "swift-otter"
    Then its tool calls and plain text show in Main only
    And "swift-otter" shows a working indicator until the agent replies or the turn ends

  # ── Sidebar and attention ───────────────────────────────────────────

  Scenario: Conversations are nested under their card
    Given the card has conversations "swift-otter" and "calm-heron"
    Then the sidebar lists them under the card, most recent first
    And each shows its title, or "New conversation" before it has one

  Scenario: Switching between Main and conversations from the sidebar
    Given the conversation "swift-otter" is open
    When I click the card row in the sidebar
    Then Main shows again
    And the card chat has no extra row above it for switching

  Scenario: Unread replies
    Given the agent's reply is the last message of "swift-otter"
    Then "swift-otter" shows in bold in the sidebar and on the phone, with no other marker
    And kanban conversation list reports it as waiting on the human
    When I open it
    Then it is no longer bold, on every device
    And it stays waiting on the human until I send a message in it

  # ── Pop off ─────────────────────────────────────────────────────────

  Scenario: Continue an agent message in a new conversation on the Mac
    When I right-click an agent message in the chat and choose "Continue in new conversation"
    Then a new conversation opens that starts with that message quoted
    And my first message in it gives the agent the start of the quoted message as context

  Scenario: Continue an agent message in a new conversation on the phone
    When I press and hold an agent message and choose "Continue in new conversation"
    Then a new conversation opens that starts with that message quoted

  Scenario: Continue my own message in a new conversation
    When I right-click one of my messages, use its hover button, or press and hold it on the phone, and choose "Continue in new conversation"
    Then a new conversation opens with my message quoted as "Continued from your message", and the agent's reply below it if there is one
    And my first message in it tells the agent it continues the user's message, and its reply when there is one

  # ── Devices and masters ─────────────────────────────────────────────

  Scenario: Every device sees the same conversations
    Given a card the box owns
    When I start a conversation for it on the Mac and send a message
    Then the box appends it to its log and sends the prompt to the session
    And the Mac keeps a copy of the box's log under ~/.kanban-code/peers/<machine>/conversations/
    And the phone lists the same conversations with the same unread and waiting state

  Scenario: The CLI lists and shows conversations
    When I run `kanban conversation list` in the card's session
    Then it prints each conversation's id, title, message count and whether it waits on the human
    When I run `kanban conversation show swift-otter`
    Then it prints the conversation's messages, oldest first

  Scenario: Conversations survive restarts
    When the app or the server restarts
    Then every conversation, its title, messages and read state come back from the log
