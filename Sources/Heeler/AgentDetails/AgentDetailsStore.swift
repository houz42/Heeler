import Foundation
import Observation

// SPDX-License-Identifier: Apache-2.0
//
// The agent-details live-data store (v2 slice 1): broker-backed context
// telemetry, the model catalog, the explicit model-change flow, and the
// compaction-history read. One store per agent chat pane, owned beside
// AgentChatStore by the detail view.
//
// Honest-state rules (design contract):
// - No telemetry capability → everything stays unavailable; the inspector
//   says the adapter cannot change models and never guesses numbers.
// - Transcript length is NOT a substitute for reported context usage.
// - A model change is pending until the AGENT confirms; the old model is
//   retained on rejection, and a working turn is an honest refusal (the
//   store never auto-interrupts — the adapter also refuses server-side).
// - Compaction history shows what the transcript actually recorded;
//   missing before/after counts or summaries render unavailable states.

@MainActor
@Observable
final class AgentDetailsStore {
    // MARK: Observable state

    /// The agent's last reported context usage; nil = not reported.
    private(set) var context: AgentTelemetry.Context?
    /// The agent's current model; nil = not reported.
    private(set) var currentModel: AgentCatalogModel?
    /// The agent's working directory; nil = not reported.
    private(set) var workingDirectory: String?
    /// The searchable model catalog; nil until models.list lands.
    private(set) var models: [AgentCatalogModel]?
    /// The explicit model-change flow state.
    private(set) var modelChange = AgentModelChangeState()
    /// The compaction events the transcript exposes (oldest→newest).
    private(set) var compactions: [AgentCompactionEvent] = []
    /// One-shot rejection notice shown after a failed change.
    private(set) var rejectionNotice: String?

    // MARK: Wiring

    /// The wire seam: send one agent-scoped request over the live broker
    /// channel. Production wraps AgentChatStore; tests stub closures.
    struct Wire: Sendable {
        let request: @Sendable (
            _ method: String, _ params: JSONValue?
        ) async throws -> JSONValue
        /// Reads a transcript-side compaction summary when the row model
        /// only carries a reference; nil = the transcript seam is absent.
        let readItem: (@Sendable (_ itemId: String) async throws -> Data)?

        init(
            request: @escaping @Sendable (
                _ method: String, _ params: JSONValue?
            ) async throws -> JSONValue,
            readItem: (@Sendable (_ itemId: String) async throws -> Data)? = nil
        ) {
            self.request = request
            self.readItem = readItem
        }
    }

    private let wire: Wire
    /// True when the matched registration declared telemetry.
    private var telemetrySupported: Bool
    /// Latest agent status for the working gate.
    private var isAgentWorking: () -> Bool
    /// True while the host connection is down (offline gate).
    private var isOffline: () -> Bool

    init(
        wire: Wire,
        telemetrySupported: Bool,
        isAgentWorking: @escaping () -> Bool = { false },
        isOffline: @escaping () -> Bool = { false }
    ) {
        self.wire = wire
        self.telemetrySupported = telemetrySupported
        self.isAgentWorking = isAgentWorking
        self.isOffline = isOffline
    }

    /// Capability changes across reconnects (a fresh registration may
    /// gain or lose the telemetry bit).
    func setTelemetrySupported(_ supported: Bool) {
        telemetrySupported = supported
    }

    var supportsTelemetry: Bool { telemetrySupported }

    /// Convenience for views bound via @Bindable: the model-change
    /// pending flag without a Binding subscript.
    var isPendingModelChange: Bool { modelChange.isPending }

    // MARK: Gate

    /// The model-picker gate as the design contract defines it.
    var modelGate: AgentModelGate {
        if modelChange.isPending { return .pendingChange }
        if isOffline() { return .offline }
        if isAgentWorking() { return .working }
        if !telemetrySupported { return .unsupported }
        return .allowed
    }

    // MARK: Telemetry refresh

    /// Pulls session.telemetry; an unsupported or failed read leaves the
    /// last known values (the inspector shows them as last-known, never
    /// silently empties).
    func refreshTelemetry() async {
        guard telemetrySupported else { return }
        do {
            let value = try await wire.request("session.telemetry", nil)
            let telemetry = try Self.decode(AgentTelemetry.self, from: value)
            if let context = telemetry.context { self.context = context }
            if let model = telemetry.model { currentModel = model }
            if let cwd = telemetry.cwd { workingDirectory = cwd }
        } catch is CancellationError {
        } catch {
            // Transient: the last known state stays; the UI labels it.
        }
    }

    /// Pulls the catalog (models.list) once per store life, or on demand.
    func loadModels() async {
        guard telemetrySupported else { return }
        do {
            let value = try await wire.request("models.list", nil)
            let result = try Self.decode(AgentModelsResult.self, from: value)
            models = result.models
        } catch is CancellationError {
        } catch {
            // Transient: the picker shows the honest empty state.
        }
    }

    // MARK: Explicit model change

    /// Opens the confirm card for `picked`. Nothing is sent yet.
    func beginConfirmation(picked: AgentCatalogModel) {
        guard case .allowed = modelGate else { return }
        modelChange.phase = .confirming(picked: picked)
        rejectionNotice = nil
    }

