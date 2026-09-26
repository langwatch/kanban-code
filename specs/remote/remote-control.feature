Feature: Remote control from a phone and from other agents
  As a developer away from my Mac
  I want my phone and my other agents to drive Kanban Code on the Mac
  So that sessions keep running on the Mac while I pilot them from anywhere on my tailnet

  # Contract: docs/remote-control.md. Wire types: KanbanCodeRemoteKit.

  Background:
    Given Settings > Remote Control is on
    And the Mac is on Tailscale

  Scenario: The server is reachable only on loopback and the tailnet
    Then it listens on 127.0.0.1 and the Mac's Tailscale addresses on port 7780
    And it does not listen on the LAN address
    And when Tailscale comes up after the app, the server binds its address then

  Scenario: Pairing a phone
    When I add a device named "iPhone" with scope full in Settings > Remote Control
    Then the app shows its token once and a QR code of the kanbancode://pair link
    And ~/.kanban-code/remote/devices.json keeps only the token's SHA-256
    When the phone scans the QR code
    Then it shows the board of the Mac

  Scenario: Pairing an agent from the command line
    When I run "kanban remote pair --name openclaw --scope agent" on the Mac
    Then it prints a token and the pairing link

  Scenario Outline: Requests are refused without the right token
    When a request to <path> comes with <credential>
    Then it is refused with <status>

    Examples:
      | path                        | credential           | status |
      | GET /v1/board               | no token             | 401    |
      | GET /v1/board               | a revoked token      | 401    |
      | WS /v1/cards/x/terminal     | an agent token       | 403    |
      | GET /v1/health              | no token             | 200    |

  Scenario: Revoking a device closes its connections
    Given a phone streaming a card's terminal
    When I revoke the phone in Settings > Remote Control
    Then its sockets close and its next request is refused

  Scenario: The phone gets the working set, not the whole history
    Given the Mac has archived cards, All Sessions cards and 40 Done cards
    When the phone reads the board
    Then it gets no archived and no All Sessions cards, and the 30 most recent Done cards
    When it asks with all=1
    Then it gets every card

  Scenario: The board follows the Mac live
    Given the phone is connected to /v1/events
    Then it gets the whole board first
    When a card moves to Waiting on the Mac
    Then within a second the phone gets a cards event with only that card in upserted
    When a card is archived on the Mac
    Then the phone gets its id in removed
    When the phone sends a resync frame
    Then it gets the whole board again

  Scenario: Streaming an agtop card's terminal
    Given a card running on agtop
    When the phone opens the card's terminal
    Then the Mac runs "agtop open <id> --solo" in a pseudo-terminal sized to the phone
    And what I type on the phone reaches that agtop
    And closing the terminal on the phone leaves the session running

  Scenario: Streaming a tmux card's terminal
    Given a card running on tmux
    When the phone opens the card's terminal
    Then the Mac runs "tmux attach -t <session>" in a pseudo-terminal

  Scenario: Sending a prompt from the phone
    Given a card whose session is in a turn
    When I send "also run the tests" with mode queue
    Then it reaches the session when the turn ends
    When I send "stop, wrong file" with mode now
    Then the turn is interrupted and the text is sent

  Scenario: An agent starts a coding task on the Mac
    Given OpenClaw has an agent token
    When it runs "kanban remote task --project langwatch --worktree 'fix the flaky test'"
    Then a card is created in langwatch with its own worktree and launched on the Mac
    And "kanban remote transcript <card>" shows the conversation as it goes

  Scenario: An agent token cannot open a terminal
    When OpenClaw opens WS /v1/cards/<id>/terminal
    Then it is refused with 403
