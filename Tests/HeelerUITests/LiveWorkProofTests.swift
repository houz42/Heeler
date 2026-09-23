import XCTest

// SPDX-License-Identifier: Apache-2.0
//
/// v3 live-work indicator — the visual proof suite against the
/// `--demo-chat-live-work` fixture: the state control drives the
/// PRODUCTION ChatLiveWorkIndicator through every state the design
/// maps. Assertions ride the accessibility tree (the indicator
/// carries "Agent working"/"Agent idle"/… labels); the screenshots
/// carry the visual proof (animated spark at the live edge while
/// Working; NOTHING while Idle/No report — no marker, no reserved
/// space) in the run's result bundle.

@MainActor
final class LiveWorkProofTests: XCTestCase {

    private func launchLiveWork() -> XCUIApplication {
        UITestApp.launchDemo(.chatLiveWork)
    }

    private func element(
        _ labelFragment: String, in app: XCUIApplication
    ) -> XCUIElement {
        app.descendants(matching: .any).matching(
            NSPredicate(format: "label CONTAINS %@", labelFragment)
        ).firstMatch
    }

    // MARK: - Working: the animated spark renders at the live edge

    func testWorkingShowsSparkAtLiveEdge() {
        let app = launchLiveWork()

        // The default selection is Working: the spark's accessible
        // label names it.
        XCTAssertTrue(
            element("Agent working", in: app).waitForExistence(
                timeout: UITestTimeouts.standard),
            "working must show the live-work spark")

        captureScreenshot(
            app, "live-work-working-spark", lifetime: .keepAlways)
    }

    // MARK: - Idle: NOTHING — no marker, no reserved space

    func testIdleShowsNoMarker() {
        let app = launchLiveWork()

        let idleButton = app.buttons["Idle"].firstMatch
        XCTAssertTrue(
            idleButton.waitForExistence(timeout: UITestTimeouts.standard),
            "the demo state control must be reachable")
        idleButton.tap()

        // The spark (and every state label) is GONE: no marker row.
        XCTAssertTrue(
            element("Agent working", in: app).waitForNonExistence(
                timeout: UITestTimeouts.standard),
            "idle must show NO work marker")
        XCTAssertTrue(
            element("Agent idle", in: app).waitForNonExistence(
                timeout: UITestTimeouts.standard),
            "idle reserves NO marker space — not even a static one")

        captureScreenshot(
            app, "live-work-idle-nothing", lifetime: .keepAlways)
    }

    // MARK: - Blocked/Completed/Unknown: static, never animated

    func testBlockedCompletedUnknownShowStaticMark() {
        let app = launchLiveWork()

        for (button, label) in [
            ("Blocked", "Agent waiting for input"),
            ("Completed", "Agent finished"),
            ("Unknown", "Agent status unknown"),
        ] {
            let control = app.buttons[button].firstMatch
            XCTAssertTrue(
                control.waitForExistence(timeout: UITestTimeouts.standard),
                "the \(button) control must be reachable")
            control.tap()

            XCTAssertTrue(
                element(label, in: app).waitForExistence(
                    timeout: UITestTimeouts.standard),
                "\(button) must render its static mark")
        }

        captureScreenshot(
            app, "live-work-static-states", lifetime: .keepAlways)
    }

    // MARK: - No report: NOTHING (connection alone ≠ thinking)

    func testNoReportShowsNothing() {
        let app = launchLiveWork()

        let control = app.buttons["No report"].firstMatch
        XCTAssertTrue(
            control.waitForExistence(timeout: UITestTimeouts.standard))
        // The control rides a horizontal rail; the last chip can sit
        // off-screen on narrow devices — scroll it into view first.
        if !control.isHittable {
            app.swipeLeft()
        }
        control.tap()

        XCTAssertTrue(
            element("Agent working", in: app).waitForNonExistence(
                timeout: UITestTimeouts.standard),
            "no fresh producer report must show NOTHING")
        XCTAssertTrue(
            element("Agent status unknown", in: app).waitForNonExistence(
                timeout: UITestTimeouts.standard),
            "absence of a report is not an unknown-state marker")

        captureScreenshot(
            app, "live-work-no-report-nothing", lifetime: .keepAlways)
    }

    // MARK: - Tap for details (no visible status sentence)

    func testTapOpensDetails() {
        let app = launchLiveWork()

        let spark = element("Agent working", in: app)
        XCTAssertTrue(
            spark.waitForExistence(timeout: UITestTimeouts.standard))
        spark.tap()

        // The details sheet names the state + the producer's line.
        XCTAssertTrue(
            element("Agent Status", in: app).waitForExistence(
                timeout: UITestTimeouts.standard),
            "tap must open the details sheet")
        XCTAssertTrue(
            element("Running the targeted suite", in: app)
                .waitForExistence(timeout: UITestTimeouts.standard),
            "the details sheet carries the producer detail line")

        captureScreenshot(
            app, "live-work-details-sheet", lifetime: .keepAlways)
    }
}
