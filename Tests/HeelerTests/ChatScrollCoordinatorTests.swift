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
        let (coordinator, _) = makeCoordinator(
            document: 4000, viewport: 700, contentTop: 0, intersects: true)
        coordinator.scrollPhaseChanged(.idle)
        // Keyboard shows: the viewport shrinks (geometry) and the
        // bottom sentinel is pushed offscreen (not a scroll up — the
        // shrink flag keeps following). The hold fires on the LAST
        // ROW (never the bare edge).
        coordinator.geometryChanged(ChatViewportGeometry(
            documentHeight: 4000, viewportHeight: 400,
            contentTop: 0, rowsIntersectViewport: true))
        coordinator.bottomEdgeVisibleChanged(false)
        coordinator.geometryChanged(ChatViewportGeometry(
            documentHeight: 4000, viewportHeight: 400,
            contentTop: 10, rowsIntersectViewport: true))
        #expect(
            coordinator.position?.viewID(type: String.self) == "row-z")

        // Keyboard hides: the viewport grows back, the sentinel
        // returns, the hold settles — no further commands.
        coordinator.bottomEdgeVisibleChanged(true)
        coordinator.geometryChanged(ChatViewportGeometry(
            documentHeight: 4000, viewportHeight: 700,
            contentTop: 0, rowsIntersectViewport: true))
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
            document: 4000, viewport: 700, contentTop: 0, intersects: true,
            following: false)
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
            contentTop: 3200, rowsIntersectViewport: true))
        #expect(coordinator.position == nil)
    }

    @Test("send growth while following latest: the hold targets the NEW last row, revealed at the bottom")
    func sendGrowthFollowsNewLastRow() {
        let (coordinator, _) = makeCoordinator(
            document: 4000, viewport: 700, contentTop: 0, intersects: true)
        // The reader is following latest, at the bottom edge.
        coordinator.scrollPhaseChanged(.idle)

        // The just-sent message lands: content GROWS, the bottom
        // sentinel is pushed offscreen (the edge is lost). The
        // coordinator holds the bottom edge on the NEW last row — the
        // just-sent message is revealed ("a bit"), never an overscroll
        // past it into blank.
        coordinator.itemsChanged(first: "row-a", last: "row-new")
        coordinator.bottomEdgeVisibleChanged(false)
        coordinator.geometryChanged(ChatViewportGeometry(
            documentHeight: 4200, viewportHeight: 700,
            contentTop: 0, rowsIntersectViewport: true))
        #expect(
            coordinator.position?.viewID(type: String.self) == "row-new")

        // The landing verification follows the same (new) target.
        coordinator.scrollPhaseChanged(.animating)
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
        // Growth now holds the bottom edge (following + edge lost).
        coordinator.itemsChanged(first: "row-a", last: "row-new")
        coordinator.bottomEdgeVisibleChanged(false)
        coordinator.geometryChanged(ChatViewportGeometry(
            documentHeight: 4200, viewportHeight: 700,
            contentTop: 0, rowsIntersectViewport: true))
        #expect(
            coordinator.position?.viewID(type: String.self) == "row-new")
    }

    @Test("a visibility flip alone NEVER writes intent (growth while idle at the edge follows)")
    func visibilityAloneNeverFlipsIntent() {
        let (coordinator, _) = makeCoordinator(
            document: 4000, viewport: 700, contentTop: 0, intersects: true)
        // The user nudges but stays at the edge; the settle leaves the
        // sentinel VISIBLE; then growth pushes it offscreen while
        // idle — intent was and stays FOLLOWING (at the edge, growth
        // follows: the design's rule).
        coordinator.scrollPhaseChanged(.tracking)
        coordinator.scrollPhaseChanged(.idle)
        coordinator.itemsChanged(first: "row-a", last: "row-new")
        coordinator.bottomEdgeVisibleChanged(false)
        coordinator.geometryChanged(ChatViewportGeometry(
            documentHeight: 4200, viewportHeight: 700,
            contentTop: 0, rowsIntersectViewport: true))
        #expect(
            coordinator.position?.viewID(type: String.self) == "row-new")

        // The SAME sequence while latched READING: the sentinel's
        // return (a programmatic settle, not the user) does NOT
        // resume following — growth still issues no command.
        let (reading, _) = makeCoordinator(
            document: 4000, viewport: 700, contentTop: 1000,
            intersects: true, following: false)
        reading.bottomEdgeVisibleChanged(true)
        reading.itemsChanged(first: "row-a", last: "row-newer")
        reading.geometryChanged(ChatViewportGeometry(
            documentHeight: 4400, viewportHeight: 700,
            contentTop: 1000, rowsIntersectViewport: true))
        #expect(reading.position == nil)
    }

    @Test("user interaction SUSPENDS a live automatic command")
    func userTouchSuspendsAutomatics() {
        let (coordinator, _) = makeCoordinator(
            document: 4000, viewport: 700, contentTop: 0, intersects: true)
        // A live follow-latest hold is in flight...
        coordinator.itemsChanged(first: "row-a", last: "row-new")
        coordinator.bottomEdgeVisibleChanged(false)
        coordinator.geometryChanged(ChatViewportGeometry(
            documentHeight: 4200, viewportHeight: 700,
            contentTop: 0, rowsIntersectViewport: true))
        #expect(coordinator.position != nil)
        // ...the user's touch arrives: the automatic is SUSPENDED
        // immediately (their intent outranks it; a pending position
        // would fight their drag).
        coordinator.scrollPhaseChanged(.tracking)
        #expect(coordinator.position == nil)
    }
}

