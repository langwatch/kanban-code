Feature: Saving a secret pasted into a prompt
  As a developer who pastes a credential into a chat
  I want the composer to save it to the vault under the name I choose
  So that a rotated key replaces the old one instead of piling up as NAME_2

  # The Mac chat composer, the iPhone chat composer and the kanban-vault
  # rush plugin all follow these rules. See docs/vault.md, "Pasted secrets".

  Background:
    Given the vault holds "METABASE_API_KEY" with tier ask, rules, a label and tags
    And I send a prompt holding a new Metabase key

  Scenario: The offered name is free
    Then the composer offers to save it as "METABASE_API_KEY_2"
    When I save without changing the name
    Then "METABASE_API_KEY_2" is added as a judged secret with no further question
    And the prompt goes out with "{{vault:METABASE_API_KEY_2}}" in place of the key

  Scenario: A typed name the vault already holds asks before replacing
    When I change the name to "METABASE_API_KEY" and save
    Then the composer asks "METABASE_API_KEY is already in the vault. Replace its value?"
    And nothing is saved while the question shows

  Scenario: Replacing keeps everything but the value
    Given the composer asked whether to replace "METABASE_API_KEY"
    When I choose to replace
    Then "METABASE_API_KEY" holds the new key
    And it keeps its tier, rules, label and tags
    And no "METABASE_API_KEY_2" is added
    And the prompt goes out with "{{vault:METABASE_API_KEY}}" in place of the key

  Scenario: Picking another name instead
    Given the composer asked whether to replace "METABASE_API_KEY"
    When I choose another name
    Then the name is "METABASE_API_KEY_2" again and I can edit it
    And "METABASE_API_KEY" keeps its value

  Scenario: The typed name already holds the pasted value
    Given the vault holds "METABASE_KEY_COPY" with the very key I pasted
    When I change the name to "METABASE_KEY_COPY" and save
    Then the composer asks nothing and saves nothing
    And the prompt goes out with "{{vault:METABASE_KEY_COPY}}" in place of the key

  Scenario: A replace that needs the owner's approval shows it is waiting
    Given replacing a stored value from the iPhone or from rush asks the owner
    When I choose to replace
    Then the composer says it waits for my approval to replace "METABASE_API_KEY"
    And the prompt is not sent until the approval is given
    And a denial leaves the stored value, with the reason shown and the prompt unsent

  Scenario: rush keeps the question open past its time limit for a program
    Given rush stops the kv it runs for a plugin after a minute
    When the approval has not come by then
    Then the plugin asks "Waiting for your approval to replace METABASE_API_KEY" with "check again" and "back to the box"
    And checking again takes the approval the open request got, without a second request

  Scenario: The Mac composer replaces at once
    Given I chose to replace in the Mac app's own composer
    Then the value is replaced with no approval, as an edit in Settings > Vault is

  Scenario: A value the secret already holds is never a replace
    When any caller sets "METABASE_API_KEY" to the value it already holds, with no tier, rules, label or tags
    Then the vault answers that it already holds this value
    And it asks no approval and writes nothing
