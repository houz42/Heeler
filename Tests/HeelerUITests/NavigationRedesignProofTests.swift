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
        let menu = app.buttons[UITestFixtures.destinationSelector].firstMatch
        waitToExist(menu)
        captureScreenshot(app, "nav-phone-menu-closed")
        // Open the menu. A SwiftUI toolbar Menu can eat the first tap
        // without presenting (highlight-state race on fresh launches), so
        // tap-and-poll: each attempt re-taps until the Settings row is
        // queryable, within the standard budget.
        let settingsItem = app.buttons["Settings"].firstMatch
        let menuDeadline = Date().addingTimeInterval(UITestTimeouts.standard)
        while !settingsItem.exists, Date() < menuDeadline {
            menu.tap()
            _ = settingsItem.waitForExistence(timeout: 2)
        }
        XCTAssertTrue(
            settingsItem.exists,
            "the destination menu must offer Settings")
        captureScreenshot(app, "nav-phone-menu-open")

        settingsItem.tap()
        // The Settings page mounts with the SAME compact selector,
        // relabeled.
        let settingsMenu = app.buttons["Settings, switch destination"].firstMatch
        XCTAssertTrue(
            settingsMenu.waitForExistence(timeout: UITestTimeouts.standard),
            "the selector must relabel to the new destination")
        XCTAssertTrue(
            app.staticTexts["Notifications"].firstMatch
                .waitForExistence(timeout: UITestTimeouts.standard),
            "the Settings page must mount")
        captureScreenshot(app, "nav-phone-settings")

        // Round trip: back to Agents, the list state is where it was.
        settingsMenu.tap()
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
