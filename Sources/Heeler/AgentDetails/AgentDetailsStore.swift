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

    /// The compaction-history coverage as the chat store reported it.
    enum CompactionCoverage: Sendable, Equatable {
        case notQueried
        case partial
    }

    /// How the currently-shown context/model values were obtained and
    /// when — the inspector's freshness copy is derived from THIS, never
    /// assumed.
    enum Freshness: Sendable, Equatable {
        /// Nothing has been reported yet (never fetched / not exposed).
        case unknown
        /// Reported live on the last successful refresh.
        case live
        /// Reported earlier; the latest refresh failed or the host is
        /// offline — the values are last-known, not current.
        case stale
    }

    /// The agent's last reported context usage; nil = not reported.
    private(set) var context: AgentTelemetry.Context?
    /// Freshness of `context` + `currentModel` (see ``Freshness``).
    private(set) var freshness: Freshness = .unknown
    /// The agent's current model; nil = not reported.
    private(set) var currentModel: AgentCatalogModel?
    /// The agent's working directory; nil = not reported.
    private(set) var workingDirectory: String?
    /// The searchable model catalog; nil until models.list lands.
    private(set) var models: [AgentCatalogModel]?
    /// The explicit model-change flow state.
    private(set) var modelChange = AgentModelChangeState()
    /// True while a model.set request is on the wire — a concurrent
    /// telemetry read seeing the OLD model must not resolve a pending
    /// change that is still genuinely in flight.
    private var modelSetInFlight = false
    /// The compaction events the transcript exposes (oldest→newest).
    private(set) var compactions: [AgentCompactionEvent] = []
    /// True once a page install has delivered the compaction inventory
    /// — distinguishes "the agent was asked and reported" from "not yet
    /// looked". The page window's own coverage limit is honest too:
    /// see ``compactionsCoverage``.
    private(set) var compactionsQueried = false
    /// The compaction-history coverage as the chat store reported it:
    /// the recent window (+ paged-in older records) is PARTIAL until
    /// older history is read; the inspector never claims "none
    /// recorded" from a window that hasn't reached the older history.
    private(set) var compactionsCoverage: CompactionCoverage = .notQueried
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
            freshness = .live
            // A pending change resolves from the live report — BOTH ways.
            // The request is NOT in flight anymore (a cancelled or
            // transport-lost send left it pending), so the agent's own
            // current model is authoritative: the target applied, or it
            // did not. Never leave a resolved outcome pending forever.
            if case .pending(_, let to) = modelChange.phase,
                !modelSetInFlight, let model = telemetry.model {
                if model.wireID == to.wireID {
                    modelChange.phase = .idle
                    rejectionNotice = nil
                } else {
                    modelChange.phase = .idle
                    rejectionNotice =
                        "The change did not apply. The agent's current model is retained."
                }
            }
        } catch is CancellationError {
        } catch {
            // The last known values stay, labeled stale — never silently
            // presented as current.
            if freshness == .live { freshness = .stale }
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
        // LIVE GATE RECHECK at the decision moment: the state may have
        // changed between opening the card and confirming.
        guard case .allowed = modelGate else {
            rejectionNotice = modelGate.notice
            modelChange.phase = .idle
            return false
        }
        guard let current = currentModel ?? nil else {
            // No reported current model: the transition card cannot render
            // — require the agent's own report first (honest state).
            rejectionNotice = "The agent has not reported its current model."
            modelChange.phase = .idle
            return false
        }
        modelChange.phase = .pending(from: current, to: picked)
        modelSetInFlight = true
        defer { modelSetInFlight = false }
        do {
            let value = try await wire.request(
                "model.set", .object(["id": .string(picked.wireID)]))
            let result = try Self.decode(AgentModelSetResult.self, from: value)
            if result.switched {
                if let model = result.model { currentModel = model }
                else { currentModel = picked }
                freshness = .live
                modelChange.phase = .idle
                return true
            }
            // Rejected: the old model is retained; the result may carry it.
            if let retained = result.model { currentModel = retained }
            modelChange.phase = .idle
            rejectionNotice =
                "Provider rejected the change. Previous model retained. Check access before retrying."
            return false
        } catch let error as AgentChatError {
            if case .wire(let code, let message, _) = error,
                code == "invalid_request" {
                // SERVER-ORIGINATED REFUSAL (the adapter's context-fit gate,
                // the busy gate, unknown model, unverifiable usage): the
                // agent answered — show its reason verbatim, never replace
                // it with generic reconciliation copy.
                modelChange.phase = .idle
                rejectionNotice = message
                return false
            }
            // Transport-shaped wire errors: the outcome is UNCERTAIN —
            // reconcile from the agent's own report before claiming
            // anything. The request is OVER (we're in its catch): clear
            // the in-flight flag first or the reconcile's own guard
            // would block it.
            modelSetInFlight = false
            rejectionNotice = nil
            await reconcilePendingChange()
            return false
        } catch is CancellationError {
            // A cancelled await leaves pending — the change may still land;
            // reconcile on the next refresh resolves it. Never assume
            // failure, never assume success.
            return false
        } catch {
            // Transport failure is NOT a provider rejection: the remote
            // MAY have applied the change. Stay pending and reconcile
            // from the agent's own report before claiming anything.
            modelSetInFlight = false
            rejectionNotice = nil
            await reconcilePendingChange()
            return false
        }
    }

    /// Resolves an uncertain pending change from the agent's own current
    /// report: if the live model IS the target, the change landed
    /// (confirm it); otherwise the old model is retained (resolve
    /// pending). An unreadable report leaves pending standing — the
    /// next refresh retries.
    func reconcilePendingChange() async {
        guard case .pending(_, let to) = modelChange.phase, !modelSetInFlight else { return }
        do {
            let value = try await wire.request("session.telemetry", nil)
            let telemetry = try Self.decode(AgentTelemetry.self, from: value)
            if let model = telemetry.model {
                if model.wireID == to.wireID {
                    // The agent applied it — the change landed.
                    currentModel = model
                    freshness = .live
                    modelChange.phase = .idle
                    rejectionNotice = nil
                } else {
                    // The agent reports a different model — the target
                    // did not apply.
                    currentModel = model
                    freshness = .live
                    modelChange.phase = .idle
                    rejectionNotice =
                        "The change did not apply. The agent's current model is retained."
                }
            }
            if let context = telemetry.context { self.context = context }
            if let cwd = telemetry.cwd { workingDirectory = cwd }
        } catch {
            // Unverifiable right now: pending stays; the next refresh
            // retries the reconciliation. No claim either way.
        }
    }

    /// Seeds the observable state in one call. Preview/test fixture
    /// surface ONLY — production paths flow through the wire.
    /// Fixture seam for the pending phase (tests drive the uncertain
    /// state directly).
    func seedPendingPhase(from: AgentCatalogModel, to: AgentCatalogModel) {
        modelChange.phase = .pending(from: from, to: to)
    }

    func seedFixture(
        context: AgentTelemetry.Context? = nil,
        currentModel: AgentCatalogModel? = nil,
        workingDirectory: String? = nil,
        compactions: [AgentCompactionEvent] = [],
        freshness: Freshness = .live
    ) {
        self.context = context
        self.currentModel = currentModel
        self.workingDirectory = workingDirectory
        self.freshness = freshness
        setCompactions(compactions)
    }

    /// Dismisses the one-shot rejection notice.
    func clearRejectionNotice() {
        rejectionNotice = nil
    }

    // MARK: Compaction history

    /// Installs compaction events collected by the chat store: the
    /// history WAS queried (the agent answered), and the coverage is
    /// the recent window plus any paged-in older records — partial by
    /// construction until the older history is read.
    func setCompactions(_ events: [AgentCompactionEvent]) {
        compactions = events
        compactionsQueried = true
        compactionsCoverage = .partial
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
                // The recorded method is the actual trigger; no invented
                // Automatic/Manual classification.
                event.trigger = method
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
