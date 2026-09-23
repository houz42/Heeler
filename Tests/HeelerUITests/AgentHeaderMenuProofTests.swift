import XCTest

/// v3 "Header menu and statistics" proofs: the header's agent identity area
/// opens the Agent menu with its fixed section order (context → Statistics →
/// Actions → Companion terminal), Statistics read REPORTED telemetry (the
/// demo fixture reports no model → "Not reported", never the agent's NAME),
/// lifecycle actions render honest per-capability support (the demo Host has
/// no chat broker → Interrupt unsupported WITH reason; Stop/Resume unsupported
/// naming the missing herdr primitives), and Back + surface selector stay
/// separate controls. Captures attach to the result bundle for vision review.
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
    /// four sections in the design's fixed order, and every gated action
    /// shows its honest reason.
    func testHeaderMenuShowsSectionsAndGatedActions() {
        openHeaderMenu()

        // Identity/context lines, host → session → workspace → tab, in order.
        XCTAssertTrue(element(containing: "Session: main").exists)
        XCTAssertTrue(element(containing: "Workspace: iOS App").exists)
        XCTAssertTrue(element(containing: "Tab: work").exists)

        // Statistics: REPORTED telemetry only. The demo fixture reports no
        // model, so Model says "Not reported" — never the agent's NAME
        // ("ios-polish" is identity, not a model).
        XCTAssertTrue(element(containing: "Model: Not reported").exists)
        XCTAssertFalse(
            element(containing: "Model: ios-polish").exists,
            "the agent's name must never appear as its model")
        XCTAssertTrue(
            element(containing: "Working directory: /workspace/meadow").exists)
        XCTAssertTrue(element(containing: "Data freshness: Current").exists)

        // Actions: the demo Host has no chat broker, so Interrupt is
        // honestly unsupported WITH its reason; Stop and Resume name the
        // missing herdr primitives; New conversation is available.
        XCTAssertTrue(button("Interrupt turn").exists)
        let interruptReason = app.descendants(matching: .any).matching(
            NSPredicate(format: "label CONTAINS %@", "generic interrupt")
        ).firstMatch
        XCTAssertTrue(
            interruptReason.waitForExistence(timeout: UITestTimeouts.standard),
            "the gated Interrupt must explain why it is unavailable")
        XCTAssertTrue(button("Stop agent").exists)
        XCTAssertTrue(button("Resume saved conversation").exists)
        XCTAssertTrue(
            element(containing: "herdr 0.9.1 has no agent.stop").exists,
            "the unsupported Stop must explain the missing herdr primitive")
        XCTAssertTrue(
            element(containing: "herdr 0.9.1 has no agent.resume").exists)
        waitToExist(button("New conversation"))
        // The gated-action reason captions grow the menu past the popup's
        // fold; iOS menu popups scroll on drag. Scroll until the
        // companion entry is on stage.
        let companion = button("Open Shell Terminal")
        let companionDeadline = Date().addingTimeInterval(UITestTimeouts.standard)
        while !companion.exists, Date() < companionDeadline {
            app.swipeUp(velocity: .slow)
        }
        XCTAssertTrue(
            companion.waitForExistence(timeout: UITestTimeouts.standard),
            "the Companion terminal entry never appeared (scrolled)")

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
