Feature: Onboarding with Multiple Assistants
  As a new user setting up Kanban Code
  I want the onboarding to help me configure all my coding assistants
  So that I can use any installed assistant right away

  Background:
    Given the onboarding wizard is shown

  # ── Coding Assistants Step ──

  @integration
  Scenario: Step shows all known assistants
    Then the "Coding Assistants" step should check for:
      | Assistant   | Check Command     |
      | Claude Code | which claude      |
      | Gemini CLI  | which gemini      |
      | Mastra Code | which mastracode  |

  @integration
  Scenario: All assistants installed
    Given "claude", "gemini", and "mastracode" are on PATH
    Then Claude Code, Gemini CLI, and Mastra Code should show green checkmarks

  @integration
  Scenario: Only Claude installed
    Given "claude" is on PATH but "gemini" and "mastracode" are not
    Then Claude Code should show a green checkmark
    And Gemini CLI should show "Not installed" with install instructions
    And Mastra Code should show "Not installed" with install instructions

  @integration
  Scenario: Only Gemini installed
    Given "gemini" is on PATH but "claude" and "mastracode" are not
    Then Gemini CLI should show a green checkmark
    And Claude Code should show "Not installed" with install instructions
    And Mastra Code should show "Not installed" with install instructions

  @integration
  Scenario: Only Mastra Code installed
    Given "mastracode" is on PATH but "claude" and "gemini" are not
    Then Mastra Code should show a green checkmark
    And Claude Code should show "Not installed" with install instructions
    And Gemini CLI should show "Not installed" with install instructions

  @integration
  Scenario: No assistants installed
    Given "claude", "gemini", and "mastracode" are not on PATH
    Then Claude Code, Gemini CLI, and Mastra Code should show "Not installed"
    And install instructions should be shown for all three

  @unit
  Scenario: Claude install instruction
    Given Claude Code is not installed
    Then the install command should be "npm install -g @anthropic-ai/claude-code"

  @unit
  Scenario: Gemini install instruction
    Given Gemini CLI is not installed
    Then the install command should be "npm install -g @google/gemini-cli"

  @unit
  Scenario: Mastra Code install instruction
    Given Mastra Code is not installed
    Then the install command should be "npm install -g mastracode"

  @integration
  Scenario: Mastra Code setup explains database access
    Given Mastra Code is installed
    Then the onboarding should explain that session history is read from "~/Library/Application Support/mastracode/"
    And it should show whether the Mastracode database is accessible

  # ── Hooks Step ──

  @integration
  Scenario: Hooks step checks Claude and Gemini
    Given both Claude and Gemini are installed
    Then the hooks step should check hook installation for both

  @integration
  Scenario: Install Claude hooks
    Given Claude Code is installed but hooks are not installed
    When "Install Claude Hooks" is clicked
    Then hooks should be written to ~/.claude/settings.json

  @integration
  Scenario: Install Gemini hooks
    Given Gemini CLI is installed but hooks are not installed
    When "Install Gemini Hooks" is clicked
    Then hooks should be installed via Gemini's hook system

  @integration
  Scenario: Mastra Code does not require a hooks step
    Given Mastra Code is installed and enabled
    Then the onboarding should NOT show a "Mastra Code Hooks" step
    And activity tracking should rely on database polling instead

  @integration
  Scenario: Kill pre-existing Claude sessions warning
    Given Claude hooks were just installed
    And 3 Claude processes are running without hooks
    Then a warning should appear: "3 Claude sessions running without hooks"
    And a "Kill All Claude Sessions" button should be shown

  @integration
  Scenario: Kill pre-existing Gemini sessions
    Given Gemini hooks were just installed
    And 2 Gemini processes are running without hooks
    Then a warning should appear: "2 Gemini sessions running without hooks"
    And a "Kill All Gemini Sessions" button should be shown

  # ── Summary Step ──

  @integration
  Scenario: Summary shows status of all assistants
    Then the summary step should show:
      | Item               | Status           |
      | Claude Code        | Ready/Not set up |
      | Claude Code Hooks  | Ready/Not set up |
      | Gemini CLI         | Ready/Not set up |
      | Mastra Code        | Ready/Not set up |
      | Pushover           | Ready/Not set up |
      | tmux               | Ready/Not set up |
      | GitHub CLI         | Ready/Not set up |

  # ── Dependency Checker ──

  @integration
  Scenario: DependencyChecker reports assistant and database status
    When DependencyChecker.checkAll() runs
    Then the status should include:
      | Field                    | Type |
      | claudeAvailable          | Bool |
      | geminiAvailable          | Bool |
      | mastracodeAvailable      | Bool |
      | mastracodeDatabaseAccess | Bool |
      | hooksInstalled           | Bool |
      | tmuxAvailable            | Bool |
      | ghAvailable              | Bool |
