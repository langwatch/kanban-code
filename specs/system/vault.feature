Feature: Vault projects, environments and card identity
  As a developer whose agents need credentials
  I want a secret to belong to a project and an environment
  So that a project loads its own secrets as a group and its dev secrets cost no judge call

  # A secret's name is its id: KEY is shared, project/environment/KEY is a
  # project's own. See docs/vault.md.

  Scenario: A name splits into project, environment and key
    Given the secret "shop/api/prod/DATABASE_URL"
    Then its project is "shop/api", its environment "prod" and its key "DATABASE_URL"
    And approvals, the audit log and "kv ls" show it as "Database URL · shop/api · prod"

  Scenario: An old name keeps resolving after a rename
    Given the secret "OPENAI_API_KEY__SHOP" renamed to "shop/dev/OPENAI_API_KEY"
    When a client asks for "OPENAI_API_KEY__SHOP"
    Then it gets the value under the name it asked for
    And the audit line names "shop/dev/OPENAI_API_KEY"
    And the other replica gets the rename as a tombstone and an alias

  Scenario: A rename onto the same value merges
    Given "K__ONE" and "K" hold the same value
    When "K__ONE" is renamed to "K"
    Then one secret "K" remains with the stricter tier, both sources and the alias "K__ONE"

  Scenario: A rename onto another value is refused
    Given "K__TWO" and "K" hold different values
    When "K__TWO" is renamed to "K"
    Then nothing changes and the outcome is "conflict"

  Scenario: The project of a folder
    Given the repository "shop" with the subfolder "api"
    Then the project of "shop/api" is "shop/api" and then "shop"
    And a linked worktree of "shop" is the project "shop"
    And a ".vault-project" file in the repository root replaces the folder name

  Scenario: kv env loads the project's group
    Given the secrets "shop/dev/DATABASE_URL" and "shop/prod/DATABASE_URL"
    When I run "kv env -- cmd" in the "shop" folder
    Then cmd gets DATABASE_URL from "shop/dev/DATABASE_URL"
    When I run "kv env --env prod -- cmd"
    Then cmd gets DATABASE_URL from "shop/prod/DATABASE_URL"

  Scenario: A manifest line without a value takes the project's secret, else the shared one
    Given the manifest ".env.vault" with the lines "OPENAI_API_KEY" and "SLACK_TOKEN"
    And the secrets "shop/dev/OPENAI_API_KEY", "OPENAI_API_KEY" and "SLACK_TOKEN"
    When I run "kv env -- cmd" in the "shop" folder
    Then OPENAI_API_KEY comes from "shop/dev/OPENAI_API_KEY"
    And SLACK_TOKEN comes from the shared "SLACK_TOKEN"

  Scenario: A manifest line naming a secret wins over the group
    Given the manifest line "DATABASE_URL={{vault:shop/prod/DATABASE_URL}}"
    When I run "kv env -- cmd" in the "shop" folder
    Then DATABASE_URL comes from "shop/prod/DATABASE_URL"
    And the dev DATABASE_URL is not asked for

  Scenario: A card gets its project's development secret without Jev
    Given the judged secret "shop/dev/API_KEY" without rules
    And a card whose process runs in the "shop" folder or one of its worktrees
    When the card asks for it
    Then it is allowed by policy with no Jev call
    And the audit line says "the project's own development secret"

  Scenario Outline: Other secrets keep their path
    Given a card whose process runs in the "shop" folder
    When it asks for <secret>
    Then the release goes <path>

    Examples:
      | secret                                    | path          |
      | a prod secret of shop                     | to Jev        |
      | a dev secret of shop that has rules       | to Jev        |
      | a shared secret                           | to Jev        |
      | a dev secret of another project           | to Jev        |
      | a dev secret of shop with tier ask        | to the human  |
      | a dev secret of shop where every use asks | to the human  |
      | a dev secret of shop with tier never      | to a refusal  |

  Scenario: The folder the request claims does not count
    Given a card whose process runs in another project's folder
    When its request says the working directory is the "shop" folder
    Then "shop/dev/API_KEY" still goes to Jev

  Scenario: Jev is asked once per rules text
    Given a request for 6 judged secrets without rules and 3 with the rules "deploys only"
    When the vault judges it
    Then Jev gets 2 questions, each listing its secret names
    And each of the 9 secrets has its own audit line

  Scenario: A detached process is placed by its session token
    Given a card session started by the master, with KANBAN_CARD_TOKEN in its environment
    And a process of that session that was detached and now has launchd as its parent
    When it calls kv
    Then the master finds no card in its ancestry and takes the card of the token
    And the audit line says "by session token"

  Scenario: A wrong or missing token changes nothing
    Given a process outside every card session
    When it calls kv with no token, or with one the master has no hash for
    Then it is treated as a process outside every card

  Scenario: A token ends with its session
    Given a card whose session ended more than 15 minutes ago
    When a process calls kv with that card's token
    Then the token is refused and removed
    And a new session of the card gets a new token

  Scenario: The token never reaches the pane or another card
    When the master starts a tmux card session
    Then KANBAN_CARD_ID and KANBAN_CARD_TOKEN are set with "tmux new-session -e"
    And the command typed into the pane does not contain them
    And an app or tmux server started from that card's shell drops both before starting other sessions

  # Processes outside a card

  Scenario: An open secret is released to a process outside every card
    Given a scheduled job on the master's machine that is in no card session
    When it runs "kv run" for a secret of tier open
    Then the secret is released with no question
    And the audit line says "outside any card session" and names the process chain

  Scenario: A judged secret from outside a card goes to Jev first
    Given a scheduled job on the master's machine that is in no card session
    When it asks for a secret of tier judged with a reason
    Then Jev gets the command, the reason, the secret's rules and the process chain
    And an allow of at least 60% releases it with no question
    And anything else asks the human, with "Approve once" and "Deny"

  Scenario Outline: What still asks from outside a card
    Given a process outside every card
    When it <action>
    Then <outcome>

    Examples:
      | action                              | outcome             |
      | asks for a secret of tier ask       | the human is asked  |
      | asks for a secret of tier never     | it is refused       |
      | edits, deletes or renames a secret  | the human is asked  |
      | changes a secret's tier             | the human is asked  |

  Scenario: A request over the network always asks
    Given a device that calls the vault over the tailnet
    When it asks for a secret of tier open
    Then the human is asked

  Scenario: An unanswered request waits 12 hours
    Given a request that asks the human
    When no answer comes
    Then it stays open on the Mac and the phone for 12 hours
    And kv waits as long, and says so when it starts waiting
    And after 12 hours it is denied by timeout

  Scenario: A caller that gave up leaves its request open
    Given a job whose own timeout ended its kv call
    Then the request stays open for the rest of the 12 hours
    And the same call made again waits on the same request

  # Owner-only secrets

  Scenario: Ask and never secrets are sealed to the owner keys
    Given owner keys with a recovery key and at least one device key
    When a secret of tier ask or never is stored
    Then the vault file holds it only as ciphertext for the owner keys
    And the machine key alone cannot read its value

  Scenario: Sealing waits for the recovery key and a device
    Given owner keys with only a device key
    When a secret of tier ask is stored
    Then it stays under the machine key
    And "kv owner" counts it as still plain

  Scenario: An approval on a device is the decryption
    Given a sealed secret of tier ask
    When a card asks for it
    Then the attention request carries the ciphertext
    And approving on a device opens it after biometry and sends the value with the answer
    And the card gets the value

  Scenario: An approval without the device key is refused
    Given an open request for a sealed secret
    When an approval arrives with no unsealed value
    Then the answer is refused and the request stays open

  Scenario: A lease keeps the value in memory only
    Given a sealed secret approved for the card
    When the card asks again within the lease
    Then it gets the value with no prompt
    And after a master restart the next use asks the device again

  Scenario: A device refuses a sealed value under another name
    Given a request that names secret A with the ciphertext of secret B
    When the device opens it
    Then it refuses and sends nothing

  Scenario: Moving a tier re-encrypts
    When a secret moves from judged to ask
    Then the master seals it
    When a sealed secret moves from ask to judged
    Then the edit needs a device to open it
    And it is stored under the machine key

  Scenario: Changing the owner keys re-seals every secret on a device
    Given a second device asks to be enrolled
    When a device that holds a key approves it
    Then that device encrypts each sealed secret to the new set
    And only ciphertext goes back to the master

  Scenario: The recovery key opens a sealed secret with the age tool
    Given a sealed secret
    When its ciphertext is decrypted with the recovery identity by "age -d"
    Then the name and the value come out

  Scenario: AWS credentials are minted on the approving device
    Given an AWS profile whose long-lived key is sealed
    When a device approves a request for the profile
    Then the device calls STS and sends only temporary credentials
    And it asks for the longest session, falling back to shorter ones the role allows
    And the master serves later allowed requests from them until 15 minutes before they expire

  Scenario: The audit log is a hash chain
    When the vault writes an audit line
    Then the line carries the hash of the line before it
    And a changed or removed line shows as a break in "kv audit check"

  Scenario: The peer keeps a copy the writer cannot rewrite
    Given the box pushed its audit lines to the Mac
    When lines are removed from the box's log
    Then "kv audit check" on the Mac reports them as missing on the box
    And the mirror route only adds lines

  Scenario: Device approvals are recorded on the device
    When a vault request is approved on the Mac
    Then the Mac records it in its own chained file
    And an approval a log gives to the Mac with no record there is reported

  Scenario Outline: A lease lasts the secret's own lease time
    Given a secret of tier ask whose lease time is <length>
    When a card asks for it
    Then the lease option reads "Approve for this card (<words>)"
    And approving for the card gives a lease that ends <words> later
    And a use after that asks again

    Examples:
      | length  | words      |
      | 15m     | 15 minutes |
      | 1h      | 1 hour     |
      | 8h      | 8 hours    |
      | not set | 2 days     |

  Scenario Outline: kv takes a lease time between 1 minute and 2 days
    When an agent runs "kv tier NAME ask --lease <given>"
    Then kv <outcome>

    Examples:
      | given | outcome                                   |
      | 30m   | sends a lease time of 1800 seconds        |
      | 1h    | sends a lease time of 3600 seconds        |
      | 1h30m | sends a lease time of 5400 seconds        |
      | 2d    | sends a lease time of 172800 seconds      |
      | 3d    | refuses: a lease lasts at most 2 days     |
      | 30s   | refuses: a lease lasts at least 1 minute  |
      | soon  | refuses and shows the lengths it takes    |

  Scenario: The master refuses a lease time out of bounds
    When an edit carries a lease time of 3 days
    Then it is refused and the human is not asked

  Scenario: One approval for several secrets lasts the shortest lease time
    Given a secret with a lease time of 1 hour and one with 2 days
    When a card asks for both and the human approves for the card
    Then both leases end 1 hour later

  Scenario: The lease time is edited in Settings and listed by kv
    When the lease time of a secret is set to 1 hour in Settings > Vault
    Then "kv ls" shows "lease 1h" for it
    And "kv ls --json" has 3600 as its leaseSeconds
    And the other masters hold the same lease time after the next sync

  Scenario: Every use under a lease is logged with its command
    Given a card holds a lease on a secret
    When the card runs three commands with it
    Then the audit log has one line for each, with the command, the card and the decider "lease"
    And "kv log" prints each command under its line
    And the hash chain is intact

  Scenario: A refusal keeps the command that asked
    When the human denies a request
    Then the audit line reads denied, decided by the human, on the device that answered
    And it carries the command and the reason of the request

  Scenario: A value in a command is not written to the audit log
    Given a command that carries the value of a secret in plain
    When the release is logged
    Then the line has "{{vault:NAME}}" where the value was

  Scenario Outline: Refusing needs no Touch ID
    Given an open request for <what>
    When the human picks "Deny" on <where>
    Then the answer is sent with no Touch ID, Face ID, password or device key
    And the request is denied and logged as the human's decision

    Examples:
      | what                                   | where            |
      | a secret of tier ask                   | the Mac sheet    |
      | a sealed secret                        | the Mac sheet    |
      | an AWS profile minted on the device    | the Mac sheet    |
      | a sealed secret                        | the Mac banner   |
      | a sealed secret                        | the phone        |
      | a change to a secret                   | the phone        |

  Scenario: Approving still needs the device
    Given an open request for a sealed secret
    When the human picks "Approve once"
    Then the device key opens the value after Touch ID or Face ID
    And closing the sheet instead asks for no authentication and answers no request

  Scenario Outline: A reason that opens with a command word
    When an agent gives the reason "<reason>"
    Then kv <outcome>

    Examples:
      | reason                         | outcome                              |
      | make build the app             | refuses it as reading like a command |
      | Make the key ask on every use  | takes it                             |
