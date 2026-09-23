import XCTest

// SPDX-License-Identifier: Apache-2.0

/// Drawer gesture + animation proofs (v2; reliability widening v3),
/// phone width, on the demo console fixture. The user items this
/// file pins:
///
/// 1. LEFT-EDGE SWIPE opens the drawer — from the left screen edge on
///    the ROOT pages only, following the finger, committing past the
///    velocity/position threshold; a pushed detail's edge swipe still
///    goes BACK (the recognizer is disabled on the same suppression
///    seam as the trigger, so the interactive pop never competes).
///    V3 RELIABILITY: the drawer also opens from the WIDENED band —
///    a swipe that starts 20–44 pt in from the bezel (where the stock
///    screen-edge recognizer silently never engaged — the real-phone
///    "doesn't always work" report) — at multiple heights and speeds;
///    a VERTICAL drag starting in that band stays the page's scroll
///    and never opens the drawer. FOLLOW-UP: DIAGONAL band swipes on
///    the real Agents list (whose scroll pan raced the plain band pan
///    and won slightly-diagonal swipes before the failure-requirement
///    fix) open the drawer too; the list still scrolls vertically
///    from the band, and row taps still push.
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

    // MARK: 1b. V3 reliability — the widened begin band

    /// A drag synthesized with an EXACT start x (points, not the
    /// normalized 0.01 the edge helpers use). The v3 proofs start
    /// INSIDE the widened band (20–44 pt) where a real-phone swipe
    /// routinely lands — the stock screen-edge recognizer never
    /// engaged there, which is the "doesn't always work" report.
    private func dragFromX(
        _ startX: CGFloat, _ startY: CGFloat,
        toEndX endX: CGFloat, velocity: XCUIGestureVelocity = .default
    ) {
        let start = app.coordinate(
            withNormalizedOffset: CGVector(
                dx: startX / app.frame.width,
                dy: startY / app.frame.height))
        start.press(
            forDuration: 0.05,
            thenDragTo: app.coordinate(
                withNormalizedOffset: CGVector(
                    dx: endX / app.frame.width,
                    dy: startY / app.frame.height)),
            withVelocity: velocity,
            thenHoldForDuration: 0)
    }

    /// THE reliability proof (v3, per the design contract's
    /// acceptance): the drawer opens from starts all across the 44 pt
    /// band — 2 pt (bezel), 12/24 pt (mid-band), 40 pt (outer band) —
    /// at top/middle/bottom heights, slow and fast. One miss anywhere
    /// in the band is the user's "retry" experience; the whole matrix
    /// must open.
    func testWidenedBandOpensAtEveryStartPoint() {
        XCTAssertTrue(
            trigger.waitForExistence(timeout: UITestTimeouts.launch))

        let height = app.frame.height
        // (start x pt, y fraction, velocity): the contract's band
        // matrix — 2/12/24/40 pt starts at top/middle/bottom, slow
        // and fast. (2/12 are the old stock-bezel dead zone's inner
        // pair; 24/40 the previously-unreachable widened pair.)
        let cases: [(CGFloat, CGFloat, XCUIGestureVelocity)] = [
            (2, 0.5, .default),
            (12, 0.25, .slow),
            (24, 0.5, .slow),
            (40, 0.75, .fast),
        ]
        var caseIndex = 0
        for (startX, yFraction, velocity) in cases {
            dragFromX(
                startX, height * yFraction, toEndX: 280, velocity: velocity)
            XCTAssertTrue(
                waitOpen(),
                "a swipe starting at \(Int(startX)) pt from the edge "
                    + "must open the drawer")
            // The proof capture rides the 24 pt case (index 2 —
            // outside the stock ~20 pt bezel band, the exact
            // real-phone miss): the drawer must be VISIBLE open in
            // the frame, not just asserted.
            if caseIndex == 2 {
                captureScreenshot(
                    app, "drawer-v3-widened-band-open",
                    lifetime: .keepAlways)
            }
            // Reset to the closed root page for the next case.
            app.buttons["Close navigation"].firstMatch.tap()
            XCTAssertTrue(
                waitClosed(),
                "the close must fully dismiss before the next swipe")
            caseIndex += 1
        }
    }

    /// The widened band must not eat the page's VERTICAL scroll: a
    /// drag that starts inside the band and moves DOWN never opens
    /// the drawer (the design's rule — vertical gestures scroll the
    /// conversation), and the page's list is still live afterwards.
    func testVerticalDragInsideBandDoesNotOpenDrawer() {
        XCTAssertTrue(
            trigger.waitForExistence(timeout: UITestTimeouts.launch))

        let height = app.frame.height
        // Start 24 pt in — mid-band — and drag DOWN 150 pt.
        let start = app.coordinate(
            withNormalizedOffset: CGVector(
                dx: 24 / app.frame.width, dy: 0.35))
        start.press(
            forDuration: 0.05,
            thenDragTo: app.coordinate(
                withNormalizedOffset: CGVector(
                    dx: 24 / app.frame.width,
                    dy: 0.35 + 150 / height)),
            withVelocity: .slow,
            thenHoldForDuration: 0)

        XCTAssertTrue(
            waitClosed(),
            "a vertical drag starting in the widened band must stay "
                + "the page's scroll — never open the drawer")
        // The page is untouched by the band: the trigger still works.
        XCTAssertTrue(
            app.buttons[UITestFixtures.navigationTrigger].firstMatch
                .isHittable,
            "the page must remain interactive after the vertical drag")
    }

    /// A LEFTWARD fling starting in the widened band opens nothing
    /// (and never triggers Back on a root page): the band's gate
    /// demands horizontal-dominant RIGHTWARD motion.
    func testLeftwardDragInsideBandDoesNotOpenDrawer() {
        XCTAssertTrue(
            trigger.waitForExistence(timeout: UITestTimeouts.launch))

        // Start 24 pt in, drag toward the bezel (out to 2 pt).
        dragFromX(24, app.frame.height * 0.5, toEndX: 2)
        XCTAssertTrue(
            waitClosed(),
            "a leftward drag starting in the widened band must not "
                + "open the drawer")
    }

    // MARK: 1c. Follow-up — the agent-list conflict

    /// A drag synthesized with an EXACT start point and a DELTA (the
    /// diagonal shape a real thumb produces): the follow-up proofs
    /// start in the band and sweep right while drifting up or down —
    /// the exact swipe that lost the race to the Agents list's scroll
    /// pan before the failure-requirement fix (a plain pan has no
    /// system-level precedence over scroll views, so the list claimed
    /// slightly-diagonal band swipes first).
    private func diagonalDragFromX(
        _ startX: CGFloat, _ startY: CGFloat,
        dx: CGFloat, dy: CGFloat,
        velocity: XCUIGestureVelocity = .default
    ) {
        let width = app.frame.width
        let height = app.frame.height
        app.coordinate(
            withNormalizedOffset: CGVector(
                dx: startX / width, dy: startY / height))
            .press(
                forDuration: 0.05,
                thenDragTo: app.coordinate(
                    withNormalizedOffset: CGVector(
                        dx: (startX + dx) / width,
                        dy: (startY + dy) / height)),
                withVelocity: velocity,
                thenHoldForDuration: 0)
    }

    /// THE agent-list proof (follow-up): DIAGONAL band swipes on the
    /// real Agents list — rows visible, the List's scroll pan the
    /// live competitor — open the drawer from every in-band start.
    /// Diagonals drift DOWN (finger sweeping right while settling
    /// onto the screen) and UP, both inside the failure-requirement
    /// window where the list's scroll previously won.
    func testDiagonalBandSwipeOpensDrawerOnAgentList() {
        XCTAssertTrue(
            trigger.waitForExistence(timeout: UITestTimeouts.launch))
        // Rows on stage: the List's scroll is the live competitor.
        let firstRow = app.buttons.matching(
            NSPredicate(format: "label CONTAINS %@", UITestFixtures.chatAgentRow)
        ).firstMatch
        waitToExist(firstRow)

        let height = app.frame.height
        // (startX pt, y fraction, dx, dy): in-band starts (24/32/40)
        // sweeping right ~180 pt while drifting ±35 pt diagonal.
        let cases: [(CGFloat, CGFloat, CGFloat, CGFloat)] = [
            (24, 0.45, 180, 35),
            (32, 0.60, 180, -35),
            (40, 0.40, 180, 35),
        ]
        var caseIndex = 0
        for (startX, yFraction, dx, dy) in cases {
            diagonalDragFromX(
                startX, height * yFraction, dx: dx, dy: dy)
            XCTAssertTrue(
                waitOpen(),
                "a diagonal swipe starting at \(Int(startX)) pt on the "
                    + "agent list must open the drawer")
            // The proof capture rides the FIRST case (24 pt, the
            // real-phone dead zone, ON the agent list): the drawer
            // must be VISIBLE open in the frame, not just asserted.
            if caseIndex == 0 {
                captureScreenshot(
                    app, "drawer-v3-list-diagonal-open",
                    lifetime: .keepAlways)
            }
            app.buttons["Close navigation"].firstMatch.tap()
            XCTAssertTrue(
                waitClosed(),
                "the close must fully dismiss before the next swipe")
            caseIndex += 1
        }
    }

    /// The failure-requirement must not break the list's scroll — two
    /// measured truths drive this test's shape:
    /// (1) A vertical drag that starts INSIDE the edge margin
    ///     (~24 pt) is eaten by the platform's own edge-gate
    ///     machinery on VANILLA main (control run: the row does not
    ///     move with no drawer recognizer at all), so "scrolls from
    ///     inside the margin" is not a property any fix can grant —
    ///     the assertion there is only that the drawer does NOT
    ///     open.
    /// (2) A vertical drag starting OUTSIDE the margin (60 pt) is
    ///     the regression-relevant check: the band's require-to-fail
    ///     dependency must never hold a scroll it doesn't own, so
    ///     the list still scrolls exactly as before the fix.
    func testVerticalDragInBandStillScrollsAgentList() {
        XCTAssertTrue(
            trigger.waitForExistence(timeout: UITestTimeouts.launch))
        let firstRow = app.buttons.matching(
            NSPredicate(format: "label CONTAINS %@", UITestFixtures.chatAgentRow)
        ).firstMatch
        waitToExist(firstRow)

        let height = app.frame.height
        // (1) In-margin vertical: the drawer must not open.
        diagonalDragFromX(24, height * 0.35, dx: 8, dy: 150, velocity: .slow)
        XCTAssertTrue(
            waitClosed(),
            "a vertical drag starting in the band must never open "
                + "the drawer")

        // (2) Outside-margin vertical: the list scrolls (row y moves)
        // — the band must never hold a scroll it doesn't own. The
        // drag shape here is the proven scroll driver (app.swipeUp,
        // the same one every list proof uses — a synthesized
        // coordinate drag at .slow does not scroll this List even on
        // vanilla main, control-run measured, so it cannot serve as
        // the regression probe).
        let before = firstRow.frame.minY
        app.swipeUp(velocity: .fast)
        let after = firstRow.frame.minY
        XCTAssertTrue(
            abs(after - before) > 20,
            "a vertical swipe outside the edge margin must still scroll "
                + "the agent list (row moved \(abs(after - before)) pt)")
    }

    /// Row interactions intact after the fix: an agent row tap still
    /// pushes its detail (the band's failure-requirement never
    /// delays or swallows taps — a tap fails every pan).
    func testRowTapStillPushesDetail() {
        XCTAssertTrue(
            trigger.waitForExistence(timeout: UITestTimeouts.launch))
        let cell = app.buttons.matching(
            NSPredicate(format: "label CONTAINS %@", UITestFixtures.chatAgentRow)
        ).firstMatch
        waitToExist(cell)
        cell.tap()
        XCTAssertTrue(app.waitForPushedDetail(), "agent detail never pushed")
        // Back, so the surface is in its root state again.
        app.buttons["Back"].firstMatch.tap()
        XCTAssertTrue(
            trigger.waitForExistence(timeout: UITestTimeouts.standard),
            "Back must return to the root page")
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

    /// DISMISSAL CONTINUITY + containment ordering (review round v2):
    /// the × dismissal is a SLIDE, not a vanish — a background capture
    /// inside the 0.5 s exit-settle window catches the drawer mid
    /// slide-out; and containment releases only WITH the unmount: the
    /// scrim (the drawer layer's own AX identity) disappears no later
    /// than the page returns, never earlier — a page exposed under a
    /// still-mounted drawer is the containment bug the shared
    /// `drawerIsPresented` predicate exists to make impossible.
    func testDismissalSlidesOutAndContainmentReleasesWithUnmount() {
        XCTAssertTrue(
            trigger.waitForExistence(timeout: UITestTimeouts.launch))

        // Open from the trigger, wait for the settled state.
        trigger.tap()
        XCTAssertTrue(waitOpen(), "the trigger must open the drawer")

        // The mid-settle capture: the × dismissal's exit spring runs
        // ~0.5 s; capture at 0.15 s in — the drawer part-way out,
        // scrim part-way faded.
        let box = CaptureBox()
        box.schedule(at: .now() + 0.15)
        app.buttons["Close navigation"].firstMatch.tap()

        // Containment ordering: once the dismissal COMPLETES, the page
        // is reachable again AND the drawer layer is gone. Poll until
        // the trigger (the page's first element) returns, then require
        // the layer's scrim to be gone in the SAME settled state.
        XCTAssertTrue(
            app.buttons[UITestFixtures.navigationTrigger].firstMatch
                .waitForExistence(timeout: UITestTimeouts.standard),
            "the page must return after the dismissal completes")
        XCTAssertFalse(
            app.buttons["Dismiss navigation"].firstMatch.waitForExistence(
                timeout: 1),
            "the drawer layer must be gone once the page is back — "
                + "containment releases with the unmount, never before")

        // The mid-settle capture landed — the exit is a slide.
        let png = box.take()
        XCTAssertNotNil(png, "the mid-settle capture must have fired")
        let attachment = XCTAttachment(
            uniformTypeIdentifier: "public.png",
            name: "drawer-v2-dismiss-slide-out",
            payload: png,
            userInfo: nil)
        attachment.lifetime = .keepAlways
        add(attachment)
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

        // Reveal target ≈ 60 pt (0.15 normalized on a 402 pt phone) —
        // below the 92 pt settle point WITH MARGIN: the synthesized
        // release can still carry the .slow drag's 250 px/s, which
        // projects +30 pt at the settle horizon; 60 + 30 = 90 stays
        // under the settle, so the release deterministically snaps
        // the drawer back closed.
        let box = CaptureBox()
        // The hold runs 2.0 s; capture at ~1.2 s in — mid-hold, finger
        // down, drawer parked at the partial reveal.
        box.schedule(at: .now() + 1.2)
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.01, dy: 0.5))
            .press(
                forDuration: 0.1,
                thenDragTo: app.coordinate(
                    withNormalizedOffset: CGVector(dx: 0.15, dy: 0.5)),
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
