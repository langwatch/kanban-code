Feature: Side chat (/btw and /catchup)
  As a user who comes back to a session hours later
  I want to ask about it and get a summary since my last message
  Without anything of that going into the conversation

  Background:
    Given a card with a Claude Code session, on rush or on tmux
    And its chat is open on the Mac or on the phone

  # ── /btw ────────────────────────────────────────────────────────────

  Scenario: Ask a side question
    When I type "/btw which tests are still failing?" in the composer and send it
    Then a panel opens over the top of the chat
    And the answer streams into the panel
    And nothing is sent to the session
    And the session's transcript file is unchanged
    And no new session shows up on the board

  Scenario: /btw alone opens an empty panel
    When I send "/btw"
    Then the panel opens with a follow-up field and nothing asked

  Scenario: Continue in the side chat
    Given the side chat answered a question
    When I type a follow-up and choose "Ask here"
    Then the follow-up is answered in the panel
    And the side model gets the earlier questions and answers
    And nothing is sent to the session

  Scenario: Bring the side chat into the main chat
    Given the side chat answered a question
    When I type a reply and choose "Send to main chat"
    Then the session gets my reply first, then the side chat's questions and answers as context
    And the message counts as typed by me
    And the panel closes

  Scenario: Dismiss
    When I close the panel
    Then the side chat is forgotten
    And a run that is still answering is stopped

  Scenario: The side run cannot change anything
    When the side model tries to call a tool
    Then the call is denied
    And the run uses the logged-in plan, never an API key

  # ── /catchup ────────────────────────────────────────────────────────

  Scenario: Catch up from the composer
    When I send "/catchup"
    Then the panel shows "Since you sent" with the start of my last message
    And the summary shows as sections in this order, each left out when empty:
      | What you asked     |
      | Where it stands    |
      | Key facts          |
      | Waiting on you     |
      | Blocked or failed  |
      | What else happened |

  Scenario: Catch up from the button
    When I use the catch-up button in the composer
    Then the same summary shows as for "/catchup"

  Scenario: The scope starts at my last message
    Given I sent "refactor the billing webhooks"
    And afterwards another agent messaged the session with `kanban send`
    And a task notification arrived in the session
    When I run /catchup
    Then the summary covers everything since "refactor the billing webhooks"
    And the messages from the agent and the notification are listed under "What else happened"

  Scenario: A prompt I queued counts from when I wrote it
    Given I queued a prompt while the agent worked
    And it was delivered ten minutes later
    When I run /catchup
    Then the summary covers what happened since I queued it

  Scenario: A prompt an agent queued is not mine
    Given an agent queued a prompt for the card
    When it is delivered
    Then my last message is still the one I typed before

  Scenario: Every item links to its message
    Given the summary shows
    When I use the link at the end of an item
    Then the panel folds
    And the chat scrolls to the cited message and tints it for a few seconds

  Scenario: The full report
    Given the agent wrote a long final report of the main task
    Then the summary shows a "Full report" button under "Where it stands"
    And the button shows that message in the chat

  Scenario: A cited message that is not loaded
    Given the cited message is older than what the chat has loaded
    When I use its link
    Then the Mac reads the transcript around the message
    And the phone loads older pages until it has the message
    And the chat scrolls to it

  # ── Reopening ───────────────────────────────────────────────────────

  Scenario: Catch up again with nothing new
    Given I ran /catchup and closed the panel
    And the session has no message after the last one that catch-up covers
    When I run /catchup again
    Then the previous catch-up shows at once
    And no model run starts
    And it says when it was made and that nothing is new since

  Scenario: The follow-ups come back with it
    Given I asked a follow-up in the side chat of a catch-up
    When the catch-up is reopened
    Then the follow-up and its answer show under it
    And a new follow-up carries them as history

  Scenario: It survives a restart and reaches the other device
    Given I ran /catchup on the Mac
    When the app restarts, or I open the card on the phone
    And the session has nothing new
    Then /catchup shows the same catch-up at once

  Scenario: A new message makes the next catch-up fresh
    Given a kept catch-up
    When the agent writes a message, I send one, or another agent delivers one
    Then the next /catchup runs the model again
    And the new catch-up replaces the kept one

  Scenario: Refresh
    Given a catch-up shows in the panel
    When I use Refresh
    Then a new catch-up runs, whatever the session holds
    And the side chat starts over with it

  Scenario: The answer is not JSON
    When the side model answers in plain text
    Then the panel shows the text as markdown

  # ── Where it runs ───────────────────────────────────────────────────

  Scenario: A card on another master
    Given the card runs on the box
    When I run /catchup from the Mac or the phone
    Then the box runs the side chat and the answer streams back

  Scenario: Sessions without a side chat
    Given a Codex or Gemini card, or a session on an ssh or boxd machine
    Then the catch-up button is not shown, or the panel says the side chat is not available

  # ── The card's machine is offline ───────────────────────────────────

  Scenario: The machine does not answer
    Given the Mac that owns the card is asleep
    When I run /catchup on the phone and the request gets no answer
    Then the panel says "<machine name> is offline. It may be asleep."
    And it does not say "The request timed out."
    And it offers Retry

  Scenario: Retry
    Given the panel says the machine is offline
    When the machine is back and I use Retry
    Then the same question is asked again in its place
    And the answer shows

  Scenario: An error the machine answered with
    Given the machine is online
    When the side chat fails with an error of its own
    Then the panel shows that error
    And it offers Retry

  Scenario: The phone keeps the Mac awake
    Given a Mac on power with its lid closed that is awake for a moment
    When I run /catchup on the phone for a card on that Mac
    Then the Mac stays awake for 10 minutes after my last request to the card
    And the run is not cut off by sleep

  # ── The record of what I typed ──────────────────────────────────────

  Scenario: What the Kanban chat sends is recorded as mine
    When I send a prompt from the chat on the Mac or the phone
    Then it is written to the card's record with the time I wrote it
    And a rush that lists `--human` gets the flag

  Scenario: What agents send is not recorded
    When a prompt arrives from `kanban send`, a DM, a channel, a remote agent or a self-compact follow-up
    Then it is not written to the record
    And an agent-scope device cannot mark a prompt as mine

  Scenario: A session older than the record
    Given no record covers the session
    Then a user message with no delivery marker, no task notification and no harness wrapper counts as mine