    /// Cancels the confirm card — the model never changed.
    func cancelConfirmation() {
        guard case .confirming = modelChange.phase else { return }
        modelChange.phase = .idle
    }

    /// Sends the confirmed change: enters pending (the agent applies it);
    /// resolves confirmed/rejected from the agent's response. The current
    /// model moves only on switched:true. Returns the outcome so the UI
    /// can render the rejection notice in place.
    @discardableResult
    func confirmChange() async -> Bool {
        guard case .confirming(let picked) = modelChange.phase else {
            return false
        }
        guard let current = currentModel ?? nil else {
            // No reported current model: still safe to attempt, but the
            // transition card cannot render — require the agent's own
            // report first (honest state).
            rejectionNotice = "The agent has not reported its current model."
            modelChange.phase = .idle
            return false
        }
        modelChange.phase = .pending(from: current, to: picked)
        do {
            let value = try await wire.request(
                "model.set", .object(["id": .string(picked.wireID)]))
            let result = try Self.decode(AgentModelSetResult.self, from: value)
            if result.switched {
                if let model = result.model { currentModel = model }
                else { currentModel = picked }
                modelChange.phase = .idle
                return true
            }
            // Rejected: the old model is retained; the result may carry it.
            if let retained = result.model { currentModel = retained }
            modelChange.phase = .idle
            rejectionNotice =
                "Provider rejected the change. Previous model retained. Check access before retrying."
            return false
        } catch is CancellationError {
            // A cancelled await leaves pending — the change may still land;
            // a later telemetry refresh reconciles. Never assume failure.
            return false
        } catch {
            // Transport failure is NOT a provider rejection: keep pending
            // copy honest by falling back to the last known model state.
            modelChange.phase = .idle
            rejectionNotice = "The change could not be delivered. The previous model is retained."
            return false
        }
    }

    /// Seeds the observable state in one call. Preview/test fixture
    /// surface ONLY — production paths flow through the wire.
    func seedFixture(
        context: AgentTelemetry.Context? = nil,
        currentModel: AgentCatalogModel? = nil,
        workingDirectory: String? = nil,
        compactions: [AgentCompactionEvent] = []
    ) {
        self.context = context
        self.currentModel = currentModel
        self.workingDirectory = workingDirectory
        setCompactions(compactions)
    }

    /// Dismisses the one-shot rejection notice.
    func clearRejectionNotice() {
        rejectionNotice = nil
    }

    // MARK: Compaction history

    /// Installs compaction events parsed from the transcript surface.
    /// Pure seam: the parsing is testable without a store.
    func setCompactions(_ events: [AgentCompactionEvent]) {
        compactions = events
    }

    // MARK: Decoding

    nonisolated private static func decode<T: Decodable>(
        _ type: T.Type, from value: JSONValue
    ) throws -> T {
        try JSONDecoder().decode(type, from: JSONEncoder().encode(value))
    }
}

// MARK: - Compaction parsing (pure)

/// Parses omp session JSONL `compaction` entries into
/// ``AgentCompactionEvent`` values. Missing fields stay nil — the honest
/// unavailable states — and malformed lines are skipped, never fatal.
enum AgentCompactionParser {
    static func parse(lines: [String]) -> [AgentCompactionEvent] {
        var events: [AgentCompactionEvent] = []
        for line in lines {
            guard let data = line.data(using: .utf8),
                let record = try? JSONSerialization.jsonObject(
                    with: data) as? [String: Any],
                record["type"] as? String == "compaction",
                let id = record["id"] as? String
            else { continue }
            var event = AgentCompactionEvent(id: id)
            if let ts = record["timestamp"] as? String { event.time = AgentIso8601.parse(ts) }
            if let method = record["method"] as? String, !method.isEmpty {
                event.trigger = "Automatic · \(method)"
            }
            if let before = record["tokensBefore"] as? Int { event.tokensBefore = before }
            if let after = record["tokensAfter"] as? Int { event.tokensAfter = after }
            if let summary = record["summary"] as? String, !summary.isEmpty {
                event.summary = summary
            }
            events.append(event)
        }
        return events
    }

    /// Extracts only the compaction lines from a full transcript.
    static func compactionLines(from lines: [String]) -> [String] {
        lines.filter { line in
            line.contains("\"type\":\"compaction\"")
                || line.contains("\"type\": \"compaction\"")
        }
    }
}

// MARK: - Fuzzy model search (pure)

/// The compact model picker's search: scores name, id, and provider with
/// the SAME AgentFuzzyMatcher the Agents search uses (the design
/// specifies this exact scale) and orders by best score, stable index.
enum AgentModelSearch {
    static func matches(
        query: String, models: [AgentCatalogModel]
    ) -> [AgentCatalogModel] {
        guard !query.isEmpty else { return models }
        var scored: [(model: AgentCatalogModel, score: Int, index: Int)] = []
        for (index, model) in models.enumerated() {
            let candidates = [
                model.displayName, model.id, model.provider,
                model.displayName + " " + model.provider,
            ]
            let best = candidates
                .map { AgentFuzzyMatcher.score(query, against: $0) }
                .max() ?? -1
            if best >= 0 { scored.append((model, best, index)) }
        }
        return scored
            .sorted { $0.score == $1.score ? $0.index < $1.index : $0.score > $1.score }
            .map { $0.model }
    }
}
