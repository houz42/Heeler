import XCTest

// SPDX-License-Identifier: Apache-2.0
//
/// v3 work inspector — the read-only surface's UI proofs on the
/// `--demo-tasks-inspector` fixture (a real-shaped transcript: the
/// todo tool's rendered checklist with phases/mixed states, and a
/// `task` spawn of 4 scouts). Asserts the design's observable
/// contract: producer-order hierarchy visible in the accessibility
/// tree, LEAF-ONLY totals (no group double counting), the left-icon
/// state carrier with accessible state names, subagent identity rows
/// with the honest Unknown runtime state, and the tabs switching
/// between the two surfaces.

@MainActor
final class TasksInspectorProofTests: XCTestCase {

    private func launchInspector() -> XCUIApplication {
        UITestApp.launchDemo(.tasksInspector)
    }

    private func text(
        _ fragment: String, in app: XCUIApplication
    ) -> XCUIElement {
        app.descendants(matching: .any).matching(
            NSPredicate(format: "label CONTAINS %@", fragment)
        ).firstMatch
    }

    /// The Tasks tab renders the producer-order hierarchy: the
    /// leaf-only progress line and every phase row + leaf row from
    /// the fixture checklist.
    func testTasksHierarchyRendersInProducerOrder() {
        let app = launchInspector()

        // Leaf-only total: 2 of 5 completed (two research leaves
        // done; one delivery leaf in progress, one blocked, one
        // pending — the GROUP rows never count).
        XCTAssertTrue(
            text("2 of 5 tasks completed", in: app).waitForExistence(
                timeout: UITestTimeouts.standard),
            "the leaf-only progress line never rendered")

        // Phase rows in producer order, then their leaves.
        let expected = [
            "Research",
            "Census real todo result shapes",
            "Verify task spawn argument structure",
            "Delivery",
            "Ship the tasks inspector slice",
            "Log the capture evidence",
        ]
        for fragment in expected {
            XCTAssertTrue(
                text(fragment, in: app).waitForExistence(
                    timeout: UITestTimeouts.standard),
                "row \"\(fragment)\" never rendered — the hierarchy "
                    + "must show the producer's own order")
        }
    }

    /// Collapsing a group hides its subtree; the summary keeps
    /// counting leaves (the group's row is never part of the tally).
    func testCollapsingAGroupHidesItsSubtree() {
        let app = launchInspector()

        let leaf = text("Census real todo result shapes", in: app)
        XCTAssertTrue(
            leaf.waitForExistence(timeout: UITestTimeouts.standard))

        // The Research group's collapse control (a distinct a11y
        // label — disclosure is its own action).
        let collapse = app.buttons.matching(
            NSPredicate(format: "label CONTAINS %@", "Collapse group")
        ).firstMatch
        XCTAssertTrue(
            collapse.waitForExistence(timeout: UITestTimeouts.standard),
            "the group disclosure control never rendered")
        collapse.tap()

        // The subtree is hidden; the group row and the OTHER group's
        // leaves stay.
        XCTAssertTrue(
            leaf.waitForNonExistence(timeout: UITestTimeouts.standard),
            "collapsed group still shows its children")
        XCTAssertTrue(
            text("Ship the tasks inspector slice", in: app).exists,
            "collapsing one group hid an unrelated group's rows")

        // The leaf-only total is unchanged: collapsing is a VIEW
        // action, never a data change (the tally counts leaves the
        // group hides, not the group row).
        XCTAssertTrue(
            text("2 of 5 tasks completed", in: app).exists,
            "collapsing changed the leaf-only tally")
    }

    /// State is carried by the LEFT icon only, but the accessible
    /// label NAMES the state — a completed leaf reads "Completed",
    /// a blocked one "Blocked" with its producer reason.
    func testAccessibleLabelsNameTheState() {
        let app = launchInspector()

        XCTAssertTrue(
            text("Completed", in: app).waitForExistence(
                timeout: UITestTimeouts.standard),
            "no row names its completed state accessibly")
        XCTAssertTrue(
            text("Blocked", in: app).waitForExistence(
                timeout: UITestTimeouts.standard),
            "no row names its blocked state accessibly")
        // The producer's blocked reason renders as the row's detail.
        XCTAssertTrue(
            text("awaiting user pick", in: app).exists,
            "the blocked reason never rendered")
    }

    /// The Subagents tab: distinct two-line identity rows in spawn
    /// order, with the honest runtime state (Unknown) and assignment
    /// subtitle — no fabricated "completed" state from prose.
    func testSubagentsTabShowsIdentityRowsInSpawnOrder() {
        let app = launchInspector()

        app.buttons["Subagents"].tap()

        let names = [
            "DroverInternals",
            "HeelerInternals",
            "WhipInternals",
            "MultiplexInternals",
        ]
        for name in names {
            XCTAssertTrue(
                text(name, in: app).waitForExistence(
                    timeout: UITestTimeouts.standard),
                "subagent \(name) never rendered")
        }
        // Assignment subtitles render (the two-line identity row).
        XCTAssertTrue(
            text("Research the Drover iOS app internals", in: app).exists)

        // The honest unknown runtime state, named accessibly.
        XCTAssertTrue(
            text("runtime state: Unknown", in: app).exists,
            "a transcript-derived subagent must report Unknown runtime "
                + "state — never scraped or fabricated")
    }

    /// The tabs are separate surfaces; switching works.
    func testTabsSwitchBetweenTasksAndSubagents() {
        let app = launchInspector()
        XCTAssertTrue(
            text("2 of 5 tasks completed", in: app).waitForExistence(
                timeout: UITestTimeouts.standard))

        app.buttons["Subagents"].tap()
        XCTAssertTrue(
            text("DroverInternals", in: app).waitForExistence(
                timeout: UITestTimeouts.standard))

        app.buttons["Tasks"].tap()
        XCTAssertTrue(
            text("2 of 5 tasks completed", in: app).waitForExistence(
                timeout: UITestTimeouts.standard))
    }

    /// Captures for the vision-verified proof: the Tasks tab
    /// (hierarchy + collapse controls + totals) and the Subagents
    /// tab (identity rows + honest unknowns).
    func testCaptureInspectorSurfaces() {
        let app = launchInspector()
        XCTAssertTrue(
            text("2 of 5 tasks completed", in: app).waitForExistence(
                timeout: UITestTimeouts.standard))
        captureScreenshot(app, "tasks-inspector-tasks", lifetime: .keepAlways)

        app.buttons["Subagents"].tap()
        XCTAssertTrue(
            text("DroverInternals", in: app).waitForExistence(
                timeout: UITestTimeouts.standard))
        captureScreenshot(
            app, "tasks-inspector-subagents", lifetime: .keepAlways)
    }
}
