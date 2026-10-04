Feature: Peer scope
  As the owner of two paired masters
  I want each master's token for the other to do what pairing needs and no more
  So that a master that is broken into cannot open a shell on the other

  Background:
    Given the Mac and the box are paired masters
    And each holds a token of the other with the "peer" scope

  Scenario Outline: A peer token makes the calls pairing uses
    When a master calls "<route>" on its peer with its peer token
    Then the call is served

    Examples:
      | route                                 |
      | GET /v1/links                         |
      | GET /v1/board                         |
      | GET /v1/cards/search                  |
      | GET /v1/sync/state                    |
      | POST /v1/optmem/run                   |
      | POST /v1/cli                          |
      | GET /v1/vault/replica                 |
      | POST /v1/vault/card-token             |
      | GET /v1/attention                     |
      | POST /v1/attention/{id}/resolve       |
      | POST /v1/cards/{id}/prompt            |
      | POST /v1/cards/{id}/move              |
      | GET /v1/cards/{id}/handover           |
      | GET /v1/cards/{id}/transcript/raw     |
      | POST /v1/cards/{id}/side-chat         |
      | POST /v1/scrub/run                    |

  Scenario: A peer token cannot open a terminal
    When a master opens "GET /v1/cards/{id}/terminal" on its peer with its peer token
    Then the answer is 403 "the peer scope cannot open terminals"
    And no process is started

  Scenario Outline: A peer token cannot reach secrets
    When a master calls "<route>" on its peer with its peer token
    Then the answer is 403

    Examples:
      | route                        |
      | POST /v1/vault/release       |
      | POST /v1/vault/aws           |
      | GET /v1/vault/secrets        |
      | POST /v1/vault/secrets       |
      | DELETE /v1/vault/secrets/X   |

  Scenario: A route added later is refused until it is listed
    When a master calls a route the peer list does not name
    Then the answer is 403

  Scenario: A forwarded prompt stays the human's
    When the box forwards a prompt the human typed to a card the Mac owns
    Then the prompt arrives unmarked, as with a full token

  Scenario: The Mac still shows the terminals of the box's cards
    Given the Mac's peer entry has a terminal token of the box
    When I open the terminal of a card the box owns
    Then the Mac attaches with the terminal token
    And that token can read the board and open terminals, and nothing else

  Scenario: The limit is the same in both directions
    Then the box's token for the Mac has the "peer" scope
    And the Mac's token for the box has the "peer" scope
