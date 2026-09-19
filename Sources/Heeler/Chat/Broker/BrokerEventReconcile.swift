import Foundation

// SPDX-License-Identifier: Apache-2.0
//
// Pure reconcile logic for broker events. Ordering holds only within
// one (instanceId, generation); seq is strictly increasing there. The
// reducer is stateless: the store owns the accumulator.

/// The streaming reconcile state for one subscribed registration.
struct BrokerReconcileState: Sendable, Equatable {
    let instanceId: String
    let generation: Int
    /// Highest contiguous seq consumed. Events arrive in order per the
    /// contract, but a late/out-of-order frame must never corrupt the
    /// transcript — anything older than `lastSeq` is dropped.
    var lastSeq: Int = 0
    /// Buffered newer-than-expected frames when a gap appears (should
    /// not happen on an ordered socket; kept so a reordered delivery is
    /// corrected rather than dropped).
    var buffered: [BrokerEventFrame] = []

    init(instanceId: String, generation: Int) {
        self.instanceId = instanceId
        self.generation = generation
    }
}

/// What one consumed event means for the transcript.
enum BrokerEventEffect: Sendable, Equatable {
    /// Apply as usual (nothing durable yet: deltas are provisional).
    case accepted(BrokerEventFrame)
    /// Frame older/other-instance/other-generation: ignore.
    case ignored
    /// A durable transition (turn/message/tool end) — the store re-opens
    /// the recent page to reconcile truth.
    case refetchRecent
    /// Identity churn: re-match and re-open everything.
    case resync
}

enum BrokerEventReconcile: Sendable {
    /// Folds one frame into the state, deciding its effect. Ordering:
    /// seq must be strictly increasing within (instanceId, generation);
    /// older or duplicate frames are ignored, and a gap buffers the
    /// frame (correcting reorder) while the gap persists — a missing
    /// frame never rewrites history silently: after a bounded window
    /// the store must resync instead.
    static func fold(
        _ state: inout BrokerReconcileState, frame: BrokerEventFrame
    ) -> BrokerEventEffect {
        guard frame.instanceId == state.instanceId else { return .ignored }
        guard frame.generation == state.generation else {
            // New generation without a session_identity event first, or a
            // stale generation's late frame: both resync (the store
            // re-matches, which lands on the new generation).
            return .resync
        }
        guard frame.seq > state.lastSeq else { return .ignored }
        if frame.seq > state.lastSeq + 1, state.lastSeq > 0 {
            // Gap: buffer; the store's gap watchdog resyncs if it does
            // not close. (The contract guarantees ordered delivery, so
            // this is belt-and-braces for a misbehaving fan-out.)
            state.buffered.append(frame)
            return .ignored
        }
        state.lastSeq = frame.seq
        switch BrokerEventKind(rawValue: frame.kind) {
        case .resyncRequired:
            return .resync
        case .sessionIdentity:
            // Generation bumped with the announcement: re-match identity.
            return .resync
        case .messageEnd, .turnEnd, .agentEnd, .toolEnd:
            // Durable transition — history is truth; re-read the recent
            // page (bounded re-open, not a full resync).
            return .refetchRecent
        case .messageStart, .messageDelta, .agentStart, .turnStart,
            .toolStart, .toolUpdate:
            return .accepted(frame)
        case nil:
            // Unknown kinds are additive: accepted for buffering parity
            // but trigger nothing durable.
            return .accepted(frame)
        }
    }
}
