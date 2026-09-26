Feature: Session Discovery
  As a developer with many Claude Code sessions across projects
  I want Kanban Code to discover and display all my sessions
  So that nothing falls through the cracks

  Background:
    Given the Kanban Code application is running

  # ── Discovery Sources ──
  # (Learned from claude-resume: sessions-index.json + .jsonl scanning)

  Scenario: Discover sessions from index files
    Given sessions-index.json files exist under ~/.claude/projects/
    When the discovery process runs
    Then sessions listed in index files should be found
    And their metadata (summary, project path) should be extracted

  Scenario: Discover sessions not in index
    Given a .jsonl file exists under ~/.claude/projects/ without an index entry
    When the discovery process runs
    Then the session should be discovered by scanning .jsonl files directly

  Scenario: Session metadata from .jsonl scanning
    Given a session .jsonl file exists
    When it is scanned for metadata
    Then the following should be extracted via line-by-line streaming:
      | Field          | Source                                          |
      | sessionId      | Filename (UUID.jsonl)                           |
      | firstPrompt    | First "type":"user" message text                |
      | summary        | From index or auto-generated from first prompt  |
      | projectPath    | From parentUuid/cwd field                       |
      | gitBranch      | From cwd if it's a worktree path                |
      | messageCount   | Count of user+assistant type lines              |
      | modifiedTime   | fs.stat mtime (not index timestamp)             |

  Scenario: Large first messages are handled via streaming
    Given a session where the first user message is 57KB
    When the discovery process scans it
    Then it should use readline streaming (not fixed buffer)
    And the session should be discovered successfully
    And scanning should stop after finding the first user message

  Scenario: Sessions with file-history-snapshot as first line
    Given a session .jsonl starts with a "file-history-snapshot" line
    When the discovery process scans it
    Then it should skip non-message lines
    And still find the first user message on subsequent lines

  Scenario: Session with zero messages is excluded
    Given a session .jsonl has only system lines (no user/assistant)
    Then it should not appear on the board

  Scenario: Deduplication between index and scan
    Given a session appears in both sessions-index.json and .jsonl scan
    Then it should appear only once
    And the file mtime should be used (not the index timestamp)

  # ── Cross-Project Discovery ──

  Scenario: Sessions from all projects are discovered
    Given I have sessions under:
      | Project Path                                    |
      | ~/.claude/projects/-Users-rchaves-Projects-remote-langwatch/ |
      | ~/.claude/projects/-Users-rchaves-Projects-remote-scenario/  |
    When the discovery process runs
    Then sessions from all project directories should be found

  Scenario: Project path decoding
    Given a directory is named "-Users-rchaves-Projects-remote-scenario"
    Then it should be decoded to "/Users/rchaves/Projects/remote/scenario"
    And displayed as "~/Projects/remote/scenario" in the UI

  # ── Background Refresh ──

  Scenario: Periodic re-scan for new sessions
    Given the initial discovery completed
    When 30 seconds elapse
    Then a lightweight re-scan should detect new .jsonl files
    And only new or modified files should be fully parsed

  Scenario: Discovery is non-blocking
    When the discovery process is running
    Then the UI should remain responsive
    And existing cards should be interactive
    And new discoveries should appear incrementally

  # ── Headless Sessions ──

  Scenario: A headless session no card claims stays in All Sessions
    Given a script runs "claude -p" in a project, so its transcript records "entrypoint": "sdk-cli"
    And no card has its sessionId, and no agtop card is waiting for a session in that project
    When the discovery process runs
    Then a discovered card is created for the session with headless = true
    And the card is listed in All Sessions only, whatever its activity
    And it never shows in Backlog, In Progress, Waiting, In Review or Done

  Scenario: Existing discovered headless cards leave the board columns
    Given a discovered card sits in Waiting for a session whose transcript records "entrypoint": "sdk-cli"
    And the user never renamed, pinned, launched or moved the card
    When the next reconcile runs
    Then the card moves to All Sessions and is not deleted

  Scenario: Sessions Kanban runs headless keep their cards
    Given a card launched on agtop, so its session runs as "claude -p" with "entrypoint": "sdk-cli"
    When the discovery process runs
    Then the card keeps its session and its column follows activity as usual
    And it stays on the board after its agtop host is gone

  Scenario: A headless session does not attach to an interactive card by project
    Given a card launched in tmux is waiting for its session in "/repo"
    When a headless session in "/repo" is discovered
    Then the card keeps waiting for its own session
    And the headless session gets a hidden card of its own

  Scenario: The user can take a headless card onto the board
    Given a headless card in All Sessions
    When the user drags it to Waiting, pins it, renames it or resumes it
    Then the card stays on the board from then on, even after its drag override clears
