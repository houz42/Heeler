import Foundation
import Observation
import SwiftUI

// SPDX-License-Identifier: Apache-2.0
//
// The chat viewport's ONE scroll-position/geometry owner (design doc:
// "Blank viewport prevention": "use a single scroll-position/geometry
// coordinator and validate the platform mechanism. No competing scroll
// commands from keyboard handlers, data refresh and sentinels").
//
// What it is: an @MainActor @Observable state machine ChatScreen drives.
// Every actor that historically issued scroll intents — the initial
// open, keyboard cycles, older-page prepends, data refresh, the jump
// pill — reports its fact to the coordinator, which decides ONE
// programmatic position (if any) and hands it back for the view to
// bind. The view reports geometry/phase back; decisions are one-shot:
// once the geometry shows a row intersecting the viewport again, the
// decision clears and can never fight the user's own scrolls.
//
// Anchor policy (design doc), all decided HERE:
// - long initial history opens at the LATEST edge;
// - short content top-aligns (NO programmatic command — the stock
//   defaultScrollAnchor handles a short document; a forced zero offset
//   here fought it and caused visible jumps);
// - older paging pins the top visible record (issued while the OLD
//   layout is still current, so the pin is a no-op movement that holds
//   when the prepended rows land);
// - keyboard/rotation/type-size changes preserve the reading anchor
//   unless the reader was following latest, in which case the BOTTOM
//   edge is preserved.
//
// The blank-viewport repair: when content exists but NO row intersects
// the visible window (the reported device blank — a stale document-
// offset restoration that lands the window in the padding above the
// first row), the coordinator issues ONE corrective position, bounded
// to a few attempts so a hostile layout can never loop it.

/// The measured geometry of one scroll layout pass. Both frames are in
/// ONE coordinate space (global), so `contentTop` and the intersection
/// are exact — no mixed-space arithmetic.
struct ChatViewportGeometry: Sendable, Equatable {
    /// The transcript stack's laid-out height (all rows + padding).
    let documentHeight: CGFloat
    /// The ScrollView's visible height.
    let viewportHeight: CGFloat
    /// The transcript stack's top edge, relative to the visible top
    /// (0 = flush with the viewport's top; > 0 = the visible window
    /// sits ABOVE the content — the blank-viewport signature).
    let contentTop: CGFloat
    /// Whether ANY part of the transcript stack intersects the visible
    /// window — the design doc's "a real message must intersect it"
    /// invariant, made measurable.
    let rowsIntersectViewport: Bool

    /// Content overflows the visible window (long history).
    var overflows: Bool {
        documentHeight > viewportHeight + 1
    }
}

/// The decision coordinator for the chat transcript's scroll position.
@MainActor
@Observable
final class ChatScrollCoordinator {

    // MARK: Reported inputs

    private(set) var followsLatest = true
    private(set) var scrollIdle = true
    private(set) var geometry: ChatViewportGeometry?
    private(set) var itemBounds: (first: String, last: String)?

    /// Repair attempts so far (a layout that never satisfies the
    /// corrective position must not loop the coordinator). Exposed for
    /// the decision-table tests.
    private(set) var repairAttempts = 0

    /// The repair bound.
    private static let maxRepairAttempts = 3

    // MARK: Output — ONE programmatic position at a time

    /// The current scroll decision. The view binds this through its
    /// own `scrollPosition` state (a direct binding would let every
    /// user-scroll write clobber the decision); one-shot: it clears
    /// once the geometry shows rows intersecting the viewport again.
    private(set) var position: ScrollPosition?

    /// Whether the initial anchor decision was made (once per mount).
    private var didInitialAnchor = false

    // MARK: Input ports

