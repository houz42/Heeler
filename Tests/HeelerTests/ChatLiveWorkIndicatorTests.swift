import SwiftUI
import Testing

@testable import Heeler

// SPDX-License-Identifier: Apache-2.0
//
// Unit pins for the v3 live-work indicator's state→visibility/
// animation mapping — the design doc's activity decisions as an
// executable contract (v3-ui-architecture-design.md: 'Activity
// animation preview' + 'Idle agent'):
//
// - working = animated spark, visible
// - idle = NOTHING: no marker, no reserved space
// - unknown/blocked/completed = static, never animated
// - no fresh producer report (nil) = NOTHING (connection success
//   alone does not imply thinking)
// - the spark's six-frame shape cycle (dot → cross → starburst →
//   contraction → dot) is pinned frame by frame

@Suite("Live-work indicator (state → visibility/animation)")
struct ChatLiveWorkIndicatorTests {

    // MARK: - The core mapping

    @Test("working → visible AND animated")
    func workingIsAnimated() {
        let p = ChatLiveWorkPresentation(.working)
        #expect(p.isVisible)
        #expect(p.isAnimated)
    }

    @Test("idle → NOT visible (no marker, no reserved space)")
    func idleIsNothing() {
        let p = ChatLiveWorkPresentation(.idle)
        #expect(!p.isVisible)
        #expect(!p.isAnimated)
    }

    @Test("nil (no fresh producer report) → NOT visible")
    func noReportIsNothing() {
        let p = ChatLiveWorkPresentation(nil)
        #expect(!p.isVisible)
        #expect(!p.isAnimated)
    }

    @Test("blocked/completed/unknown → visible but NEVER animated")
    func staticStatesNeverAnimate() {
        for state in [ChatLiveWorkState.blocked, .completed, .unknown] {
            let p = ChatLiveWorkPresentation(state)
            #expect(
                p.isVisible,
                "\(state) must render a static mark")
            #expect(
                !p.isAnimated,
                "\(state) must never animate")
        }
    }

    // MARK: - The frame cycle (the spark's shape sequence)

    @Test("frame 0 is the bare dot (no rays)")
    func frame0IsDot() {
        #expect(ChatLiveWorkSpark.rayLengths(frame: 0).isEmpty)
        #expect(ChatLiveWorkSpark.coreFraction(frame: 0) > 0)
    }

    @Test("frame 1 is the short 4-ray cross")
    func frame1IsShortCross() {
        let rays = ChatLiveWorkSpark.rayLengths(frame: 1)
        #expect(rays.count == 4)
        #expect(rays.allSatisfy { $0.fraction < 1 && $0.fraction > 0 })
    }

    @Test("frame 2 is the full 8-ray starburst")
    func frame2IsStarburst() {
        let rays = ChatLiveWorkSpark.rayLengths(frame: 2)
        #expect(rays.count == 8)
        #expect(rays.allSatisfy { $0.fraction == 1 })
    }

    @Test("frame 3 contracts back to the 4-ray cross")
    func frame3Contracts() {
        let rays = ChatLiveWorkSpark.rayLengths(frame: 3)
        #expect(rays.count == 4)
        #expect(rays.allSatisfy { $0.fraction < 1 && $0.fraction > 0 })
    }

    @Test("frames 4–5 contract back to the dot")
    func frames45ReturnToDot() {
        #expect(ChatLiveWorkSpark.rayLengths(frame: 4).isEmpty)
        #expect(ChatLiveWorkSpark.rayLengths(frame: 5).isEmpty)
    }

    @Test("the working static frame is the starburst (Reduce Motion)")
    func workingStaticFrameIsStarburst() {
        let p = ChatLiveWorkPresentation(.working)
        #expect(p.staticFrame == 2)
        // …and the starburst frame really is the full burst.
        #expect(
            ChatLiveWorkSpark.rayLengths(frame: p.staticFrame).count == 8)
    }

    @Test("static-state frames render the dot (no cycle dependency)")
    func staticStatesUseDotFrame() {
        // blocked/completed/unknown's static frame: the bare dot
        // (frame 0 has no rays, only the core).
        for state in [ChatLiveWorkState.blocked, .completed, .unknown] {
            let p = ChatLiveWorkPresentation(state)
            #expect(p.staticFrame == 0)
            #expect(ChatLiveWorkSpark.rayLengths(frame: p.staticFrame).isEmpty)
            #expect(ChatLiveWorkSpark.coreFraction(frame: p.staticFrame) > 0)
        }
    }

    // MARK: - Accessibility labels (no visible status sentence,
    // but the tree stays nameable)

    @Test("every state carries a distinct a11y label")
    func labelsAreDistinct() {
        let labels = [
            ChatLiveWorkPresentation.accessibilityLabel(for: .working),
            ChatLiveWorkPresentation.accessibilityLabel(for: .idle),
            ChatLiveWorkPresentation.accessibilityLabel(for: .blocked),
            ChatLiveWorkPresentation.accessibilityLabel(for: .completed),
            ChatLiveWorkPresentation.accessibilityLabel(for: .unknown),
        ]
        #expect(Set(labels).count == 5)
        #expect(labels.allSatisfy { !$0.isEmpty })
    }

    // MARK: - Frame arithmetic (the 0.9s six-frame cycle)

    @Test("the cycle is six frames over 0.9s")
    func cycleConstants() {
        #expect(ChatLiveWorkPresentation.frameCount == 6)
        #expect(ChatLiveWorkPresentation.cycleDuration == 0.9)
    }

    @Test("frame index wraps negative and overflowed inputs")
    func frameIndexWraps() {
        #expect(ChatLiveWorkSpark.rayLengths(frame: -1).count
            == ChatLiveWorkSpark.rayLengths(frame: 5).count)
        #expect(ChatLiveWorkSpark.rayLengths(frame: 6).count
            == ChatLiveWorkSpark.rayLengths(frame: 0).count)
        #expect(ChatLiveWorkSpark.rayLengths(frame: 8).count
            == ChatLiveWorkSpark.rayLengths(frame: 2).count)
    }
}

