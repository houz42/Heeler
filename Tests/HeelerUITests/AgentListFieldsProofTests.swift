import XCTest

// SPDX-License-Identifier: Apache-2.0
//
/// The Agent List Fields settings page's HOST rows (review D9): the
/// `desktopcomputer` leading icon was never seen on screen — the page
/// has no demo route, so this suite drives the real navigation path
/// (drawer → Settings → Agent List Fields) and pins that the global
/// row AND one Host row both render with their stable accessibility
/// identifiers, capturing the visual proof screenshot.

@MainActor
final class AgentListFieldsProofTests: XCTestCase {
    var app: XCUIApplication!

    override func setUp() {
        continueAfterFailure = false
        app = UITestApp.launchDemo(.console)
    }

    /// Both the global-default row and a per-Host row render and push
    /// their own editing surface.
    func testHostRowsRenderWithIconsAndNavigate() {
        openSettings()

        let row = app.buttons["Agent List Fields"].firstMatch
        XCTAssertTrue(
            row.waitForExistence(timeout: UITestTimeouts.standard),
            "the Agent List Fields row must render on Settings")
        row.tap()

        XCTAssertTrue(
            app.navigationBars["Agent List Fields"].firstMatch
                .waitForExistence(timeout: UITestTimeouts.standard),
            "the Agent List Fields page never pushed")

        // The global-default row renders (identifier is the page's own
        // stable contract).
        let globalRow = app.descendants(matching: .any)
            .matching(identifier: "settings.agentList.global").firstMatch
        XCTAssertTrue(
            globalRow.waitForExistence(timeout: UITestTimeouts.standard),
            "the global default row never rendered")

        // At least one per-Host row renders alongside it — the row the
        // desktopcomputer icon rides.
        let hostRow = app.descendants(matching: .any)
            .matching(NSPredicate(
                format: "identifier BEGINSWITH %@", "settings.agentList.host."))
            .firstMatch
        XCTAssertTrue(
            hostRow.waitForExistence(timeout: UITestTimeouts.standard),
            "no per-Host row rendered — the hostRow surface is missing")

        captureScreenshot(
            app, "agent-list-fields-host-rows", lifetime: .keepAlways)

        // The row pushes its own editing surface.
        hostRow.tap()
        XCTAssertTrue(
            app.waitForPushedDetail(),
            "the Host row never pushed its field editor")
    }

    private func openSettings() {
        let wideSidebar = app.otherElements["App destinations"].firstMatch
        if wideSidebar.waitForExistence(timeout: 2) {
            let settings = wideSidebar.buttons["Settings"].firstMatch
            XCTAssertTrue(
                settings.waitForExistence(timeout: UITestTimeouts.standard),
                "the wide sidebar must offer Settings")
            settings.tap()
        } else {
            let trigger = app.buttons[UITestFixtures.navigationTrigger]
                .firstMatch
            XCTAssertTrue(
                trigger.waitForExistence(timeout: UITestTimeouts.launch))
            trigger.tap()
            let settings = app.buttons["Settings"].firstMatch
            XCTAssertTrue(
                settings.waitForExistence(timeout: UITestTimeouts.standard))
            settings.tap()
        }
        XCTAssertTrue(
            app.staticTexts["Notifications"].firstMatch
                .waitForExistence(timeout: UITestTimeouts.standard),
            "the Settings page must mount")
    }
}
