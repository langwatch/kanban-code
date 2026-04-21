Feature: Onboarding with Multiple Assistants
  As a new user setting up Kanban Code
  I want the onboarding to help me configure all my coding assistants
  So that I can use any installed assistant right away

  Background:
    Given the onboarding wizard is shown

  # ── Coding Assistants Step ──

  Scenario: Step shows all known assistants
    Then the "Coding Assistants" step should check for:
      | Assistant   | Check Command    |
      | Claude Code | which claude     |
      | Gemini CLI  | which gemini     |
      | Codex CLI   | which codex      |

  Scenario: All assistants installed
    Given "claude", "gemini", and "codex" are on PATH
    Then all should show green checkmarks

  Scenario: Only Claude installed
    Given "claude" is on PATH but "gemini" is not
    Then Claude Code should show a green checkmark
    And Gemini CLI should show "Not installed" with install instructions

  Scenario: Only Gemini installed
    Given "gemini" is on PATH but "claude" is not
    Then Gemini CLI should show a green checkmark
    And Claude Code should show "Not installed" with install instructions

  Scenario: Neither installed
    Given none of "claude", "gemini", or "codex" is on PATH
    Then all should show "Not installed"
    And install instructions should be shown for all enabled assistants

  Scenario: Claude install instruction
    Given Claude Code is not installed
    Then the install command should be "npm install -g @anthropic-ai/claude-code"

  Scenario: Gemini install instruction
    Given Gemini CLI is not installed
    Then the install command should be "npm install -g @google/gemini-cli"

  Scenario: Codex install instruction
    Given Codex CLI is not installed
    Then the install command should be "npm install -g @openai/codex"

  # ── Hooks Step ──

  Scenario: Hooks step checks assistants that support hooks
    Given Claude, Gemini, and Codex are installed
    Then the hooks step should check hook installation for Claude and Gemini
    And Codex should not get a hooks installation step

  Scenario: Install Claude hooks
    Given Claude Code is installed but hooks are not installed
    When "Install Claude Hooks" is clicked
    Then hooks should be written to ~/.claude/settings.json

  Scenario: Install Gemini hooks
    Given Gemini CLI is installed but hooks are not installed
    When "Install Gemini Hooks" is clicked
    Then hooks should be installed via Gemini's hook system

  Scenario: Codex uses session file polling instead of hooks
    Given Codex CLI is installed
    Then onboarding should not offer "Install Codex Hooks"
    And Codex activity should be described as session file polling

  Scenario: Kill pre-existing sessions warning
    Given Claude hooks were just installed
    And 3 Claude processes are running without hooks
    Then a warning should appear: "3 Claude sessions running without hooks"
    And a "Kill All Claude Sessions" button should be shown

  Scenario: Kill pre-existing Gemini sessions
    Given Gemini hooks were just installed
    And 2 Gemini processes are running without hooks
    Then a warning should appear: "2 Gemini sessions running without hooks"
    And a "Kill All Gemini Sessions" button should be shown

  # ── Summary Step ──

  Scenario: Summary shows status of all assistants
    Then the summary step should show:
      | Item               | Status   |
      | Claude Code        | Ready/Not set up |
      | Claude Code Hooks  | Ready/Not set up |
      | Gemini CLI         | Ready/Not set up |
      | Gemini CLI Hooks   | Ready/Not set up |
      | Codex CLI          | Ready/Not set up |
      | Pushover           | Ready/Not set up |
      | tmux               | Ready/Not set up |
      | GitHub CLI         | Ready/Not set up |

  # ── Dependency Checker ──

  Scenario: DependencyChecker reports all assistants
    When DependencyChecker.checkAll() runs
    Then the status should include:
      | Field             | Type |
      | claudeAvailable   | Bool |
      | geminiAvailable   | Bool |
      | codexAvailable    | Bool |
      | hooksInstalled    | Bool |
      | tmuxAvailable     | Bool |
      | ghAvailable       | Bool |
