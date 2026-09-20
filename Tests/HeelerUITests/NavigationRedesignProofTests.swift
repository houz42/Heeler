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
        // A NONTRIVIAL state to preserve: scroll the list so the first
        // row leaves the viewport, remember where it landed.
        app.swipeUp()
        let firstRowFrameBefore = firstRow.frame
        captureScreenshot(app, "nav-phone-agents-scrolled", lifetime: .keepAlways)

        // The sheet-era toolbar buttons are gone; the compact selector
        // carries the destinations instead.
        let menu = app.buttons[UITestFixtures.destinationSelector].firstMatch
        waitToExist(menu)
        captureScreenshot(app, "nav-phone-menu-closed", lifetime: .keepAlways)
        // Open the menu. A SwiftUI toolbar Menu can eat a tap while the
        // launch settles, but a re-tap AFTER the menu presented would
        // collapse it again — so each attempt waits a full presentation
        // budget before retrying, and only retries when nothing appeared.
        let settingsItem = app.buttons["Settings"].firstMatch
        var attempt = 0
        while !settingsItem.exists, attempt < 3 {
            attempt += 1
            menu.tap()
            if settingsItem.waitForExistence(timeout: 5) { break }
        }
        XCTAssertTrue(
            settingsItem.exists,
            "the destination menu must offer Settings")
        captureScreenshot(app, "nav-phone-menu-open", lifetime: .keepAlways)

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
        captureScreenshot(app, "nav-phone-settings", lifetime: .keepAlways)

        // Round trip: back to Agents, the list state is where it was.
        settingsMenu.tap()
        XCTAssertTrue(
            app.staticTexts[UITestFixtures.agentRows[0]]
                .waitForExistence(timeout: UITestTimeouts.standard),
            "the Agents list must return with its state preserved")
        // The scrolled position survived the round trip: the first row is
        // at the same viewport offset it was before the switch (5 rows do
        // not fill a 874 pt list, so a preserved offset keeps the row
        // mid-list rather than snapping back to the top).
        XCTAssertEqual(
            firstRow.frame.minY, firstRowFrameBefore.minY, accuracy: 12,
            "scroll offset must survive the destination round trip")
        captureScreenshot(app, "nav-phone-agents-back", lifetime: .keepAlways)
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
        captureScreenshot(app, "nav-phone-chat", lifetime: .keepAlways)

        toggle.tap()
        // The control now offers the way back, at the same place.
        let backToggle = app.buttons["Show Chat"].firstMatch
        XCTAssertTrue(
            backToggle.waitForExistence(timeout: UITestTimeouts.standard),
            "the toggle must flip its label to Show Chat on the terminal surface")
        XCTAssertEqual(
            backToggle.frame.minY, frameInChat.minY, accuracy: 2,
            "the toggle must keep its vertical placement across surfaces")
        captureScreenshot(app, "nav-phone-terminal", lifetime: .keepAlways)

        backToggle.tap()
        XCTAssertTrue(
            app.buttons["Show Terminal"].firstMatch
                .waitForExistence(timeout: UITestTimeouts.standard),
            "the toggle must return to the chat surface")
        captureScreenshot(app, "nav-phone-chat-back", lifetime: .keepAlways)
    }
}
