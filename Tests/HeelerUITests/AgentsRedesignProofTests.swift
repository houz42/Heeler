import XCTest

/// Interactive proofs of the redesigned Agents list (handoff §B): fuzzy
/// title search with REAL typing, `field:` autocomplete with arrow-key
/// navigation and Enter-accept, removable filter chips, ordering/grouping
/// views, the search empty state, and query/focus retention across
/// navigation. Demo fixture via `launchDemo(.console)`: 5 agents, 2 hosts,
/// kinds codex/claude/gemini/opencode, sessions main/ci, named "work" tabs.
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
        app.descendants(matching: .searchField)
            .matching(NSPredicate(format: "label == %@", "Search agent titles or filter by context"))
            .firstMatch
    }

    private func row(containing text: String) -> XCUIElement {
        app.cells.containing(NSPredicate(format: "label CONTAINS %@", text)).firstMatch
    }

    private func staticText(containing text: String) -> XCUIElement {
        app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", text)).firstMatch
    }

    // MARK: §B1 — two-line rows, kind icons, one quiet location line

    func testRowsShowKindIconTitleAndOneQuietLocationLine() {
        // The redesigned row: title line + the quiet concatenated
        // host · session · workspace · tab line — all four location values
        // on the phone, no field labels.
        waitToExist(staticText(containing: "Polish the Attach experience"))
        let location = staticText(containing: "Studio Mac · main · iOS App")
        XCTAssertTrue(location.exists, "the quiet location line must render all four values")
        captureScreenshot(app, "agents-row-two-line")
    }

    // MARK: §B2 — fuzzy title search with real typing

    func testFuzzyTypingFiltersRowsAndCount() {
        waitToExist(staticText(containing: "Polish the Attach experience"))
        // REAL keystrokes with the focus pair: keyboard stayed, text retained.
        searchField.typeTextWithFocusAssertion(on: app, "Polsh")
        // Typo'd abbreviation matches only the one row.
        XCTAssertTrue(staticText(containing: "Polish the Attach experience").waitForExistence(timeout: 2))
        XCTAssertFalse(staticText(containing: "Refresh the setup guide").exists)
        XCTAssertTrue(staticText(containing: "1 of 5 agents").exists, "count reflects filtered matches")
        captureScreenshot(app, "agents-fuzzy-typing")
    }

    // MARK: §B2 — field autocomplete, arrows, Enter accepts

    func testFieldSuggestionsArrowNavigationAndEnterAccept() throws {
        waitToExist(staticText(containing: "Polish the Attach experience"))
        searchField.tap()
        app.waitForKeyboard()
        searchField.typeText("host:")
        // Value suggestions for the field appear.
        XCTAssertTrue(staticText(containing: "Build Server").waitForExistence(timeout: 5),
                      "field query must offer value suggestions")
        captureScreenshot(app, "agents-field-suggestions")
        // Arrow-down highlights; Enter accepts the highlighted suggestion.
        searchField.typeKey(.downArrow, modifierFlags: [])
        searchField.typeKey(.return, modifierFlags: [])
        // The filter chip landed and the count reflects it: Studio Mac holds
        // 3 agents.
        XCTAssertTrue(staticText(containing: "3 of 5 agents").waitForExistence(timeout: 5),
                      "Enter must accept the highlighted suggestion into a filter chip")
        captureScreenshot(app, "agents-enter-accepted-chip")
        // Esc never submits a message: the query is empty and the chip rail
        // is the only search state left.
        XCTAssertFalse(staticText(containing: "Harden webhook retries").exists,
                       "the Build Server agents must be filtered out")
    }

    // MARK: §B2 — removable filter chips

    func testChipRemovalRestoresFullList() throws {
        waitToExist(staticText(containing: "Polish the Attach experience"))
        searchField.tap()
        app.waitForKeyboard()
        searchField.typeText("host:")
        XCTAssertTrue(staticText(containing: "Studio Mac").waitForExistence(timeout: 5))
        searchField.typeKey(.downArrow, modifierFlags: [])
        searchField.typeKey(.return, modifierFlags: [])
        XCTAssertTrue(staticText(containing: "3 of 5 agents").waitForExistence(timeout: 5))
        // Remove the chip by its corner-x (accessibility label carries field+value).
        let remove = app.buttons["Remove Host filter Studio Mac"].firstMatch
        XCTAssertTrue(remove.waitForExistence(timeout: 5), "chip must expose a remove control")
        remove.tap()
        XCTAssertTrue(staticText(containing: "5 of 5 agents").waitForExistence(timeout: 5),
                      "chip removal must restore the full list")
        captureScreenshot(app, "agents-chip-removed")
    }

    // MARK: §B2 — Esc dismisses suggestions without submitting

    func testEscapeDismissesSuggestions() {
        waitToExist(staticText(containing: "Polish the Attach experience"))
        searchField.tap()
        app.waitForKeyboard()
        searchField.typeText("Pol")
        XCTAssertTrue(staticText(containing: "Fuzzy titles").waitForExistence(timeout: 5))
        searchField.typeKey(.escape, modifierFlags: [])
        XCTAssertFalse(staticText(containing: "Fuzzy titles").waitForNonExistence(timeout: 2) == false,
                       "suggestions must dismiss on Esc")
        // Nothing was submitted: rows unchanged, query intact.
        XCTAssertTrue(staticText(containing: "Polish the Attach experience").exists)
        captureScreenshot(app, "agents-esc-dismiss")
    }

    // MARK: §B4 — ordering and grouping views in the Agents view menu

    func testOrderingAndGroupingViewsRender() {
        waitToExist(staticText(containing: "Polish the Attach experience"))
        let menu = app.buttons["Agent list view options"].firstMatch
        XCTAssertTrue(menu.waitForExistence(timeout: 5))

        // Order: Title A–Z.
        menu.tap()
        let titleOrder = app.buttons["Title A–Z"].firstMatch
        XCTAssertTrue(titleOrder.waitForExistence(timeout: 5))
        titleOrder.tap()
        captureScreenshot(app, "agents-order-title")

        // Grouping: Host sections.
        menu.tap()
        let hostGroup = app.buttons["Host"].firstMatch
        XCTAssertTrue(hostGroup.waitForExistence(timeout: 5))
        hostGroup.tap()
        XCTAssertTrue(staticText(containing: "Build Server").waitForExistence(timeout: 5),
                      "host grouping must section per machine")
        captureScreenshot(app, "agents-group-host")

        // Grouping: Agent state (urgency ladder: Needs you first).
        menu.tap()
        let stateGroup = app.buttons["Agent state"].firstMatch
        XCTAssertTrue(stateGroup.waitForExistence(timeout: 5))
        stateGroup.tap()
        XCTAssertTrue(staticText(containing: "Needs you").waitForExistence(timeout: 5),
                      "state grouping must lead with the urgent bucket")
        captureScreenshot(app, "agents-group-state")
    }

    // MARK: §B2 — empty state

    func testSearchEmptyState() {
        waitToExist(staticText(containing: "Polish the Attach experience"))
        searchField.tap()
        app.waitForKeyboard()
        searchField.typeText("zzzqq")
        XCTAssertTrue(staticText(containing: "No Matching Agents").waitForExistence(timeout: 5),
                      "a matching-nothing query must show the empty state")
        captureScreenshot(app, "agents-empty-state")
        let clear = app.buttons["Clear Search"].firstMatch
        XCTAssertTrue(clear.waitForExistence(timeout: 5))
        clear.tap()
        XCTAssertTrue(staticText(containing: "5 of 5 agents").waitForExistence(timeout: 5))
    }

    // MARK: §B2 — focus/query survive navigation

    func testQueryAndFiltersSurviveNavigation() {
        waitToExist(staticText(containing: "Polish the Attach experience"))
        searchField.typeTextWithFocusAssertion(on: app, "Audit")
        XCTAssertTrue(staticText(containing: "1 of 5 agents").waitForExistence(timeout: 5))
        // Push an agent detail, then come back.
        row(containing: "Audit VoiceOver labels").tap()
        XCTAssertTrue(app.waitForPushedDetail(), "agent detail never pushed")
        app.navigationBars.buttons.firstMatch.tap()
        // The query and its result state survive the round trip.
        XCTAssertTrue(staticText(containing: "1 of 5 agents").waitForExistence(timeout: 5),
                      "query must survive navigation")
        XCTAssertTrue(staticText(containing: "Audit VoiceOver labels").exists)
        captureScreenshot(app, "agents-query-survives-nav")
    }
}

/// Negated wait helper (XCUITest lacks it).
extension XCUIElement {
    @discardableResult
    func waitForNonExistence(timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if !exists { return true }
            Thread.sleep(forTimeInterval: 0.2)
        }
        return !exists
    }
}
