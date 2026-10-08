import Foundation
import Testing

@testable import Heeler

// SPDX-License-Identifier: Apache-2.0
//
// The scroll-position/geometry coordinator's decision table — the
// single-owner contract, unit-tested without a UIScrollView (the
// design doc's "validate the platform mechanism" is the UITest
// suite's job; the DECISIONS are pinned here).

@Suite("Chat scroll coordinator")
@MainActor
struct ChatScrollCoordinatorTests {

    private func makeCoordinator(
        document: CGFloat, viewport: CGFloat, contentTop: CGFloat,
        intersects: Bool, first: String = "row-a", last: String = "row-z",
        following: Bool = true
    ) -> (ChatScrollCoordinator, ChatViewportGeometry) {
        let coordinator = ChatScrollCoordinator()
        let geometry = ChatViewportGeometry(
            documentHeight: document, viewportHeight: viewport,
            contentTop: contentTop, rowsIntersectViewport: intersects)
        // Order matters: items first (the initial-anchor decision runs
        // on the first geometry), then the geometry.
        coordinator.itemsChanged(first: first, last: last)
        if !following {
            // Reading intent is the USER's: their scroll up (tracking)
            // pushes the sentinel offscreen and latches reading.
            coordinator.scrollPhaseChanged(.tracking)
            coordinator.bottomEdgeVisibleChanged(false)
            coordinator.scrollPhaseChanged(.idle)
        }
        coordinator.geometryChanged(geometry)
        return (coordinator, geometry)
    }

    // MARK: Initial open

    @Test("healthy initial open: NO programmatic command (stock anchors own it)")
    func initialHealthyOpenNoCommand() {
        // Long history, rows intersecting: the stock
        // defaultScrollAnchor owns the initial latest-edge open; the
        // coordinator is repair-only on a healthy layout (a redundant
        // latest-edge command fought the stock anchor — visible jumps).
        let (coordinator, _) = makeCoordinator(
            document: 4000, viewport: 700, contentTop: 0, intersects: true)
        #expect(coordinator.position == nil)
    }

    @Test("short initial history: NO programmatic position (stock anchors)")
    func initialShortHistoryNoCommand() {
        let (coordinator, _) = makeCoordinator(
            document: 300, viewport: 700, contentTop: 0, intersects: true)
        #expect(coordinator.position == nil)
    }

    @Test("initial blank (window off every row) is repaired once, bounded")
    func initialBlankIsRepaired() {
        // The device blank on open: the restored layout lands the
        // visible window in the padding above the first row. The
        // repair targets the LAST ROW bottom-anchored (never the bare
        // document edge — edge positions overshoot past the last row
        // into unmaterialized lazy space).
        let (coordinator, _) = makeCoordinator(
            document: 500, viewport: 700, contentTop: 200,
            intersects: false)
        #expect(
            coordinator.position?.viewID(type: String.self) == "row-z")
        #expect(coordinator.repairAttempts == 1)

