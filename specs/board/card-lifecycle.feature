Feature: Card Lifecycle and Automation
  As a developer using Kanban Code to manage Claude Code sessions
  I want cards to automatically move between columns based on their links and state
  So that my board always reflects the true state of work

  Background:
    Given the Kanban Code application is running
    And the background reconciliation process is active

  # ── Card Labels ──

  Scenario: Card label reflects the primary link type
    Given a card exists on the board
    Then the card should show a label based on which links are present:
      | Links present                    | Label     | Color  |
      | sessionLink (with or without others) | SESSION   | orange |
      | worktreeLink only                | WORKTREE  | green  |
      | issueLink only                   | ISSUE     | blue   |
      | prLink only                      | PR        | purple |
      | no typed links (manual task)     | TASK      | gray   |
    And the priority order is: SESSION > WORKTREE > ISSUE > PR > TASK
    And badge text color adapts: white in light mode, black in dark mode

  Scenario: Card shows secondary link indicators
    Given a card has sessionLink AND prLink AND issueLink
    Then the primary label should be "SESSION" (blue)
    And small secondary icons should appear for PR and issue

  # ── Card Detail Header ──

  Scenario: Card detail shows property rows for each link
    Given I select a card with sessionLink, tmuxLink, worktreeLink, prLink, and issueLink
    Then the detail header should show property rows (icon + label + value + actions):
      | Row       | Icon                        | Value                   | Actions      |
      | Branch    | arrow.triangle.branch       | feat/login              | × unlink     |
      | Worktree  | folder                      | /path/to/worktree       | (shown if path exists) |
      | PR        | arrow.triangle.pull         | #456 · Open             | ↗ open, × unlink |
      | Issue     | circle.circle               | #123                    | ↗ open, × unlink |
      | Project   | folder                      | /Users/.../langwatch    | copy         |
      | Session   | number                      | C0BFCB49-D60E-...       | copy         |
    And only rows with data should be shown
    And a "+ Add link" button should appear at the bottom

  Scenario: Card detail has dynamic tabs based on links
    Given a card's available links determine which tabs appear:
      | Links present     | Available tabs                           |
      | tmuxLink          | Terminal                                 |
      | sessionLink       | History                                  |
      | issueLink         | Issue (markdown-rendered body)            |
      | prLink            | Pull Request (body + CI checks + reviews) |
      | promptBody only   | Prompt (markdown-rendered text)           |
    And a card with all links has Terminal + History + Issue + Pull Request tabs
    And the tab priority for default selection is: Terminal > History > Issue > PR > Prompt
    And in the expanded layout the tabs live in the "..." menu of the toolbar, under "Show", so the card title and the pull request buttons keep their room

  Scenario: Backlog issue card shows Issue tab with Start button in header
    Given a card has only an issueLink (backlog GitHub issue)
    Then the detail view should show an Issue tab with the markdown-rendered body
    And the header should show a "Start" button (not inside the tab content)
    And the Issue tab should have an "Open in Browser" button

  Scenario: Issue tab renders GitHub-flavored markdown
    Given a card has issueLink with body containing markdown (headers, code blocks, tables, links)
    When I open the Issue tab
    Then the body should be rendered as rich formatted text
    And code blocks should have syntax highlighting
    And links should be clickable
    And tables should render as proper tables

  Scenario: Pull Request tab shows CI checks and review status
    Given a card has a prLink with status, checkRuns, approvalCount, and unresolvedThreads
    When I open the Pull Request tab
    Then I should see:
      | Section          | Content                                        |
      | Header           | PR title, #number, status badge, Open in Browser |
      | Checks           | Each CI check with name + pass/fail/pending icon |
      | Reviews          | Approval count (green), unresolved threads (orange) |
      | Body             | PR description rendered as markdown              |

  Scenario: PR body loads lazily
    Given a card has a prLink but the body has not been fetched yet
    When I switch to the Pull Request tab
    Then a loading spinner should appear while the body is fetched
    And once loaded, the markdown-rendered body should replace the spinner
    And the body should be cached for the current card selection

  Scenario: Prompt tab for manual tasks
    Given a card has promptBody but no issueLink
    When I open the card detail
    Then a "Prompt" tab should appear (not "Issue" or "Pull Request")
    And the prompt text should be rendered as markdown

  # ── Backlog → In Progress ──

  Scenario: Starting a task from backlog via Kanban Code
    Given a task "Implement user auth" is in the Backlog column
    When I click the "Start" button on the card
    Then a launch confirmation dialog should appear with the prompt
    And on confirmation:
      | Step | Action                                              |
      | 1    | A tmux session should be created                    |
      | 2    | Claude Code should be launched with the prompt      |
      | 3    | The card gains a tmuxLink                           |
      | 4    | The card moves to "In Progress"                     |
      | 5    | SessionStart hook adds sessionLink to the same card |

  # A card that waits for its session accepts one by project path. Every
  # idle session of a busy project matched that test, so a card could take
  # a session written days earlier, and the session the launch really
  # started got a duplicate card of its own.
  Scenario: A launch takes only the session it started
    Given a card is launching in project "/dev/project"
    And the project has a session last written 2 days ago
    When the reconciler offers that session to the card
    Then the card should stay without a session
    And the old session should get its own card
    When the session the launch started is written
    Then that session should go to the launching card

  Scenario: Two launches in one project do not swap sessions
    Given two cards are launching in project "/dev/project"
    When a new session appears
    Then the card launched most recently should take it
    And the other card should keep waiting for its own

  Scenario: Starting a GitHub issue from backlog
    Given a GitHub issue "#123: Fix login bug" is in the Backlog
    When I click "Start" on the card
    Then the launch confirmation dialog shows the prompt built from templates
    And on launch, the existing card (with issueLink) gains tmuxLink + sessionLink
    And the card moves to "In Progress" (no new card created)

  Scenario: Starting work on a card that has a worktree
    Given a card with a worktree and no session is on the board
    When I click "Start Work"
    Then the launch confirmation dialog should appear
    And Claude should be launched in the existing worktree directory
    And no --worktree flag should be passed (worktree already exists)
    And the card gains tmuxLink + sessionLink while keeping worktreeLink

  Scenario: Task started externally gets no card
    Given I started Claude Code from my terminal with `claude --worktree feat-123`
    When the background process detects the new session
    Then no card appears for it
    And it is linked only to a card that already has its session, terminal or branch

  # ── In Progress → Requires Attention ──

  Scenario: Claude asks for plan approval
    Given a Claude session is actively working in "In Progress"
    When Claude enters plan mode and waits for user input
    Then the card should move to "Requires Attention"
    And a push notification should be sent
    And the card should show "Waiting for plan approval" status

  Scenario: Claude thinks it's done
    Given a Claude session is actively working in "In Progress"
    When Claude's Stop hook fires
    Then the card should move to "Requires Attention"
    And a push notification should be sent (deduplicated within 62s)
    And the card should show "Task may be complete" status

  Scenario: Claude needs permission for a tool
    Given a Claude session is actively working
    When Claude triggers a Notification hook for permission request
    Then the card should move to "Requires Attention"
    And the notification should include the permission being requested

  Scenario: Anti-duplicate notifications
    Given a Claude session just triggered a Stop hook
    And a notification was sent
    When a Notification hook fires within 62 seconds for the same session
    Then no duplicate notification should be sent
    And the card should remain in "Requires Attention"

  # ── Requires Attention → In Progress ──

  Scenario: User responds to Claude from Kanban Code terminal
    Given a card is in "Requires Attention"
    When I open the card's terminal and send a message to Claude
    Then the card should move back to "In Progress"
    And the session activity timestamp should update

  Scenario: User responds from external terminal
    Given a card is in "Requires Attention"
    When I send a message to Claude from my own terminal
    And the UserPromptSubmit hook fires
    Then the card should move back to "In Progress"

  # ── In Progress → In Review ──

  Scenario: PR created while Claude is not actively working
    Given a Claude session created a PR on GitHub
    And the session has been idle for more than 5 minutes
    When the reconciler detects the PR via branch matching
    Then a prLink should be added to the card
    And the card should move to "In Review"
    And the PR number, title, and status should appear on the card

  Scenario: PR exists but Claude is still working
    Given a card has a prLink
    But the session is actively working (recent activity)
    Then the card should remain in "In Progress"
    And the PR badge should be visible on the card

  # ── In Review → In Progress (addressing feedback) ──

  Scenario: User asks Claude to address review comments
    Given a card is in "In Review" for PR #42
    When I open the terminal and ask Claude to address review feedback
    Then the card should move to "In Progress"
    And when Claude finishes, it should skip "Requires Attention"
    And move directly to "In Review"
    And a notification should still be sent when Claude stops

  # ── In Review → Done ──

  Scenario: Single PR merged moves card to Done
    Given a card is in "In Review" with one PR (#42)
    When PR #42 is merged on GitHub
    And the background process detects the merge via `gh`
    Then the card should move to "Done"

  Scenario: All PRs merged moves card to Done
    Given a card is in "In Review" with PRs #42 and #43
    When both PRs are merged on GitHub
    Then the card should move to "Done"

  Scenario: Partial PR merge keeps card in In Review
    Given a card is in "In Review" with PRs #42 (merged) and #43 (open)
    Then the card should remain in "In Review"
    Because not all PRs are complete

  Scenario: PR is closed without merge
    Given a card is in "In Review" for PR #42
    When the PR is closed without merging
    Then the card should move to "Done"
    And the card should show "Closed" status

  # Work in one project often ships a change to a sibling repository too,
  # and the card carries both pull requests. The refresh asked the card's
  # own repository for every number on it, so the sibling's pull request
  # was looked up in a repository it does not live in. It kept the status
  # it had when the link was made, for good.
  Scenario: A pull request in another repository still refreshes
    Given a card in project "langwatch" carries PR #925 of repository "scenario"
    And PR #925 is merged on GitHub
    When the background refresh runs
    Then #925 should be looked up in "scenario", not in "langwatch"
    And the card should show #925 as merged

  Scenario: One query per repository, however many cards point at it
    Given several cards carry pull requests of the same repository
    When the background refresh runs
    Then those numbers should join one batched query for that repository

  Scenario: A pull request with no URL uses the card's own repository
    Given a card carries PR #42 with no URL yet
    When the background refresh runs
    Then #42 should be looked up in the card's own repository
    Because nothing else says where it lives

  # ── Done → Cleanup ──

  Scenario: Cleaning up a worktree from Done
    Given a card is in "Done" with a worktreeLink
    Then a "Clean up worktree" button should be visible
    When I click it
    Then a confirmation dialog should appear
    And on confirm:
      | Step | Action                                    |
      | 1    | Kill associated tmux session if exists     |
      | 2    | Remove the git worktree                   |
      | 3    | Clear worktreeLink and tmuxLink on card    |
    And the card should move to "All Sessions"

  Scenario: Done card without worktree moves to archive directly
    Given a card is in "Done" without a worktreeLink
    When I click "Archive"
    Then the card should move to "All Sessions"

  # ── All Sessions → In Progress (reviving) ──

  Scenario: Resuming a session from All Sessions
    Given a card with a sessionLink is in "All Sessions"
    When I click "Resume"
    Then a tmux session should be created (tmuxLink added)
    And Claude should be resumed with `claude --resume <sessionId>`
    And the card should move to "In Progress"

  Scenario: Forking a session from All Sessions
    Given a card is in "All Sessions"
    When I click "Fork"
    Then the session .jsonl should be duplicated with a new UUID
    And a new card should appear (new KSUID id, new sessionLink)
    And the original card should remain in "All Sessions"

  # ── Session Staleness ──

  Scenario: Active session without worktree or tmux
    Given a session is less than 24 hours old (configurable)
    And it has no worktreeLink or tmuxLink
    Then it should remain in its current column
    And not be auto-archived

  Scenario: Stale session auto-archives
    Given a session has been idle for more than 24 hours (configurable)
    And it has no worktreeLink or tmuxLink
    And it is not in "Backlog"
    Then it should automatically move to "All Sessions"

  Scenario: Manually archiving an active session
    Given a session is in "In Progress"
    When I drag it to "All Sessions"
    Then the card should move to "All Sessions"
    And the card should be marked as manually archived
    And it should not auto-return to "In Progress" based on age alone
