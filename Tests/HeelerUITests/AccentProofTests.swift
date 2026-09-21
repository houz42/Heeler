import XCTest

// SPDX-License-Identifier: Apache-2.0

/// Accent (v2 redesign) proofs: the app-wide accent is the design pair
/// (light #22644D, dark #9ACFB2) driven by ONE adaptive asset
/// (Assets.xcassets/AccentColor), so every accent surface — agent tiles,
/// chat author lines, settings controls, route in-use dots — reads green.
/// These capture each surface in BOTH appearances: the suite is run twice
/// (`xcrun simctl ui <udid> appearance light|dark` before each run — the
/// app follows System), with ACCENT_APPEARANCE tagging attachment names.
/// Assertions ride the accessibility tree (surfaces mounted and showing
/// the accent-bearing content); the screenshots carry the colour proof.
@MainActor
final class AccentProofTests: XCTestCase {

    /// Appearance tag for attachment names ("light"/"dark"); falls back
    /// to "system" when the runner was launched without one.
    private static var appearance: String {
        ProcessInfo.processInfo.environment["ACCENT_APPEARANCE"] ?? "system"
    }

    // MARK: Agents list (kind tiles + viewbar chips)

    func testAgentsListAccentSurfaces() {
        let app = UITestApp.launchDemo(.console)
        let row = app.buttons.matching(
            NSPredicate(format: "label CONTAINS %@", UITestFixtures.chatAgentRow)
        ).firstMatch
        XCTAssertTrue(
            row.waitForExistence(timeout: UITestTimeouts.standard),
            "the demo roster must be on screen (the agents list surface)")
        captureScreenshot(
            app, "accent-agents-list-\(Self.appearance)", lifetime: .keepAlways)
    }

    // MARK: Chat (author line + composer affordances)

    func testChatAccentSurfaces() {
        let app = UITestApp.launchDemo(.console)
        let cell = app.buttons.matching(
            NSPredicate(format: "label CONTAINS %@", UITestFixtures.chatAgentRow)
        ).firstMatch
        XCTAssertTrue(
            cell.waitForExistence(timeout: UITestTimeouts.standard),
            "the chat-bearing agent row must be tappable")
        cell.tap()

        XCTAssertTrue(
            app.waitForPushedDetail(),
            "tapping the chat-bearing row must open the pushed detail")
        // The transcript's known fixture line (the same one the reading
        // proofs wait on) proves the chat surface mounted; the assistant
        // articles' accent author lines ride the screenshot.
        let message = app.staticTexts.matching(
            NSPredicate(format: "label CONTAINS %@", "Long-run verification notes")
        ).firstMatch
        XCTAssertTrue(
            message.waitForExistence(timeout: UITestTimeouts.standard),
            "the demo transcript must render on the chat surface")
        captureScreenshot(
            app, "accent-chat-\(Self.appearance)", lifetime: .keepAlways)
    }

    // MARK: Settings (picker + link rows)

    func testSettingsAccentSurfaces() {
        let app = UITestApp.launchDemo(.console)
        openSettings(app)
        XCTAssertTrue(
            app.staticTexts["Notifications"].firstMatch
                .waitForExistence(timeout: UITestTimeouts.standard),
            "the Settings page must mount")
        // The Appearance picker row: its selected-value text reads the
        // accent — the control the screenshot must carry.
        let appearance = app.buttons.matching(
            NSPredicate(format: "label BEGINSWITH %@", "Appearance")
        ).firstMatch
        XCTAssertTrue(
            appearance.waitForExistence(timeout: UITestTimeouts.standard),
            "the Appearance picker row must be present")
        captureScreenshot(
            app, "accent-settings-\(Self.appearance)", lifetime: .keepAlways)
    }

    /// Settings opens from the drawer (the settings reading proofs'
    /// width-aware shape).
    private func openSettings(_ app: XCUIApplication) {
        let wideSidebar = app.otherElements["App destinations"].firstMatch
        if wideSidebar.waitForExistence(timeout: 2) {
            let settings = wideSidebar.buttons["Settings"].firstMatch
            XCTAssertTrue(
                settings.waitForExistence(timeout: UITestTimeouts.standard))
            settings.tap()
        } else {
            let trigger = app.buttons[UITestFixtures.navigationTrigger].firstMatch
            XCTAssertTrue(trigger.waitForExistence(timeout: UITestTimeouts.launch))
            trigger.tap()
            let settings = app.buttons["Settings"].firstMatch
            XCTAssertTrue(
                settings.waitForExistence(timeout: UITestTimeouts.standard))
            settings.tap()
        }
    }

    // MARK: Host routes (the in-use dot)

    func testHostRouteInUseDotAccent() {
        let app = UITestApp.launchDemo(.hostList)
        let inUseRow = app.buttons["host-route-studio.demo.invalid"].firstMatch
        XCTAssertTrue(
            inUseRow.waitForExistence(timeout: UITestTimeouts.standard),
            "the Studio Mac in-use route row must be on the card")
        captureScreenshot(
            app, "accent-host-route-dot-\(Self.appearance)", lifetime: .keepAlways)
    }
}
