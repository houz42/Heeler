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
            coordinator.bottomEdgeVisibleChanged(false)
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
        // visible window in the padding above the first row.
        let (coordinator, _) = makeCoordinator(
            document: 500, viewport: 700, contentTop: 200,
            intersects: false)
        #expect(coordinator.position?.edge == .bottom)
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

    // MARK: Keyboard/geometry preservation


    @Test("keyboard shrink while following latest keeps the bottom edge")
    func keyboardShrinkFollowsLatest() {
        let (coordinator, _) = makeCoordinator(
            document: 4000, viewport: 700, contentTop: 0, intersects: true)
        coordinator.scrollPhaseChanged(.idle)
        // Keyboard shows: viewport shrinks, still intersecting.
        let shrunk = ChatViewportGeometry(
            documentHeight: 4000, viewportHeight: 400,
            contentTop: 0, rowsIntersectViewport: true)
        coordinator.geometryChanged(shrunk)
        #expect(coordinator.position?.edge == .bottom)

        // Keyboard hides: viewport grows back.
        let grown = ChatViewportGeometry(
            documentHeight: 4000, viewportHeight: 700,
            contentTop: 0, rowsIntersectViewport: true)
        coordinator.geometryChanged(grown)
        #expect(coordinator.position?.edge == .bottom)
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
}