    /// The bottom sentinel's presence: true = the latest edge is on
    /// screen (no command needed to hold it). false = either the
    /// reader scrolled up (stop following) or content GREW while
    /// following (keep following — the sentinel was pushed offscreen
    /// by the new records, not by the reader).
    private(set) var bottomEdgeVisible = true
    /// Set when the last record id changed while the reader was
    /// following latest (content growth at the edge): the sentinel's
    /// NEXT departure keeps followsLatest (growth ≠ reading history).
    private var edgeGrewWhileFollowing = false
    /// Same flag for the viewport SHRINK path (the keyboard appearing
    /// while at the edge).
    private var viewportShrankWhileFollowing = false


    func bottomEdgeVisibleChanged(_ visible: Bool) {
        guard bottomEdgeVisible != visible else { return }
        bottomEdgeVisible = visible
        if visible {
            followsLatest = true
            edgeGrewWhileFollowing = false
            viewportShrankWhileFollowing = false
        } else if edgeGrewWhileFollowing || viewportShrankWhileFollowing {
            // The sentinel left because content grew or the viewport
            // shrank (the keyboard) while the reader was following —
            // NOT a scroll up. Keep following; the hold re-reveals
            // the edge.
            edgeGrewWhileFollowing = false
            viewportShrankWhileFollowing = false
        } else {
            // The reader left the bottom edge by scrolling up: they
            // are reading history now.
            followsLatest = false
        }
        ChatViewportLog.shared.record(
            .anchor, visible ? "at latest edge" : "left latest edge")
    }

    func topSentinelVisibleChanged(_ visible: Bool) {
        ChatViewportLog.shared.record(
            .anchor, "top sentinel \(visible)")
    }

    func scrollPhaseChanged(_ phase: ScrollPhase) {
        let idle = !phase.isScrolling
        guard idle != scrollIdle else { return }
        scrollIdle = idle
        if idle {
            settleIfSatisfied()
        }
    }

    func geometryChanged(_ new: ChatViewportGeometry) {
        guard new != geometry else { return }
        let old = geometry
        // A viewport SHRINK while following latest (the keyboard
        // appearing) may push the bottom sentinel offscreen without
        // the reader scrolling — the sentinel's next departure must
        // not stop the following.
        if followsLatest, let old, new.viewportHeight < old.viewportHeight {
            viewportShrankWhileFollowing = true
        }
        geometry = new
        ChatViewportLog.shared.record(
            .geometry,
            "doc=\(Int(new.documentHeight)) vp=\(Int(new.viewportHeight)) top=\(Int(new.contentTop)) intersect=\(new.rowsIntersectViewport)")
        guard old == nil else {
            revalidateAfterGeometryChange()
            return
        }
        decideInitialAnchor()
    }

    func itemsChanged(first: String, last: String) {
        guard itemBounds?.first != first || itemBounds?.last != last
        else { return }
        let hadItems = itemBounds != nil
        // Growth at the edge: the LAST record id changed while the
        // reader was following latest (a just-sent message, a stream
        // tail) — capture it BEFORE the bounds update.
        if followsLatest, let oldLast = itemBounds?.last,
            oldLast != last, !last.isEmpty
        {
            edgeGrewWhileFollowing = true
        }
        itemBounds = (first, last)
        ChatViewportLog.shared.record(.records, "first=\(first) last=\(last)")
        if !hadItems, geometry != nil, !didInitialAnchor {
            // Content arrived after the first measurement: the initial
            // anchor decision runs now.
            decideInitialAnchor()
        }
        // Content growth at the latest edge (a just-sent message): a
        // pending bottom-targeted landing follows the NEW last row so
        // the verification targets what actually needs to be on
        // screen, not the row that was last when the jump fired.
        if followsLatest, let pending = pendingLandingTargetID,
            pending != last, !last.isEmpty
        {
            pendingLandingTargetID = last
        }
        // A viewport whose rows intersect again re-arms repairs.
        if geometry?.rowsIntersectViewport == true {
            repairAttempts = 0
        }
    }

    // MARK: Decisions


