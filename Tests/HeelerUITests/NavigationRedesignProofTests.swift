import XCTest

// SPDX-License-Identifier: Apache-2.0

/// Navigation redesign (#A) proofs, phone width: the compact top-left
/// destination selector replaces the bottom-sheet-era toolbar buttons —
/// it opens a menu with the current destination checked, switches pages,
/// and a round trip preserves the Agents list state. The agent detail's
/// icon-only Chat/Terminal toggle keeps its placement on both surfaces.
///
/// These live in the persistent harness (not a temp target) because the
/// destination menu IS the production navigation surface: every future
/// change to it should keep these passing.
@MainActor
final class NavigationRedesignProofTests: XCTestCase {
    var app: XCUIApplication!

    override func setUp() {
        continueAfterFailure = false
        app = UITestApp.launchDemo(.console)
    }

    override func tearDown() {
        app.terminate()
    }

    /// The compact selector opens a destination menu, current checked;
    /// switching to Hosts and back preserves the Agents list.
    func testDestinationMenuSwitchesPreservingAgentsListState() {
        // The fixture's agent rows are mounted on the Console page.
        let firstRow = app.staticTexts[UITestFixtures.agentRows[0]]
        waitToExist(firstRow)
        captureScreenshot(app, "nav-phone-agents")

        // The sheet-era toolbar buttons are gone; the compact selector
        // carries the destinations instead.
        let menu = app.buttons["Agents, switch destination"].firstMatch
        waitToExist(menu)
        captureScreenshot(app, "nav-phone-menu-closed")

        menu.tap()
        // The menu lists all three destinations, the current one checked
        // (a Menu-Picker renders the checkmark as the selected control).
        let hostsItem = app.buttons["Hosts"].firstMatch
        XCTAssertTrue(
            hostsItem.waitForExistence(timeout: UITestTimeouts.standard),
            "the destination menu must offer Hosts")
        XCTAssertTrue(
            app.buttons["Settings"].firstMatch.exists,
            "the destination menu must offer Settings")
        captureScreenshot(app, "nav-phone-menu-open")

        hostsItem.tap()
        // The Hosts page mounts with the SAME compact selector, relabeled.
        let hostsMenu = app.buttons["Hosts, switch destination"].firstMatch
        XCTAssertTrue(
            hostsMenu.waitForExistence(timeout: UITestTimeouts.standard),
            "the selector must relabel to the new destination")
        captureScreenshot(app, "nav-phone-hosts")

        // Round trip: back to Agents, the list state is where it was.
        hostsMenu.tap()
        let agentsItem = app.buttons["Agents"].firstMatch
        XCTAssertTrue(
            agentsItem.waitForExistence(timeout: UITestTimeouts.standard))
        agentsItem.tap()
        XCTAssertTrue(
            app.staticTexts[UITestFixtures.agentRows[0]]
                .waitForExistence(timeout: UITestTimeouts.standard),
            "the Agents list must return with its state preserved")
        captureScreenshot(app, "nav-phone-agents-back")
    }

    /// The agent detail's top-right icon-only toggle flips surfaces
    /// without moving; verified from the chat surface (the terminal
    /// surface's return flip is the same control with the label swapped).
    func testChatTerminalToggleKeepsPlacement() {
        let cell = app.cells.containing(
            NSPredicate(format: "label CONTAINS %@", "ios-polish")
        ).firstMatch
        waitToExist(cell)
        cell.tap()
        XCTAssertTrue(app.waitForPushedDetail(), "agent detail never pushed")

        let toggle = app.buttons["Show Terminal"].firstMatch
        XCTAssertTrue(toggle.waitForExistence(timeout: UITestTimeouts.standard))
        let frameInChat = toggle.frame
        captureScreenshot(app, "nav-phone-chat")

        toggle.tap()
        // The control now offers the way back, at the same place.
        let backToggle = app.buttons["Show Chat"].firstMatch
        XCTAssertTrue(
            backToggle.waitForExistence(timeout: UITestTimeouts.standard),
            "the toggle must flip its label to Show Chat on the terminal surface")
        XCTAssertEqual(
            backToggle.frame.minY, frameInChat.minY, accuracy: 2,
            "the toggle must keep its vertical placement across surfaces")
        captureScreenshot(app, "nav-phone-terminal")

        backToggle.tap()
        XCTAssertTrue(
            app.buttons["Show Terminal"].firstMatch
                .waitForExistence(timeout: UITestTimeouts.standard),
            "the toggle must return to the chat surface")
        captureScreenshot(app, "nav-phone-chat-back")
    }
}
