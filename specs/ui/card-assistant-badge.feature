Feature: Card Assistant Badge
  As a developer managing tasks across multiple assistants
  I want to see which assistant each card uses
  So that I can quickly identify card types on the board

  Background:
    Given the Kanban Code application is running

  # ── Badge Display ──

  Scenario: Card shows assistant icon
    Given a card with assistant "gemini"
    Then the card should display a Gemini icon/badge

  Scenario: Claude card shows Claude icon
    Given a card with assistant "claude"
    Then the card should display a Claude icon/badge

  Scenario: Codex card shows Codex icon
    Given a card with assistant "codex"
    Then the card should display a Codex icon/badge

  Scenario: Legacy card without assistant shows Claude icon
    Given an existing card with no assistant field (nil)
    Then the card should display a Claude icon/badge
    # effectiveAssistant defaults to claude

  Scenario: Badge is subtle
    Then the assistant badge should be a small icon
    And it should not dominate the card layout
    And it should be near the session/task label area

  # ── Card Detail View ──

  Scenario: Card detail shows assistant name
    Given a card with assistant "gemini" is selected
    When the card detail view is shown
    Then the assistant should be displayed as "Gemini CLI"

  Scenario: Card detail shows Codex assistant name
    Given a card with assistant "codex" is selected
    When the card detail view is shown
    Then the assistant should be displayed as "Codex CLI"

  Scenario: Card detail shows migration button
    Given a card with assistant "claude" and a session
    When the card detail view is shown
    Then migration buttons should be available for other installed assistants