    /// The initial open is owned by the stock defaultScrollAnchor
    /// (latest-edge for long history; top-aligned short content). The
    /// coordinator's initial decision is REPAIR-ONLY: a first mount
    /// whose restored layout lands the visible window off every row
    /// (the device blank on open) takes the SAME bounded repair as
    /// later cycles. A healthy initial layout gets NO command (a
    /// redundant latest-edge here would fight the stock anchor and
    /// has caused visible jumps).
    private func decideInitialAnchor() {
        guard let geometry, let bounds = itemBounds, !bounds.first.isEmpty
        else { return }
        didInitialAnchor = true
        guard geometry.rowsIntersectViewport else {
            repairAttempts += 1
            if followsLatest {
                issuePosition(
                    ScrollPosition(id: bounds.last, anchor: .bottom))
                pendingLandingTargetID = bounds.last
                ChatViewportLog.shared.record(
                    .anchor, "initial: REPAIR blank → last row \(bounds.last)")
            } else {
                issuePosition(ScrollPosition(id: bounds.first, anchor: .top))
                ChatViewportLog.shared.record(
                    .anchor, "initial: REPAIR blank → top row \(bounds.first)")
            }
            return
        }
    }


    /// A geometry change (keyboard, rotation, type size, layout
    /// invalidation, refresh): re-validate the reading state and
    /// repair a blank viewport if this is the failure shape.
    private func revalidateAfterGeometryChange() {
        guard let geometry, let bounds = itemBounds, !bounds.first.isEmpty
        else {
            // No content: nothing to protect (the honest empty state
            // renders instead).
            return
        }
        // A live decision whose target is now satisfied settles.
        settleIfSatisfied()

        // The blank-viewport repair (content exists, NO row intersects
        // the visible window, no scroll in flight): one corrective
        // position, bounded. NEVER the bare document edge — edge
        // positions scroll past the last row into unmaterialized lazy
        // space (the reported send/jump blank): the target is the
        // LAST ROW, and the landing is verified (verifyBlankLanding).
        if !geometry.rowsIntersectViewport, scrollIdle,
            repairAttempts < Self.maxRepairAttempts
        {
            repairAttempts += 1
            if followsLatest {
                issuePosition(
                    ScrollPosition(id: bounds.last, anchor: .bottom))
                pendingLandingTargetID = bounds.last
            } else {
                issuePosition(ScrollPosition(id: bounds.first, anchor: .top))
            }
            ChatViewportLog.shared.record(
                .anchor,
                "REPAIR blank viewport (#\(repairAttempts)) → \(followsLatest ? "last row \(bounds.last)" : "top row \(bounds.first)")")
            return
        }
        // Following latest on overflow: hold the bottom edge through
        // keyboard/refresh/SEND cycles — but ONLY when the edge is
        // actually LOST (the bottom sentinel left the screen). A
        // settled viewport at the bottom edge needs NO command; an
        // unconditional re-issue here fought every settlement and
        // churned commands on each geometry pass (the send/jump
        // blank class). The target is the LAST ROW (bottom-anchored —
        // its bottom pinned to the viewport's bottom, so growth
        // reveals the new message "a bit"), never the bare document
        // edge; the landing is verified.
        if followsLatest, !bottomEdgeVisible, geometry.overflows,
            scrollIdle
        {
            issuePosition(ScrollPosition(id: bounds.last, anchor: .bottom))
            pendingLandingTargetID = bounds.last
            ChatViewportLog.shared.record(
                .anchor, "follow-latest: hold bottom edge (last row)")
        }
        // Reading mid-history: NO programmatic command. The reader's
        // anchor row stays visible (LazyVStack preserves it across
        // alignment/size-only changes); the coordinator never scrolls
        // the reader away from it.
    }

    /// Older-page prepends: pin the top row — the CURRENT first row,
    /// issued while the old layout is still current (a no-op movement
    /// that holds the anchor when the prepended rows land above it).
    /// Intra-row offset is preserved by the anchor row never re-keying.
    func olderPageWillPrepend(currentFirstID: String) {
        guard !currentFirstID.isEmpty else { return }
        issuePosition(ScrollPosition(id: currentFirstID, anchor: .top))
        ChatViewportLog.shared.record(
            .anchor, "older page: pin top row \(currentFirstID)")
    }

