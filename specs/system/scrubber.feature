Feature: Secret scrubber
  As the owner of the machines
  I want secrets that end up in transcripts replaced by vault references
  So that I can paste a key into a chat and not think about it again

  Background:
    Given the master holds the vault key
    And the vault has a secret "SLACK_BOT_TOKEN" of tier ask

  Scenario: A dry run counts and changes nothing
    Given a transcript that holds the value of "SLACK_BOT_TOKEN"
    When I run "kv scrub --dry-run"
    Then the report counts 1 replacement under "SLACK_BOT_TOKEN"
    And the transcript is byte for byte as before
    And the report holds no value

  Scenario: A vault value is replaced by its reference
    Given a transcript line whose text holds the value of "SLACK_BOT_TOKEN"
    When the scrubber runs
    Then the text reads "{{vault:SLACK_BOT_TOKEN}}" in its place
    And the line still parses as JSON
    And the file has the same size, inode and modification time

  Scenario: A value is found inside nested JSON text
    Given a tool result that holds JSON text with the value inside a string
    When the scrubber runs
    Then the value is replaced at both levels of escaping
    And both levels still parse

  Scenario: A key the vault does not hold is saved first
    Given a transcript that holds an Anthropic key the vault does not have
    When the scrubber runs
    Then the vault has a secret "scrubbed/found/ANTHROPIC_API_KEY_<fingerprint>" of tier ask
    And the transcript holds a reference to it

  Scenario: A made up key in a vendor's format is left alone
    Given a transcript that holds "sk-lw-test-key-..." style fixtures, a key shown as "sk-ant-...***" and an identifier that starts with "sk-"
    When the scrubber runs
    Then none of them is saved to the vault
    And none of them is replaced

  Scenario: By default only a key I typed is saved
    Given the patterns mode is "typed"
    And I pasted an OpenAI key into a card's chat
    And an agent printed a key its local dev stack minted
    When the scrubber runs
    Then the key I pasted is saved under "scrubbed/found" with tier ask
    And it is replaced in my message and in every assistant and tool line that repeats it
    And the key the dev stack minted stays in the file and is not saved

  Scenario: Typed text comes only from the records of my messages
    When the scrubber looks for keys I typed
    Then it reads Kanban's "human-messages" record and rush's "human.jsonl"
    And a user record of a transcript does not count on its own

  Scenario: A key typed later is replaced in older files too
    Given an earlier run left a transcript alone that holds a key only an agent wrote
    When I type that key into a chat and the scrubber runs
    Then the key is replaced in the older transcript as well

  Scenario: Every key in a vendor's format can be taken
    Given I ran "kv scrub --patterns on"
    When the scrubber runs
    Then a key the vault does not hold is saved and replaced wherever it is

  Scenario: Format patterns can be turned off
    Given I ran "kv scrub --patterns off"
    When the scrubber runs
    Then values the vault holds are replaced
    And a key the vault does not hold stays in the file and is not saved

  Scenario: The scan never reads a value from the vault
    When the scrubber scans
    Then it compares fingerprints from "vault/scrub-index.json"
    And the index holds no value and no key

  Scenario: An owner-only secret stays findable after it is sealed
    Given the owner keys are active
    When a secret of tier ask is set
    Then it is fingerprinted in the save that sets it, before its value is sealed
    And the other master takes the fingerprints from this one at its next run

  Scenario: Plain vault entries do not rewrite transcripts
    Given the vault has a secret whose value is "eu-central-1"
    When the scrubber runs
    Then no "eu-central-1" in any transcript is replaced

  Scenario: A name longer than the value
    Given a secret whose reference by name is longer than its value
    When the scrubber replaces it
    Then the reference is "{{vault:#<start of the fingerprint>}}"
    And the line keeps its length

  Scenario: A session in progress is left for the next run
    Given a transcript written 2 minutes ago
    When the scrubber runs
    Then that file is not changed
    And the report counts it as live

  Scenario: A run keeps what it replaced for a week
    When the scrubber replaces values in a file
    Then the file, the offset and the bytes that were there are first recorded in "~/.kanban-code/scrub-backups/<date>/ranges.jsonl"
    And the record takes a few bytes per value, whatever the size of the file
    And a backup folder older than 7 days is deleted

  Scenario: Restore writes back what was replaced
    Given a file the scrubber changed, with lines appended since
    When I run "kv scrub --restore <file>"
    Then the replaced bytes are back
    And the appended lines are still there

  Scenario: A compressed transcript on a Mac stays compressed
    Given a transcript stored with APFS transparent compression
    When the scrubber replaces a value in it
    Then the file is compressed again, with the same name, size and times
    And it is left alone when the disk has less than 1 GB free beyond its full size

  Scenario: A run stops before the disk fills
    Given the disk has less than 1 GB free
    When the scrubber runs
    Then it changes no more files and the report says why

  Scenario: The schedule covers every master
    When I set the daily time in Settings > Vault
    Then the Mac saves it
    And each paired master receives it and runs at that time over its own files

  Scenario: Extra paths are read on every master
    Given I add "~/notes/log.txt" under Paths in Settings > Vault
    When the scrubber runs
    Then the file is read on each master where it exists, with "~" as that master's home folder
    And a line of the file keeps its length when a value in it is replaced

  Scenario: A dry run result does not stay in the settings
    When I press Dry Run in Settings > Vault
    Then its counts show under the buttons, with a Details button that lists counts per file and no value
    And after I close and reopen the settings only the last real run of each master shows
