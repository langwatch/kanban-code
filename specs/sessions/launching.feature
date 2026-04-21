Feature: Session Launching
  As a developer using Kanban Code
  I want to launch Claude Code sessions from the board with a confirmation dialog
  So that I can review and edit prompts before starting work

  Background:
    Given the Kanban Code application is running
    And tmux is installed

  # ── Launch Confirmation Dialog ──

  Scenario: Launch confirmation dialog appears before every launch
    Given I click "Start" on any backlog card
    Then a launch confirmation dialog should appear with:
      | Field            | Type              | Editable | Notes                                    |
      | Project path     | Text              | no       |                                          |
      | Prompt           | TextEditor        | yes      |                                          |
      | Create worktree  | Checkbox          | yes      | Hidden if card has existing worktreeLink  |
      | Run remotely     | Checkbox          | yes      | Disabled if no global remote or project not under localPath |
      | Command preview  | Monospaced text   | no       | Updates live as toggles change           |
    And the prompt should be pre-filled from prompt templates
    And I can edit the prompt before clicking "Launch"
    And "Cancel" dismisses without launching

  Scenario: Prompt is built from templates before dialog
    Given the promptTemplate is "/orchestrate ${prompt}"
    And a manual task has promptBody "Fix the login flow"
    When I click "Start"
    Then the dialog should show: "/orchestrate Fix the login flow"
    And I can modify it before launching

  Scenario: Create worktree checkbox defaults and persists
    When the launch confirmation dialog first appears
    Then "Create worktree" should be checked by default
    When I uncheck "Create worktree" and launch
    Then the next time I open the dialog, it should be unchecked
    Because the preference is saved via @AppStorage("createWorktree")

  Scenario: Create worktree checkbox disabled for non-git folders
    Given the project folder is NOT a git repository
    When the launch confirmation dialog appears
    Then "Create worktree" should be disabled (grayed out)
    And an inline label should say "Not a git repository" with an info icon
    And the command preview should not include --worktree

  Scenario: Create worktree checkbox hidden when worktree exists
    Given the card already has a worktreeLink
    When the launch confirmation dialog appears
    Then the "Create worktree" checkbox should not be visible
    Because creating a second worktree would be confusing

  Scenario: Run remotely checkbox defaults and persists
    Given global remote settings are configured and the project is under localPath
    When the launch confirmation dialog first appears
    Then "Run remotely" should be checked by default
    When I uncheck "Run remotely" and launch
    Then the next time I open the dialog, it should be unchecked
    Because the preference is saved via @AppStorage("runRemotely")

  Scenario: Run remotely checkbox disabled without remote config
    Given global remote settings are NOT configured
    When the launch confirmation dialog appears
    Then "Run remotely" should be disabled (grayed out)
    And an inline label should say "Configure remote execution in Settings > Remote" with an info icon

  Scenario: Launching locally when Run remotely is unchecked
    Given global remote settings are configured and the project is under localPath
    And "Run remotely" is unchecked in the dialog
    When I click "Launch"
    Then Claude should be started WITHOUT the remote shell wrapper
    And no SHELL or KANBAN_* environment variables should be set
    And no Mutagen sync should be started

  # ── Command Preview ──

  Scenario: Command preview shows basic command
    Given global remote settings are not configured
    And "Create worktree" is unchecked
    When the launch confirmation dialog appears
    Then the command preview should show: claude '<prompt>'

  Scenario: Command preview updates live with toggles
    Given a project that is a git repo
    When I check "Create worktree"
    Then the command preview should update to include --worktree
    When I uncheck "Create worktree"
    Then the command preview should update to remove --worktree

  Scenario: Command preview shows remote env vars
    Given global remote settings with host ubuntu@server.com and project under localPath
    And "Run remotely" is checked
    Then the command preview should show:
      SHELL=~/.kanban-code/remote/zsh KANBAN_REMOTE_HOST=ubuntu@server.com ... claude '...'

  Scenario: Command preview truncates long prompts
    Given a prompt longer than 60 characters
    Then the command preview should show the first ~60 characters followed by "..."

  Scenario: Launching without worktree
    Given "Create worktree" is unchecked in the dialog
    When I click "Launch"
    Then Claude should be started without the --worktree flag
    And no worktreeLink should be set on the card

  Scenario: Launching with worktree
    Given "Create worktree" is checked in the dialog
    When I click "Launch"
    Then Claude should be started with `claude --worktree <name>`
    And the worktree name should be derived from the card:
      | Card type      | Worktree name        |
      | GitHub issue   | issue-123            |
      | Manual task    | (auto-generated)     |

  # ── Launching from Backlog ──

  Scenario: Launch Claude for a GitHub issue
    Given a GitHub issue "#123: Fix login bug" is in Backlog
    And the project is configured at "~/Projects/remote/langwatch-saas"
    When I click "Start" and confirm the launch dialog
    Then the following should happen in order:
      | Step | Action                                                        |
      | 1    | Create tmux session named "issue-123"                         |
      | 2    | Inside tmux: cd to project directory                          |
      | 3    | Run: claude --worktree issue-123                              |
      | 4    | Send the prompt from the dialog                              |
    And the existing card should gain a tmuxLink
    And no new card should be created

  Scenario: Launch Claude for a manual task
    Given a manual task is in Backlog with promptBody "Fix auth flow"
    When I click "Start"
    Then the launch confirmation dialog should show the promptBody
    And I can edit the prompt before clicking "Launch"
    When I confirm the launch dialog
    Then Claude should be launched with the edited prompt
    And the existing card should gain a tmuxLink

  Scenario: Launch Claude on an orphan worktree
    Given an orphan worktree card exists (has worktreeLink, no sessionLink)
    When I click "Start Work"
    Then the launch confirmation dialog should appear
    And the prompt field should be empty (user must provide a prompt)
    And "Create worktree" should be hidden (worktree already exists)
    When I enter a prompt and click "Launch"
    Then Claude should be launched in the existing worktree directory
    And no --worktree flag should be passed

  Scenario: Launch Claude with auto-generated worktree name
    Given a manual task without a specific branch name
    When "Create worktree" is checked in the launch dialog
    Then Claude should be launched with `claude --worktree`
    And Claude Code will auto-generate the worktree name
    And the reconciler should later detect the worktree and add worktreeLink

  # ── Cancel Launch ──

  Scenario: Cancel launch in progress
    Given I clicked "Start" and the launch confirmation dialog confirmed
    And the session is in "Starting session…" state (isLaunching = true)
    When I click "Stop" on the launching spinner
    Then the launch should be cancelled
    And the tmux session should be killed
    And the card should return to its previous state
    And I should be able to start again

  # ── Tmux Session Resilience ──
  #
  # When Claude exits (error, crash, or normal completion), the tmux session
  # must stay alive so the user can see output and take charge.

  Scenario: Claude command exits — tmux session stays alive
    Given a tmux session "feat-login" is created for a launch
    When Claude exits (error or completion)
    Then the tmux session should remain alive
    And the user should see a shell prompt (not "[exited]")
    Because the session uses send-keys instead of passing the command directly

  Scenario: Claude fails to start — user can see the error
    Given a tmux session is created for a launch
    And the claude command fails (e.g., invalid arguments)
    When the user attaches to the tmux session
    Then they should see the error output from the failed command
    And a live shell prompt below it
    Because send-keys types the command into a shell, keeping the shell alive

  Scenario: tmux session creation uses send-keys
    When creating a tmux session with name "feat-login" and command "claude --resume abc"
    Then the implementation should:
      | Step | Action                                         |
      | 1    | Create session: tmux new-session -d -s feat-login -c <path> |
      | 2    | Send command: tmux send-keys -t feat-login "claude --resume abc" Enter |
    And the shell process owns the session (not the command)

  Scenario: Reuse existing tmux session
    Given a tmux session "feat-login" already exists
    When a launch attempts to create a session with the same name
    Then it should reuse the existing session (not kill and recreate)
    Because killing an active session would clear the terminal contents

  # ── Worktree Session Detection ──
  #
  # When launching with --worktree, Claude Code creates the session .jsonl
  # in a worktree-specific directory (not the project's directory).
  # e.g., ~/.claude/projects/-Users-rchaves-Projects-repo-.claude-worktrees-feat-login/

  Scenario: Detect session file in worktree-specific directory
    Given a launch with --worktree for project "/Users/me/Projects/repo"
    And the encoded project prefix is "-Users-me-Projects-repo"
    When Claude creates the session in ~/.claude/projects/-Users-me-Projects-repo-.claude-worktrees-feat-login/
    Then the session detector should find the new .jsonl file
    Because it scans ALL directories under ~/.claude/projects/ matching the project prefix

  Scenario: Session detector snapshots existing files before launch
    When launching with --worktree
    Then the detector should snapshot existing .jsonl files in:
      | Directory                          | Purpose                          |
      | ~/.claude/projects/<encoded-project>/ | Normal project sessions        |
      | ~/.claude/projects/<encoded-project>-*/ | Worktree-specific sessions  |
    And only NEW files (not in the snapshot) should be considered as the launched session

  Scenario: New worktree directory appears during polling
    Given the encoded project directory exists before launch
    When Claude creates a new worktree-specific directory during launch
    Then the detector should discover it on the next poll iteration
    And use an empty baseline for that new directory (all files are new)

  Scenario: Worktree launch gets more polling time
    When launching with --worktree
    Then the session detector should poll for 6 seconds (12 attempts)
    Because worktree setup takes longer than normal launches (3 seconds, 6 attempts)

  Scenario: Branch is available immediately after launch completes
    Given a worktree launch completes and session .jsonl is detected
    When the first line of the .jsonl contains gitBranch = "worktree-feat-login"
    Then worktreeLink should be set on the card immediately (in launchCompleted)
    And the card should show the branch name without waiting for the next reconcile cycle
    Because executeLaunch reads the first line of the .jsonl to extract gitBranch

  Scenario: Branch fallback to directory name
    Given a worktree launch completes and session .jsonl is detected
    When the .jsonl first line has no gitBranch field
    Then worktreeLink.branch should be extracted from the worktree directory name
    Because the directory name is the best available fallback

  # ── Dangerously Skip Permissions ──

  Scenario: Skip permissions checkbox defaults to checked
    When the launch confirmation dialog first appears
    Then "Dangerously skip permissions" should be checked by default
    And the command preview should include --dangerously-skip-permissions

  Scenario: Skip permissions preference persists
    When I uncheck "Dangerously skip permissions" and launch
    Then the next time I open the dialog, it should be unchecked
    Because the preference is saved via @AppStorage("dangerouslySkipPermissions")

  Scenario: Skip permissions flag in command
    Given "Dangerously skip permissions" is checked
    Then the claude command should include --dangerously-skip-permissions
    When I uncheck "Dangerously skip permissions"
    Then the flag should be removed from the command

  # ── Sub-repo Support ──

  Scenario: Launch Claude in a sub-repo
    Given a project is configured with:
      | projectPath | ~/Projects/remote/langwatch-saas/langwatch |
      | repoRoot    | ~/Projects/remote/langwatch-saas           |
    When I start a task
    Then Claude should be launched in the projectPath
    But worktrees and PRs should be tracked against the repoRoot

  # ── Launching without tmux ──

  Scenario: tmux not installed
    Given tmux is not installed
    When I click "Start" on a backlog item
    Then Claude should still be launched
    But in a background process instead of a tmux session
    And the card should show "no tmux" indicator
    And I should see a hint to install tmux for better experience

  # ── Remote Execution ──

  Scenario: Remote execution configured
    Given remote execution is configured with:
      | Setting    | Value                         |
      | host       | ubuntu@server.com             |
      | remotePath | /home/ubuntu/Projects         |
      | localPath  | ~/Projects/remote             |
    When I start a task for project "~/Projects/remote/langwatch-saas"
    Then Claude should be launched with the remote shell wrapper
    And the SHELL environment variable should point to the fake shell
    And Mutagen sync should be started for the project

  # ── Start Button on Cards ──

  Scenario: Backlog cards show a Start button
    Given a card is in the Backlog column
    Then a play button should be visible on the card
    And clicking it should open the launch confirmation dialog

  Scenario: Context menu Start option
    Given any card in the Backlog column
    When I right-click the card
    Then a "Start" option should appear in the context menu

  # ── Resuming ──

  Scenario: Resume an existing session from any column
    Given a card has sessionLink.sessionId = "abc-123"
    When I click "Resume"
    Then if there's an existing tmux session, it should be used
    Otherwise a new tmux session should be created
    And Claude should be resumed with `claude --resume abc-123`
    And the card should gain/update its tmuxLink

  Scenario: Resume without tmux session
    Given a card has sessionLink but no tmuxLink
    When I click "Resume"
    Then the card should IMMEDIATELY move to "In Progress" (synchronous update)
    And the drawer should open on the terminal tab
    Then a new tmux session should be created
    And `claude --resume <sessionId>` should be run inside it
    And the card should gain a tmuxLink
    And the card should NOT bounce between states (no waiting → in progress flicker)

  Scenario: Copy resume command
    Given a card has sessionLink.sessionId = "abc-123"
    When I click "Copy resume command"
    Then `cd <projectPath> && claude --resume abc-123` should be copied to clipboard

  Scenario: Copy resume command uses the card's assistant
    Given a card has assistant "codex"
    And sessionLink.sessionId = "019da64f-874c-7a03-bde4-7660c09931f2"
    When I click "Copy resume command"
    Then `cd <projectPath> && codex resume --no-alt-screen 019da64f-874c-7a03-bde4-7660c09931f2` should be copied to clipboard

  Scenario: Copy resume command for card without session
    Given a card has no sessionLink (e.g., backlog issue)
    When I click "Copy resume command"
    Then "# no session yet" should be copied to clipboard
