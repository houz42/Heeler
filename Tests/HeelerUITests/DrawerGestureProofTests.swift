import XCTest

// SPDX-License-Identifier: Apache-2.0

/// Drawer gesture + animation proofs (v2), phone width, on the demo
/// console fixture. The two user items this file pins:
///
/// 1. LEFT-EDGE SWIPE opens the drawer — from the left screen edge on
///    the ROOT pages only, following the finger, committing past the
///    velocity/position threshold; a pushed detail's edge swipe still
///    goes BACK (the recognizer is disabled on the same suppression
///    seam as the trigger, so the interactive pop never competes).
/// 2. ANIMATION — the drawer slides edge-following with a spring
///    settle and the scrim fading in sync; drag-to-close with
///    snap-back: a short drag springs back open, a committed drag
///    closes; a short edge drag snaps back closed.
///
/// The hamburger trigger stays the accessible path (the existing
/// NavigationRedesignProofTests already cover it) — these are the
/// ADDITIVE gesture proofs.
@MainActor
final class DrawerGestureProofTests: XCTestCase {
    var app: XCUIApplication!

    override func setUp() {
        continueAfterFailure = false
        app = UITestApp.launchDemo(.console)
    }

    override func tearDown() {
        app.terminate()
    }

    // MARK: helpers

    private var trigger: XCUIElement {
        app.buttons[UITestFixtures.navigationTrigger].firstMatch
    }

    /// The drawer's AX identity (v2): the drawer's close button, which
    /// exists in the AX tree only while the open has SETTLED (the
    /// drawer's AX chrome rides the resting state — a bare "Hosts"
    /// match is ambiguous on the Console page anyway, whose own
    /// elements carry Hosts labels). waitOpen therefore doubles as
    /// "the open settled to its stable frame"; waitClosed proves the
    /// closed drawer left the tree entirely (the always-mounted
    /// drawer's buttons must not leak when closed — verified failure
    /// mode: 'Close navigation' resolvable at x = -184).

    private var drawerCloseButton: XCUIElement {
        app.buttons["Close navigation"].firstMatch
    }

    @discardableResult
    private func waitOpen(timeout: TimeInterval = UITestTimeouts.standard)
        -> Bool
    {
        drawerCloseButton.waitForExistence(timeout: timeout)
    }

    @discardableResult
    private func waitClosed(timeout: TimeInterval = 3) -> Bool {
        !drawerCloseButton.waitForExistence(timeout: timeout)
    }

