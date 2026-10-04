Feature: Searching every card from the phone
  As the owner of a board with thousands of cards on two masters
  I want the phone's search to find any card, archived and old ones too
  So that I can open an old card and bring it back without going to the Mac

  Background:
    Given the phone holds only the working set: no archived cards, no All Sessions cards, the 30 most recent Done cards
    And the masters know every card, about 2,500 on the Mac

  Scenario: The server finds an archived card by its name
    Given an archived card "Export invoices to Parquet"
    When a client calls "GET /v1/cards/search?q=parquet"
    Then the answer lists the card with "archived" true

  Scenario Outline: Every word must match, in any field, whatever the case or the accents
    Given a card "Résumé parser" of project "acme-web" on branch "feat/cv-upload" with pull request #8321 "feat: parse uploads"
    When a client searches for "<query>"
    Then the card is <found>

    Examples:
      | query          | found     |
      | resume         | found     |
      | RESUME acme    | found     |
      | cv-upload      | found     |
      | #8321          | found     |
      | parse uploads  | found     |
      | resume billing | not found |

  Scenario: The first lines of a card's prompt count
    Given a card named "Billing exports" whose prompt starts with "Export the invoices to Parquet"
    When a client searches for "parquet"
    Then the card is found
    And a word that only appears far down the prompt does not find it

  Scenario: Board cards come first, then the most recently active
    Given a matching card on the board and a matching archived card that was active more recently
    When a client searches
    Then the board card is listed first

  Scenario: Only cards the phone does not hold
    When a client searches with "scope=older"
    Then no card of the working set is in the answer

  Scenario: A master asks its peers for the cards only they know
    Given the Mac has an All Sessions card nobody claimed, which is not synced to the box
    When a client searches the box for that card
    Then the box asks the Mac and the card is in the answer, named as the Mac's

  Scenario: A peer that is off does not hold the answer
    Given the Mac is asleep
    When a client searches the box
    Then the answer comes within 3 seconds with the cards the box knows
    And "unreachable" names the Mac

  Scenario: Token scopes
    Then a full, an agent and a peer token may search
    And a terminal token is refused with 403
    And a search does not hold the Mac awake

  Scenario: Search on the phone's board
    Given the phone shows the board
    When I type the name of an archived card in the search field
    Then cards of the board that match show at once
    And a section "Archived and older" fills from the server a moment later
    And a progress row shows while it loads
    And "Could not search older cards" shows when no master answers

  Scenario: Opening an archived card from the search
    When I tap a card under "Archived and older"
    Then its conversation shows without unarchiving it
    And a "Bring back to board" button shows above it
    When I tap "Bring back to board"
    Then the card is in the Backlog of the board without a manual refresh

  Scenario: Search in the archived cards screen
    Given the phone shows "Archived cards", the 200 most recent ones
    When I type in its search field
    Then the list shows the archived, All Sessions and older Done cards that match, from the server
    When I touch and hold a card and choose "Bring back to board"
    Then the card leaves the list and is on the board

  Scenario: A card brought back stays on the board
    Given an archived card whose session ended more than a day ago
    When it is unarchived, or pinned, from the Mac, the phone or the API
    Then it is in the Backlog as a manual placement
    And it is still there after the board reconciles
    And resuming it lets activity move it again

  Scenario: The CLI searches the same way
    When an agent runs "kanban remote cards --search parquet"
    Then it lists the matching cards of every master, archived ones included
