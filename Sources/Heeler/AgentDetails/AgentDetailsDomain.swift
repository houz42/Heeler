import Foundation

// SPDX-License-Identifier: Apache-2.0
//
// Agent-details v2 domain (slice 1). The telemetry wire shapes the omp
// adapter serves over agent-chat v2 (capability key `telemetry`):
// session.telemetry / models.list / model.set. Every field is optional in
// decode — an adapter that does not report a surface renders an honest
// "not reported" state, never a guessed value. The broker's old
// registrations (8 keys, no telemetry) decode with telemetry:false.

// MARK: - Capability

/// One broker registration's capability flags as the client sees them.
/// The `telemetry` flag (v2) gates the agent-details inspector's live
/// surfaces; older adapters honestly report false and the UI renders the
/// unsupported state.
struct AgentDetailsCapability: Sendable, Equatable {
    var telemetry: Bool

    init(telemetry: Bool = false) {
        self.telemetry = telemetry
    }
}

// MARK: - Wire shapes

/// One catalog model entry from models.list / session.telemetry.model.
/// All fields optional except the identity pair: the adapter only emits
/// what the host registry actually reported.
struct AgentCatalogModel: Decodable, Sendable, Equatable, Identifiable {
    let id: String
    let provider: String
    var name: String?
    var contextWindow: Int?
    var maxTokens: Int?
    var input: [String]?
    var reasoning: Bool?
    var supportsComputerUse: Bool?
    var cost: Cost?

    struct Cost: Decodable, Sendable, Equatable {
        var input: Double?
        var output: Double?
        var cacheRead: Double?
        var cacheWrite: Double?
    }

    /// The stable wire identity the picker confirms against.
    var wireID: String { "\(provider)/\(id)" }

    /// Display name: the host's name when reported, else the raw id.
    var displayName: String { name?.isEmpty == false ? name! : id }

    var supportsImages: Bool { input?.contains("image") == true }

    var identity: String { wireID }
}

/// session.telemetry result. Absent surfaces stay nil — the inspector
/// renders each absence honestly ("Not reported").
struct AgentTelemetry: Decodable, Sendable, Equatable {
    var model: AgentCatalogModel?
    var context: Context?
    var cwd: String?

    struct Context: Decodable, Sendable, Equatable {
        var tokens: Int?
        var contextWindow: Int?
    }
}

/// models.list result.
struct AgentModelsResult: Decodable, Sendable, Equatable {
    let models: [AgentCatalogModel]
}

/// model.set result. `switched:false` carries the retained (old) model.
struct AgentModelSetResult: Decodable, Sendable, Equatable {
    let switched: Bool
    var reason: String?
    var model: AgentCatalogModel?
}

/// Parses the transcript's ISO timestamps: fractional seconds when
/// present, plain internet date-time otherwise.
enum AgentIso8601: @unchecked Sendable {
    static func parse(_ text: String) -> Date? {
        if let date = fractional.date(from: text) { return date }
        return plain.date(from: text)
    }

    /// ISO8601DateFormatter is thread-safe per Apple documentation but
    /// not Sendable-annotated; the formatters are immutable after setup.
    private nonisolated(unsafe) static let fractional: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private nonisolated(unsafe) static let plain = ISO8601DateFormatter()
}

// MARK: - Compaction history

/// One compaction event the transcript exposes (omp session JSONL
/// `type:"compaction"` entries, surfaced as boundary items over the
/// agent-chat history). Missing measurements are nil and render honest
/// unavailable states — never invented.
struct AgentCompactionEvent: Sendable, Equatable, Identifiable {
    let id: String
    var time: Date?
    var trigger: String?
    var tokensBefore: Int?
    var tokensAfter: Int?
    /// The actual retained-summary text when the agent reported one.
    var summary: String?
}

/// Extracts compaction events from agent-chat page items (boundary
/// items with the v2 measurement fields). Pure seam.
enum AgentChatCompactionCollector: Sendable {
    static func collect(from items: [AgentChatItem]) -> [AgentCompactionEvent] {

        var events: [AgentCompactionEvent] = []
        for item in items {
            guard case .boundary(
                let id, let boundary, let summary, _, let occurredAt,
                let trigger, let before, let after) = item,
                boundary == "compaction"
            else { continue }
            var event = AgentCompactionEvent(id: id)
            if let occurredAt { event.time = AgentIso8601.parse(occurredAt) }
            if let trigger, !trigger.isEmpty {
                event.trigger = "Automatic · \(trigger)"
            }
            event.tokensBefore = before
            event.tokensAfter = after
            event.summary = summary
            events.append(event)
        }
        return events
    }
}

// MARK: - Compact numbers

/// The preview's compactNumber, ported exactly: under 1k raw (locale
/// grouped); >= 1M one-decimal "m"; else one-decimal "k" with the 1000k
/// promotion (999,96k+ raw numbers round up to "1m", never "1000k").
enum CompactTokenNumber {
    static func format(_ n: Int) -> String {
        let magnitude = abs(n)
        if magnitude < 1000 {
            return n.formatted(.number.grouping(.automatic))
        }
        if magnitude >= 1_000_000 {
            let rounded = (Double(n) / 1_000_000 * 10).rounded() / 10
            return trimmed(rounded) + "m"
        }
        let rounded = (Double(n) / 1000 * 10).rounded() / 10
        if abs(rounded) >= 1000 {
            // The k round crossed 1000: promote to a coarser m (one
            // decimal on the m magnitude), matching the preview.
            let promoted = (Double(n) / 100_000).rounded() / 10
            return trimmed(promoted) + "m"
        }
        return trimmed(rounded) + "k"
    }

    /// One decimal only when it carries information: 864k, not 864.0k.
    private static func trimmed(_ value: Double) -> String {
        value == value.rounded()
            ? String(Int(value))
            : String(format: "%.1f", value)
    }
}

// MARK: - Model-change pending state

/// The explicit model-change flow's state machine (design contract): a
/// pick opens a confirm card; confirming enters the pending state on the
/// AGENT (the request is in flight); the agent's response resolves
/// confirmed or rejected. The OLD MODEL is retained throughout —
/// `currentModel` only moves on confirmed.
struct AgentModelChangeState: Sendable, Equatable {
    enum Phase: Sendable, Equatable {
        case idle
        /// Confirm card open: the picked model awaits explicit user
        /// confirmation. Nothing has been sent.
        case confirming(picked: AgentCatalogModel)
        /// The agent is applying the change; the current model has NOT
        /// changed yet.
        case pending(from: AgentCatalogModel, to: AgentCatalogModel)
    }

    var phase: Phase = .idle
    /// The model that remains live until a switch confirms.
    var currentModel: AgentCatalogModel?

    var isPending: Bool {
        if case .pending = phase { return true }
        return false
    }
}

// MARK: - Availability projection

/// Why the inspector cannot change a model — each gate renders its own
/// honest copy (design contract verbatim).
enum AgentModelGate: Sendable, Equatable {
    case allowed
    /// The adapter/broker does not support model telemetry.
    case unsupported
    /// The agent is working: never auto-interrupt.
    case working
    /// The host connection is down; cached details, changes disabled.
    case offline
    /// A change is already awaiting confirmation.
    case pendingChange

    var notice: String? {
        switch self {
        case .allowed: return nil
        case .unsupported:
            return "This adapter cannot change models. Use its native interface."
        case .working:
            return "Finish or stop the current turn before changing models. No automatic interruption."
        case .offline:
            return "Reconnect before changing the model."
        case .pendingChange:
            return "A change is awaiting confirmation."
        }
    }
}
