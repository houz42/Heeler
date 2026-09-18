import Foundation

// SPDX-License-Identifier: Apache-2.0
//
// Pure swipe-to-chord mapping for the tools keyboard's herdr prefix
// recognizer (ADR 0013's key row): a horizontal or upward swipe on the
// Agent key row becomes the herdr prefix chord — prefix, then the swipe's
// direction as an arrow. Swipe left/right maps to next/previous agent and
// swipe up to console under herdr's shipped example bindings; the bytes
// only ever carry prefix + arrow, so the semantics are whatever the
// host's herdr binds there (a remapped prefix key needs a remapped table,
// which is why the byte mapping is data, not a hidden constant).

/// The swipe directions that carry a herdr prefix chord.
enum PrefixSwipeDirection: Int, CaseIterable, Sendable {
    case left
    case right
    case up
}

/// Pure classification and byte mapping. The SwiftUI gesture wiring lives
/// in AgentControlKeyboard; only the math and the wire bytes live here.
enum PrefixSwipeRecognizer {
    /// A drag shorter than this never fires a chord.
    static let recognitionDistance: CGFloat = 44
    /// Tracking begins at the distance the keyboard's page-swipe pager
    /// used to cancel key presses, so keys still stand down mid-swipe even
    /// though the pager no longer claims the touch.
    static let trackingDistance: CGFloat = 16

    /// The dominant-axis direction of a finished drag, or nil when the drag
    /// is too short, mostly downward, or ambiguous.
    static func direction(
        translation: CGSize, minimumDistance: CGFloat = recognitionDistance
    ) -> PrefixSwipeDirection? {
        let dx = translation.width
        let dy = translation.height
        if abs(dx) >= minimumDistance, abs(dx) > abs(dy) {
            return dx < 0 ? .left : .right
        }
        if -dy >= minimumDistance, -dy > abs(dx) {
            return .up
        }
        return nil
    }

    /// herdr's default prefix is Ctrl-B (0x02); the gesture direction rides
    /// in as its normal-mode CSI arrow. Application-cursor-mode encodings
    /// (SS3) are deliberately absent: the prefix mode of a herdr host is a
    /// normal-mode key reader.
    static func chord(for direction: PrefixSwipeDirection) -> Data {
        let prefix: UInt8 = 0x02
        let arrow: [UInt8]
        switch direction {
        case .left: arrow = [0x1B, 0x5B, 0x44]  // CSI D
        case .right: arrow = [0x1B, 0x5B, 0x43]  // CSI C
        case .up: arrow = [0x1B, 0x5B, 0x41]  // CSI A
        }
        return Data([prefix] + arrow)
    }
}
