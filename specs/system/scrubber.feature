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

  Scenario: The first run keeps a backup for a week
    Given no run has changed files on this machine yet
    When the scrubber runs
    Then each file it changes is first copied, gzipped, under "~/.kanban-code/scrub-backups/<date>/"
    And a backup folder older than 7 days is deleted

  Scenario: The schedule covers every master
    When I set the daily time in Settings > Vault
    Then the Mac saves it
    And each paired master receives it and runs at that time over its own files

  Scenario: OptMem records keep their width
    Given a memory in the OptMem log that holds a vault value
    When the scrubber runs
    Then the record has the same width
    And memo reads every memory as before
