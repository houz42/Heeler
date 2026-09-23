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

// MARK: - Child-run proofs (live-registration observation)

/// The child-run proofs over the `--demo-tasks-inspector-childrun`
/// fixture: the same four-scout spawn LINKED with a real-shaped
/// live registration list. The contract: registered children show
/// Running (green) with the live chip and an honest Not-reported
/// verdict; unregistered children keep the honest Unknown; a
/// broker-only child gets its own row with the honest
/// no-assignment line. No fabricated completed/failed states, no
/// right-side text badges.
extension TasksInspectorProofTests {
    func testLiveRegistrationsUpgradeSpawnedRowsToRunning() {
        let app = UITestApp.launchDemo(.tasksInspectorChildRun)

        // The Subagents tab is the route's initial tab.
        // DroverInternals + HeelerInternals carry live
        // registrations: the accessible label names Running.
        XCTAssertTrue(
            text("DroverInternals", in: app).waitForExistence(
                timeout: UITestTimeouts.standard),
            "the spawned row never rendered")
        XCTAssertTrue(
            text("runtime state: Running", in: app).waitForExistence(
                timeout: UITestTimeouts.standard),
            "a live-registered child must report Running — "
                + "registration proves liveness")

        // Two live children → two Running SCOUT rows (the fixture
        // links exactly DroverInternals and HeelerInternals). Assert
        // per-row compound labels — an aggregate CONTAINS count also
        // matches the broker-only row and nested elements, so it
        // cannot prove WHICH rows run.
        for name in ["DroverInternals", "HeelerInternals"] {
            let row = app.descendants(matching: .any).matching(
                NSPredicate(
                    format: "label CONTAINS %@ AND label CONTAINS %@",
                    name, "runtime state: Running")).firstMatch
            XCTAssertTrue(
                row.waitForExistence(timeout: UITestTimeouts.standard),
                "\(name) must report Running — registration proves liveness")
        }

        // The two UNREGISTERED scouts stay Unknown.
        for name in ["WhipInternals", "MultiplexInternals"] {
            let row = app.descendants(matching: .any).matching(
                NSPredicate(
                    format: "label CONTAINS %@ AND label CONTAINS %@",
                    name, "runtime state: Unknown")).firstMatch
            XCTAssertTrue(
                row.waitForExistence(timeout: UITestTimeouts.standard),
                "\(name) has no live registration — it must keep Unknown")
        }

        // The verdict stays Not reported for EVERY row — live ≠
        // accepted, and the broker has no verdict channel.
        XCTAssertTrue(
            text("result: Not reported", in: app).exists,
            "a live child must never report an accepted verdict")
    }

    func testUnregisteredChildKeepsHonestUnknown() {
        let app = UITestApp.launchDemo(.tasksInspectorChildRun)

        // WhipInternals + MultiplexInternals have NO live
        // registration: absence proves nothing (finished, failed,
        // cancelled, or never started) — the honest Unknown stands.
        XCTAssertTrue(
            text("WhipInternals", in: app).waitForExistence(
                timeout: UITestTimeouts.standard))
        XCTAssertTrue(
            text("runtime state: Unknown", in: app).waitForExistence(
                timeout: UITestTimeouts.standard),
            "an unregistered child must keep Unknown — absence "
                + "proves nothing")
    }

    func testBrokerOnlyChildRendersItsOwnRowWithHonestAssignment() {
        let app = UITestApp.launchDemo(.tasksInspectorChildRun)

        // The broker-only child: registered under the parent, named
        // by no spawn the transcript carries.
        XCTAssertTrue(
            text("QueueSyncResearch", in: app).waitForExistence(
                timeout: UITestTimeouts.standard),
            "the broker-only child row never rendered")
        // Its honest assignment state (the wire carries no
        // assignment) rides the row's accessible label.
        let row = app.descendants(matching: .any).matching(
            NSPredicate(
                format: "label CONTAINS %@ AND label CONTAINS %@",
                "QueueSyncResearch", "assigned: not on this wire")).firstMatch
        XCTAssertTrue(
            row.waitForExistence(timeout: UITestTimeouts.standard),
            "a broker-only row must name its unobservable assignment")
        // The live-child-run chip renders.
        XCTAssertTrue(
            text("live child run", in: app).exists,
            "the live-child-run chip never rendered")
    }

    func testObservedRunDetailNamesTheRegistrationAndItsLimits() {
        let app = UITestApp.launchDemo(.tasksInspectorChildRun)

        // Tap a live-registered row → the detail names the observed
        // registration (identity) and the honest limit (no exit
        // state or verdict channel).
        let row = text("DroverInternals", in: app)
        XCTAssertTrue(
            row.waitForExistence(timeout: UITestTimeouts.standard))
        row.tap()

        XCTAssertTrue(
            text("Observed child run", in: app).waitForExistence(
                timeout: UITestTimeouts.standard),
            "the observed-run detail section never rendered")
        XCTAssertTrue(
            text("Registered live", in: app).exists,
            "the detail must name the live registration")
        XCTAssertTrue(
            text("no exit state or result verdict", in: app).exists,
            "the detail must name the observation's limit honestly")
    }

    func testCaptureChildRunSurfaces() {
        let app = UITestApp.launchDemo(.tasksInspectorChildRun)
        XCTAssertTrue(
            text("DroverInternals", in: app).waitForExistence(
                timeout: UITestTimeouts.standard))
        captureScreenshot(
            app, "tasks-inspector-childrun", lifetime: .keepAlways)

        // The Tasks tab keeps its producer-reported states — a
        // live child never marks its parent task done.
        app.buttons["Tasks"].tap()
        XCTAssertTrue(
            text("2 of 5 tasks completed", in: app).waitForExistence(
                timeout: UITestTimeouts.standard),
            "the Tasks tab's producer-reported hierarchy changed")
    }
}
