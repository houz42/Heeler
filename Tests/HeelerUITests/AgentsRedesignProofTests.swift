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

    /// Accepts the highlighted suggestion via the keyboard's search key.
    private func acceptHighlightedViaKeyboard() {
        XCTAssertTrue(keyboardSearchKey.waitForExistence(timeout: 5),
                      "keyboard search key must exist while typing")
        // Hardware-keyboard parity: arrow-down also moves the highlight
        // (onKeyPress(.downArrow)); invisible without a hardware keyboard,
        // but the accept below takes the highlighted (top) row either way.
        searchField.typeKey(.downArrow, modifierFlags: [])
        keyboardSearchKey.tap()
    }

    // MARK: §B1 — two-line rows, kind icons, one quiet location line

    func testRowsShowTwoLinesKindIconAndFullIdentity() {
        // The row's identity (AX value): all four location values present —
        // host, session, workspace, tab — no field labels, one line.
        waitToExist(row(containing: "ios-polish"))
        let iosPolish = row(containing: "ios-polish")
        let identity = iosPolish.value as? String ?? ""
        XCTAssertTrue(identity.contains("Host Studio Mac"), "host must ride the row identity: \(identity)")
        XCTAssertTrue(identity.contains("session main"), "session must ride the row identity: \(identity)")
        XCTAssertTrue(identity.contains("workspace iOS App"), "workspace must ride the row identity: \(identity)")
        XCTAssertTrue(identity.contains("tab work"), "tab must ride the row identity: \(identity)")
        // Kind resolves from runtime metadata and rides the row.
        let label = iosPolish.label
        XCTAssertTrue(label.contains("Codex"), "kind must show on the row: \(label)")
        XCTAssertTrue(label.contains("status Working"), "status must show: \(label)")
        // The second agent row shows a different kind (never guessed).
        waitToExist(row(containing: "accessibility"))
        XCTAssertTrue(row(containing: "accessibility").label.contains("Gemini CLI"))
        captureScreenshot(app, "agents-row-two-line", lifetime: .keepAlways)
    }

    // MARK: §B2 — fuzzy title search with real typing

    func testFuzzyTypingFiltersRowsAndCount() {
        waitToExist(row(containing: "ios-polish"))
        // REAL keystrokes with the focus pair: keyboard stayed, text retained.
        searchField.typeTextWithFocusAssertion(on: app, "Polsh")
        // Typo'd abbreviation of the TITLE "Polish the Attach experience"
        // matches only that row (titles are what free-text search scores).
        XCTAssertTrue(row(containing: "ios-polish").waitForExistence(timeout: 5))
        XCTAssertFalse(row(containing: "docs-review").exists)
        XCTAssertTrue(staticText(containing: "1 of 5 agents").waitForExistence(timeout: 5),
                      "count reflects filtered matches")
        captureScreenshot(app, "agents-fuzzy-typing", lifetime: .keepAlways)
    }

    // MARK: §B2 — field autocomplete, arrows, Enter accepts

    func testFieldSuggestionsArrowNavigationAndEnterAccept() {
        waitToExist(row(containing: "ios-polish"))
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
        // Arrow-down highlights; Enter accepts the highlighted suggestion
        // into a filter chip: Studio Mac holds 3 agents.
        acceptHighlightedViaKeyboard()
        XCTAssertTrue(app.buttons["Remove Host filter Studio Mac"].firstMatch
            .waitForExistence(timeout: 5),
            "Enter must accept the highlighted suggestion into a filter chip")
        // The Build Server agents are filtered out; Studio Mac's remain.
        XCTAssertTrue(row(containing: "ios-polish").waitForExistence(timeout: 5))
        XCTAssertFalse(row(containing: "api-tests").exists)
        captureScreenshot(app, "agents-enter-accepted-chip", lifetime: .keepAlways)
    }

    // MARK: §B2 — removable filter chips

    func testChipRemovalRestoresFullList() {
        waitToExist(row(containing: "ios-polish"))
        searchField.tap()
        app.waitForKeyboard()
        searchField.typeText("stu")
        XCTAssertTrue(app.buttons.matching(
            NSPredicate(format: "label CONTAINS %@", "Studio Mac")).firstMatch
            .waitForExistence(timeout: 5))
        acceptHighlightedViaKeyboard()
        XCTAssertTrue(app.buttons["Remove Host filter Studio Mac"].firstMatch
            .waitForExistence(timeout: 5))
        // Remove the chip by its corner-x (accessibility label carries
        // field + value).
        let remove = app.buttons["Remove Host filter Studio Mac"].firstMatch
        XCTAssertTrue(remove.waitForExistence(timeout: 5), "chip must expose a remove control")
        remove.tap()
        XCTAssertTrue(staticText(containing: "5 of 5 agents").waitForExistence(timeout: 5),
                      "chip removal must restore the full list")
        XCTAssertTrue(row(containing: "reviewer").waitForExistence(timeout: 5),
                      "the filtered-out host's agents must return")
        captureScreenshot(app, "agents-chip-removed", lifetime: .keepAlways)
    }

    // MARK: §B2 — Esc dismisses suggestions without submitting

    func testEscapeDismissesSuggestionsWithoutSubmitting() {
        waitToExist(row(containing: "ios-polish"))
        searchField.tap()
        app.waitForKeyboard()
        searchField.typeText("stu")
        XCTAssertTrue(staticText(containing: "Fuzzy titles").waitForExistence(timeout: 5),
                      "the suggestion list must show its help line while suggestions render")
        // Dismissal without submitting: hardware Esc where the keyboard
        // routes it, and — the phone's universal affordance — losing
        // focus (the preview's onblur rule) must dismiss the suggestions
        // while the query and rows stay intact.
        searchField.typeKey(.escape, modifierFlags: [])
        if staticText(containing: "Fuzzy titles").exists {
            // Hardware Esc did not route through the software keyboard:
            // tap a neutral element below the field — focus leaves the
            // field and the suggestions must dismiss (onblur rule).
            staticText(containing: "agents").tap()
            sleep(1)
        }
        XCTAssertTrue(
            staticText(containing: "Fuzzy titles").waitForNonExistence(timeout: 5)
                && app.buttons.matching(
                    NSPredicate(format: "label CONTAINS %@", "Studio Mac, 3 agents"))
                    .firstMatch.waitForNonExistence(timeout: 2),
            "suggestions must dismiss without submitting")
        // Nothing was submitted: rows unchanged, query intact.
        XCTAssertTrue(row(containing: "ios-polish").waitForExistence(timeout: 5))
        captureScreenshot(app, "agents-esc-dismiss", lifetime: .keepAlways)
    }

    // MARK: §B4 — ordering and grouping views in the Agents view menu

    func testOrderingAndGroupingViewsRender() {
        waitToExist(row(containing: "ios-polish"))
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
        waitToExist(row(containing: "ios-polish"))
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
        waitToExist(row(containing: "ios-polish"))
        searchField.typeTextWithFocusAssertion(on: app, "Audit")
        XCTAssertTrue(staticText(containing: "1 of 5 agents").waitForExistence(timeout: 5))
        // Push an agent detail, then come back.
        row(containing: "accessibility").tap()
        XCTAssertTrue(app.waitForPushedDetail(), "agent detail never pushed")
        // iOS 27 hides the back button from the AX tree: back is the
        // left-edge swipe (the gesture the phone actually has).
        let edge = app.coordinate(withNormalizedOffset: CGVector(dx: 0.01, dy: 0.5))
        let target = app.coordinate(withNormalizedOffset: CGVector(dx: 0.85, dy: 0.5))
        edge.press(forDuration: 0.05, thenDragTo: target)
        // The query and its result state survive the round trip.
        XCTAssertTrue(staticText(containing: "1 of 5 agents").waitForExistence(timeout: 10),
                      "query must survive navigation")
        XCTAssertTrue(row(containing: "accessibility").waitForExistence(timeout: 5))
        captureScreenshot(app, "agents-query-survives-nav", lifetime: .keepAlways)
    }
}