        // The repair lands (rows intersect again): re-arms.
        coordinator.geometryChanged(ChatViewportGeometry(
            documentHeight: 500, viewportHeight: 700,
            contentTop: 0, rowsIntersectViewport: true))
        coordinator.scrollPhaseChanged(.idle)
        #expect(coordinator.position == nil)
        #expect(coordinator.repairAttempts == 0)
    }

    @Test("initial blank while reading mid-history: repair targets the TOP row")
    func initialBlankMidHistoryRepairTargetsTopRow() {
        let (coordinator, _) = makeCoordinator(
            document: 4000, viewport: 700, contentTop: 3000,
            intersects: false, following: false)
        #expect(
            coordinator.position?.viewID(type: String.self) == "row-a")
    }


    // MARK: Bounded repair

    @Test("repair bound: a never-satisfied layout stops after max attempts")
    func repairBounded() {
        let (coordinator, _) = makeCoordinator(
            document: 500, viewport: 700, contentTop: 200,
            intersects: false)
        #expect(coordinator.repairAttempts == 1)
        // Geometry keeps changing but never intersects: the repair
        // stops at the bound (no infinite command loop).
        var contentTop: CGFloat = 260
        for _ in 0..<6 {
            contentTop += 10
            coordinator.geometryChanged(ChatViewportGeometry(
                documentHeight: 500, viewportHeight: 700,
                contentTop: contentTop, rowsIntersectViewport: false))
        }
        #expect(coordinator.repairAttempts <= 3)
    }

    @Test("keyboard shrink while following latest keeps the bottom edge")
    func keyboardShrinkFollowsLatest() {
        // The reader is FOLLOWING at the bottom edge: contentTop is
        // (viewport - document), the most negative the stack can be.
        let (coordinator, _) = makeCoordinator(
            document: 4000, viewport: 700, contentTop: -3300,
            intersects: true)
        coordinator.scrollPhaseChanged(.idle)
        // Keyboard shows: the viewport shrinks (the edge is lost —
        // contentTop now exceeds vp - doc, meaning the stack's bottom
        // sits BELOW the visible window). The hold fires on the LAST
        // ROW (never the bare edge).
        coordinator.geometryChanged(ChatViewportGeometry(
            documentHeight: 4000, viewportHeight: 400,
            contentTop: -3000, rowsIntersectViewport: true))
        #expect(
            coordinator.position?.viewID(type: String.self) == "row-z")

        // Keyboard hides: the viewport grows back to the edge — no
        // further commands (the geometry reconcile holds visibility).
        coordinator.geometryChanged(ChatViewportGeometry(
            documentHeight: 4000, viewportHeight: 700,
            contentTop: -3300, rowsIntersectViewport: true))
        #expect(coordinator.position == nil)
    }

    @Test("keyboard change while reading mid-history: NO scroll command")
    func keyboardChangeMidHistoryPreservesAnchor() {
        let (coordinator, _) = makeCoordinator(
            document: 4000, viewport: 700, contentTop: 1000,
            intersects: true, following: false)
        coordinator.scrollPhaseChanged(.idle)
        #expect(coordinator.position == nil)
        // Keyboard shows: rows still intersect; the reader's anchor
        // must be PRESERVED (no command).
        let shrunk = ChatViewportGeometry(
            documentHeight: 4000, viewportHeight: 400,
            contentTop: 1000, rowsIntersectViewport: true)
        coordinator.geometryChanged(shrunk)
        #expect(coordinator.position == nil)
    }

    // MARK: Older paging

    @Test("older page pins the current first row")
    func olderPagePinsTopRow() {
        let (coordinator, _) = makeCoordinator(
            document: 4000, viewport: 700, contentTop: 0, intersects: true,
            following: false)
        coordinator.scrollPhaseChanged(.idle)
        coordinator.olderPageWillPrepend(currentFirstID: "row-a")
        #expect(coordinator.position?.viewID(type: String.self) == "row-a")
        #expect(coordinator.position != nil)
        // After the prepend, items changed — the pin HOLDS (the
        // decision stays until settled; the anchor row is now
        // mid-document).
        coordinator.itemsChanged(first: "row-old", last: "row-z")
        #expect(coordinator.position?.viewID(type: String.self) == "row-a")
    }

    // MARK: Jump pill

    @Test("user jumps update follow-latest tracking")
    func userJumpUpdatesFollowing() {
        let (coordinator, _) = makeCoordinator(
            document: 4000, viewport: 700, contentTop: 0, intersects: true)
        coordinator.userJumped(to: "row-a", anchor: .top)
        // The coordinator does not expose followsLatest directly in
        // this suite; the observable behavior: a later geometry change
        // while NOT following latest issues no bottom-edge command.
        coordinator.scrollPhaseChanged(.idle)
        let shrunk = ChatViewportGeometry(
            documentHeight: 4000, viewportHeight: 400,
            contentTop: 0, rowsIntersectViewport: true)
        coordinator.geometryChanged(shrunk)
        #expect(coordinator.position == nil)
    }

    @Test("jump-to-bottom that lands blank takes ONE center-anchored correction")
    func jumpToBottomBlankLandingIsCorrected() {
        let (coordinator, _) = makeCoordinator(
            document: 4000, viewport: 700, contentTop: -1500,
            intersects: true, following: false)
        // Mid-history: the bottom edge is offscreen.
        coordinator.bottomEdgeVisibleChanged(false)
        // The user jumps to the bottom (the last row, bottom-anchored).
        coordinator.userJumped(to: "row-z", anchor: .bottom)
        #expect(
            coordinator.position?.viewID(type: String.self) == "row-z")

        // The landing OVERSHOOTS (the LazyVStack estimate on the
        // unmaterialized region): the scroll settles with NO row
        // intersecting — the reported blank page.
        coordinator.scrollPhaseChanged(.animating)
        coordinator.geometryChanged(ChatViewportGeometry(
            documentHeight: 4000, viewportHeight: 700,
            contentTop: 4000, rowsIntersectViewport: false))
        coordinator.scrollPhaseChanged(.idle)

        // ONE center-anchored correction on the SAME target: a center
        // anchor can never place the target outside its own extent,
        // so the real message is on screen.
        #expect(
            coordinator.position?.viewID(type: String.self) == "row-z")

        // The correction lands: rows intersect, the reader is back at
        // the bottom edge (the sentinel reports visible) — settled, no
        // further commands.
        coordinator.bottomEdgeVisibleChanged(true)
        coordinator.geometryChanged(ChatViewportGeometry(
            documentHeight: 4000, viewportHeight: 700,
            contentTop: -3300, rowsIntersectViewport: true))
        #expect(coordinator.position == nil)
    }

    @Test("send growth while following latest: the hold targets the NEW last row, revealed at the bottom")
    func sendGrowthFollowsNewLastRow() {
        let (coordinator, _) = makeCoordinator(
            document: 4000, viewport: 700, contentTop: -3300,
            intersects: true)
        // The reader is following latest, at the bottom edge.
        coordinator.scrollPhaseChanged(.idle)

        // The just-sent message lands: content GROWS, the bottom
        // sentinel is pushed offscreen (the edge is lost). The
        // coordinator holds the bottom edge on the NEW last row — the
        // just-sent message is revealed ("a bit"), never an overscroll
        // past it into blank.
        coordinator.itemsChanged(first: "row-a", last: "row-new")
        // The follow fires and ANIMATES (a programmatic follow is
        // never idle), then lands at the new bottom edge.
        coordinator.scrollPhaseChanged(.animating)
        #expect(
            coordinator.position?.viewID(type: String.self) == "row-new")
        coordinator.geometryChanged(ChatViewportGeometry(
            documentHeight: 4200, viewportHeight: 700,
            contentTop: -3500, rowsIntersectViewport: true))

        // The landing verification follows the same (new) target:
        // the overshoot leaves rows not intersecting → the center
        // correction targets the new row.
        coordinator.geometryChanged(ChatViewportGeometry(
            documentHeight: 4200, viewportHeight: 700,
            contentTop: 4200, rowsIntersectViewport: false))
        coordinator.geometryChanged(ChatViewportGeometry(
            documentHeight: 4200, viewportHeight: 700,
            contentTop: 4200, rowsIntersectViewport: false))
        coordinator.scrollPhaseChanged(.idle)
        #expect(
            coordinator.position?.viewID(type: String.self) == "row-new")
    }

    @Test("settlement: rows intersecting again clears the decision")
    func settlementClearsDecision() {
        let (coordinator, _) = makeCoordinator(
            document: 500, viewport: 700, contentTop: 200,
            intersects: false)
        #expect(coordinator.position != nil)
        // The repair lands: rows intersect, scroll idle.
        let healed = ChatViewportGeometry(
            documentHeight: 500, viewportHeight: 700,
            contentTop: 0, rowsIntersectViewport: true)
        coordinator.geometryChanged(healed)
        #expect(coordinator.position == nil)
    }

    // MARK: Empty content

    @Test("no content: no decisions at all")
    func noContentNoDecisions() {
        let coordinator = ChatScrollCoordinator()
        coordinator.geometryChanged(ChatViewportGeometry(
            documentHeight: 0, viewportHeight: 700, contentTop: 0,
            rowsIntersectViewport: false))
        coordinator.geometryChanged(ChatViewportGeometry(
            documentHeight: 700, viewportHeight: 700, contentTop: 700,
            rowsIntersectViewport: false))
        #expect(coordinator.position == nil)
    }

    // MARK: Slow-reading intent separation (the design amendment)

    // MARK: Identity-swap follow (trace104, the real-path trace)

    @Test("provisional→committed swap while following: the follow carries to the settled reply")
    func identitySwapCarriesTheFollow() {
        // The trace104 sequence, replayed exactly: the reader followed
        // the provisional tail (last row = provisional), the tail
        // VANISHES (window replacement pins the previous committed
        // record, the settle clears the pending landing), and THEN the
        // committed reply lands as the NEW last row — the follow must
        // re-fire on the last-row CHANGE, never waiting on a sentinel
        // departure (the device's zero-height sentinel never
        // published one).
        let (coordinator, _) = makeCoordinator(
            document: 9000, viewport: 680, contentTop: -8318,
            intersects: true)
        coordinator.scrollPhaseChanged(.idle)

        // A provisional tail streams in as the new last row: the
        // follow tracks it.
        coordinator.itemsChanged(first: "row-a", last: "provisional")
        #expect(
            coordinator.position?.viewID(type: String.self) == "provisional")

        // The stream finishes: the tail vanishes and the window
        // replacement pins the PREVIOUS committed record (the
        // transaction's honest fallback — the reply has not landed
        // yet). The settle clears the decision (rows intersect).
        coordinator.itemsChanged(first: "row-a", last: "prev-committed")
        coordinator.contentWindowReplaced(
            survivorID: "prev-committed", firstID: "row-a",
            lastID: "prev-committed")
        coordinator.geometryChanged(ChatViewportGeometry(
            documentHeight: 8979, viewportHeight: 680,
            contentTop: -8605, rowsIntersectViewport: true))
        coordinator.scrollPhaseChanged(.idle)
        #expect(coordinator.position == nil, "the swap transaction settled")

        // THE COMMITTED REPLY LANDS as the new last row (the identity
        // swap completes). The follow re-fires IMMEDIATELY — the trace
        // showed no sentinel event ever arriving, so this must not
        // depend on one — and the SETTLED reply is revealed at the
        // bottom.
        coordinator.itemsChanged(first: "row-a", last: "settled-reply")
        #expect(
            coordinator.position?.viewID(type: String.self) == "settled-reply",
            "the committed reply landed below the fold — the follow did not carry across the swap")
    }

    @Test("a user scroll up LATCHES reading: content growth while paused issues NO command")
    func readingLatchSurvivesGrowth() {
        let (coordinator, _) = makeCoordinator(
            document: 4000, viewport: 700, contentTop: 0, intersects: true)
        // The user's slow drag up (tracking) — mid-read, they pause
        // (stay in tracking), then content grows (a stream arrives).
        coordinator.scrollPhaseChanged(.tracking)
        coordinator.bottomEdgeVisibleChanged(false)
        coordinator.itemsChanged(first: "row-a", last: "row-stream")
        coordinator.geometryChanged(ChatViewportGeometry(
            documentHeight: 4500, viewportHeight: 700,
            contentTop: 1500, rowsIntersectViewport: true))
        // READING is latched: no follow-latest command fires — the
        // reader's position is preserved (the slow-read instability
        // was intent flipping back to following on visibility).
        #expect(coordinator.position == nil)

        // More growth while still idle-and-reading: STILL no command.
        coordinator.itemsChanged(first: "row-a", last: "row-stream-2")
        coordinator.geometryChanged(ChatViewportGeometry(
            documentHeight: 5000, viewportHeight: 700,
            contentTop: 1500, rowsIntersectViewport: true))
        #expect(coordinator.position == nil)

        // The release (idle) does not flip intent either.
        coordinator.scrollPhaseChanged(.idle)
        coordinator.itemsChanged(first: "row-a", last: "row-stream-3")
        coordinator.geometryChanged(ChatViewportGeometry(
            documentHeight: 5500, viewportHeight: 700,
            contentTop: 1500, rowsIntersectViewport: true))
        #expect(coordinator.position == nil)
    }

    @Test("the probe sequence 1: at-bottom drag away via INTERACTING geometry — reading latched, growth issues no command")
    func probeSequence1AtBottomDragAway() {
        // The design pane's deterministic probe, sequence 1: at the
        // bottom edge, the user's touch (tracking) sees atBottom so
        // no latch engages; the drag then moves the content off the
        // edge (interacting); the intent must latch from the USER
        // MOVEMENT, and the incoming growth must NOT fire a follow.
        let (coordinator, _) = makeCoordinator(
            document: 4000, viewport: 700, contentTop: -3300,
            intersects: true)
        // Touch down at the edge: no latch (still at the edge).
        coordinator.scrollPhaseChanged(.tracking)
        // The drag moves the content up/away (top rises off the
        // at-edge threshold) while interacting.
        coordinator.scrollPhaseChanged(.interacting)
        coordinator.geometryChanged(ChatViewportGeometry(
            documentHeight: 4000, viewportHeight: 700,
            contentTop: -2900, rowsIntersectViewport: true))
        // The gesture ends; the growth arrives with a NEW last row.
        coordinator.scrollPhaseChanged(.idle)
        coordinator.itemsChanged(first: "row-a", last: "new-last")
        coordinator.geometryChanged(ChatViewportGeometry(
            documentHeight: 4200, viewportHeight: 700,
            contentTop: -2900, rowsIntersectViewport: true))
        // READING latched: no command (the probe recorded
        // followsLatest=true, command=true — the regression).
        #expect(
            coordinator.position == nil,
            "the growth fired a follow after the user dragged away from the edge")
    }

    @Test("the probe sequence 2: an ANIMATING follow interrupted by the user latches on the user's movement")
    func probeSequence2AnimatingInterruption() {
        // The pane's sequence 2: mid-document, a programmatic follow
        // is ANIMATING; the user's touch interrupts (tracking);
        // their drag moves the content; the intent must become
        // reading, and the new last row must NOT fire a follow.
        let (coordinator, _) = makeCoordinator(
            document: 4000, viewport: 700, contentTop: -2900,
            intersects: true)
        // A programmatic follow in flight (the identity-swap follow,
        // say), then the user interrupts.
        coordinator.itemsChanged(first: "row-a", last: "new-last")
        coordinator.scrollPhaseChanged(.animating)
        #expect(coordinator.position != nil)
        // The user's interruption — the animating->tracking
        // transition must not be swallowed by the idle-bool guard.
        coordinator.scrollPhaseChanged(.tracking)
        #expect(coordinator.position == nil, "the user's touch did not suspend the live automatic")
        // Their drag moves the content further off the edge.
        coordinator.scrollPhaseChanged(.interacting)
        coordinator.geometryChanged(ChatViewportGeometry(
            documentHeight: 4000, viewportHeight: 700,
            contentTop: -2600, rowsIntersectViewport: true))
        coordinator.scrollPhaseChanged(.idle)
        // The new last row arrives: no follow (reading latched).
        coordinator.itemsChanged(first: "row-a", last: "newer-last")
        coordinator.geometryChanged(ChatViewportGeometry(
            documentHeight: 4300, viewportHeight: 700,
            contentTop: -2600, rowsIntersectViewport: true))
        #expect(
            coordinator.position == nil,
            "a follow fired after the user interrupted and dragged away")
    }

    @Test("an INTERACTING drag away (no tracking sample) latches reading — growth never yanks (the real-path regression)")
    func interactingDragAwayLatchesReading() {
        // The real-path failure: a slow 1.1s swipe reports
        // .interacting (never .tracking), the geometry shows the
        // reader away from the bottom edge, then an incoming reply
        // grew the document — the follow-latest hold fired and yanked
        // the reader 350pt. The latch must engage from the
        // interacting phase alone and hold across the growth.
        let (coordinator, _) = makeCoordinator(
            document: 2662, viewport: 374, contentTop: -1989,
            intersects: true)
        // The swipe: interacting for its whole length (the phase the
        // device reports for a slow drag), then decelerating, then
        // idle. NO .tracking sample ever arrives.
        coordinator.scrollPhaseChanged(.interacting)
        // The gesture's first report latched reading (away from the
        // edge by the measured geometry)...
        // (asserted indirectly: the growth below must not fire a
        // follow hold)
        coordinator.scrollPhaseChanged(.decelerating)
        coordinator.scrollPhaseChanged(.idle)
        // THE GROWTH (an incoming reply lands): while latched
        // reading, NO follow-latest command fires — the anchor holds.
        coordinator.itemsChanged(first: "row-a", last: "incoming-reply")
        coordinator.geometryChanged(ChatViewportGeometry(
            documentHeight: 2736, viewportHeight: 374,
            contentTop: -1989, rowsIntersectViewport: true))
        #expect(
            coordinator.position == nil,
            "the follow-latest hold fired while the user was reading away — the reader got yanked")
        // More growth: still latched, still no yank.
        coordinator.itemsChanged(first: "row-a", last: "incoming-reply-2")
        coordinator.geometryChanged(ChatViewportGeometry(
            documentHeight: 2812, viewportHeight: 374,
            contentTop: -1989, rowsIntersectViewport: true))
        #expect(coordinator.position == nil)
    }

    @Test("a drag that leaves the bottom edge MID-GESTURE latches reading")
    func midGestureDepartureLatches() {
        // The drag STARTS at the bottom edge (no latch at touch-down)
        // and leaves it partway: the mid-gesture re-check latches.
        let (coordinator, _) = makeCoordinator(
            document: 4000, viewport: 700, contentTop: -3300,
            intersects: true)
        coordinator.scrollPhaseChanged(.tracking)  // at-edge: no latch
        // The user drags up; the gesture stays interacting and the
        // geometry departs the edge (contentTop rises above the
        // at-edge threshold). The bool dedupe would block this report
        // — the mid-gesture re-check must see it.
        coordinator.scrollPhaseChanged(.interacting)
        coordinator.geometryChanged(ChatViewportGeometry(
            documentHeight: 4000, viewportHeight: 700,
            contentTop: -3000, rowsIntersectViewport: true))
        coordinator.scrollPhaseChanged(.interacting)  // still dragging
        // Reading latched mid-gesture: growth does NOT follow.
        coordinator.scrollPhaseChanged(.idle)
        coordinator.itemsChanged(first: "row-a", last: "new-reply")
        coordinator.geometryChanged(ChatViewportGeometry(
            documentHeight: 4200, viewportHeight: 700,
            contentTop: -3000, rowsIntersectViewport: true))
        #expect(
            coordinator.position == nil,
            "growth yanked a mid-gesture reader who had left the edge")
    }

    @Test("a user's own scroll back to the edge RESUMES following")
    func userScrollBackResumesFollowing() {
        let (coordinator, _) = makeCoordinator(
            document: 4000, viewport: 700, contentTop: 0, intersects: true)
        // The user scrolls up (reading latched)...
        coordinator.scrollPhaseChanged(.tracking)
        coordinator.bottomEdgeVisibleChanged(false)
        coordinator.scrollPhaseChanged(.idle)
        // ...then scrolls back down: their own scroll puts the edge
        // back on screen — following RESUMES (the only resume path).
        coordinator.scrollPhaseChanged(.tracking)
        coordinator.bottomEdgeVisibleChanged(true)
        coordinator.scrollPhaseChanged(.idle)
        // Growth now holds the bottom edge: the follow fires and the
        // scroll ANIMATES (a programmatic follow is never idle — the
        // settle must not clear a healthy command mid-flight).
        coordinator.itemsChanged(first: "row-a", last: "row-new")
        coordinator.scrollPhaseChanged(.animating)
        #expect(
            coordinator.position?.viewID(type: String.self) == "row-new")
        coordinator.geometryChanged(ChatViewportGeometry(
            documentHeight: 4200, viewportHeight: 700,
            contentTop: -3500, rowsIntersectViewport: true))
        coordinator.scrollPhaseChanged(.idle)
        #expect(coordinator.position == nil)
    }

    @Test("a visibility flip alone NEVER writes intent (growth while idle at the edge follows)")
    func visibilityAloneNeverFlipsIntent() {
        let (coordinator, _) = makeCoordinator(
            document: 4000, viewport: 700, contentTop: -3300,
            intersects: true)
        // The user nudges but stays at the edge; the settle leaves the
        // sentinel VISIBLE; then growth pushes it offscreen while
        // idle — intent was and stays FOLLOWING (at the edge, growth
        // follows: the design's rule).
        coordinator.scrollPhaseChanged(.tracking)
        coordinator.scrollPhaseChanged(.idle)
        coordinator.itemsChanged(first: "row-a", last: "row-new")
        // The follow ANIMATES (programmatic), then lands at the new
        // bottom edge.
        coordinator.scrollPhaseChanged(.animating)
        #expect(
            coordinator.position?.viewID(type: String.self) == "row-new")
        coordinator.geometryChanged(ChatViewportGeometry(
            documentHeight: 4200, viewportHeight: 700,
            contentTop: -3500, rowsIntersectViewport: true))
        coordinator.scrollPhaseChanged(.idle)

        // The SAME sequence while latched READING: the geometry's
        // at-edge return (a programmatic settle, not the user) does
        // NOT resume following — growth still issues no command.
        let (reading, _) = makeCoordinator(
            document: 4000, viewport: 700, contentTop: -1500,
            intersects: true, following: false)
        reading.itemsChanged(first: "row-a", last: "row-newer")
        reading.geometryChanged(ChatViewportGeometry(
            documentHeight: 4400, viewportHeight: 700,
            contentTop: -1500, rowsIntersectViewport: true))
        #expect(reading.position == nil)
    }

    // MARK: Window replacement anchor transaction (the real-path blank trace)

    @Test("a window replacement re-anchors to the surviving row — deterministic, not budgeted")
    func windowReplacementReanchors() {
        // The reader is mid-history (reading latched).
        let (coordinator, _) = makeCoordinator(
            document: 6000, viewport: 700, contentTop: 4000,
            intersects: true, following: false)
        // Burn the repair budget first: the transaction must NOT
        // depend on it.
        coordinator.geometryChanged(ChatViewportGeometry(
            documentHeight: 6000, viewportHeight: 700,
            contentTop: 7000, rowsIntersectViewport: false))
        coordinator.geometryChanged(ChatViewportGeometry(
            documentHeight: 6000, viewportHeight: 700,
            contentTop: 7100, rowsIntersectViewport: false))
        coordinator.geometryChanged(ChatViewportGeometry(
            documentHeight: 6000, viewportHeight: 700,
            contentTop: 7200, rowsIntersectViewport: false))
        coordinator.geometryChanged(ChatViewportGeometry(
            documentHeight: 6000, viewportHeight: 700,
            contentTop: 7300, rowsIntersectViewport: false))

        // THE TRANSITION: the recent page replaced the window and the
        // reader's row survived: the re-anchor targets the SURVIVOR,
        // top-anchored, in the same pass — never a timer, never the
        // exhausted budget.
        coordinator.contentWindowReplaced(
            survivorID: "row-survivor", firstID: "row-a", lastID: "row-z")
        #expect(
            coordinator.position?.viewID(type: String.self) == "row-survivor")
        #expect(coordinator.repairAttempts == 0)

        // No survivor (the reader's row was deleted): the honest
        // fallback is the window's FIRST row.
        coordinator.contentWindowReplaced(
            survivorID: nil, firstID: "row-a2", lastID: "row-z2")
        #expect(
            coordinator.position?.viewID(type: String.self) == "row-a2")

        // A FOLLOWING reader takes the last row, bottom-anchored.
        let (following, _) = makeCoordinator(
            document: 6000, viewport: 700, contentTop: 0,
            intersects: true)
        following.contentWindowReplaced(
            survivorID: "row-survivor", firstID: "row-a", lastID: "row-z")
        #expect(
            following.position?.viewID(type: String.self) == "row-z")
    }

    @Test("user interaction SUSPENDS a live automatic command")
    func userTouchSuspendsAutomatics() {
        let (coordinator, _) = makeCoordinator(
            document: 4000, viewport: 700, contentTop: -3300,
            intersects: true)
        // A live follow-latest hold is in flight (the growth follow
        // fires on the last-row change alone)...
        coordinator.itemsChanged(first: "row-a", last: "row-new")
        #expect(coordinator.position != nil)
        // ...the user's touch arrives: the automatic is SUSPENDED
        // immediately (their intent outranks it; a pending position
        // would fight their drag).
        coordinator.scrollPhaseChanged(.tracking)
        #expect(coordinator.position == nil)
    }
}

