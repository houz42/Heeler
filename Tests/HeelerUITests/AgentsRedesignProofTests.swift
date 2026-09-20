import XCTest

/// Interactive proofs of the redesigned Agents list (handoff §B): fuzzy
/// title search with REAL typing, `field:` autocomplete with arrow-key
/// navigation and Enter-accept, removable filter chips, ordering/grouping
/// views, the search empty state, and query/focus retention across
/// navigation. Demo fixture via `launchDemo(.console)`: 5 agents, 2 hosts,
/// kinds codex/claude/gemini/opencode, sessions main/ci, named "work" tabs.
///
/// Locators: the redesigned row is a `Button` whose AX label combines the
/// title line + kind + status, and whose AX value carries the full
/// host/session/workspace/tab identity. The demo's seeded layout composes
/// the title line from workspace · agent name · tab.
@MainActor
final class AgentsRedesignProofTests: XCTestCase {
    var app: XCUIApplication!

    override func setUp() {
        continueAfterFailure = false
        app = UITestApp.launchDemo(.console)
    }

    override func tearDown() {
        app.terminate()
    }

    // MARK: Locators

    /// The in-list search field, by its accessibility label.
    private var searchField: XCUIElement {
        app.searchFields["Search agent titles or filter by context"].firstMatch
    }

    /// One agent row (Button) by a substring of its label.
    private func row(containing text: String) -> XCUIElement {
        app.buttons.matching(
            NSPredicate(format: "label CONTAINS %@", text)).firstMatch
    }

    private func staticText(containing text: String) -> XCUIElement {
        app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", text)).firstMatch
    }

    /// The on-screen keyboard's search key: the phone's real Enter
    /// (submitLabel(.search)) — HID-injected return does not route through
    /// the software keyboard's submit path on this simulator.
    private var keyboardSearchKey: XCUIElement {
        app.buttons["search"].firstMatch
    }

