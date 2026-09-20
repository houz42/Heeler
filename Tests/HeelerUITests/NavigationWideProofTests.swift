import XCTest

// SPDX-License-Identifier: Apache-2.0

/// Navigation redesign (#A, narrow-sidebar revision) proofs, WIDE layouts:
/// the hamburger trigger beside the plain page title toggles the 184 pt
/// reserved sidebar (AX "Collapse/Expand navigation sidebar"); the fold
/// persists across a pushed-detail round trip; a chat selection hides ALL
/// destination chrome. Runs on iPad-class simulators — the phone drawer
/// proofs live in NavigationRedesignProofTests.
@MainActor
final class NavigationWideProofTests: XCTestCase {
    var app: XCUIApplication!

    override func setUp() {
        continueAfterFailure = false
        app = UITestApp.launchDemo(.console)
    }

    override func tearDown() {
        app.terminate()
    }

    /// Taps a labeled element without a type constraint: SwiftUI toolbar
    /// buttons intermittently mismatch Button vs PopUpButton between the
    /// legacy and modern AX attributes, which makes typed taps throw — the
    /// any-type query taps the same element.
    private func tapAnyLabeled(_ label: String) {
        let element = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label == %@", label)).firstMatch
        XCTAssertTrue(
            element.waitForExistence(timeout: UITestTimeouts.standard),
            "\(label) must exist to be tapped")
        element.tap()
    }

    func testWideSidebarToggleFoldPersistenceAndChromeHide() {
        // iPad portrait opens the Console's agent-list column hidden
        // (detailOnly); the heading lives in that column, so reveal the
        // list through the split's own control first.
        let showAgentsList = app.buttons["Show Sidebar"].firstMatch
        XCTAssertTrue(
            showAgentsList.waitForExistence(timeout: UITestTimeouts.launch),
            "the split must offer its own reveal control at launch")
        showAgentsList.tap()

        // The wide root page carries the collapse trigger, and the
        // reserved sidebar column lists the destinations.
        let trigger = app.buttons["Collapse navigation sidebar"].firstMatch
        XCTAssertTrue(
            trigger.waitForExistence(timeout: UITestTimeouts.standard),
            "the wide root page must carry the collapse trigger once its "
                + "agents column is on stage")
        let sidebar = app.otherElements["App destinations"].firstMatch
        let sidebarHosts = sidebar.buttons["Hosts"].firstMatch
        XCTAssertTrue(
            sidebarHosts.waitForExistence(timeout: UITestTimeouts.standard),
            "the expanded sidebar must expose its destination buttons")
        captureScreenshot(app, "nav2-wide-sidebar-open", lifetime: .keepAlways)

        // Fold: the sidebar leaves the tree; the trigger flips to expand.
        tapAnyLabeled("Collapse navigation sidebar")
        let expand = app.buttons["Expand navigation sidebar"].firstMatch
        XCTAssertTrue(
            expand.waitForExistence(timeout: UITestTimeouts.standard),
            "the trigger must flip to expand")
        XCTAssertFalse(
            sidebar.exists,
            "the folded sidebar must be gone from the tree")
        captureScreenshot(app, "nav2-wide-sidebar-collapsed", lifetime: .keepAlways)

        // Unfold, then switch to Settings through the sidebar.
        tapAnyLabeled("Expand navigation sidebar")
        XCTAssertTrue(
            sidebarHosts.waitForExistence(timeout: UITestTimeouts.standard),
            "the sidebar must return")
        sidebarHosts.tap()
        let settingsTrigger = app.buttons["Collapse navigation sidebar"].firstMatch
        XCTAssertTrue(
            settingsTrigger.waitForExistence(timeout: UITestTimeouts.standard),
            "the Settings page must carry the same wide trigger")

        // Fold HERE, then push Settings' Text Size sub-page: ALL
        // destination chrome hides; Back restores the page with its prior
        // FOLDED sidebar state.
        tapAnyLabeled("Collapse navigation sidebar")
        let settingsExpand = app.buttons["Expand navigation sidebar"].firstMatch
        XCTAssertTrue(
            settingsExpand.waitForExistence(timeout: UITestTimeouts.standard))
        // Tap through the row's static text (the enclosing Button is
        // 992 pt wide on the folded wide layout; the text tap lands the
        // NavigationLink reliably), then assert the PUSH by its content
        // — the System row the detail page renders — not by the nav bar
        // title (hidden pages' nav bars can linger in the AX tree).
        let textRow = app.staticTexts["Text Size"].firstMatch
        waitToExist(textRow)
        textRow.tap()
        let systemRow = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label == %@", "System")).firstMatch
        XCTAssertTrue(
            systemRow.waitForExistence(timeout: UITestTimeouts.standard),
            "the Text Size sub-page must push and show the System choice")
        // The hidden-but-mounted Agents page keeps its trigger in the
        // AX tree; the contract is that no destination chrome is
        // REACHABLE — assert on hittability, not raw existence.
        XCTAssertFalse(
            app.buttons["Expand navigation sidebar"].firstMatch.isHittable,
            "the trigger must hide inside the pushed sub-page")
        captureScreenshot(app, "nav2-wide-subpage-no-chrome", lifetime: .keepAlways)

        // Back: the pushed page's own nav bar back button.
        let textPageBar = app.navigationBars.matching(
            NSPredicate(format: "label == %@", "Text Size")).firstMatch
        textPageBar.buttons.firstMatch.tap()
        XCTAssertTrue(
            settingsExpand.waitForExistence(timeout: UITestTimeouts.standard),
            "Back must restore the page with its prior FOLDED sidebar state")
        captureScreenshot(app, "nav2-wide-fold-restored", lifetime: .keepAlways)

        // Back on Agents: a chat selection also hides ALL destination
        // chrome on wide. (The chat is a column selection — no nav push —
        // so this stays at the proof's end.)
        tapAnyLabeled("Expand navigation sidebar")
        let agentsRow = app.buttons["Agents"].firstMatch
        waitToExist(agentsRow)
        agentsRow.tap()
        let agentsTrigger = app.buttons["Collapse navigation sidebar"].firstMatch
        XCTAssertTrue(
            agentsTrigger.waitForExistence(timeout: UITestTimeouts.standard),
            "the Agents page must carry the wide trigger")
        let cell = app.buttons.matching(
            NSPredicate(format: "label CONTAINS %@", "Polish the Attach experience")
        ).firstMatch
        waitToExist(cell)
        cell.tap()
        XCTAssertTrue(app.waitForPushedDetail(), "agent detail never shown")
        // Hidden-but-mounted pages keep their triggers in the AX tree;
        // the contract is that none is REACHABLE with a detail shown.
        let triggers = app.buttons.matching(
            NSPredicate(format: "label CONTAINS %@", "navigation sidebar"))
        var allInert = true
        for index in 0..<triggers.count where allInert {
            if triggers.element(boundBy: index).isHittable {
                allInert = false
            }
        }
        XCTAssertTrue(
            allInert,
            "no trigger may be hittable while a chat detail is shown")
        captureScreenshot(app, "nav2-wide-detail-no-chrome", lifetime: .keepAlways)
    }
}
