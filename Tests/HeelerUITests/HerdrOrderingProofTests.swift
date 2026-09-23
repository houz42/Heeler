import XCTest

/// v3 "Default herdr ordering" proofs: the Agents list defaults to Herdr
/// order — the producer's own workspace/tab/pane arrangement, hosts in the
/// user's catalog order — visibly DIFFERENT from A–Z and from status order
/// on the demo fixture (iOS App workspace enumerated before Product Docs,
/// p1 above p4 in a vertical split). The optional Pinned section (a seeded
/// pin on the working iOS agent) renders ABOVE the canonical rows as a
/// bookmark DUPLICATE: the pinned row appears in both places, and the
/// canonical rows keep the producer order. The sort picker's copy states
/// the cross-session truth ("Hosts/sessions in your order; workspaces and
/// tabs in herdr order") and the honest "Order unavailable" rule.
@MainActor
final class HerdrOrderingProofTests: XCTestCase {
    var app: XCUIApplication!

    override func setUp() {
        continueAfterFailure = false
        app = UITestApp.launchDemo(.console)
    }

    override func tearDown() {
        app.terminate()
    }

    // MARK: Locators

    private func row(containing text: String) -> XCUIElement {
        app.buttons.matching(
            NSPredicate(format: "label CONTAINS %@", text)).firstMatch
    }

    private func staticText(containing text: String) -> XCUIElement {
        app.staticTexts.matching(
            NSPredicate(format: "label CONTAINS %@", text)).firstMatch
    }

    /// Vertical position of a row: the y of its frame.
    private func rowY(containing text: String) -> CGFloat {
        row(containing: text).frame.minY
    }

    // MARK: The default is Herdr order

    /// A fresh launch (fresh demo defaults) shows Herdr order with NO
    /// user interaction: the demo fixture's producer arrangement —
    /// Polish (mobile t1, upper pane), Audit (mobile t1, lower pane),
    /// then Refresh (docs workspace) — ahead of the Build Server rows,
    /// hosts in catalog order (Studio Mac's rows before Build Server's).
    func testDefaultOrderIsProducerArrangementNotAlphabeticalOrStatus() {
        // The list must settle first: the fixture agents appear after
        // the demo transports connect.
        let polish = row(containing: "Polish the Attach experience")
        XCTAssertTrue(
            polish.waitForExistence(timeout: UITestTimeouts.launch * 2),
            "fixture agents never appeared")

        let auditY = rowY(containing: "Audit VoiceOver labels")
        let refreshY = rowY(containing: "Refresh the setup guide")
        let checkoutY = rowY(containing: "Checkout review")
        let hardenY = rowY(containing: "Harden webhook retries")

        // The Studio Mac block (Polish/Audit/Refresh) leads the Build
        // Server block (Checkout/Harden): catalog order, not names —
        // "Build Server" alphabetizes before "Studio Mac".
        XCTAssertTrue(polish.frame.minY < checkoutY,
                      "the first catalog host's rows must lead")
        XCTAssertTrue(auditY < checkoutY && refreshY < checkoutY)

        // Inside the Studio Mac block: producer arrangement, not A–Z
        // (Audit would win) and not status order (done Audit would win).
        XCTAssertTrue(polish.frame.minY < auditY,
                      "the upper pane (Polish) must render above the lower pane (Audit)")
        XCTAssertTrue(auditY < refreshY,
                      "the second workspace's tab (Refresh) follows the first workspace's panes")

        // Inside the Build Server block: producer order again — the
        // fixture enumerates Checkout (blocked) before API (working);
        // status order would put blocked first too, so ALSO assert the
        // Studio block where the two orders disagree.
        XCTAssertTrue(checkoutY < hardenY)
        captureScreenshot(app, "herdr-order-default", lifetime: .keepAlways)
    }

    // MARK: The Pinned bookmark section

    /// The seeded pin produces the optional Pinned section ABOVE the
    /// canonical rows: the pinned row appears TWICE (bookmark duplicate)
    /// and the canonical rows keep the producer order — a pin is not a
    /// silent reorder.
    func testPinnedSectionDuplicatesWithoutReorderingTheCanonicalList() {
        let pinnedHeader = staticText(containing: "Pinned")
        XCTAssertTrue(
            pinnedHeader.waitForExistence(timeout: UITestTimeouts.launch * 2),
            "the seeded pin must render the Pinned section header")
        // The pinned row exists twice: once in the section (above) and
        // once in the canonical rows (below). The List is lazy, so the
        // below-the-fold canonical duplicate is not materialized until
        // the list scrolls — swipe, then count.
        app.swipeUp(velocity: .fast)
        let polishQuery = app.buttons.matching(
            NSPredicate(format: "label CONTAINS %@", "Polish the Attach experience"))
        XCTAssertGreaterThanOrEqual(
            polishQuery.count, 2,
            "the pinned row must render in the Pinned section AND the canonical list")

        let sectionRowY = polishQuery.element(boundBy: 0).frame.minY
        let canonicalRowY = polishQuery.element(boundBy: 1).frame.minY
        XCTAssertLessThan(
            pinnedHeader.frame.minY, sectionRowY,
            "the Pinned header renders above its rows")
        XCTAssertLessThan(
            sectionRowY, canonicalRowY,
            "the Pinned section renders above the canonical rows")

        // The canonical rows keep producer order: Audit (the lower pane
        // of the first workspace) still renders before Refresh (the
        // second workspace) — the pin did not remove or reorder anyone.
        let auditY = rowY(containing: "Audit VoiceOver labels")
        let refreshY = rowY(containing: "Refresh the setup guide")
        XCTAssertTrue(auditY < refreshY)
        captureScreenshot(app, "herdr-order-pinned-section", lifetime: .keepAlways)
    }

    // MARK: The sort picker copy

    /// The order chooser states the cross-session truth: herdr publishes
    /// no global ordinal, so hosts/sessions stay in the user's order and
    /// only workspaces/tabs follow herdr — with the honest
    /// "Order unavailable" rule for rows the producer could not place.
    func testOrderChooserCopyStatesCrossSessionTruthAndUnavailableRule() {
        let menu = app.buttons["Agent list view options"].firstMatch
        XCTAssertTrue(
            menu.waitForExistence(timeout: UITestTimeouts.standard))
        menu.tap()
        let order = app.buttons["Order"].firstMatch
        XCTAssertTrue(order.waitForExistence(timeout: UITestTimeouts.standard))
        order.tap()
        XCTAssertTrue(
            app.navigationBars["Order agents"].waitForExistence(
                timeout: UITestTimeouts.standard))

        // The default option is marked and the copy states the split.
        XCTAssertTrue(
            staticText(containing: "Hosts/sessions in your order; workspaces and tabs in herdr order")
                .waitForExistence(timeout: UITestTimeouts.standard),
            "the Herdr order option must carry the cross-session copy")
        XCTAssertTrue(
            staticText(containing: "Order unavailable").exists,
            "the chooser note must state the missing-ordinal rule")
        captureScreenshot(app, "herdr-order-chooser-copy", lifetime: .keepAlways)

        // One tap on Herdr order applies and returns to the sheet root.
        app.buttons.matching(
            NSPredicate(format: "label CONTAINS %@", "Herdr order")).firstMatch.tap()
        XCTAssertTrue(
            app.buttons["Reset list layout"].firstMatch.waitForExistence(
                timeout: UITestTimeouts.standard),
            "the chooser must return to the parent sheet root")
        let done = app.buttons["Done"].firstMatch
        if done.waitForExistence(timeout: UITestTimeouts.standard) {
            done.tap()
        }
    }
}
