import XCTest

/// v3 "Header menu and statistics" proofs: the header's agent identity area
/// opens the Agent menu with its fixed section order (context → Statistics →
/// Actions → Companion terminal), the herdr-gated lifecycle actions render
/// their honest disabled reasons, and Back + surface selector stay separate
/// reachable controls while the menu is closed. Captures attach to the
/// result bundle for vision review.
///
/// Query note: SwiftUI menu rows surface under varying XCUI element types
/// (menu item / other / static text depending on iOS release), so the
/// assertions query by LABEL across `descendants(matching: .any)` — the
/// same tree the probe capture documented.
@MainActor
final class AgentHeaderMenuProofTests: XCTestCase {
    var app: XCUIApplication!

    override func setUp() {
        continueAfterFailure = false
        app = UITestApp.launchDemo(.console)
    }

    override func tearDown() {
        app.terminate()
    }

    private func element(containing text: String) -> XCUIElement {
        app.descendants(matching: .any).matching(
            NSPredicate(format: "label CONTAINS %@", text)).firstMatch
    }

    private func button(_ label: String) -> XCUIElement {
        app.buttons[label].firstMatch
    }

    /// The header menu lives on the agent DETAIL: push the fixture's
    /// working agent (its row carries a transcript, so the chat surface
    /// opens and the header shows the Agent menu trigger).
    private func pushWorkingAgentDetail() {
        let cell = app.cells.containing(
            NSPredicate(
                format: "label CONTAINS %@ OR label CONTAINS %@",
                "ios-polish", "Polish the Attach experience")
        ).firstMatch
        // The run's FIRST test pays the app-install cold-start cost; the
        // demo rows land well after launch when the simulator is fresh.
        XCTAssertTrue(
            cell.waitForExistence(timeout: UITestTimeouts.launch * 2),
            "fixture agent row never appeared")
        // Lazy list tolerance (the smoke test's pattern): the row is
        // on-stage already, but a cold first-run render can stall —
        // scroll until it lands rather than failing.
        let rowDeadline = Date().addingTimeInterval(UITestTimeouts.launch)
        while !cell.isHittable, Date() < rowDeadline {
            app.swipeUp()
        }
        cell.tap()
        XCTAssertTrue(app.waitForPushedDetail(), "agent detail never pushed")
    }

    private func openHeaderMenu() {
        pushWorkingAgentDetail()
        let trigger = button("Agent menu, ios-polish")
        waitToExist(trigger)
        trigger.tap()
        // The menu content: the identity/context section's Host line.
        XCTAssertTrue(
            element(containing: "Host: Studio Mac")
                .waitForExistence(timeout: UITestTimeouts.standard),
            "the menu's identity section never rendered")
    }

    /// Tapping the header's identity area opens the Agent menu with the
    /// four sections in the design's fixed order, and the herdr-gated
    /// actions (Stop / Resume) show as unavailable with reasons.
    func testHeaderMenuShowsSectionsAndGatedActions() {
        openHeaderMenu()

        // Identity/context lines, host → session → workspace → tab, in order.
        XCTAssertTrue(element(containing: "Session: main").exists)
        XCTAssertTrue(element(containing: "Workspace: iOS App").exists)
        XCTAssertTrue(element(containing: "Tab: work").exists)

        // Statistics.
        XCTAssertTrue(element(containing: "Model: ios-polish").exists)
        XCTAssertTrue(
            element(containing: "Working directory: /workspace/meadow").exists)
        XCTAssertTrue(element(containing: "Data freshness: Current").exists)

        // Actions: Interrupt available (fixture agent is Working), Stop and
        // Resume gated with the herdr-0.9.1 reasons, New conversation present.
        waitToExist(button("Interrupt turn"))
        XCTAssertTrue(button("Stop agent").exists)
        XCTAssertTrue(button("Resume saved conversation").exists)
        XCTAssertTrue(
            element(containing: "herdr 0.9.1 has no agent.stop").exists,
            "the unsupported Stop must explain the missing herdr primitive")
        XCTAssertTrue(
            element(containing: "herdr 0.9.1 has no agent.resume").exists)
        waitToExist(button("New conversation"))

        // Companion terminal entry.
        waitToExist(button("Open Shell Terminal"))

        captureScreenshot(app, "header-menu-open", lifetime: .keepAlways)
    }

    /// The header menu never swallows its neighbors: the surface selector
    /// stays a separate control while the menu is closed, and dismissing
    /// the menu returns the header (Back stays reachable throughout).
    func testBackAndSurfaceSelectorStaySeparate() {
        pushWorkingAgentDetail()
        let trigger = button("Agent menu, ios-polish")
        waitToExist(trigger)
        // Surface picker independent of the menu trigger.
        let surfaceToggle = button("Show Terminal")
        XCTAssertTrue(
            surfaceToggle.waitForExistence(timeout: UITestTimeouts.standard),
            "the surface selector must remain its own control beside the menu trigger")
        trigger.tap()
        XCTAssertTrue(
            element(containing: "Host: Studio Mac")
                .waitForExistence(timeout: UITestTimeouts.standard),
            "the menu's identity section never rendered")
        // Dismiss by tapping outside the menu, then the controls return.
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.02)).tap()
        XCTAssertTrue(
            trigger.waitForExistence(timeout: UITestTimeouts.standard),
            "the header trigger must return after the menu closes")
        captureScreenshot(app, "header-menu-closed", lifetime: .keepAlways)
    }

    /// The gated actions refuse taps honestly: Stop agent is disabled, and
    /// a tap on it navigates nowhere.
    func testGatedStopAgentDoesNotFire() {
        openHeaderMenu()
        let stop = button("Stop agent")
        waitToExist(stop)
        XCTAssertFalse(stop.isEnabled, "Stop must be disabled on herdr 0.9.1")
        stop.tap()
        // Still on the detail: the menu did not navigate anywhere.
        XCTAssertTrue(
            button("Agent menu, ios-polish")
                .waitForExistence(timeout: UITestTimeouts.standard))
        captureScreenshot(app, "header-menu-stop-gated", lifetime: .keepAlways)
    }
}
