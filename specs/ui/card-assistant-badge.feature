Feature: Card Assistant Badge
  As a developer managing tasks across multiple assistants
  I want to see which assistant each card uses
  So that I can quickly identify card types on the board

  Background:
    Given the Kanban Code application is running

  # ── Badge Display ──

  @integration
  Scenario: Card shows Gemini icon
    Given a card with assistant "gemini"
    Then the card should display a Gemini icon/badge

  @integration
  Scenario: Claude card shows Claude icon
    Given a card with assistant "claude"
    Then the card should display a Claude icon/badge

  @integration
  Scenario: Mastra Code card shows Mastra icon
    Given a card with assistant "mastracode"
    Then the card should display a Mastra Code icon/badge

  @integration
  Scenario: Legacy card without assistant shows Claude icon
    Given an existing card with no assistant field (nil)
    Then the card should display a Claude icon/badge

  @integration
  Scenario: Badge is subtle
    Then the assistant badge should be a small icon
    And it should not dominate the card layout
    And it should be near the session/task label area

  # ── Card Detail View ──

  @integration
  Scenario: Card detail shows assistant name
    Given a card with assistant "mastracode" is selected
    When the card detail view is shown
    Then the assistant should be displayed as "Mastra Code"

  @integration
  Scenario: Card detail shows migration targets
    Given a card with assistant "claude" and a session
    When the card detail view is shown
    Then a migration menu should be available for each other enabled assistant
    And it should include "Gemini CLI"
    And it should include "Mastra Code"
