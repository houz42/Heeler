import Foundation

// SPDX-License-Identifier: Apache-2.0
//
// agent-chat v1 reconcile: routed event streams are monotonic per
// (instanceId, generation); a disconnect or a gap means reopen — no
// replay guarantee in v1. Stream IDs are provisional and SEPARATE from
// committed item IDs; history.changed is the authoritative reconcile
// signal. The subscribe-before-snapshot flow buffers events until the
// first page's throughSeq lands, then drops everything ≤ the watermark.

/// Reconcile state for one subscribed registration.
struct AgentChatReconcileState: Sendable, Equatable {
    let instanceId: String
    let generation: Int
    var lastSeq = 0

    init(instanceId: String, generation: Int) {
        self.instanceId = instanceId
        self.generation = generation
    }
}

/// What one consumed event means for the store.
enum AgentChatEventEffect: Sendable, Equatable {
    /// A provisional stream update (message.started/delta/finished) —
    /// keyed by streamId, never durable.
    case stream(StreamSignal)
    /// history.changed: authoritative — re-open the recent page.
    case refetchRecent
    /// session.unavailable / resync_required / generation churn: the
    /// store re-matches from scratch.
    case resync
    /// interaction lifecycle (only when the capability is on).
    case interaction(InteractionSignal)
    /// Buffered until a watermark or out-of-scope: no action now.
    case ignored
}

/// Provisional stream signals. `streamId` is adapter-generated per
/// in-flight message and is NOT a durable item id.
enum StreamSignal: Sendable, Equatable {
    case started(streamId: String, authorRole: String?)
    case delta(streamId: String, blockIndex: Int, text: String)
    case finished(streamId: String)
}

/// Interaction lifecycle signals (capability-gated surface).
enum InteractionSignal: Sendable, Equatable {
    case opened(AgentChatInteraction)
    case resolved(requestId: String, outcome: String, source: String)
}

enum AgentChatEventReconcile: Sendable {
    /// Folds one routed frame. Frames with seq ≤ lastSeq are duplicates
    /// (dropped); a gap (seq > lastSeq + 1) is a REOPEN — v1 gives no
    /// replay guarantee, so gap buffering from the prototype arm is
    /// deliberately gone.
    static func fold(
        _ state: inout AgentChatReconcileState, frame: AgentChatEventFrame
    ) -> AgentChatEventEffect {
        guard frame.instanceId == state.instanceId, frame.generation == state.generation
        else {
            return .resync
        }
        guard frame.seq > state.lastSeq else { return .ignored }
        guard frame.seq == state.lastSeq + 1 || state.lastSeq == 0 else {
            return .resync
        }
        state.lastSeq = frame.seq

        switch frame.type {
        case "message.started":
            return .stream(
                .started(
                    streamId: frame["streamId"]?.stringValue ?? "",
                    authorRole: frame["author"].flatMap({ $0["role"]?.stringValue })))
        case "message.delta":
            return .stream(
                .delta(
                    streamId: frame["streamId"]?.stringValue ?? "",
                    blockIndex: frame["blockIndex"]?.intValue ?? 0,
                    text: frame["text"]?.stringValue ?? ""))
        case "message.finished":
            return .stream(.finished(streamId: frame["streamId"]?.stringValue ?? ""))
        case "history.changed":
            return .refetchRecent
        case "resync_required", "session.changed":
            return .resync
        case "interaction.opened":
            guard let interaction = frame["interaction"].flatMap(decodeInteraction)
            else { return .ignored }
            return .interaction(.opened(interaction))
        case "interaction.resolved":
            return .interaction(
                .resolved(
                    requestId: frame["requestId"]?.stringValue ?? "",
                    outcome: frame["outcome"]?.stringValue ?? "",
                    source: frame["source"]?.stringValue ?? ""))
        default:
            // Unknown additive event kinds: consumed for ordering, no
            // durable action.
            return .ignored
        }
    }

    /// Applies the first page's watermark: everything ≤ throughSeq is
    /// already reflected in the page. Buffered frames above it replay
    /// through fold; the ones ≤ it are dropped by resetting lastSeq.
    static func applyWatermark(
        _ state: inout AgentChatReconcileState, throughSeq: Int
    ) {
        state.lastSeq = max(state.lastSeq, throughSeq)
    }

    private static func decodeInteraction(_ value: JSONValue) -> AgentChatInteraction? {
        guard let data = try? JSONEncoder().encode(value),
            let interaction = try? JSONDecoder().decode(
                AgentChatInteraction.self, from: data)
        else { return nil }
        return interaction
    }
}
