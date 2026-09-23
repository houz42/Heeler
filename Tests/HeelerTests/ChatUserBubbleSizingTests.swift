import Foundation
import Testing

@testable import Heeler

/// v3 content-sized own-message bubbles — the WIDTH POLICY as pure
/// functions. The design doc's tokens: maximum bubble width
/// `min(0.85 × available transcript width, 560pt)`, 12pt horizontal /
/// 8pt vertical internal padding, the cap is a maximum never a forced
/// width. These tests pin the arithmetic so a future "fix" cannot
/// silently stretch own bubbles back to a fixed fraction of the row.
@Suite("User Bubble Sizing")
struct ChatUserBubbleSizingTests {

    // MARK: design tokens

    @Test func designTokensAreExact() {
        #expect(ChatUserBubbleSizing.horizontalPadding == 12)
        #expect(ChatUserBubbleSizing.verticalPadding == 8)
        #expect(ChatUserBubbleSizing.absoluteCap == 560)
        #expect(ChatUserBubbleSizing.transcriptFraction == 0.85)
    }

    // MARK: the cap

    @Test func capIsFractionOnNarrowTranscripts() {
        // A phone transcript (~361pt usable width): the fraction wins.
        #expect(ChatUserBubbleSizing.maxVisibleBubbleWidth(
            transcriptWidth: 361) == 361 * 0.85)
        #expect(ChatUserBubbleSizing.maxVisibleBubbleWidth(
            transcriptWidth: 361) < 560)
    }

    @Test func capIsAbsoluteCapOnWideTranscripts() {
        // A wide/iPad transcript where 0.85 × would exceed 560: the
        // absolute cap wins (0.85 × 700 = 595 > 560).
        #expect(ChatUserBubbleSizing.maxVisibleBubbleWidth(
            transcriptWidth: 700) == 560)
        #expect(ChatUserBubbleSizing.maxVisibleBubbleWidth(
            transcriptWidth: 1_000) == 560)
    }

    @Test func capBoundaryIsExact() {
        // 0.85 × t == 560 exactly at t = 560/0.85 ≈ 658.82: at and
        // just past the crossing, the cap is 560.
        let crossing: CGFloat = 560 / 0.85
        #expect(ChatUserBubbleSizing.maxVisibleBubbleWidth(
            transcriptWidth: crossing) == 560)
        #expect(ChatUserBubbleSizing.maxVisibleBubbleWidth(
            transcriptWidth: crossing - 1) < 560)
    }

    // MARK: the content proposal

    @Test func proposedContentWidthAddsBothHorizontalPaddings() {
        // The LAYOUT proposal is the visible cap plus 2 × 12pt, so a
        // filled long-prose bubble's TEXT area spans exactly the
        // visible maximum after padding.
        let width = ChatUserBubbleSizing.proposedContentWidth(
            transcriptWidth: 361)
        #expect(width == 361 * 0.85 + 24)
    }

    @Test func proposedContentWidthRespectsAbsoluteCapPlusPadding() {
        // Wide transcript: proposal is 560 + 24, never more.
        #expect(ChatUserBubbleSizing.proposedContentWidth(
            transcriptWidth: 900) == 584)
    }

    // MARK: the cap is a maximum, never a forced width

    @Test func capNeverForcesWidth() {
        // The policy exposes a MAXIMUM only: an own bubble's visible
        // width is min(content + 2×padding, maxVisibleBubbleWidth) at
        // the VIEW level (HuggingBubble's layout). The arithmetic
        // functions themselves return caps independent of content —
        // pinning that this enum offers no "bubbleWidth(content:)"
        // that would smuggle a forced width back in is the point of
        // this suite's existence: content smaller than the cap keeps
        // its own size, which the hug-content layout guarantees and
        // the sim captures evidence.
        let cap = ChatUserBubbleSizing.maxVisibleBubbleWidth(
            transcriptWidth: 361)
        // A one-word bubble ("Ship it.") renders ~60pt wide — far
        // below the cap. The cap does not depend on content length.
        #expect(cap > 60)
    }

    @Test func zeroAndTinyTranscriptsDegradeToZeroCap() {
        // Degrade honestly: a zero-width transcript proposes a zero
        // cap (the row is not yet measured); never negative, never
        // NaN.
        #expect(ChatUserBubbleSizing.maxVisibleBubbleWidth(
            transcriptWidth: 0) == 0)
        #expect(ChatUserBubbleSizing.maxVisibleBubbleWidth(
            transcriptWidth: 10) == 10 * 0.85)
    }
}