    /// A left-edge drag synthesized as a real HID touch: press at the
    /// edge, drag to `endX` (normalized), lift. The velocity variant
    /// carries a hold (0 s = lift on arrival) — this SDK's
    /// withVelocity press requires it.
    private func edgeDrag(toNormalizedX endX: CGFloat) {
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.01, dy: 0.5))
            .press(
                forDuration: 0.05,
                thenDragTo: app.coordinate(
                    withNormalizedOffset: CGVector(dx: endX, dy: 0.5)))
    }

    private func edgeDragSlow(toNormalizedX endX: CGFloat) {
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.01, dy: 0.5))
            .press(
                forDuration: 0.05,
                thenDragTo: app.coordinate(
                    withNormalizedOffset: CGVector(dx: endX, dy: 0.5)),
                withVelocity: .slow,
                thenHoldForDuration: 0)
    }
    // MARK: 1. Edge swipe opens (root pages only)

    /// A full edge swipe on the Agents ROOT page follows the finger and
    /// commits the open.
    func testEdgeSwipeOpensDrawerOnRootPage() {
        XCTAssertTrue(
            trigger.waitForExistence(timeout: UITestTimeouts.launch),
            "the root page must carry the hamburger trigger")

        edgeDrag(toNormalizedX: 0.7)
        XCTAssertTrue(
            waitOpen(),
            "a left-edge swipe on the root page must open the drawer")

        // The drawer is fully committed: the current destination reads
        // as checked and the others are tappable.
        XCTAssertTrue(
            app.buttons["Hosts"].firstMatch.isHittable,
            "the drawer's destinations must be hittable after the swipe")
        captureScreenshot(app, "drawer-v2-edge-swipe-open", lifetime: .keepAlways)

        // Dismiss to a clean state.
        app.buttons["Close navigation"].firstMatch.tap()
        XCTAssertTrue(waitClosed(), "close × must dismiss the swiped-open drawer")
    }

    /// The SAME edge gesture works on the Hosts and Settings root pages
    /// (the seam is per-root-page, not Agents-only).
    func testEdgeSwipeOpensOnEveryRootPage() {
        XCTAssertTrue(
            trigger.waitForExistence(timeout: UITestTimeouts.launch))

        // Hosts
        edgeDrag(toNormalizedX: 0.7)
        XCTAssertTrue(waitOpen(), "edge swipe must open on Agents")
        app.buttons["Hosts"].firstMatch.tap()
        XCTAssertTrue(
            app.buttons["Scan to Pair"].firstMatch.waitForExistence(
                timeout: UITestTimeouts.standard),
            "the Hosts page must mount")
        XCTAssertTrue(waitClosed(), "selection must dismiss the drawer")

        // Hosts root page → edge swipe.
        edgeDrag(toNormalizedX: 0.7)
        XCTAssertTrue(waitOpen(), "edge swipe must open on the Hosts root page")
        captureScreenshot(
            app, "drawer-v2-edge-swipe-hosts", lifetime: .keepAlways)
        app.buttons["Settings"].firstMatch.tap()
        XCTAssertTrue(
            app.buttons[UITestFixtures.navigationTrigger].firstMatch
                .waitForExistence(timeout: UITestTimeouts.standard),
            "the Settings page must carry the trigger")
        XCTAssertTrue(waitClosed(), "selection must dismiss the drawer")

        // Settings root page → edge swipe.
        edgeDrag(toNormalizedX: 0.7)
        XCTAssertTrue(
            waitOpen(), "edge swipe must open on the Settings root page")
        captureScreenshot(
            app, "drawer-v2-edge-swipe-settings", lifetime: .keepAlways)
        app.buttons["Agents"].firstMatch.tap()
        XCTAssertTrue(
            app.buttons[UITestFixtures.navigationTrigger].firstMatch
                .waitForExistence(timeout: UITestTimeouts.standard),
            "Back on Agents, the trigger must return")
    }

    /// THE seam proof: an edge swipe with an agent detail PUSHED must go
    /// BACK — never the drawer. The recognizer rides the same
    /// suppression seam as the trigger, so the system's interactive pop
    /// owns the edge unchallenged.
    func testEdgeSwipeOnPushedDetailStillGoesBack() {
        XCTAssertTrue(
            trigger.waitForExistence(timeout: UITestTimeouts.launch))

        let cell = app.buttons.matching(
            NSPredicate(format: "label CONTAINS %@", UITestFixtures.chatAgentRow)
        ).firstMatch
        waitToExist(cell)
        cell.tap()
        XCTAssertTrue(app.waitForPushedDetail(), "agent detail never pushed")

        // The suppression seam: no trigger while pushed.
        let hidden = !app.buttons[UITestFixtures.navigationTrigger].firstMatch
            .waitForExistence(timeout: UITestTimeouts.standard)
        XCTAssertTrue(hidden, "the trigger must hide inside the detail")

        // The SAME edge drag that opens the drawer on a root page must
        // pop the detail here — the drawer must NOT open.
        edgeDrag(toNormalizedX: 0.8)
        XCTAssertTrue(
            app.buttons[UITestFixtures.navigationTrigger].firstMatch
                .waitForExistence(timeout: UITestTimeouts.standard),
            "the edge swipe must go BACK on a pushed detail")
        XCTAssertTrue(
            waitClosed(),
            "the edge swipe must NOT open the drawer on a pushed detail")
        captureScreenshot(
            app, "drawer-v2-edge-swipe-detail-goes-back",
            lifetime: .keepAlways)

        // And the pop actually landed on the ROOT page, not a pushed
        // detail with chrome: the drawer opens from here again.
        edgeDrag(toNormalizedX: 0.7)
        XCTAssertTrue(
            waitOpen(),
            "after Back, the edge swipe must open the drawer again")
    }

    // MARK: 2. Drag-snap + animation

    /// A SHORT edge drag (well past the touch start, far short of the
    /// settle point) released → the drawer SNAPPS CLOSED — it followed
    /// the finger partway and sprang back without committing.
    func testShortEdgeDragSnapsClosed() {
        XCTAssertTrue(
            trigger.waitForExistence(timeout: UITestTimeouts.launch))

        // The settle point is half the 184 pt drawer (92 pt). Drag only
        // ~60 pt (0.15 normalized on a 402 pt phone) — under the
        // settle point — and release slowly (no flick): snap closed.
        edgeDragSlow(toNormalizedX: 0.15)
        XCTAssertTrue(
            waitClosed(),
            "a short, slow edge drag must snap back closed")
    }

    /// The same short drag on the OPEN drawer (drag-to-close) springs
    /// BACK OPEN — snap-back — while a long/fast drag commits the close.
    func testDragToCloseSnapBehavior() {
        XCTAssertTrue(
            trigger.waitForExistence(timeout: UITestTimeouts.launch))

        // Open from the trigger (the accessible path — the gesture is
        // additive, so it must still work alongside the edge swipe).
        trigger.tap()
        XCTAssertTrue(waitOpen(), "the trigger must still open the drawer")

        // SHORT drag-to-close, HELD at the end before release (~60 pt
        // — under the 92 pt settle point — with the finger STOPPED so
        // release velocity is ~0): snap BACK OPEN. The momentum rule
        // is the design: a release WHILE MOVING — even the same 60 pt
        // at the synthesized 250 px/s — legitimately projects past the
        // settle point and commits, so the snap-back proof must lift
        // the finger off a HELD, stationary position instead.
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.35, dy: 0.5))
            .press(
                forDuration: 0.05,
                thenDragTo: app.coordinate(
                    withNormalizedOffset: CGVector(dx: 0.20, dy: 0.5)),
                withVelocity: .slow,
                thenHoldForDuration: 0.4)

        XCTAssertTrue(
            waitOpen(),
            "a short drag-to-close must snap back open (not dismiss)")
        // LONG drag-to-close (past the settle point): commits the
        // close. The end coordinate stays ONSCREEN (normalized 0.02
        // — HID synthesis to an offscreen negative coordinate is
        // unreliable); 0.35→0.02 is ~133 pt of travel, past the
        // 92 pt settle point.
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.35, dy: 0.5))
            .press(
                forDuration: 0.05,
                thenDragTo: app.coordinate(
                    withNormalizedOffset: CGVector(dx: 0.02, dy: 0.5)))
        XCTAssertTrue(
            waitClosed(),
            "a committed drag-to-close must dismiss the drawer")
        captureScreenshot(
            app, "drawer-v2-drag-committed-close", lifetime: .keepAlways)

        // The page is intact and the trigger still works — the gesture
        // round-trip leaves the accessible path untouched.
        XCTAssertTrue(
            app.buttons[UITestFixtures.navigationTrigger].firstMatch
                .waitForExistence(timeout: UITestTimeouts.standard),
            "the trigger must remain reachable after the drag round trip")
        trigger.tap()
        XCTAssertTrue(
            waitOpen(), "the trigger must still open after drag-to-close")
    }

    /// MID-DRAG capture (the animation proof): a slow edge drag HELD at
    /// a partial reveal — the drawer visibly part-way across the screen
    /// with the scrim proportionally faded — captured while the finger
    /// is still down. The hold-variant press keeps the touch at the
    /// drag destination; the capture runs on a background queue inside
    /// the hold window (screenshots are IPC to the test daemon, and the
    /// box below keeps the handoff Swift-6-clean).
    func testMidDragCapturePartialRevealWithScrim() {
        XCTAssertTrue(
            trigger.waitForExistence(timeout: UITestTimeouts.launch))

        // Reveal target ≈ 80 pt (0.20 normalized on a 402 pt phone) —
        // deliberately BELOW the 92 pt settle point so the release after
        // the hold snaps the drawer back closed.
        let box = CaptureBox()
        // The hold runs 2.0 s; capture at ~1.2 s in — mid-hold, finger
        // down, drawer parked at the partial reveal.
        box.schedule(at: .now() + 1.2)
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.01, dy: 0.5))
            .press(
                forDuration: 0.1,
                thenDragTo: app.coordinate(
                    withNormalizedOffset: CGVector(dx: 0.20, dy: 0.5)),
                withVelocity: .slow,
                thenHoldForDuration: 2.0)

        // The press returned = the finger lifted from a sub-settle
        // reveal: the drawer must snap back closed.
        XCTAssertTrue(
            waitClosed(),
            "release from a sub-settle hold must snap the drawer closed")

        // The mid-drag capture landed.
        let png = box.take()
        XCTAssertNotNil(png, "the mid-drag capture must have fired")
        let attachment = XCTAttachment(
            uniformTypeIdentifier: "public.png",
            name: "drawer-v2-mid-drag",
            payload: png,
            userInfo: nil)
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}

/// Lock-guarded handoff for the mid-drag capture: the screenshot is
/// taken on a background queue while the test thread is blocked inside
/// the hold-variant press, so the PNG crosses threads through this.
final class CaptureBox: @unchecked Sendable {
    private let lock = NSLock()
    private var png: Data?

    func schedule(at deadline: DispatchTime) {
        DispatchQueue.global().asyncAfter(deadline: deadline) {
            let data = XCUIScreen.main.screenshot().pngRepresentation
            self.lock.lock()
            self.png = data
            self.lock.unlock()
        }
    }

    func take() -> Data? {
        lock.lock()
        defer { lock.unlock() }
        return png
    }
}
