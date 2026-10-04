Feature: Slash command list in the chat composer
  As a user who types a command in a card's chat
  I want the commands and skills that session can run listed while I type
  So that I do not have to remember their names

  Background:
    Given a card whose chat is open on the Mac or on the phone

  # ── When the list shows ─────────────────────────────────────────────

  Scenario: The list opens on a slash
    When I type "/" in the empty composer
    Then a list shows above the composer
    And each row has the command's name and one line of description
    And the first command is selected

  Scenario: The list filters while I type
    When I type "/catchu"
    Then the list holds "/catchup"
    And names that start with what I typed come before names that only contain it

  Scenario: The list closes once the command is written
    When the text holds a space or a line break
    Then no list shows

  Scenario: A path is not a command
    When I type "/Users/me/notes.txt"
    Then no list shows

  Scenario: A message that does not start with a slash
    When I type "see /catchup"
    Then no list shows

  Scenario: The list never blocks a plain message
    When I type "hello" and send it
    Then the message goes to the session as before

  # ── Keys on the Mac ─────────────────────────────────────────────────

  Scenario: Arrows move the selection
    Given the list shows several commands
    When I press down, then up
    Then the selection moves down, then back
    And it wraps around at both ends

  Scenario: Tab completes
    Given I typed "/catchu" and "/catchup" is selected
    When I press Tab
    Then the composer holds "/catchup " with the caret at the end
    And the list closes

  Scenario: Return completes a name that is not written in full
    Given I typed "/catchu" and "/catchup" is selected
    When I press Return
    Then the composer holds "/catchup "
    And nothing is sent

  Scenario: Return sends a name written in full
    Given I typed "/catchup" and "/catchup" is selected
    When I press Return
    Then the command runs as it does without the list

  Scenario: Esc closes the list
    Given the list shows
    When I press Esc
    Then the list closes and the session is not interrupted
    And it stays closed until the text stops being a command name

  Scenario: Recalling a sent message
    Given I recalled an earlier message that starts with "/" with the up arrow
    Then no list shows and the arrows keep recalling messages

  # ── On the phone ────────────────────────────────────────────────────

  Scenario: A tap completes
    Given I typed "/catchu" in the phone's composer
    When I tap "/catchup" in the list
    Then the composer holds "/catchup " with the caret at the end

  # ── What the list holds ─────────────────────────────────────────────

  Scenario: The chat's own commands
    Given a Claude Code card
    Then the list starts with "/catchup" and "/btw", marked Kanban

  Scenario: The agent's commands
    Given a Claude Code card
    Then the list holds "/compact", "/clear" and the other commands of Claude Code that run when sent as a message

  Scenario: The user's skills and commands
    Given a skill "deploy" in the user's Claude Code skills folder
    And a command file "git/push.md" in the user's commands folder
    Then the list holds "/deploy" and "/git:push" with the descriptions of their frontmatter

  Scenario: A skill that is not for the user
    Given a skill whose frontmatter says "user-invocable: false"
    Then the list does not hold it

  Scenario: The project's skills and commands
    Given the session runs in a folder of a repository with ".claude/skills" and ".claude/commands"
    Then the list holds them, from the session's folder up to the repository root
    And a project skill wins over a user skill of the same name

  Scenario: Plugins
    Given a plugin "catalog" is installed and enabled, with a skill "audit"
    Then the list holds "/catalog:audit"
    And a plugin that is installed but not enabled adds nothing
    And a plugin installed for another project adds nothing

  Scenario: A session with its own configuration folder
    Given a rush card, whose Claude Code runs with the rush account's configuration folder
    Then skills, commands, plugins and settings are read from that folder, through its symlinks

  Scenario: Each name once
    Given a project skill named like one of the agent's commands
    Then the list holds that name once, with the project's description

  Scenario: Codex and Gemini cards
    Given a Codex or Gemini card
    Then the list holds that agent's commands and no side chat commands

  # ── Where the list comes from ───────────────────────────────────────

  Scenario: The list comes from the machine that owns the card
    Given a card that another master owns
    When I type "/" in its chat on the Mac or on the phone
    Then the list holds the skills on that master's disk

  Scenario: The owner is away
    Given a card whose master does not answer
    Then the list is the last one that master gave
    And with none, it holds the chat's and the agent's commands

  Scenario: The list is read again when it opens
    Given I added a skill since the chat last showed the list
    When I type "/" again half a minute later
    Then the new skill is in the list

  Scenario: The phone and a paired master may read the list
    Then a device with the full, agent or peer scope may call the route
    And a terminal-scope device is refused
