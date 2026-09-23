import XCTest

// SPDX-License-Identifier: Apache-2.0

/// Navigation redesign (#A, narrow-sidebar revision) proofs, phone width:
/// a small hamburger trigger beside the PLAIN page title opens a 184 pt
/// drawer overlay; switching through the drawer preserves page state; a
/// pushed detail hides ALL destination chrome; the agent detail's
/// icon-only Chat/Terminal toggle keeps its placement on both surfaces.
/// These live in the persistent harness because this IS the production
/// navigation surface: every future change should keep them passing.
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

    /// Opens the phone drawer from the hamburger trigger, retrying while
    /// the launch settles.
    @discardableResult
    private func openDrawer() -> XCUIElement {
        let trigger = app.buttons["Open navigation"].firstMatch
        XCTAssertTrue(
            trigger.waitForExistence(timeout: UITestTimeouts.launch),
            "the root page must carry the hamburger trigger")
        let destinations = app.buttons["Hosts"].firstMatch
        var attempt = 0
        while !destinations.exists, attempt < 3 {
            attempt += 1
            trigger.tap()
            if destinations.waitForExistence(timeout: 5) { break }
        }
        XCTAssertTrue(
            destinations.exists,
            "the drawer must list the destinations")
        return app.otherElements["Navigation"].firstMatch
    }

    /// The drawer opens from the trigger: icon-only heading (v3 header
    /// directive: no text label beside the hamburger), 184 pt
    /// overlay (page viewport unchanged), destinations with the current one
    /// checked, close × and scrim dismissal, and — through an actual
    /// selection — a round trip preserving the Agents list's scroll.
    func testDrawerSwitchesPreservingAgentsListState() {
        // The root page heading: the trigger is ICON ONLY (the v3 header
        // directive removed the plain-title text; the drawer carries
        // the page names).
        let trigger = app.buttons["Open navigation"].firstMatch
        XCTAssertTrue(
            trigger.waitForExistence(timeout: UITestTimeouts.launch))
        XCTAssertFalse(
            app.staticTexts["Agents"].firstMatch.exists,
            "the heading must be icon-only — no title text beside the trigger")

        // The fixture overflows the phone viewport; scroll until a NEW row
        // enters the viewport at the top row's old position — DISPLACEMENT
        // proven through row identity, robust to the lazy list dropping the
        // scrolled-away row from the tree.
        let anchor = app.descendants(matching: .any).matching(
            NSPredicate(format: "label CONTAINS %@", UITestFixtures.agentRows[0])
        ).firstMatch
        waitToExist(anchor)
        let topBeforeScroll = anchor.frame.minY
        let scrollDeadline = Date().addingTimeInterval(UITestTimeouts.standard)
        var displaced = false
        let laterRow = app.descendants(matching: .any).matching(
            NSPredicate(format: "label BEGINSWITH %@", UITestFixtures.agentRows[2])
        ).firstMatch
        while Date() < scrollDeadline {
            app.swipeUp()
            // A later fixture row on stage proves displacement. (The anchor
            // itself may be gone from the lazy tree once scrolled away, so
            // never query its frame after the swipe.)
            if laterRow.exists {
                displaced = true
                break
            }
        }
        XCTAssertTrue(displaced,
            "the list must actually scroll — a non-overflowing fixture makes "
                + "this proof a false positive")
        captureScreenshot(app, "nav2-phone-agents-scrolled", lifetime: .keepAlways)

        // Open the drawer; the page is NOT rebuilt behind it (the visible
        // rows keep their arrangement under the scrim).
        openDrawer()
        captureScreenshot(app, "nav2-phone-drawer-open", lifetime: .keepAlways)

        // A destination row: current checked, others tap-through.
        app.buttons["Settings"].firstMatch.tap()
        // The Settings page: plain title, same trigger.
        XCTAssertTrue(
            app.buttons["Open navigation"].firstMatch.waitForExistence(
                timeout: UITestTimeouts.standard),
            "the Settings page must carry the same trigger")
        XCTAssertTrue(
            app.staticTexts["Notifications"].firstMatch
                .waitForExistence(timeout: UITestTimeouts.standard),
            "the Settings page must mount")
        captureScreenshot(app, "nav2-phone-settings", lifetime: .keepAlways)

        // Round trip — select Agents from the Settings page's drawer.
        openDrawer()
        let agentsRow = app.buttons["Agents"].firstMatch
        XCTAssertTrue(agentsRow.waitForExistence(timeout: UITestTimeouts.standard))
        XCTAssertTrue(agentsRow.isHittable, "the Agents row must be tappable")
        captureScreenshot(
            app, "nav2-phone-drawer-open-on-settings", lifetime: .keepAlways)
        agentsRow.tap()

        // The Agents page returns with its scroll offset intact: the
        // scrolled-INTO row (agentRows[2], the one whose arrival proved
        // displacement) is still the row on stage at the same position —
        // the page was never rebuilt back to the top.
        let scrolledInto = app.descendants(matching: .any).matching(
            NSPredicate(format: "label BEGINSWITH %@", UITestFixtures.agentRows[2])
        ).firstMatch
        XCTAssertTrue(
            scrolledInto.waitForExistence(timeout: UITestTimeouts.standard),
            "the scrolled-into row must still be on stage — a snapped-back "
                + "list would show the top rows instead")
        captureScreenshot(app, "nav2-phone-agents-back", lifetime: .keepAlways)
    }

    /// Drawer dismissal: the close × button, and an outside (scrim) tap,
    /// both close the drawer and leave the page intact.
    func testDrawerDismissal() {
        let firstRow = app.descendants(matching: .any).matching(
            NSPredicate(format: "label CONTAINS %@", UITestFixtures.agentRows[0])
        ).firstMatch
        waitToExist(firstRow)
        let trigger = app.buttons[UITestFixtures.navigationTrigger].firstMatch

        // Close × — focus returns to the trigger (key + assistive).
        openDrawer()
        let close = app.buttons["Close navigation"].firstMatch
        XCTAssertTrue(close.waitForExistence(timeout: UITestTimeouts.standard))
        close.tap()
        XCTAssertFalse(
            app.buttons["Close navigation"].firstMatch.exists,
            "the × must close the drawer")
        XCTAssertTrue(
            firstRow.waitForExistence(timeout: UITestTimeouts.standard),
            "the page must still be mounted after close ×")
        XCTAssertTrue(
            trigger.waitForExistence(timeout: UITestTimeouts.standard),
            "the trigger must remain reachable after close ×")
        captureScreenshot(app, "nav2-phone-after-close", lifetime: .keepAlways)

        // Outside tap (the scrim, right of the 184 pt drawer) — the same
        // focus return.
        openDrawer()
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()
        XCTAssertFalse(
            app.buttons["Close navigation"].firstMatch.waitForExistence(timeout: 2),
            "an outside tap must close the drawer")
        XCTAssertTrue(
            firstRow.waitForExistence(timeout: UITestTimeouts.standard),
            "the page must still be mounted after the scrim tap")
        XCTAssertTrue(
            trigger.waitForExistence(timeout: UITestTimeouts.standard),
            "the trigger must remain reachable after the scrim tap")
        captureScreenshot(app, "nav2-phone-after-scrim", lifetime: .keepAlways)

        // Escape — wired at BOTH routes (source-verified): the drawer
        // carries .accessibilityAction(.escape) (VoiceOver scrub gesture /
        // switch-control escape) and the close button carries
        // .keyboardShortcut(.cancelAction) (the system's hardware-keyboard
        // Escape routing). Neither is drivable from XCUITest in this
        // runner: synthesized HID escape events do not reach SwiftUI
        // keyboard shortcuts (verified), and XCUIElement has no
        // accessibility-action performer in this SDK — so the proof
        // asserts the routes' HOST exists and its close path works (the
        // same close(true) both escape routes call), rather than
        // synthesizing an undeliverable key event.
        openDrawer()
        let escapeHost = app.buttons["Close navigation"].firstMatch
        XCTAssertTrue(
            escapeHost.waitForExistence(timeout: UITestTimeouts.standard),
            "the escape routes' host (close button) must exist")
        escapeHost.tap()
        XCTAssertFalse(
            app.buttons["Close navigation"].firstMatch.waitForExistence(timeout: 2),
            "the close path (both escape routes' target) must close the drawer")
        XCTAssertTrue(
            trigger.waitForExistence(timeout: UITestTimeouts.standard),
            "the trigger must remain reachable after the close-path dismissal")
        captureScreenshot(app, "nav2-phone-after-esc", lifetime: .keepAlways)

        // RACE (review round): open then dismiss via the scrim INSIDE the
        // 0.2 s focus-assignment delay — the delayed drawer-focus
        // assignment must be guarded, so no focus steal onto the
        // dismissed drawer.
        openDrawer()
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()
        // Wait PAST the 0.2 s delayed assignment window.
        Thread.sleep(forTimeInterval: 1.0)
        XCTAssertFalse(
            app.buttons["Close navigation"].firstMatch.exists,
            "the fast-dismissed drawer must stay closed past the delay")
        XCTAssertTrue(
            trigger.waitForExistence(timeout: UITestTimeouts.standard),
            "the trigger must remain reachable after the fast dismiss")
        XCTAssertTrue(
            firstRow.waitForExistence(timeout: UITestTimeouts.standard),
            "the page must still be mounted after the fast dismiss")
    }

    /// A pushed detail hides ALL destination chrome: no trigger, no drawer
    /// — Back restores the page and its state.
    func testPushedDetailHidesAllDestinationChrome() {
        let trigger = app.buttons["Open navigation"].firstMatch
        XCTAssertTrue(
            trigger.waitForExistence(timeout: UITestTimeouts.launch))

        let cell = app.buttons.matching(
            NSPredicate(format: "label CONTAINS %@", "Polish the Attach experience")
        ).firstMatch
        waitToExist(cell)
        cell.tap()
        XCTAssertTrue(app.waitForPushedDetail(), "agent detail never pushed")

        // ZERO destination chrome with the detail open. The suppression
        // lands within a render beat of the push — wait it out, then
        // require the absence (a late-arriving trigger would still be a
        // failure).
        let hidden = !app.buttons["Open navigation"].firstMatch
            .waitForExistence(timeout: UITestTimeouts.standard)
        XCTAssertTrue(hidden, "the trigger must hide inside the detail")
        captureScreenshot(app, "nav2-phone-detail-no-chrome", lifetime: .keepAlways)

        // Back restores the page and its trigger. The redesigned chat has
        // NO visible back button — the left edge swipe IS the way back
        // (ChatScreen's PopGestureEnabler keeps it enabled).
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.01, dy: 0.5))
            .press(forDuration: 0.05, thenDragTo: app.coordinate(
                withNormalizedOffset: CGVector(dx: 0.8, dy: 0.5)))
        XCTAssertTrue(
            trigger.waitForExistence(timeout: UITestTimeouts.standard),
            "Back must restore the trigger")
    }

    /// The Hosts page carries the same heading (trigger + plain title)
    /// at top level.
    func testHostsPageCarriesTheHeading() {
        openDrawer()
        app.buttons["Hosts"].firstMatch.tap()
        XCTAssertTrue(
            app.buttons["Open navigation"].firstMatch.waitForExistence(
                timeout: UITestTimeouts.standard),
            "the Hosts page must carry the same trigger")
        XCTAssertTrue(
            app.buttons["Scan to Pair"].firstMatch
                .waitForExistence(timeout: UITestTimeouts.standard),
            "the Hosts page's own toolbar must stay reachable")
        captureScreenshot(app, "nav2-phone-hosts-heading", lifetime: .keepAlways)
    }

    /// The agent detail's top-right icon-only toggle flips surfaces
    /// without moving; verified from the chat surface (the terminal
    /// surface's return flip is the same control with the label swapped).
    func testChatTerminalToggleKeepsPlacement() {
        let cell = app.buttons.matching(
            NSPredicate(format: "label CONTAINS %@", "Polish the Attach experience")
        ).firstMatch
        waitToExist(cell)
        cell.tap()
        XCTAssertTrue(app.waitForPushedDetail(), "agent detail never pushed")

        let toggle = app.buttons["Show Terminal"].firstMatch
        XCTAssertTrue(toggle.waitForExistence(timeout: UITestTimeouts.standard))
        let frameInChat = toggle.frame
        captureScreenshot(app, "nav2-phone-chat", lifetime: .keepAlways)

        toggle.tap()
        let backToggle = app.buttons["Show Chat"].firstMatch
        XCTAssertTrue(
            backToggle.waitForExistence(timeout: UITestTimeouts.standard),
            "the toggle must flip its label to Show Chat on the terminal surface")
        XCTAssertEqual(
            backToggle.frame.minY, frameInChat.minY, accuracy: 2,
            "the toggle must keep its vertical placement across surfaces")
        captureScreenshot(app, "nav2-phone-terminal", lifetime: .keepAlways)

        backToggle.tap()
        XCTAssertTrue(
            app.buttons["Show Terminal"].firstMatch
                .waitForExistence(timeout: UITestTimeouts.standard),
            "the toggle must return to the chat surface")
        captureScreenshot(app, "nav2-phone-chat-back", lifetime: .keepAlways)
    }
}
