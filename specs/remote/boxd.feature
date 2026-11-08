Feature: Boxd Remote Mode
  As a developer with a boxd account
  I want each card to run on its own cloud machine
  So that my Mac stays free while every conversation is kept locally

  Background:
    Given the Kanban Code application is running
    And the boxd CLI is installed and logged in
    And Settings > Remote has the mode "Boxd integration"

  # ── Settings ──

  Scenario: Remote mode picker
    When I open Settings > Remote
    Then a mode picker shows two entries, boxd first:
      | Mode                         | Description                                                                 |
      | Boxd integration             | Create cloud sandboxes for each coding assistant and run tmux and coding sessions fully remotely, but sync back jsonl to keep all conversations. Requires a boxd account. |
      | Mutagen + Claude Remote Exec | Sync files with a remote machine, run the tmux and coding assistant locally but executing commands remotely. Best for delegating cpu and ram resources locally but resilient to network latency disconnects. Works with any linux remote machine. |
    And the boxd form shows:
      | Field                  | Default                                  |
      | Snapshot               | kanban-code-base                         |
      | Source machine         | good-wolf                                |
      | Project folder         | ~/${repo_name}                           |
      | Initialization command | clone the repository or pull it          |
      | Files to copy          | **/.env                                  |
      | Pause after inactivity | 30 minutes                               |
    And "Create snapshot now" saves a snapshot of the source machine

  Scenario: Assistant launch command template
    When I open Settings > Assistants
    Then each assistant has a "Launch command" field with the default "${cli_command}"
    And a checkbox "Different command when running on a remote machine"
    And checking it shows a second field used only when the card runs remotely
    And "${cli_command}" is replaced by the command Kanban Code builds before the environment prefix is added

  # ── Launch ──

  Scenario: Launching a card on a new machine
    Given a project whose origin is "git@github.com:acme/app.git"
    When I start a card with "Run on boxd" checked and "New machine from snapshot" selected
    Then a machine named "kanban-app-<card id prefix>" is created from the snapshot
    And the kanban CLI is installed on the machine and its hooks are registered
    And the initialization command runs with ${repo_dir}, ${repo_url}, ${repo_name} and ${branch} substituted
    And the files matching "Files to copy" are copied into the checkout
    And the tmux session and the assistant run on the machine
    And the card remembers the machine

  Scenario: Worktree launch on a machine
    Given I start a card on boxd with "Create worktree" checked
    Then the machine creates the worktree under its own .claude/worktrees on a new branch
    And nothing is created or pushed on the Mac
    And the card shows the branch
    And the assistant starts in the remote worktree

  Scenario: Resume locally a card whose worktree is on the machine
    Given a card with a machine and a worktree that does not exist on the Mac
    When I resume the card with "Run on boxd" unchecked
    Then the worktree is created on the Mac, tracking origin when the branch was pushed
    And the assistant resumes there from the mirrored transcript

  Scenario: The embedded terminal behaves like a local one
    Given a card runs on a machine
    When I type in the terminal
    Then keystrokes reach the machine at once and Enter submits
    And the terminal has the size of the pane and follows a resize
    And Unicode glyphs render
    And Esc leaves scroll mode
    And a drag selects text in the terminal, not in the assistant

  Scenario: Images reach a session on a machine
    Given a card runs on a machine
    When I paste an image into the terminal with Cmd+V
    Then the image is put on the machine over the bridge
    And its path is pasted into the session after the upload, so the assistant shows it as an attached image
    When I send a chat message with images to the card
    Then the images go over the bridge and the prompt points at them by path

  Scenario: A new shell tab of a card on a machine opens on the machine
    Given a card runs on a machine
    When I press Cmd+T
    Then the shell is created on the machine, in the remote checkout
    And the terminal attaches to it, not to a session on the Mac
    When the machine cannot be reached
    Then only that tab goes away, with a notice, and the session of the card keeps running

  Scenario: A file the machine rewrites is mirrored whole
    Given a card runs on a machine
    When the statusline writes a shorter context file on the machine
    Then the Mac replaces its copy instead of adding the new bytes at the end
    And the card shows the model of the session and its context measure

  Scenario: A new build of the CLI reaches a machine that has the old one
    Given a machine with the CLI of an earlier build of the same app version
    When the app connects to it
    Then the machine takes the new bundle, because the stamp holds a digest of it

  Scenario: The transcript is mirrored to the Mac
    Given a card runs on a machine
    When the assistant writes to its transcript on the machine
    Then every line is copied to ~/.claude/projects/<encoded local path>/<session id>.jsonl
    And every machine path inside the lines is rewritten to the local path
    And hook events from the machine are appended to the local hook-events.jsonl with local paths
    And the card shows activity as if the session ran locally

  Scenario: The wheel scrolls a session on a machine
    Given a terminal attached to a session on a machine
    When I scroll up with the wheel
    Then the session enters tmux copy-mode on the machine and moves up
    When I scroll back to the bottom
    Then copy-mode ends, as it does for a local session

  Scenario: A new terminal of a card on a machine opens on the machine
    Given a card runs on a machine
    When I open a new terminal (cmd+T)
    Then the shell runs on the machine, in the checkout or worktree of the card

  Scenario: Resume locally does not touch the machine
    Given a card with a paused machine
    When I resume the card with "Run on boxd" unchecked
    Then the assistant resumes on the Mac from the mirrored transcript
    And the terminal shows the local session, and the machine stays paused
    And the stopped-machine banner does not cover the local session
    And a later resume on the machine starts from the newer transcript instead of the old session left there

  Scenario: kanban CLI inside the machine
    Given a card runs on a machine
    When the assistant runs "kanban dm" or "kanban list" on the machine
    Then the command is forwarded to the Mac and runs against the full board
    And the caller is identified by the card id of the session

  # ── Pause and resume ──

  Scenario: The app starts with a machine in standby
    Given a card with a machine in standby
    When the app starts
    Then the terminal of the card waits for a resume instead of waking the machine
    When I paste an image or scroll in a terminal of a machine that runs outside the app
    Then the app reconnects at once and the paste or scroll goes through

  Scenario: Machine paused when the session stops
    Given a card runs on a machine
    When the session ends or the terminal is killed
    Then the machine is paused right away
    And the card keeps its machine

  Scenario: A paused machine is not working
    Given a card runs on a machine and the assistant is mid-tool
    When the machine is paused
    Then the card stops its spinner

  Scenario: Machine stopped after inactivity
    Given a card runs on a machine
    When no transcript bytes and no hook events arrive for the configured timeout
    Then the machine is stopped, so it costs its disk only
    And the card shows "Machine <name> was stopped after 1h without activity" with a Resume button
    And a machine sitting in standby past the same window is stopped as well
    And a machine the sweep already stopped is not stopped again on later ticks

  Scenario: The transcript push sends only what the machine misses
    Given a card with a transcript of hundreds of megabytes that already ran on its machine
    When I resume it there after more local work
    Then the Mac compares the first lines by hash and appends only the new tail
    And a prefix that differs is pushed whole

  Scenario: A failed resume does not leave the machine on the bill
    Given a resume that fails after the machine came back
    Then the machine is paused instead of sitting in standby at full price
    And a second resume clicked during the first is ignored

  Scenario: The terminal does not wake a paused machine
    Given a terminal attached to a session on a machine
    When the app pauses the machine
    Then the terminal prints "Machine paused." and waits
    And it does not run `boxd machine connect` again until the app resumes the machine
    When the app resumes the machine
    Then the terminal attaches again on its own

  Scenario: The card in focus gets its machine back
    Given a card whose machine is in standby
    When I open the card
    Then the machine is resumed and the terminal attaches again
    And a card nobody opens keeps its machine in standby

  Scenario: A click brings a paused machine back
    Given a card in focus whose machine was paused while I read it
    When I click in the terminal, or type in it
    Then the terminal says "Resuming machine <name>" at once
    And the machine is resumed and the terminal attaches again
    But a machine that does not come back says so, and the click can be repeated

  Scenario: The dialog offers the choice of the last run
    Given a card that ran on a machine and then ran on the Mac
    When I stop the session and open the resume dialog
    Then "Run on boxd" is off, and the machine of the card is still in the picker
    When I resume it on the machine again
    Then the next resume dialog opens with "Run on boxd" on, and that machine chosen

  Scenario: Closing the tab stops the machine
    Given a card that runs on a machine no other card uses
    When I close the terminal tab of the session
    Then the machine is stopped, not put in standby
    And the card keeps its machine record, and the pill says "Stopped"
    And a resume of the card starts the machine again

  Scenario: Opening a paused card does not resume its machine
    Given a card whose live session sits on a paused machine
    When I open the card, click in its terminal or press a key
    Then the machine stays in standby
    And the assistant tab shows the transcript of the session in the skin of the terminal
    And a bar at the bottom says why the machine was paused, with a "Resume machine" button

  Scenario: Resume machine is one action
    Given a card whose live session sits on a paused machine
    When I click "Resume machine", or press Cmd+Enter on the card
    Then the bar says "Resuming machine <name>…" and offers no button meanwhile
    And the terminal attaches again once the machine is connected
    And a machine that does not come back gets a "did not answer" line and the button again

  Scenario: A machine that cannot start leaves the card free to resume locally
    Given boxd refuses to create or start a machine, for example out of credits
    When I resume a card on that machine
    Then the toast says why in one line, without the boxd command line
    And a machine the app did not know before is dropped from the toolbar
    And a paused machine goes back to paused, keeping its sessions
    And resuming the card without "Run on boxd" starts it on the Mac

  Scenario: Resume machine resumes the assistant when the session did not survive
    Given a card whose live session sits on a machine that was stopped, not paused
    When I click "Resume machine"
    Then the machine is started
    And the transcript is pushed and the assistant resumed on it without a second click
    And the card shows the launch steps meanwhile, never a "session ended" screen

  Scenario: A prompt brings the machine back first
    Given a card whose live session sits on a paused machine
    When I send a message from chat mode, or send a queued prompt
    Then the machine is resumed before the prompt is pasted
    And the prompt counts as work, so the machine keeps its idle window

  Scenario: A look at a paused card costs only the look
    Given a card whose machine I brought back with "Resume machine"
    When I open another card, with no work done on the machine meanwhile
    Then the machine goes back to standby at once
    But a prompt, or any work on the machine, keeps it running for the idle window
    And a machine that was already running when I opened the card is left alone

  Scenario: The idle window is the same for every machine
    Given a machine with no work on it
    Then it is paused after the timeout of the settings, open card or not
    But a machine with a card that is actively working is never paused

  Scenario: The terminal reads the pause marker before it connects
    Given a terminal whose attach dropped when the app paused the machine
    When the loop starts its next try
    Then it reads the pause marker first and waits
    And it does not connect, which would take the machine out of standby

  Scenario: The app follows a machine resumed elsewhere
    Given a machine the app paused
    When `boxd machine resume` runs in a shell
    Then within a minute the bridge reconnects
    And the card leaves its paused state
    And a `kanban` command waiting inside the machine gets its answer

  Scenario: A machine that comes back with no work goes to standby again
    Given a machine the app paused for inactivity
    When something outside the app takes it out of standby
    Then the app reconnects and keeps the activity clock of the machine
    And the machine is paused again within 5 minutes when no work arrives
    But work on the machine gives it the full inactivity timeout again

  Scenario: Resume attaches to the existing tmux session
    Given a card with a paused machine whose tmux session is still there
    When I resume the card with "Run on boxd" checked and the same machine selected
    Then the machine is resumed and the app attaches to the existing tmux session
    And no new assistant process is started

  Scenario: Resume after the tmux session is gone
    Given a card with a machine whose tmux session no longer exists
    When I resume the card on that machine
    Then the local transcript is pushed to the machine when it has more lines than the copy there
    And the assistant starts with --resume on the machine

  Scenario: A transcript already on the machine is not pushed again
    Given a card whose transcript has the same lines on the Mac and on the machine
    And the copy on the machine is smaller in bytes because its paths are shorter
    When I resume the card on that machine
    Then no transcript is pushed
    And the assistant starts with --resume on the machine

  Scenario: A pushed transcript does not come back over the bridge
    Given a card with a transcript of a hundred megabytes
    When the app pushes it to the machine
    Then the agent holds the file while it is written and takes the pushed bytes as already on the Mac
    And the tmux commands of the launch are answered while the push runs
    And the card shows "Pushing transcript (107 MB)" under the spinner

  Scenario: A large file crosses the bridge in chunks
    Given a file on the machine that grows by many megabytes at once
    When the agent streams it to the Mac
    Then every message carries at most 4 MB, cut at a newline
    And an exec answer is not delayed by the file

  Scenario: A machine whose bridge is open stays connected during a launch
    Given a card whose machine is connected
    When I resume the card on that machine
    Then the machine is not reported as connecting
    And the tmux commands of the resume reach the machine

  Scenario: Resume on another machine
    Given a card with a machine
    When I resume the card with another machine or "New machine" selected
    Then the checkout is prepared on the new machine
    And the transcript is pushed there and resumed
    And the previous machine is kept

  Scenario: Resume locally
    Given a card with a machine
    When I resume the card with "Run on boxd" unchecked
    Then the machine is paused and kept
    And the assistant resumes locally from the mirrored transcript

  Scenario: Remove machine from the resume dialog
    Given a card with a machine
    When I click "Remove machine" in the resume dialog
    Then a confirmation asks before the machine is destroyed

  # ── Machine lifecycle ──

  Scenario: Archive destroys the machine
    Given a card with a machine
    When I archive the card
    Then a dialog asks "Are you sure? This destroys the boxd machine"
    And confirming destroys the machine and archives the card
    And Return confirms, as on "Destroy machine" and "Remove worktree"
    And a notice says "Machine <name> destroyed"

  Scenario: Archive asks before destroying even with no terminal open
    Given a card on a machine Kanban created, with no tmux session
    When I archive the card
    Then the same dialog asks before the machine is destroyed

  Scenario: Only machines Kanban created are ever destroyed
    Given a card linked to a machine Kanban did not create for a card
    Like an ssh machine from the settings, a peer master such as "rchaves-platform", or a boxd VM picked by name
    When I archive or delete the card
    Then the card lets go of the machine
    And the machine is not destroyed, stopped or removed
    And the supervisor refuses to remove any machine whose name does not start with "kanban-"

  Scenario: Card menu machine actions
    Given a card with a machine
    Then the card menu offers "Pause Machine" while it runs
    And "Destroy Machine" when the session is not running
    And "Destroy Machine" asks for a confirmation

  Scenario: Subagents share the parent's machine
    Given a card runs on a machine
    When it spawns a subagent
    Then the subagent runs on the same machine
    And archiving the subagent does not destroy the machine

  Scenario: Quit leaves the machines running
    Given sessions on machines
    When the app quits
    Then the quit sheet lists them with a cloud icon next to the name
    And quitting without killing leaves the machines running

  Scenario: Killing the managed sessions on quit stops the machines
    Given sessions on machines
    When I quit with "Kill managed sessions on quit" checked
    Then the sessions on the machines are killed
    And their machines are stopped before the process ends, not left in standby

  Scenario: Sleep leaves the machines working
    When the Mac goes to sleep
    Then no machine is stopped and the sessions keep working
    And the bridges reconnect after wake

  Scenario: There is no pause, only stop
    When any policy parks a machine: the manual button, the idle sweep,
      a closed tab, a failed launch, the quit path
    Then the machine is stopped (disk only), never left in standby
    And the reason still shows on the card banner

  Scenario: The machine parks itself when its sessions go quiet
    Given every connect installs a watchdog loop on the machine
    When nothing writes a transcript or hook event for the idle window
      and no terminal is attached
    Then the watchdog kills the idle sessions and shortens the machine's own
      suspend timers, so boxd suspends it within a minute
    And a stray packet that wakes the machine at night loops straight back
      into that park, instead of leaving it running until morning
    And a connect restores the timers and the grace window
    And a card on a machine does not keep the Mac awake through Amphetamine

  Scenario: The card shows what the launch is doing
    Given a launch on boxd takes more than 30 seconds
    When the machine is created, the repository is checked out and files are copied
    Then the card shows the current step under the "Starting session" spinner
    And the launch is not marked stale while a step is in progress
    And the terminal attaches only after the tmux session exists on the machine

  Scenario: A failed preparation keeps the machine for a retry
    Given a launch on boxd fails after the machine was created
    Then the card remembers the machine
    And the machine is paused
    And a retry resumes the same machine

  Scenario: Orphan machines are cleaned up
    Given a machine named kanban-<repo>-<card> that no card references
    When the app starts or ten minutes pass
    Then a paused machine is destroyed
    And a running machine is paused first and destroyed on the next sweep
    And a machine of an archived card is destroyed
    And a running machine of a card without a session is paused
    And the source machine of the snapshot is never touched

  Scenario: Quit does not wait forever for the machines
    When the quit kills sessions on machines
    Then a panel says the machines are being stopped
    And the app quits after ten seconds even when a pause has not answered

  Scenario: The machines get the login of the Mac
    Given a Claude login on the Mac
    When a machine connects
    Then its ~/.claude/.credentials.json is the Mac's login before the session starts
    And its ~/.claude.json carries the Mac's oauthAccount
    When I switch accounts on the Mac
    Then every connected machine gets the new login within a minute
    And a notice says "Claude login changed to <email> at <time>, sent to <machine>"
    And a token rotation shows no notice

  Scenario: A refresh on a machine comes back to the Mac
    Given a machine that refreshed its Claude token
    When the next sync tick runs
    Then the Mac's Keychain holds the refreshed token
    And a notice says "Claude login refreshed on <machine> at <time>, this Mac updated"
    And the other machines get it on their next tick

  Scenario: A long-lived token replaces the synced login
    Given a Claude token from `claude setup-token` in the Assistants settings
    When a session starts on a machine
    Then CLAUDE_CODE_OAUTH_TOKEN is set in the session

  Scenario: The terminal opened during the first seconds of a launch still reaches the machine
    Given a launch on boxd that has not created its machine yet
    When the card terminal opens
    Then the terminal waits for the ready marker instead of the local tmux
    And it attaches to the machine named in the marker
    And the spinner and the current step show on top of the terminal until the session exists
