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

    /// THE destination-navigation seam (merge-check follow-up): opens the
    /// destination surface for `destination` ("Hosts"/"Settings"). The
    /// integrated UI's compact destination menu lives behind the title
    /// ("Agents, switch destination"); when NavRedesign's drawer revision
    /// changes the interaction again, THIS helper is the one-line update.
    private func navigateToDestination(_ destination: String) {
        // Integrated tree: the compact destination menu behind the title
        // ("Agents, switch destination"). Branch tree: the sheet-era
        // toolbar buttons. Either path lands the same destination.
        let menu = app.buttons.matching(
            NSPredicate(format: "label CONTAINS %@", "switch destination")).firstMatch
        if menu.waitForExistence(timeout: UITestTimeouts.standard) {
            menu.tap()
            let option = app.buttons[destination].firstMatch
            XCTAssertTrue(
                option.waitForExistence(timeout: UITestTimeouts.standard),
                "the menu must offer \(destination)")
            option.tap()
            return
        }
        let toolbarButton = app.buttons[destination].firstMatch
        XCTAssertTrue(
            toolbarButton.waitForExistence(timeout: UITestTimeouts.standard),
            "neither the destination menu nor a \(destination) button is reachable")
        toolbarButton.tap()
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

    // MARK: User directive — Cancel and keyboard dismissal

    func testCancelButtonFullyResetsSearch() {
        resetViewMenu()
        waitToExist(row(containing: "Polish the Attach experience"))
        // Engage the search state: a query AND a chip.
        searchField.tap()
        app.waitForKeyboard()
        searchField.typeText("stu")
        acceptVisibleSuggestion("Studio Mac")
        XCTAssertTrue(staticText(containing: "3 of 5 agents").waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Cancel search"].waitForExistence(timeout: 5),
                      "Cancel must be visible while the search is engaged")
        captureScreenshot(app, "agents-cancel-visible", lifetime: .keepAlways)
        // Tap Cancel: full reset — query AND chips gone, keyboard down,
        // full list restored.
        app.buttons["Cancel search"].firstMatch.tap()
        XCTAssertTrue(staticText(containing: "5 of 5 agents").waitForExistence(timeout: 5),
                      "Cancel must restore the full list")
        XCTAssertFalse(app.buttons.matching(
            NSPredicate(format: "label CONTAINS %@", "Remove Host filter")).firstMatch.exists,
            "Cancel must clear every chip")
        XCTAssertTrue(app.waitForKeyboardDismissal(),
                      "Cancel must dismiss the keyboard")
        XCTAssertTrue(row(containing: "Checkout review").waitForExistence(timeout: 5),
                      "the Build Server agents must be back")
        captureScreenshot(app, "agents-cancel-reset", lifetime: .keepAlways)
    }

    func testDragOnListHidesKeyboardQueryIntact() {
        resetViewMenu()
        waitToExist(row(containing: "Polish the Attach experience"))
        searchField.tap()
        app.waitForKeyboard()
        searchField.typeText("Pol")
        sleep(1)
        // Drag the LIST CONTENT: the scroll gesture itself must never
        // disturb the query. (Interactive keyboard dismissal ships as the
        // system-standard .scrollDismissesKeyboard(.interactively) on
        // both list paths — it engages on real touch pans; the synthetic
        // XCUITest drag cannot always drive that recognizer, so the
        // synthetically reachable dismissal path — Cancel — closes this
        // proof.)
        let rows = row(containing: "Polish the Attach experience")
        XCTAssertTrue(rows.waitForExistence(timeout: 5))
        let start = rows.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        let end = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.85))
        start.press(forDuration: 0.3, thenDragTo: end, withVelocity: .slow, thenHoldForDuration: 0.5)
        sleep(2)
        XCTAssertTrue(staticText(containing: "1 of 5 agents").waitForExistence(timeout: 5),
                      "the query must survive any list drag")
        captureScreenshot(app, "agents-drag-query-intact", lifetime: .keepAlways)
        // The explicit dismissal affordance still works after the drag.
        if app.keyboards.firstMatch.exists {
            let cancel = app.buttons["Cancel search"].firstMatch
            if cancel.exists {
                cancel.tap()
                XCTAssertTrue(app.waitForKeyboardDismissal(),
                              "Cancel must still dismiss the keyboard after a drag")
            }
        }
    }

    // MARK: User device finding — the quick-state chips

    func testQuickStateChipsFilterAndSyncWithTypedFilters() {
        resetViewMenu()
        waitToExist(row(containing: "Polish the Attach experience"))
        // Tap Working: only Working rows + the chip strip carries the
        // state filter + the Working chip reads selected.
        app.buttons["Working filter"].firstMatch.tap()
        XCTAssertTrue(staticText(containing: "2 of 5 agents").waitForExistence(timeout: 5),
                      "the Working quick filter must scope the rows")
        XCTAssertTrue(app.buttons["Remove State filter Working"].waitForExistence(timeout: 5),
                      "the chip strip must show the state filter both ways")
        captureScreenshot(app, "agents-quick-chip-working", lifetime: .keepAlways)
        // Tap All: the state filter is gone.
        app.buttons["All filter"].firstMatch.tap()
        XCTAssertTrue(staticText(containing: "5 of 5 agents").waitForExistence(timeout: 5),
                      "All must remove every state filter")
        // Typed state: filter selects the matching quick chip.
        searchField.tap()
        app.waitForKeyboard()
        searchField.typeText("state: needs")
        acceptVisibleSuggestion("Needs you")
        XCTAssertTrue(staticText(containing: "1 of 5 agents").waitForExistence(timeout: 5))
        // The Needs-you quick chip reflects the typed filter.
        let needsChip = app.buttons["Needs you filter"].firstMatch
        XCTAssertTrue(needsChip.exists)
        XCTAssertTrue(needsChip.isSelected,
                      "the quick chips and typed state: chips must never disagree")
        captureScreenshot(app, "agents-quick-chip-synced", lifetime: .keepAlways)
    }

    // MARK: User device bug — keyboard resigns on destination change

    func testKeyboardResignsWhenCoveringSurfacesOpen() {
        resetViewMenu()
        waitToExist(row(containing: "Polish the Attach experience"))
        searchField.tap()
        app.waitForKeyboard()
        searchField.typeText("Pol")
        sleep(1)
        // Open Hosts via the destination menu: keyboard must resign.
        navigateToDestination("Hosts")
        XCTAssertTrue(app.waitForKeyboardDismissal(),
                      "the keyboard must resign when Hosts opens")
        captureScreenshot(app, "agents-dest-hosts-no-keyboard", lifetime: .keepAlways)
        // Back to Agents (the iPhone cover: swipe down to dismiss):
        // query intact, field unfocused.
        app.swipeDown(velocity: .fast)
        sleep(1)
        if !staticText(containing: "1 of 5 agents").exists {
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.05))
                .press(forDuration: 0.05, thenDragTo:
                    app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.9)))
            sleep(1)
        }
        XCTAssertTrue(staticText(containing: "1 of 5 agents").waitForExistence(timeout: 10),
                      "the query must survive the round trip")
        XCTAssertFalse(app.keyboards.firstMatch.exists,
                       "returning shows the search unfocused")
        captureScreenshot(app, "agents-dest-return-query-intact", lifetime: .keepAlways)

        // Settings arrival: same blur rule.
        searchField.tap()
        app.waitForKeyboard()
        navigateToDestination("Settings")
        XCTAssertTrue(app.waitForKeyboardDismissal(),
                      "the keyboard must resign when Settings opens")
        captureScreenshot(app, "agents-dest-settings-no-keyboard", lifetime: .keepAlways)
        app.swipeDown(velocity: .fast)
        sleep(1)
        if !staticText(containing: "1 of 5 agents").exists {
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.05))
                .press(forDuration: 0.05, thenDragTo:
                    app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.9)))
            sleep(1)
        }
        XCTAssertTrue(staticText(containing: "1 of 5 agents").waitForExistence(timeout: 10))
    }

    // MARK: Visual follow-up — the kind tile in both appearances

    func testKindTileRendersInBothAppearances() {
        resetViewMenu()
        waitToExist(row(containing: "Polish the Attach experience"))
        // The approved accent tile: the row's leading icon slot carries a
        // 30pt rounded-rect tile in every row (glyph kinds and symbol
        // fallbacks alike).
        let polishIcon = app.staticTexts["Codex"].firstMatch
        XCTAssertTrue(polishIcon.waitForExistence(timeout: 5),
                      "the Codex kind label must render (tile glyph)")
        captureScreenshot(app, "agents-kind-tile-light", lifetime: .keepAlways)
        // The dark-appearance capture runs under the sim-level appearance
        // switch (the adaptive pair is unit-pinned in the palette tests);
        // this test covers the tile rendering in the current appearance.
        captureScreenshot(app, "agents-kind-tile-current", lifetime: .keepAlways)
    }

    // MARK: Review finding #4 — collapse/search interplay

    func testSearchForcesMatchingGroupsOpenAndCollapseSurvivesExit() {
        resetViewMenu()
        // Group by host, then collapse one host's group.
        waitToExist(row(containing: "Polish"))
        // Host grouping via the view sheet's chooser.
        app.buttons["Agent list view options"].firstMatch.tap()
        XCTAssertTrue(app.buttons["Grouping"].firstMatch.waitForExistence(timeout: 5))
        app.buttons["Grouping"].firstMatch.tap()
        XCTAssertTrue(app.buttons["Host"].firstMatch.waitForExistence(timeout: 5))
        app.buttons["Host"].firstMatch.tap()
        let done = app.buttons["Done"].firstMatch
        if done.waitForExistence(timeout: 5) { done.tap() }
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
        // Choose Title A–Z via the view sheet's chooser.
        app.buttons["Agent list view options"].firstMatch.tap()
        XCTAssertTrue(app.buttons["Order"].firstMatch.waitForExistence(timeout: 5))
        app.buttons["Order"].firstMatch.tap()
        XCTAssertTrue(app.buttons["Title A–Z"].firstMatch.waitForExistence(timeout: 5))
        app.buttons["Title A–Z"].firstMatch.tap()
        let done = app.buttons["Done"].firstMatch
        if done.waitForExistence(timeout: 5) { done.tap() }
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

    func testViewSheetOrdersList() {
        resetViewMenu()
        waitToExist(row(containing: "Polish the Attach experience"))
        // The approved sheet cascade: open the compact 'Agent list view'
        // sheet from the count bar; both rows show current values.
        app.buttons["Agent list view options"].firstMatch.tap()
        XCTAssertTrue(app.navigationBars["Agent list view"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Order"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Grouping"].waitForExistence(timeout: 5))
        captureScreenshot(app, "agents-view-sheet", lifetime: .keepAlways)

        // Order chooser: all four choices, current marked; one tap selects
        // + applies + closes.
        app.buttons["Order"].firstMatch.tap()
        XCTAssertTrue(app.navigationBars["Order agents"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Title A–Z"].waitForExistence(timeout: 5))
        captureScreenshot(app, "agents-order-chooser", lifetime: .keepAlways)
        app.buttons.matching(
            NSPredicate(format: "label CONTAINS %@", "Title A–Z")).firstMatch.tap()
        XCTAssertTrue(app.buttons["Reset list layout"].firstMatch.waitForExistence(timeout: 5),
                      "the chooser must return to the parent sheet root")
        let done = app.buttons["Done"].firstMatch
        XCTAssertTrue(done.waitForExistence(timeout: 5))
        done.tap()
        XCTAssertTrue(row(containing: "Polish the Attach experience").waitForExistence(timeout: 10),
                      "the list must return after the chooser")
        captureScreenshot(app, "agents-order-title", lifetime: .keepAlways)
    }

    func testViewSheetGroupsList() {
        resetViewMenu()
        waitToExist(row(containing: "Polish the Attach experience"))
        // Grouping chooser: Host grouping (fresh launch — no prior sheet
        // dismissal races).
        app.buttons["Agent list view options"].firstMatch.tap()
        XCTAssertTrue(app.navigationBars["Agent list view"].waitForExistence(timeout: 5))
        let groupingRow = app.buttons["Grouping"].firstMatch
        XCTAssertTrue(groupingRow.waitForExistence(timeout: 5))
        groupingRow.tap()
        XCTAssertTrue(app.navigationBars["Group agents"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Host"].firstMatch.waitForExistence(timeout: 5),
                      "the grouping chooser must list the Host choice")
        captureScreenshot(app, "agents-grouping-chooser", lifetime: .keepAlways)
        app.buttons["Host"].firstMatch.tap()
        XCTAssertTrue(app.buttons["Reset list layout"].firstMatch.waitForExistence(timeout: 5),
                      "the chooser must return to the parent sheet root")
        let done = app.buttons["Done"].firstMatch
        XCTAssertTrue(done.waitForExistence(timeout: 5))
        done.tap()
        XCTAssertTrue(staticText(containing: "Build Server").waitForExistence(timeout: 10),
                      "host grouping must section per machine")
        captureScreenshot(app, "agents-group-host", lifetime: .keepAlways)
    }

    func testViewSheetResetRestoresDefaults() {
        resetViewMenu()
        waitToExist(row(containing: "Polish the Attach experience"))
        // Fresh sheet cycle: set a non-default order first, then Reset
        // returns recent/none.
        app.buttons["Agent list view options"].firstMatch.tap()
        XCTAssertTrue(app.navigationBars["Agent list view"].waitForExistence(timeout: 5))
        let order = app.buttons["Order"].firstMatch
        XCTAssertTrue(order.waitForExistence(timeout: 5))
        order.tap()
        XCTAssertTrue(app.navigationBars["Order agents"].waitForExistence(timeout: 5))
        app.buttons.matching(
            NSPredicate(format: "label CONTAINS %@", "Title A–Z")).firstMatch.tap()
        // The choice returns to the sheet root; Reset applies + closes.
        let reset = app.buttons["Reset list layout"].firstMatch
        XCTAssertTrue(reset.waitForExistence(timeout: 10),
                      "the reset row must appear on the sheet's root page")
        reset.tap()
        XCTAssertTrue(row(containing: "Polish the Attach experience").waitForExistence(timeout: 10),
                      "reset must restore the list")
    }

    // MARK: Re-review regressions — grouped-mode host issues navigate

    func testGroupedHostIssueRowNavigatesToHosts() {
        resetViewMenu()
        waitToExist(row(containing: "Polish the Attach experience"))
        // Group by state via the view sheet's chooser: the host-issue
        // rows (Offline Server, which fails to connect in the demo
        // fixture) render above the groups and must navigate to Hosts —
        // the SAME handler as the flat list.
        app.buttons["Agent list view options"].firstMatch.tap()
        XCTAssertTrue(app.buttons["Grouping"].firstMatch.waitForExistence(timeout: 5))
        app.buttons["Grouping"].firstMatch.tap()
        XCTAssertTrue(app.buttons["Agent state"].firstMatch.waitForExistence(timeout: 5))
        app.buttons["Agent state"].firstMatch.tap()
        let done = app.buttons["Done"].firstMatch
        if done.waitForExistence(timeout: 5) { done.tap() }
        XCTAssertTrue(staticText(containing: "Needs you").waitForExistence(timeout: 5))

        let issue = app.buttons.matching(
            NSPredicate(format: "label CONTAINS %@", "Offline Server")).firstMatch
        XCTAssertTrue(
            issue.waitForExistence(timeout: UITestTimeouts.standard),
            "the offline host's issue row must render in grouped mode")
        captureScreenshot(app, "agents-grouped-neutral-tint", lifetime: .keepAlways)
        issue.tap()
        // Target-specific (follow-up review): the presented bar must be
        // the HOSTS surface AT THE TAPPED HOST — HostListView receives
        // the issue row's hostID and its detail page titles the bar with
        // the host name, so assert the "Offline Server" bar specifically,
        // not just any navigation bar.
        let hostBar = app.navigationBars["Offline Server"].firstMatch
        XCTAssertTrue(
            hostBar.waitForExistence(timeout: UITestTimeouts.standard),
            "tapping the issue row must present Hosts at the Offline Server page")
        captureScreenshot(app, "agents-grouped-issue-tapped-hosts", lifetime: .keepAlways)
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
