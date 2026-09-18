import Foundation

// SPDX-License-Identifier: Apache-2.0
//
// Scroll-paging trigger (Phase 5): decides when reaching the top loads
// older history, and — crucially — when it must NOT. Pure state machine so
// the trigger sequence is unit-testable without a scroll view.

/// One fire per gesture window: the trigger fires on the rising edge of
/// (sentinel visible, older available, no load in flight) and stays latched
/// until the sentinel leaves the screen. A user holding at the top gets one
/// page per arrival, not a page per layout pass; scrolling down and back up
/// re-arms for the next page.
internal struct ChatPagingGate: Sendable, Equatable {
    /// Whether a fire is latched off until the next sentinel departure.
    private var latched = false

    /// The transition for one input change. True only on the edge that
    /// should start a load.
    mutating func update(
        sentinelVisible: Bool, hasOlder: Bool, isLoadingOlder: Bool
    ) -> Bool {
        if !sentinelVisible {
            // Leaving the top ends the gesture window and re-arms.
            latched = false
            return false
        }
        guard !latched, hasOlder, !isLoadingOlder else { return false }
        latched = true
        return true
    }

    /// The inputs the gate observes; identity drives `onChange`.
    static func inputs(
        sentinelVisible: Bool, hasOlder: Bool, isLoadingOlder: Bool
    ) -> [Bool] {
        [sentinelVisible, hasOlder, isLoadingOlder]
    }
}
