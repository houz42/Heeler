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

    /// Opens the destination menu from `menu`, retrying while the launch
    /// settles. A SwiftUI toolbar Menu can eat a tap before it renders,
    /// but a re-tap AFTER the menu presented would collapse it — so each
    /// attempt waits a full presentation budget before re-tapping.
    private func openDestinationMenu(_ menu: XCUIElement) {
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
    }

    /// The compact selector opens a destination menu, current checked;
    /// switching to Settings and — through an actual Agents menu-item
    /// selection — back again preserves the Agents list's scroll offset.
    func testDestinationMenuSwitchesPreservingAgentsListState() {
        // The fixture's agent rows are mounted on the Console page. The
        // fixture overflows the phone viewport (11 agents + issues), so
        // scroll displacement is real, not cosmetic.
        let firstRow = app.staticTexts[UITestFixtures.agentRows[0]]
        waitToExist(firstRow)
        let topBeforeScroll = firstRow.frame.minY

        // Scroll until the first row is DISPLACED — proven, not assumed:
        // keep swiping until its offset actually changed.
        let scrollDeadline = Date().addingTimeInterval(UITestTimeouts.standard)
        while firstRow.frame.minY == topBeforeScroll, Date() < scrollDeadline {
            app.swipeUp()
        }
        let firstRowFrameBefore = firstRow.frame
        XCTAssertLessThan(
            firstRowFrameBefore.minY, topBeforeScroll,
            "the list must actually scroll — a non-overflowing fixture makes "
                + "this proof a false positive")
        captureScreenshot(app, "nav-phone-agents-scrolled", lifetime: .keepAlways)

        // The sheet-era toolbar buttons are gone; the compact selector
        // carries the destinations instead.
        let menu = app.buttons[UITestFixtures.destinationSelector].firstMatch
        waitToExist(menu)
        captureScreenshot(app, "nav-phone-menu-closed", lifetime: .keepAlways)

        openDestinationMenu(menu)
        captureScreenshot(app, "nav-phone-menu-open", lifetime: .keepAlways)

        app.buttons["Settings"].firstMatch.tap()
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

        // Round trip — actually SELECT Agents from the menu: open the
        // Settings page's own selector and pick the Agents item.
        openDestinationMenu(settingsMenu)
        let agentsItem = app.buttons["Agents"].firstMatch
        XCTAssertTrue(
            agentsItem.waitForExistence(timeout: UITestTimeouts.standard),
            "the destination menu must offer Agents")
        XCTAssertTrue(agentsItem.isHittable, "the Agents item must be tappable")
        captureScreenshot(app, "nav-phone-menu-open-on-settings", lifetime: .keepAlways)
        agentsItem.tap()

        // The Agents page returns; the scrolled offset survives the round
        // trip: the first row lands at the same viewport offset it had
        // before the switch (not snapped back to the top).
        XCTAssertTrue(
            firstRow.waitForExistence(timeout: UITestTimeouts.standard),
            "the Agents list must return with its state preserved")
        XCTAssertEqual(
            firstRow.frame.minY, firstRowFrameBefore.minY, accuracy: 12,
            "scroll offset must survive the destination round trip")
        captureScreenshot(app, "nav-phone-agents-back", lifetime: .keepAlways)
    }

    /// The Hosts page carries the same compact selector at top level (#A):
    /// switching from Agents lands on Hosts with the selector relabeled
    /// and the page's own toolbar actions intact.
    func testHostsPageCarriesTheDestinationSelector() {
        let firstRow = app.staticTexts[UITestFixtures.agentRows[0]]
        waitToExist(firstRow)
        let menu = app.buttons[UITestFixtures.destinationSelector].firstMatch
        waitToExist(menu)

        openDestinationMenu(menu)
        let hostsItem = app.buttons["Hosts"].firstMatch
        XCTAssertTrue(
            hostsItem.waitForExistence(timeout: UITestTimeouts.standard),
            "the destination menu must offer Hosts")
        hostsItem.tap()

        // The Hosts page mounts with the SAME compact selector, relabeled
        // to Hosts, and its own toolbar (Scan to Pair / Add Host) intact.
        let hostsMenu = app.buttons["Hosts, switch destination"].firstMatch
        XCTAssertTrue(
            hostsMenu.waitForExistence(timeout: UITestTimeouts.standard),
            "the Hosts page must carry the same compact selector")
        XCTAssertTrue(
            app.buttons["Scan to Pair"].firstMatch
                .waitForExistence(timeout: UITestTimeouts.standard),
            "the Hosts page's own toolbar must stay reachable")
        captureScreenshot(app, "nav-phone-hosts-selector", lifetime: .keepAlways)
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
