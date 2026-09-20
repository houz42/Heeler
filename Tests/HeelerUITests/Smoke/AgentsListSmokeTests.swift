import XCTest

/// Smoke: the Console agents list renders from the demo fixture — the
/// harness's proof that `launchDemo(.console)` works. Copy this file's
/// shape for every new proof test.
@MainActor
final class AgentsListSmokeTests: XCTestCase {
    var app: XCUIApplication!

    override func setUp() {
        continueAfterFailure = false
        app = UITestApp.launchDemo(.console)
    }

    override func tearDown() {
        app.terminate()
    }

    /// The Agents list shows the fixture's rows and the toolbar.
    func testAgentsListShowsFixtureRows() {
        waitToExist(app.staticTexts[UITestFixtures.agentRows[0]])
        waitToExist(app.staticTexts[UITestFixtures.agentRows[4]])
        // The compact destination selector carries the destinations
        // (#A); the sheet-era Hosts/Settings toolbar buttons are gone.
        waitToExist(app.buttons[UITestFixtures.destinationSelector])
        captureScreenshot(app, "agents-list")
    }

    /// Tapping an agent row pushes its detail (back button appears).
    func testTappingAgentRowPushesDetail() {
        // Tap through the row's enclosing cell: a static-text tap can
        // land on a non-hittable text; the cell is the NavigationLink's
        // hit target.
        let cell = app.cells.containing(
            NSPredicate(format: "label CONTAINS %@", "ios-polish")
        ).firstMatch
        waitToExist(cell)
        cell.tap()
        XCTAssertTrue(app.waitForPushedDetail(), "agent detail never pushed")
        captureScreenshot(app, "agent-detail")
    }
}
