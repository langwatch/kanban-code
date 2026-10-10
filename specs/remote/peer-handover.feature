Feature: A card started on another master
  A card launched from one master on another is released to it. The other
  master finds the card's project on its own machine, then starts the card.

  Scenario: A project with a git remote
    Given a card of a project whose repository has an origin
    When it is launched on another master
    Then that master uses its clone of the origin, cloning it when it has none
    And starts the card there

  Scenario: A new project with no remote and no commits
    Given a card of a project whose repository has no origin and no commits
    When it is launched on another master
    Then that master makes a new repository of the same name in its projects folder
    And gives it a first commit, so the card can start in a worktree
    And adds it to its projects
    And starts the card there

  Scenario: A later card of that project
    Given the other master made a repository for a project with no remote
    When another card of the project is launched on it
    Then the card starts in that same repository

  Scenario: A project with commits and no remote
    Given a card of a project whose repository has commits and no origin
    When it is launched on another master
    Then that master does not start the card
    And the reason says the project has no git remote, so its files cannot follow

  Scenario: The other master cannot take the card
    Given a card launched or moved to another master
    When that master cannot adopt it for a reason another try would repeat
    Then it sends the card back to the master that released it
    And the card is owned there again, as it was before the launch
    And a card that never ran returns to the backlog
    And the card shows that the other master could not take it, with the reason
    And the other master stops trying to adopt it

  Scenario: The other master is not ready yet
    Given a card released to another master
    When the adoption fails for a reason that may pass, such as the releasing master being offline
    Then the card stays released
    And the other master tries again