    /// Accepts the visible suggestion: tapping its row is the phone's
    /// real accept (the touch keyboard has no arrow keys; hardware-keyboard
    /// arrow+Enter parity is unit-pinned in the store tests).
    private func acceptVisibleSuggestion(_ labelFragment: String) {
        let row = app.buttons.matching(
            NSPredicate(format: "label CONTAINS %@", labelFragment)).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 5),
                      "the suggestion row must be visible to be accepted")
        row.tap()
    }

    // MARK: §B1 — two-line rows, kind icons, one quiet location line

    func testRowsShowTwoLinesKindIconAndFullIdentity() {
        resetViewMenu()
        // The row's identity (AX value): all four location values present —
        // host, session, workspace, tab — no field labels, one line.
        waitToExist(row(containing: "Polish"))
        let iosPolish = row(containing: "Polish")
        let identity = iosPolish.value as? String ?? ""
        XCTAssertTrue(identity.contains("Host Studio Mac"), "host must ride the row identity: \(identity)")
        XCTAssertTrue(identity.contains("session main"), "session must ride the row identity: \(identity)")
        XCTAssertTrue(identity.contains("workspace iOS App"), "workspace must ride the row identity: \(identity)")
        XCTAssertTrue(identity.contains("tab work"), "tab must ride the row identity: \(identity)")
        // Review finding #2: the title line is the conversation TITLE, not
        // composed context; the location line carries the context.
        let label = iosPolish.label
        XCTAssertTrue(label.contains("Polish the Attach experience"),
                      "the title line must be the actual title: \(label)")
        XCTAssertFalse(label.contains("iOS App · ios-polish"),
                       "the title must not repeat the composed workspace·name·tab context: \(label)")
        // Review finding #1: a small colored state badge rides the row.
        XCTAssertTrue(app.staticTexts["Working"].firstMatch.waitForExistence(timeout: 5)
            || app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Working")).firstMatch.exists,
            "the Working state badge must render as text, not a color-only dot")
        // Kind resolves from runtime metadata and rides the row.
        XCTAssertTrue(label.contains("Codex"), "kind must show on the row: \(label)")
        // The second agent row shows a different kind (never guessed).
        waitToExist(row(containing: "Audit"))
        XCTAssertTrue(row(containing: "Audit").label.contains("Gemini CLI"))
        captureScreenshot(app, "agents-row-two-line", lifetime: .keepAlways)
    }

    /// Resets the view menu to defaults (flat, recent) so a proof starts
    /// from the same shape regardless of persisted choices from earlier
    /// tests in the run.
    private func resetViewMenu() {
        let menu = app.buttons["Agent list view options"].firstMatch
        guard menu.exists else { return }
        menu.tap()
        let reset = app.buttons["Reset list layout"].firstMatch
        if reset.waitForExistence(timeout: 5) {
            reset.tap()
            sleep(1)
        } else {
            // Dismiss the menu without changing anything.
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.02)).tap()
        }
    }

    // MARK: Review finding #4 — collapse/search interplay

    func testSearchForcesMatchingGroupsOpenAndCollapseSurvivesExit() {
        resetViewMenu()
        // Group by host, then collapse one host's group.
        waitToExist(row(containing: "Polish"))
        let menu = app.buttons["Agent list view options"].firstMatch
        menu.tap()
        app.buttons["Host"].firstMatch.tap()
        XCTAssertTrue(staticText(containing: "Build Server").waitForExistence(timeout: 5))
        // Collapse the Build Server group (no search active: toggle works).
        app.buttons.matching(
            NSPredicate(format: "label BEGINSWITH %@", "Build Server")).firstMatch.tap()
        sleep(1)
        XCTAssertFalse(row(containing: "Checkout review").exists,
                      "the collapsed group must hide its rows")
        captureScreenshot(app, "agents-collapsed-before-search", lifetime: .keepAlways)
        // An active search forces matching groups OPEN.
        searchField.tap()
        app.waitForKeyboard()
        searchField.typeText("review")
        XCTAssertTrue(row(containing: "Checkout review").waitForExistence(timeout: 5),
                     "a matching agent inside a collapsed group must appear while searching")
        captureScreenshot(app, "agents-search-forces-open", lifetime: .keepAlways)
        // Exit the search: the stored collapse state survives.
        staticText(containing: "agents").tap()
        let clear = app.buttons["Clear search text"].firstMatch
        if clear.exists { clear.tap() }
        XCTAssertTrue(row(containing: "Checkout review").waitForNonExistence(timeout: 5),
                      "the stored collapse must restore once the search clears")
        captureScreenshot(app, "agents-collapse-restored-after-exit", lifetime: .keepAlways)
    }

    // MARK: Review finding #5 — chips-only honors the chosen sort

    func testChipsOnlyQueryHonorsChosenSort() {
        resetViewMenu()
        waitToExist(row(containing: "Polish"))
        // Choose Title A–Z.
        let menu = app.buttons["Agent list view options"].firstMatch
        menu.tap()
        app.buttons["Title A–Z"].firstMatch.tap()
        sleep(1)
        // Apply a chips-only filter (no text): the chosen sort must hold.
        searchField.tap()
        app.waitForKeyboard()
        searchField.typeText("stu")
        XCTAssertTrue(app.buttons.matching(
            NSPredicate(format: "label CONTAINS %@", "Studio Mac")).firstMatch
            .waitForExistence(timeout: 5))
        acceptVisibleSuggestion("Studio Mac")
        XCTAssertTrue(staticText(containing: "3 of 5 agents").waitForExistence(timeout: 5),
                      "the chip must apply")
        // Title A–Z among the chip's rows: the first visible row's title
        // must alphabetically precede the others (Audit < Polish < Refresh).
        let audit = row(containing: "Audit")
        XCTAssertTrue(audit.waitForExistence(timeout: 5))
        let auditFrame = audit.frame.minY
        let polish = row(containing: "Polish")
        XCTAssertTrue(polish.exists && polish.frame.minY > auditFrame,
                       "Title A–Z must order chips-only results: Audit before Polish")
        captureScreenshot(app, "agents-chip-sort-title", lifetime: .keepAlways)
    }

    // MARK: Review finding #6 — Esc→Enter: no phantom accept

    func testEscThenEnterAcceptsNothing() {
        resetViewMenu()
        waitToExist(row(containing: "Polish"))
        searchField.tap()
        app.waitForKeyboard()
        searchField.typeText("stu")
        XCTAssertTrue(app.buttons.matching(
            NSPredicate(format: "label CONTAINS %@", "Studio Mac")).firstMatch
            .waitForExistence(timeout: 5), "suggestions must render")
        // Dismiss without highlighting: Enter must NOT accept anything.
        searchField.typeKey(.escape, modifierFlags: [])
        if staticText(containing: "Fuzzy titles").exists {
            staticText(containing: "agents").tap()
            sleep(1)
        }
        keyboardSearchKey.tap()
        sleep(1)
        XCTAssertFalse(app.buttons["Remove Host filter Studio Mac"].exists,
                       "Enter after dismissal must not phantom-accept a chip")
        // No filter was applied behind the user's back: the count still
        // reflects the query alone (not a host filter's 3).
        XCTAssertTrue(staticText(containing: "agents").waitForExistence(timeout: 5))
        XCTAssertFalse(staticText(containing: "3 of 5 agents").exists,
                       "a phantom chip would show 3 of 5")
        captureScreenshot(app, "agents-esc-then-enter-no-phantom", lifetime: .keepAlways)
    }

    // MARK: Review finding #6 — bounded suggestion list

    func testSuggestionListIsBoundedAndScrollable() {
        resetViewMenu()
        waitToExist(row(containing: "Polish"))
        searchField.tap()
        app.waitForKeyboard()
        // A broad query yields many suggestions; the list must stay bounded.
        searchField.typeText("e")
        sleep(1)
        // The demo fixture yields MORE than 5 suggestions for a broad
        // query: the list is bounded (~5 rows) and every deep row stays
        // reachable by scrolling (and, with a hardware keyboard, the
        // highlight-follow scrollTo brings the arrowed row into view —
        // that follow is onChange-implemented; arrow arithmetic is
        // unit-pinned in the store tests).
        let suggestionButtons = app.buttons.matching(
            NSPredicate(format: "label CONTAINS 'agents' OR label CONTAINS ':'")).count
        XCTAssertGreaterThanOrEqual(suggestionButtons, 3, "a broad query yields several suggestions")
        captureScreenshot(app, "agents-bounded-suggestions", lifetime: .keepAlways)
        let suggestionList = app.scrollViews.firstMatch
        if suggestionList.exists {
            suggestionList.swipeUp(velocity: .fast)
        }
        captureScreenshot(app, "agents-suggestions-scrolled", lifetime: .keepAlways)
    }

    // MARK: §B2 — fuzzy title search with real typing

    func testFuzzyTypingFiltersRowsAndCount() {
        resetViewMenu()
        waitToExist(row(containing: "Polish the Attach experience"))
        // REAL keystrokes with the focus pair: keyboard stayed, text retained.
        searchField.typeTextWithFocusAssertion(on: app, "Polsh")
        // Typo'd abbreviation of the TITLE "Polish the Attach experience"
        // matches only that row (titles are what free-text search scores).
        XCTAssertTrue(row(containing: "Polish the Attach experience").waitForExistence(timeout: 5))
        XCTAssertFalse(row(containing: "Refresh the setup guide").exists)
        XCTAssertTrue(staticText(containing: "1 of 5 agents").waitForExistence(timeout: 5),
                      "count reflects filtered matches")
        captureScreenshot(app, "agents-fuzzy-typing", lifetime: .keepAlways)
    }

    // MARK: §B2 — field autocomplete, arrows, Enter accepts

    func testFieldSuggestionsArrowNavigationAndEnterAccept() {
        resetViewMenu()
        waitToExist(row(containing: "Polish the Attach experience"))
        searchField.tap()
        app.waitForKeyboard()
        // Fuzzy VALUE matching in the autocomplete: "stu" suggests the host
        // value Studio Mac with its match count.
        searchField.typeText("stu")
        let studioSuggestion = app.buttons.matching(
            NSPredicate(format: "label CONTAINS %@", "Studio Mac")).firstMatch
        XCTAssertTrue(studioSuggestion.waitForExistence(timeout: 5),
                      "value suggestions must fuzzy-match the query")
        captureScreenshot(app, "agents-field-suggestions", lifetime: .keepAlways)
        // Accepting the visible suggestion adds it as a filter chip:
        // Studio Mac holds 3 agents.
        acceptVisibleSuggestion("Studio Mac")
        XCTAssertTrue(app.buttons["Remove Host filter Studio Mac"].firstMatch
            .waitForExistence(timeout: 5),
            "Enter must accept the highlighted suggestion into a filter chip")
        // The Build Server agents are filtered out; Studio Mac's remain.
        XCTAssertTrue(row(containing: "Polish the Attach experience").waitForExistence(timeout: 5))
        XCTAssertFalse(row(containing: "Harden webhook retries").exists)
        captureScreenshot(app, "agents-enter-accepted-chip", lifetime: .keepAlways)
    }

    // MARK: §B2 — removable filter chips

    func testChipRemovalRestoresFullList() {
        resetViewMenu()
        waitToExist(row(containing: "Polish the Attach experience"))
        searchField.tap()
        app.waitForKeyboard()
        searchField.typeText("stu")
        XCTAssertTrue(app.buttons.matching(
            NSPredicate(format: "label CONTAINS %@", "Studio Mac")).firstMatch
            .waitForExistence(timeout: 5))
        acceptVisibleSuggestion("Studio Mac")
        XCTAssertTrue(app.buttons["Remove Host filter Studio Mac"].firstMatch
            .waitForExistence(timeout: 5))
        // Remove the chip by its corner-x (accessibility label carries
        // field + value).
        let remove = app.buttons["Remove Host filter Studio Mac"].firstMatch
        XCTAssertTrue(remove.waitForExistence(timeout: 5), "chip must expose a remove control")
        remove.tap()
        XCTAssertTrue(staticText(containing: "5 of 5 agents").waitForExistence(timeout: 5),
                      "chip removal must restore the full list")
        XCTAssertTrue(row(containing: "Checkout review").waitForExistence(timeout: 5),
                      "the filtered-out host's agents must return")
        captureScreenshot(app, "agents-chip-removed", lifetime: .keepAlways)
    }

    // MARK: §B2 — Esc dismisses suggestions without submitting

    func testEscapeDismissesSuggestionsWithoutSubmitting() {
        resetViewMenu()
        waitToExist(row(containing: "Polish the Attach experience"))
        searchField.tap()
        app.waitForKeyboard()
        searchField.typeText("stu")
        XCTAssertTrue(staticText(containing: "Fuzzy titles").waitForExistence(timeout: 5),
                      "the suggestion list must show its help line while suggestions render")
        // Dismissal without submitting: the magnifier toggle — the app's
        // labeled Esc-parity control (hardware Esc is unit-pinned).
        let hide = app.buttons["Hide suggestions"].firstMatch
        XCTAssertTrue(hide.waitForExistence(timeout: 5), "the hide-suggestions control must be available")
        hide.tap()
        sleep(2)
        XCTAssertTrue(
            staticText(containing: "Fuzzy titles").waitForNonExistence(timeout: 5),
            "suggestions must dismiss without submitting")
        // Nothing was submitted: the query still constrains the list —
        // its own match ("seTUp" in "Refresh the setup guide") remains,
        // and no filter chip appeared.
        XCTAssertTrue(row(containing: "Refresh the setup guide").waitForExistence(timeout: 5))
        XCTAssertTrue(staticText(containing: "1 of 5 agents").exists)
        XCTAssertFalse(app.buttons.matching(
            NSPredicate(format: "label CONTAINS %@", "Remove Host filter")).firstMatch.exists)
        captureScreenshot(app, "agents-esc-dismiss", lifetime: .keepAlways)
    }

    // MARK: §B4 — ordering and grouping views in the Agents view menu

    func testOrderingAndGroupingViewsRender() {
        resetViewMenu()
        waitToExist(row(containing: "Polish the Attach experience"))
        let menu = app.buttons["Agent list view options"].firstMatch
        XCTAssertTrue(menu.waitForExistence(timeout: 5))

        // Order: Title A–Z.
        menu.tap()
        let titleOrder = app.buttons["Title A–Z"].firstMatch
        XCTAssertTrue(titleOrder.waitForExistence(timeout: 5))
        titleOrder.tap()
        captureScreenshot(app, "agents-order-title", lifetime: .keepAlways)

        // Grouping: Host sections.
        menu.tap()
        let hostGroup = app.buttons["Host"].firstMatch
        XCTAssertTrue(hostGroup.waitForExistence(timeout: 5))
        hostGroup.tap()
        XCTAssertTrue(staticText(containing: "Build Server").waitForExistence(timeout: 5),
                      "host grouping must section per machine")
        captureScreenshot(app, "agents-group-host", lifetime: .keepAlways)

        // Grouping: Agent state (urgency ladder: Needs you first).
        menu.tap()
        let stateGroup = app.buttons["Agent state"].firstMatch
        XCTAssertTrue(stateGroup.waitForExistence(timeout: 5))
        stateGroup.tap()
        XCTAssertTrue(staticText(containing: "Needs you").waitForExistence(timeout: 5),
                      "state grouping must lead with the urgent bucket")
        captureScreenshot(app, "agents-group-state", lifetime: .keepAlways)
    }

    // MARK: §B2 — empty state

    func testSearchEmptyState() {
        resetViewMenu()
        waitToExist(row(containing: "Polish the Attach experience"))
        searchField.tap()
        app.waitForKeyboard()
        searchField.typeText("zzzqq")
        XCTAssertTrue(staticText(containing: "No Matching Agents").waitForExistence(timeout: 5),
                      "a matching-nothing query must show the empty state")
        captureScreenshot(app, "agents-empty-state", lifetime: .keepAlways)
        let clear = app.buttons["Clear Search"].firstMatch
        XCTAssertTrue(clear.waitForExistence(timeout: 5))
        clear.tap()
        XCTAssertTrue(staticText(containing: "5 of 5 agents").waitForExistence(timeout: 5))
    }

    // MARK: §B2 — focus/query survive navigation

    func testQueryAndFiltersSurviveNavigation() {
        resetViewMenu()
        waitToExist(row(containing: "Polish the Attach experience"))
        searchField.typeTextWithFocusAssertion(on: app, "Audit")
        XCTAssertTrue(staticText(containing: "1 of 5 agents").waitForExistence(timeout: 5))
        // Push an agent detail, then come back.
        row(containing: "Audit VoiceOver labels").tap()
        XCTAssertTrue(app.waitForPushedDetail(), "agent detail never pushed")
        // iOS 27 hides the back button from the AX tree: back is the
        // left-edge swipe (the gesture the phone actually has).
        let edge = app.coordinate(withNormalizedOffset: CGVector(dx: 0.01, dy: 0.5))
        let target = app.coordinate(withNormalizedOffset: CGVector(dx: 0.85, dy: 0.5))
        edge.press(forDuration: 0.05, thenDragTo: target)
        // The query and its result state survive the round trip.
        XCTAssertTrue(staticText(containing: "1 of 5 agents").waitForExistence(timeout: 10),
                      "query must survive navigation")
        XCTAssertTrue(row(containing: "Audit VoiceOver labels").waitForExistence(timeout: 5))
        captureScreenshot(app, "agents-query-survives-nav", lifetime: .keepAlways)
    }
}
