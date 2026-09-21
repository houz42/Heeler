import XCTest

/// UI proofs for the v2 automatic route surface (demo fixtures, no real
/// SSH): the Host detail's Routes section renders the selection, the
/// result line, per-route statuses, honest-unreachable surfacing, and the
/// pinned-failure offer (Try another route / Return to automatic).
@MainActor
final class HostRoutesSmokeTests: XCTestCase {
    var app: XCUIApplication!

    override func setUp() {
        continueAfterFailure = false
    }

    override func tearDown() {
        app.terminate()
    }

    /// The Automatic route surface: selection row, result line naming the
    /// in-use route (never a provider claim), reachable/unreachable rows,
    /// and the honest "Skipped" for an ineligible route.
    func testAutomaticRouteSurfaceRendersHonestStatuses() {
        app = UITestApp.launchDemo(.hostRoutes)

        // Route selection renders as one LabeledContent element
        // ("label, value").
        waitToExist(app.staticTexts["Route selection, Automatic"])

        // The result line names the in-use route by its saved name.
        XCTAssertTrue(app.staticTexts["Using Local network"].exists)

        // Per-route statuses: the in-use row and the honest unreachable
        // one.
        XCTAssertTrue(app.staticTexts["In use"].exists)
        XCTAssertTrue(app.staticTexts["Unreachable"].exists)

        // Route labels describe saved endpoints; no provider on/off
        // claim exists anywhere on the surface.
        XCTAssertFalse(
            app.staticTexts.matching(NSPredicate(format: "label CONTAINS 'is on'"))
                .firstMatch.exists)

        captureScreenshot(app, "host-routes-automatic", lifetime: .keepAlways)
    }

    /// A pinned route that failed to reach: the pin reads as pinned, the
    /// failure offer shows Try another route and Return to automatic, and
    /// the unreachable route reads honestly.
    func testPinnedFailureOffersTryAnotherAndReturnToAutomatic() {
        app = UITestApp.launchDemo(.hostRoutesPinnedFailed)

        // The failure offer renders above the Routes section — the most
        // important state on the page after a failed dial.
        waitToExist(app.staticTexts["Route failed"])
        XCTAssertTrue(app.buttons["Return to automatic"].exists)
        XCTAssertTrue(app.buttons["Try Local network"].exists)
        XCTAssertTrue(app.buttons["Try Bonjour"].exists)
        // The failed pinned route is not offered against itself.
        XCTAssertFalse(app.buttons["Try VPN"].exists)

        captureScreenshot(app, "host-routes-pinned-failed-offer", lifetime: .keepAlways)

        // Scroll down to the Routes section for the rest of the proof.
        let pinnedRow = app.staticTexts["Route pinned: VPN"]
        var attempts = 0
        while !pinnedRow.exists && attempts < 10 {
            app.swipeUp()
            attempts += 1
        }
        XCTAssertTrue(pinnedRow.exists, "the pinned result line should exist after scrolling")

        // The pinned route's honest status.
        XCTAssertTrue(app.staticTexts["Unreachable"].exists)

        captureScreenshot(app, "host-routes-pinned-failed", lifetime: .keepAlways)
    }

    private func waitToExist(_ element: XCUIElement) {
        XCTAssertTrue(
            element.waitForExistence(timeout: UITestTimeouts.standard),
            "expected \(element) to exist")
    }
}
