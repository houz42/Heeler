import XCTest

/// The v2 grouped agent-row layout (row-content directive): grouped by
/// workspace, each WORKSPACE header shows the full three-part context
/// path `host · session · workspace`, and each AGENT row is two lines —
/// the herdr TAB label on line 1, the agent TITLE as the secondary
/// subtitle on line 2. Demo fixture via `launchDemo(.console)`: 2 hosts
/// (Studio Mac session "main", Build Server session "ci"), workspaces
/// iOS App / Product Docs / Checkout / Payments API, every tab labeled
/// "work".
///
/// Locators: a grouped row is a `Button` whose AX LABEL combines both
/// lines (tab + title + kind + status); the group header is a `Button`
/// whose AX LABEL is "<workspace>, N agents" — the header's rendered
/// `host · session · workspace` path rides the AX VALUE's expanded
/// static texts, so the proof matches the visible static texts directly.
@MainActor
final class AgentListRowLayoutProofTests: XCTestCase {
    var app: XCUIApplication!

    override func setUp() {
        continueAfterFailure = false
        app = UITestApp.launchDemo(.console)
    }

    override func tearDown() {
        app.terminate()
    }

    private func row(containing text: String) -> XCUIElement {
        app.buttons.matching(
            NSPredicate(format: "label CONTAINS %@", text)).firstMatch
    }

    private func staticText(containing text: String) -> XCUIElement {
        app.staticTexts.matching(
            NSPredicate(format: "label CONTAINS %@", text)).firstMatch
    }

    /// Selects the Workspace grouping through the view menu (the same
    /// interaction path the redesign proofs use for Host/State).
    private func selectWorkspaceGrouping() {
        let menu = app.buttons["Agent list view options"].firstMatch
        XCTAssertTrue(menu.waitForExistence(timeout: UITestTimeouts.standard))
        menu.tap()
        let grouping = app.buttons["Grouping"].firstMatch
        XCTAssertTrue(grouping.waitForExistence(timeout: 5))
        grouping.tap()
        // The chooser's options can sit below the fold — scroll before
        // selecting.
        app.swipeUp(velocity: .fast)
        let workspace = app.buttons["Workspace"].firstMatch
        XCTAssertTrue(
            workspace.waitForExistence(timeout: UITestTimeouts.standard),
            "the grouping chooser must offer Workspace")
        workspace.tap()
        let done = app.buttons["Done"].firstMatch
        if done.waitForExistence(timeout: 5) {
            done.tap()
        }
    }

    // MARK: The workspace header — full context path

    func testWorkspaceHeadersCarryHostSessionWorkspacePath() {
        selectWorkspaceGrouping()
        // The iOS App group (Studio Mac · session main): the header's
        // quiet context line is the full three-part path. The header is a
        // combined AX element, so the path rides its value/label surface —
        // match the rendered path text directly.
        let studioPath = staticText(containing: "Studio Mac · main · iOS App")
        XCTAssertTrue(
            studioPath.waitForExistence(timeout: UITestTimeouts.standard),
            "the iOS App workspace header must carry the full host · session · workspace path")
        // The Build Server's Checkout group: session ci.
        let checkoutPath = staticText(containing: "Build Server · ci · Checkout")
        XCTAssertTrue(
            checkoutPath.waitForExistence(timeout: UITestTimeouts.standard),
            "the Checkout workspace header must carry the Build Server/ci context path")
        // The workspace's own name is the header's primary title.
        XCTAssertTrue(staticText(containing: "iOS App").exists)
        captureScreenshot(app, "agents-v2-workspace-headers-context-path",
            lifetime: .keepAlways)
    }

    // MARK: The agent row — two lines: tab, then title

    func testAgentRowsAreTabThenTitleTwoLines() {
        selectWorkspaceGrouping()
        // The row's AX label combines both rendered lines: line 1 is the
        // TAB label ("work" in the fixture), line 2 the agent TITLE. The
        // tab must precede the title in the label (reading order = line
        // order) — the two-line layout, as the AX tree sees it.
        let polish = row(containing: "Polish the Attach experience")
        XCTAssertTrue(
            polish.waitForExistence(timeout: UITestTimeouts.standard),
            "the row must carry the agent title")
        let label = polish.label
        let tabRange = label.range(of: "work")
        let titleRange = label.range(of: "Polish the Attach experience")
        XCTAssertTrue(tabRange != nil && titleRange != nil,
                      "the row must carry both the tab and the title: \(label)")
        if let tabRange, let titleRange {
            XCTAssertTrue(
                tabRange.lowerBound < titleRange.lowerBound,
                "the TAB label must ride line 1, above the title: \(label)")
        }
        // The host/session/workspace context does NOT ride the row label —
        // the group header above owns it (nothing crowds the tab line).
        XCTAssertFalse(label.contains("Studio Mac"),
                       "host context must live on the workspace header, not the row: \(label)")
        XCTAssertFalse(label.contains("iOS App"),
                       "workspace context must live on the workspace header, not the row: \(label)")
        // The row's AX value still names the full identity for VoiceOver.
        let identity = polish.value as? String ?? ""
        XCTAssertTrue(identity.contains("Host Studio Mac"), "host must ride the row identity: \(identity)")
        XCTAssertTrue(identity.contains("session main"), "session must ride the row identity: \(identity)")
        XCTAssertTrue(identity.contains("workspace iOS App"), "workspace must ride the row identity: \(identity)")
        XCTAssertTrue(identity.contains("tab work"), "tab must ride the row identity: \(identity)")
        captureScreenshot(app, "agents-v2-row-tab-then-title", lifetime: .keepAlways)
    }
}
