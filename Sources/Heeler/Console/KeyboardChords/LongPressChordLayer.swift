import Foundation

// SPDX-License-Identifier: Apache-2.0
//
// The pure state machine of the long-press chord layer on the tools
// keyboard (ADR 0013): holding a key cap opens an overlay of the variants
// the cap hides — Tab also hides Backtab and Ctrl-I, Esc also hides
// Esc-Esc, arrows also hide their modified forms. Generic over the variant
// type so the interaction logic stays Foundation-pure and testable; the
// concrete Agent-key table and the SwiftUI overlay live in
// LongPressChordOverlay.swift.

/// Interaction states for one long-press chord session. One session spans
/// one touch: ``press(variants:)`` when the hold is recognized,
/// ``longPressFired()`` when the overlay opens, ``select(atX:y:stripWidth:stripHeight:)``
/// while the finger drags across the overlay, and ``end()`` on release to
/// confirm the selected variant — or cancel when nothing was selected.
///
/// Quick taps never start a session (the long-press stage fails before its
/// minimum duration), so a key's ordinary send path is untouched until a
/// hold crosses the chord duration.
struct LongPressChordMachine<Variant: Identifiable & Hashable> {
    enum Phase: Equatable {
        case idle
        /// The hold is in progress but the overlay has not opened. Reached
        /// transiently: the gesture recognizer coalesces `press` and
        /// `longPressFired` into the same recognition event, and an
        /// abandoned hold (the finger lifted before the duration crossed)
        /// leaves this phase behind — the next `press` restarts it.
        case holding
        case menu
    }

    private(set) var phase: Phase = .idle
    /// The variants the open menu offers (empty while no session is live).
    private(set) var variants: [Variant] = []
    /// The variant the finger currently drags over, or nil when the finger
    /// is outside the strip — release then cancels instead of confirming.
    private(set) var selection: Int?
    /// True from the moment a menu opened until the originating key's own
    /// release passes through its tap action. That release belongs to the
    /// chord session and must not also send the plain key, so the key's
    /// action consumes this flag instead of sending.
    private(set) var isTapSuppressed = false

    var isMenuOpen: Bool { phase == .menu }

    /// Starts (or restarts) a session for a key with `variants`. A touch on
    /// a key without variants starts nothing. A second touch while a menu
    /// is open is ignored — the overlay's scrim owns the pad then, and the
    /// held finger's release still has to pass the suppression.
    mutating func press(variants: [Variant]) {
        guard phase != .menu else { return }
        isTapSuppressed = false
        selection = nil
        guard !variants.isEmpty else {
            self.variants = []
            phase = .idle
            return
        }
        self.variants = variants
        phase = .holding
    }

    /// Opens the overlay menu. Returns whether this call opened it.
    @discardableResult
    mutating func longPressFired() -> Bool {
        guard phase == .holding else { return false }
        phase = .menu
        selection = nil
        isTapSuppressed = true
        return true
    }

    /// Drag-to-select: maps a touch position in the measured strip to a
    /// variant index, splitting the strip into equal-width bands. A
    /// position outside the strip clears the selection, so dragging back to
    /// the key cancels on release.
    mutating func select(
        atX x: CGFloat, y: CGFloat, stripWidth: CGFloat, stripHeight: CGFloat
    ) {
        guard phase == .menu, !variants.isEmpty,
            stripWidth > 0, stripHeight > 0,
            x >= 0, x <= stripWidth, y >= 0, y <= stripHeight
        else {
            selection = nil
            return
        }
        let itemWidth = stripWidth / CGFloat(variants.count)
        selection = min(variants.count - 1, max(0, Int(x / itemWidth)))
    }

    /// Release: confirms the selected variant, or cancels when the finger
    /// never reached the strip. The tap suppression survives so the key's
    /// own release does not also send the plain key; the next `press`
    /// clears it.
    mutating func end() -> Variant? {
        defer {
            phase = .idle
            selection = nil
        }
        guard phase == .menu, let selection else { return nil }
        return variants[selection]
    }

    /// Closes an open menu without confirming — the scrim was tapped or the
    /// page changed. Suppression survives: the originating finger still has
    /// to release past its key's tap action.
    mutating func cancel() {
        guard phase != .idle else { return }
        phase = .idle
        selection = nil
    }

    /// Full reset, for the keyboard's disappearance: nothing can release
    /// anymore, so suppression clears with everything else.
    mutating func reset() {
        phase = .idle
        variants = []
        selection = nil
        isTapSuppressed = false
    }

    /// Consumed by the key's tap action: this release belongs to a chord
    /// session and must not send the plain key.
    mutating func clearTapSuppression() {
        isTapSuppressed = false
    }
}
