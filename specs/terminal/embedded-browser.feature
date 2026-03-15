Feature: Embedded Browser Tab
  As a developer viewing sessions on the Kanban Code board
  I want to open in-app browser tabs alongside terminal tabs
  So that I can view web UIs (local dev servers, docs) without leaving the app

  Background:
    Given the Kanban Code application is running
    And a card exists with a tmuxLink (terminal tab bar is visible)

  # ── Globe Button ──
  #
  # A globe button sits next to the existing terminal button in the
  # terminal tab bar. It creates ephemeral browser tabs that live
  # in the same capsule as terminal tabs.

  Scenario: Globe button is visible next to the terminal button
    When I view the terminal tab bar
    Then a globe icon button should appear immediately after the terminal button (terminal)
    And it should use the "globe" SF Symbol
    And it should match the terminal button styling (borderless, .app(.caption) font)
    And its tooltip should read "Open new browser tab"

  Scenario: Creating a browser tab via globe button
    When I click the globe button
    Then a new browser tab should appear in the tab capsule
    And it should be automatically selected
    And the content area should show the browser view
    And the browser should navigate to "http://localhost:5560/" by default

  Scenario: Creating multiple browser tabs
    Given I already have one browser tab open
    When I click the globe button again
    Then a second browser tab should appear in the capsule
    And it should be selected (switching away from the first browser tab)
    And both browser tabs should be independently navigable

  # ── Browser Tab in Capsule ──
  #
  # Browser tabs render inside the same capsule as terminal tabs,
  # after shell sessions. They follow the same visual pattern:
  # icon + truncated label, selected/hover background, close on hover.

  Scenario: Browser tab appears in the tab capsule
    Given I have terminal tabs "Claude Code" and "langwatch"
    When I create a browser tab
    Then the tab bar should show: Claude Code | langwatch | 🌐 New Tab | 🖥 🌐
    And the browser tab should use the "globe" SF Symbol (not "terminal")
    And the tab label should be "New Tab" initially

  Scenario: Browser tab shows page title after navigation
    Given I have a browser tab open
    When the page finishes loading with title "Dashboard — MyApp"
    Then the browser tab label should update to "Dashboard —"
    And the label should be truncated to 12 characters

  Scenario: Browser tab selected state matches terminal tab styling
    Given I have a browser tab that is selected
    Then it should show the same capsule background + shadow as selected terminal tabs
    And when I hover an unselected browser tab
    Then it should show the same light fill as hovered terminal tabs

  Scenario: Switching between terminal and browser tabs
    Given I have terminal tab "Claude Code" and browser tab "New Tab"
    When I click on the browser tab
    Then the content area should show the browser view
    And the terminal view should be hidden (opacity 0)
    When I click on "Claude Code"
    Then the content area should show the terminal
    And the browser view should be hidden
    And the browser should preserve its page state (not reload)

  # ── Browser Tab Close ──

  Scenario: Close button appears on browser tab hover
    Given I have a browser tab
    When I hover over the browser tab
    Then an "xmark" close button should appear on the left side
    And it should match the shell tab close button styling (8pt bold, 14x14 circle)

  Scenario: Closing a browser tab
    Given I have a browser tab that is currently selected
    When I click the close button on the browser tab
    Then the browser tab should be removed from the capsule
    And selection should fall back to the last terminal tab or Claude tab
    And the WKWebView should be deallocated

  Scenario: Closing browser tab when another browser tab exists
    Given I have two browser tabs "Dashboard" and "Docs"
    And "Docs" is selected
    When I close "Docs"
    Then "Dashboard" should become selected

  Scenario: Closing the only browser tab
    Given I have one browser tab and terminal tabs
    When I close the browser tab
    Then the Claude tab should become selected
    And the terminal content should be shown

  # ── Browser Content View ──
  #
  # The browser content area has a compact navigation bar at top
  # and a WKWebView filling the remaining space.

  Scenario: Browser navigation bar layout
    Given a browser tab is selected
    Then the content area should show a navigation bar at the top
    And the navigation bar should contain (left to right):
      | Element        | Icon/Type         | Behavior                        |
      | Back button    | chevron.left      | Navigates back in history       |
      | Forward button | chevron.right     | Navigates forward in history    |
      | Reload button  | arrow.clockwise   | Reloads the current page        |
      | URL field      | TextField         | Shows current URL, editable     |
    And the navigation bar should be compact (~28pt height)
    And it should use .app(.caption) font for buttons

  Scenario: Back and forward buttons reflect navigation state
    Given a browser tab is showing "http://localhost:5560/"
    Then the back button should be disabled (opacity 0.4)
    And the forward button should be disabled (opacity 0.4)
    When I navigate to "http://localhost:5560/settings"
    Then the back button should become enabled
    And the forward button should remain disabled
    When I click the back button
    Then the browser should navigate to "http://localhost:5560/"
    And the forward button should become enabled

  Scenario: Reload and stop button toggle
    Given a browser tab is idle (not loading)
    Then the reload button should show "arrow.clockwise"
    When a page is loading
    Then the button should switch to "xmark" (stop)
    And clicking it should stop the page load

  Scenario: URL field shows current URL
    Given a browser tab has navigated to "http://localhost:5560/dashboard"
    Then the URL field should display "http://localhost:5560/dashboard"
    When I click the URL field
    Then the full URL text should be selected for easy replacement

  Scenario: Navigating via URL field
    Given a browser tab is showing any page
    When I click the URL field and type "http://localhost:3000"
    And press Enter
    Then the browser should navigate to "http://localhost:3000"
    And the URL field should update to the final URL (after redirects)

  Scenario: Smart URL detection
    Given I type in the URL field
    When the input looks like a URL (contains "." or starts with "http"/"localhost"):
      | Input                        | Navigates to                          |
      | http://localhost:3000         | http://localhost:3000                  |
      | localhost:8080               | http://localhost:8080                  |
      | example.com                  | https://example.com                   |
    Then the browser should navigate to the resolved URL

  Scenario: Loading progress indicator
    When a page is loading
    Then a thin accent-colored progress bar should appear below the navigation bar
    And its width should reflect the estimated loading progress
    When the page finishes loading
    Then the progress bar should fade out

  # ── WKWebView Configuration ──

  Scenario: WebView is properly configured
    When a browser tab is created
    Then the WKWebView should be configured with:
      | Setting                          | Value                              |
      | JavaScript                       | enabled                            |
      | developerExtrasEnabled           | true                               |
      | allowsBackForwardNavigationGestures | true                            |
      | isInspectable                    | true                               |
      | processPool                      | shared across all browser tabs     |
    And the WebView should use the default website data store (persistent cookies)

  Scenario: Multiple browser tabs share cookies and storage
    Given I log into a web app in browser tab A
    When I open browser tab B and navigate to the same app
    Then I should be logged in (cookies shared via shared WKProcessPool)

  # ── WebView Integration ──
  #
  # The WKWebView is embedded via NSViewRepresentable, following the
  # same pattern as TerminalContainerView. WebViews are preserved
  # when switching tabs to avoid reload.

  Scenario: WebView fills content area below navigation bar
    Given a browser tab is selected
    Then the WKWebView should fill all available space below the navigation bar
    And it should resize when the window or detail panel resizes

  Scenario: WebView preserves state when switching tabs
    Given browser tab A is showing "http://localhost:5560/page1" with scroll position
    When I switch to terminal tab "Claude Code"
    And switch back to browser tab A
    Then the page should still show "http://localhost:5560/page1"
    And the scroll position should be preserved
    And the page should not reload

  Scenario: WebView handles page crashes gracefully
    Given a browser tab's WKWebView web content process terminates
    Then the browser tab should show an error state
    And the user should be able to click reload to recover

  # ── No-Session Placeholder ──

  Scenario: Browser button in no-session placeholder
    Given a card has no tmuxLink and no sessionLink
    When I view the terminal tab
    Then the placeholder should show two buttons:
      | Button          | Icon     | Style   |
      | New Terminal    | terminal | bordered |
      | New Browser     | globe    | bordered |
    When I click "New Browser"
    Then a browser tab should be created
    And the tab bar should appear with the browser tab

  # ── Ephemeral State ──

  Scenario: Browser tabs do not persist across app restarts
    Given I have two browser tabs open
    When I quit and relaunch Kanban Code
    Then the browser tabs should not be restored
    And the terminal tab bar should show only terminal tabs
    Because browser state is ephemeral (not stored in links.json)

  Scenario: Browser tabs do not affect store or reducer
    When I create, switch, or close browser tabs
    Then no actions should be dispatched to the BoardStore
    And links.json should not be modified
    Because browser state is managed as @State in the view layer

  # ── Keyboard and Interaction ──

  Scenario: Swipe navigation gestures
    Given a browser tab has navigation history
    When I swipe left with two fingers on the WebView
    Then the browser should navigate back
    When I swipe right with two fingers
    Then the browser should navigate forward
    Because allowsBackForwardNavigationGestures is enabled

  Scenario: WebView supports standard web interactions
    Given a browser tab is showing a web page
    Then the following interactions should work:
      | Interaction        | Expected behavior                    |
      | Click links        | Navigate within the WebView          |
      | Form input         | Type in text fields, submit forms    |
      | Scroll             | Smooth scroll within the page        |
      | Cmd+C / Cmd+V      | Copy/paste within the WebView        |
      | Right-click        | Show default WebKit context menu     |
      | Pinch to zoom      | Zoom the web content                 |
