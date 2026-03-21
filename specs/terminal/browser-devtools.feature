Feature: Browser DevTools (Eruda)
  As a developer using the embedded browser tabs
  I want built-in developer tools (console, elements, network, sources)
  So that I can debug my web application without leaving Kanban Code

  Background:
    Given the Kanban Code application is running
    And a card exists with a browser tab open

  # ── DevTools Toggle ──
  #
  # A button in the browser navigation bar toggles the Eruda devtools
  # panel. Eruda renders as an in-page overlay inside the WKWebView,
  # providing Console, Elements, Network, and Sources inspection.

  Scenario: DevTools toggle button is visible in the browser navigation bar
    When I view the browser content area
    Then the navigation bar should contain a devtools toggle button
    And it should appear after the URL field (rightmost position)
    And it should use the "hammer.fill" SF Symbol
    And it should match the existing nav bar button styling (borderless, .app(.caption) font)
    And its tooltip should read "Toggle DevTools"

  Scenario: Opening DevTools via toggle button
    Given DevTools is not visible
    When I click the DevTools toggle button
    Then the Eruda panel should appear as an overlay at the bottom of the web page
    And the toggle button icon should highlight (accent color)
    And the panel should show tool tabs: Console, Elements, Network, Sources, Resources, Info

  Scenario: Closing DevTools via toggle button
    Given DevTools is visible (Eruda panel is shown)
    When I click the DevTools toggle button
    Then the Eruda panel should hide
    And the toggle button icon should return to secondary color
    And the web page should be fully visible again

  Scenario: DevTools toggle via keyboard shortcut
    Given a browser tab is selected
    When I press Cmd+Option+I
    Then DevTools should toggle (show if hidden, hide if shown)

  # ── Eruda Injection ──
  #
  # Eruda is bundled as eruda.min.js in the app resources and injected
  # into every page via WKUserScript at document end. The library is
  # initialized but hidden by default — the toggle button controls
  # visibility.

  Scenario: Eruda is injected into every page load
    When a browser tab navigates to any URL
    Then the eruda.min.js script should be injected into the page
    And eruda.init() should be called with shadow DOM enabled
    And the Eruda entry button (floating gear icon) should be hidden
    Because we use our own toggle button in the native nav bar instead

  Scenario: Eruda persists across in-page navigation
    Given DevTools is open showing console output
    When I navigate to a different page within the browser tab
    Then Eruda should be re-injected into the new page
    And DevTools should remain visible if it was visible before
    Because WKUserScript re-injects at document end on every navigation

  Scenario: Eruda loads from bundled resources (no network dependency)
    When the app is running without internet access
    And I open a browser tab to a local dev server
    Then Eruda should still load and function correctly
    Because the script is bundled in the app, not loaded from a CDN

  # ── Console Tab ──
  #
  # The Console tab captures all console output from the inspected
  # page and allows evaluating arbitrary JavaScript expressions.

  Scenario: Console shows page console.log output
    Given DevTools is open on the Console tab
    When the web page executes console.log("hello world")
    Then "hello world" should appear in the Eruda console panel

  Scenario: Console shows errors and warnings
    Given DevTools is open on the Console tab
    When the web page triggers:
      | Call                              | Expected display        |
      | console.warn("deprecation")       | Yellow warning entry    |
      | console.error("failed")           | Red error entry         |
      | uncaught TypeError                | Red error with stack    |
    Then each message should appear with appropriate color coding

  Scenario: Console allows JavaScript evaluation
    Given DevTools is open on the Console tab
    When I type "document.title" in the Eruda console input
    And press Enter
    Then the page title should be displayed as a result

  # ── Elements Tab ──

  Scenario: Elements tab shows DOM tree
    Given DevTools is open on the Elements tab
    Then the DOM tree of the current page should be displayed
    And I should be able to expand/collapse nodes
    And selecting a node should show its computed CSS styles

  # ── Network Tab ──

  Scenario: Network tab shows requests
    Given DevTools is open on the Network tab
    When the page makes HTTP requests (fetch, XHR, resource loads)
    Then each request should appear in the network list
    And I should see the URL, status code, and response time

  # ── Sources Tab ──

  Scenario: Sources tab shows page source
    Given DevTools is open on the Sources tab
    Then the HTML source of the current page should be viewable
    And JavaScript and CSS sources should be accessible

  # ── DevTools State ──
  #
  # DevTools visibility is per-tab state. Each browser tab remembers
  # whether devtools was open independently.

  Scenario: DevTools visibility is independent per browser tab
    Given I have browser tabs A and B
    And DevTools is open on tab A
    When I switch to tab B
    Then DevTools should not be visible on tab B
    When I switch back to tab A
    Then DevTools should still be visible on tab A

  Scenario: DevTools default state is hidden
    When I create a new browser tab
    Then DevTools should not be visible
    And the toggle button should show in secondary color (inactive)

  # ── Eruda Configuration ──

  Scenario: Eruda uses shadow DOM to avoid style conflicts
    When Eruda is initialized on a page
    Then it should use useShadowDom: true
    So that the page's CSS does not affect Eruda's UI
    And Eruda's CSS does not affect the page

  Scenario: Eruda default entry button is hidden
    When Eruda is initialized on a page
    Then the floating gear/entry button that Eruda normally shows should be hidden
    Because the native toggle button in the browser nav bar replaces it