    /// The jump pill's explicit navigations — routed through the
    /// coordinator so they can never interleave with a repair. A
    /// bottom-anchored jump onto an UNMATERIALIZED lazy region rides
    /// SwiftUI's position ESTIMATE, which can overshoot past the last
    /// row into blank space (the reported jump-to-bottom blank). The
    /// landing is therefore VERIFIED: if the scroll settles with no
    /// row intersecting the viewport, ONE corrective position lands
    /// the same id CENTER-anchored — a center anchor can never place
    /// the target outside its own extent, so the real message is on
    /// screen, never blank.
    func userJumped(to id: String, anchor: UnitPoint) {
        issuePosition(ScrollPosition(id: id, anchor: anchor))
        followsLatest = anchor == .bottom
        if anchor == .bottom {
            pendingLandingTargetID = id
            landingCorrections = 0
        }
        ChatViewportLog.shared.record(.anchor, "user jump → \(id)")
    }

    /// A bottom-targeted landing that settled blank gets at most ONE
    /// center-anchored correction (then the bounded repair budget).
    private var pendingLandingTargetID: String?
    private var landingCorrections = 0

    // MARK: Settlement

    private func issuePosition(_ newPosition: ScrollPosition) {
        position = newPosition
    }

    /// A live decision clears once the geometry shows a row
    /// intersecting the viewport and no scroll is in flight —
    /// one-shot semantics, so the user's own scrolls always win after.
    /// A bottom-targeted landing that settled with NO row intersecting
    /// (the LazyVStack estimate overshot into blank) takes ONE
    /// center-anchored correction on the same target before the
    /// generic repair budget.
    private func settleIfSatisfied() {
        guard position != nil, let geometry, scrollIdle else { return }
        if geometry.rowsIntersectViewport {
            position = nil
            repairAttempts = 0
            pendingLandingTargetID = nil
            ChatViewportLog.shared.record(
                .anchor, "settled — rows intersect viewport")
        } else {
            verifyBlankLanding()
        }
    }

    /// The landing verification: a live scroll decision went idle with
    /// NO row intersecting the viewport — the blank-viewport failure
    /// shape. For a bottom-targeted landing (jump-to-bottom,
    /// send-follow), ONE center-anchored correction on the same target
    /// id (a center anchor can never place the target outside its own
    /// extent); otherwise the bounded generic repair, also last-row
    /// targeted (never the bare document edge).
    private func verifyBlankLanding() {
        guard let geometry, !geometry.rowsIntersectViewport, scrollIdle
        else { return }
        if let target = pendingLandingTargetID, landingCorrections == 0 {
            landingCorrections += 1
            issuePosition(ScrollPosition(id: target, anchor: .center))
            ChatViewportLog.shared.record(
                .anchor, "landing correction → \(target) centered")
            return
        }
        // The generic bounded repair (initial/refresh blanks).
        if repairAttempts < Self.maxRepairAttempts,
            let bounds = itemBounds, !bounds.first.isEmpty
        {
            repairAttempts += 1
            if followsLatest {
                issuePosition(
                    ScrollPosition(id: bounds.last, anchor: .bottom))
                pendingLandingTargetID = bounds.last
            } else {
                issuePosition(ScrollPosition(id: bounds.first, anchor: .top))
            }
            ChatViewportLog.shared.record(
                .anchor,
                "REPAIR blank viewport (#\(repairAttempts)) → \(followsLatest ? "last row \(bounds.last)" : "top row \(bounds.first)")")
        }
    }


    // MARK: Debug

    var debugState: String {
        let g = geometry.map {
            "doc=\(Int($0.documentHeight)) vp=\(Int($0.viewportHeight)) top=\(Int($0.contentTop)) intersect=\($0.rowsIntersectViewport)"
        } ?? "none"
        return "followsLatest=\(followsLatest) idle=\(scrollIdle) g[\(g)] repairs=\(repairAttempts)"
    }
}
