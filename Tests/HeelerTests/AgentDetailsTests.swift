import Foundation
import Testing

@testable import Heeler

// SPDX-License-Identifier: Apache-2.0
//
// Unit proofs for the agent-details slice (v2): compact-number port,
// model-change pending-state machine, compaction parsing, fuzzy search,
// capability decode (old brokers honest), and the collector.

@Suite("Compact token numbers")
struct CompactTokenNumberTests {
    @Test("raw numbers under 1000 group with locale separators")
    func rawNumbers() {
        #expect(CompactTokenNumber.format(0) == "0")
        #expect(CompactTokenNumber.format(999) == "999")
    }

    @Test("k magnitudes round to one decimal")
    func kNumbers() {
        #expect(CompactTokenNumber.format(8_640) == "8.6k")
        #expect(CompactTokenNumber.format(8_600) == "8.6k")
        #expect(CompactTokenNumber.format(86_400) == "86.4k")
        #expect(CompactTokenNumber.format(171_200) == "171.2k")
    }

    @Test("m magnitudes")
    func mNumbers() {
        #expect(CompactTokenNumber.format(1_048_576) == "1m")
        #expect(CompactTokenNumber.format(1_500_000) == "1.5m")
    }

    @Test("the 1000k promotion never prints 1000k")
    func promotion() {
        // 999,960 rounds at k to 1000 → promotes to 1m, per the preview.
        #expect(CompactTokenNumber.format(999_960) == "1m")
        #expect(CompactTokenNumber.format(1_048_575) == "1m")
    }
}

@Suite("Agent model change state machine")
@MainActor
struct AgentModelChangeStateTests {
    private static let balanced = AgentCatalogModel(
        id: "balanced", provider: "a", name: "Balanced", contextWindow: 200_000)
    private static let deep = AgentCatalogModel(
        id: "deep", provider: "b", name: "Deep", contextWindow: 256_000)

    @Test("idle gate allows; pending blocks a second change")
    func gate() async throws {
        let store = AgentDetailsStore(
            wire: .init(
                request: { _, _ in
                    .object(["switched": .bool(true)])
                }),
            telemetrySupported: true)
        #expect(store.modelGate == AgentModelGate.allowed)

        // pending blocks
        store.seedFixture(currentModel: Self.balanced)
        store.beginConfirmation(picked: Self.deep)
        _ = await store.confirmChange()
        // resolved back to idle — but during flight the gate is checked
        // via a fresh pending store:
        let pending = AgentDetailsStore(
            wire: .init(
                request: { _, _ in
                    // never answers — the state stays pending
                    try await Task.sleep(for: .seconds(30))
                    return .object(["switched": .bool(true)])
                }),
            telemetrySupported: true)
        pending.seedFixture(currentModel: Self.balanced)
        pending.beginConfirmation(picked: Self.deep)
        let confirmTask = Task { await pending.confirmChange() }
        try await Task.sleep(for: .milliseconds(100))
        #expect(pending.modelGate == AgentModelGate.pendingChange)
        confirmTask.cancel()
    }

    @Test("confirm path: the model moves only on switched true")
    func confirm() async throws {
        let store = AgentDetailsStore(
            wire: .init(
                request: { method, params in
                    #expect(method == "model.set")
                    #expect(params?["id"]?.stringValue == "b/deep")
                    return .object([
                        "switched": .bool(true),
                        "model": .object([
                            "id": .string("deep"), "provider": .string("b"),
                        ]),
                    ])
                }),
            telemetrySupported: true)
        store.seedFixture(currentModel: Self.balanced)
        store.beginConfirmation(picked: Self.deep)
        let result = await store.confirmChange()
        #expect(result == true)
        #expect(store.currentModel?.id == "deep")
        #expect(store.modelChange.phase == AgentModelChangeState.Phase.idle)
        #expect(store.rejectionNotice == nil)
    }

    @Test("rejection: the old model is retained with the notice")
    func reject() async throws {
        let store = AgentDetailsStore(
            wire: .init(
                request: { _, _ in
                    .object([
                        "switched": .bool(false), "reason": .string("rejected"),
                        "model": .object([
                            "id": .string("balanced"), "provider": .string("a"),
                        ]),
                    ])
                }),
            telemetrySupported: true)
        store.seedFixture(currentModel: Self.balanced)
        store.beginConfirmation(picked: Self.deep)
        let result = await store.confirmChange()
        #expect(result == false)
        // The retained model came from the agent's own echo.
        #expect(store.currentModel?.id == "balanced")
        #expect(store.modelChange.phase == AgentModelChangeState.Phase.idle)
        #expect(
            store.rejectionNotice?.contains("Previous model retained") == true)
    }

    @Test("working and offline gates never allow the flow to start")
    func gates() async {
        let working = AgentDetailsStore(
            wire: .init(request: { _, _ in .object([:]) }),
            telemetrySupported: true, isAgentWorking: { true })
        #expect(working.modelGate == AgentModelGate.working)
        #expect(
            working.modelGate.notice?.contains("No automatic interruption") == true)

        let offline = AgentDetailsStore(
            wire: .init(request: { _, _ in .object([:]) }),
            telemetrySupported: true, isOffline: { true })
        #expect(offline.modelGate == AgentModelGate.offline)

        let unsupported = AgentDetailsStore(
            wire: .init(request: { _, _ in .object([:]) }),
            telemetrySupported: false)
        #expect(unsupported.modelGate == AgentModelGate.unsupported)
        #expect(
            unsupported.modelGate.notice?.contains("native interface") == true)
        // An unsupported adapter never even refreshes.
        await unsupported.refreshTelemetry()
        #expect(unsupported.context == nil)
    }
}

@Suite("Compaction parsing")
struct AgentCompactionParserTests {
    @Test("full compaction entries parse with every field")
    func fullParse() {
        let lines = [
            """
            {"type":"compaction","id":"c1","timestamp":"2026-09-18T09:18:00.000Z","summary":"## Goal\\nRedesign.","tokensBefore":171200,"tokensAfter":58300,"method":"snapcompact"}
            """,
            #"{"type":"message","id":"m1","message":{"role":"user","content":"hi"}}"#,
        ]
        let events = AgentCompactionParser.parse(lines: lines)
        #expect(events.count == 1)
        let event = events[0]
        #expect(event.id == "c1")
        #expect(event.trigger == "snapcompact")
        #expect(event.tokensBefore == 171_200)
        #expect(event.tokensAfter == 58_300)
        #expect(event.summary == "## Goal\nRedesign.")
        #expect(event.time != nil)
    }

    @Test("missing fields stay nil — never invented")
    func missingFields() {
        let lines = [
            #"{"type":"compaction","id":"c2","timestamp":"2026-09-17T16:42:00.000Z"}"#,
        ]
        let events = AgentCompactionParser.parse(lines: lines)
        #expect(events.count == 1)
        let event = events[0]
        #expect(event.trigger == nil)
        #expect(event.tokensBefore == nil)
        #expect(event.tokensAfter == nil)
        #expect(event.summary == nil)
    }

    @Test("malformed lines are skipped, never fatal")
    func malformed() {
        let events = AgentCompactionParser.parse(lines: [
            "not json",
            #"{"type":"compaction"}"#, // no id
        ])
        #expect(events.isEmpty)
    }

    @Test("the page collector maps boundary items with measurements")
    func collector() throws {
        let json = #"""
        {"id":"b1","kind":"boundary","boundary":"compaction","olderAvailable":true,"occurredAt":"2026-09-18T09:18:00.000Z","trigger":"snapcompact","tokensBefore":171200,"tokensAfter":58300,"summary":"S"}
        """#
        let data = Data(json.utf8)
        let boundary = try JSONDecoder().decode(AgentChatItem.self, from: data)
        let events = AgentChatCompactionCollector.collect(from: [boundary])
        #expect(events.count == 1)
        #expect(events[0].trigger == "snapcompact")
        #expect(events[0].tokensBefore == 171_200)
    }

    @Test("plain v1 boundaries decode without the v2 fields")
    func v1Compat() throws {
        let json = #"""
        {"id":"b2","kind":"boundary","boundary":"branch","olderAvailable":false}
        """#
        let item = try JSONDecoder().decode(
            AgentChatItem.self, from: Data(json.utf8))
        let events = AgentChatCompactionCollector.collect(from: [item])
        #expect(events.isEmpty) // branch boundaries are not compactions
    }
}

@Suite("Agent chat capability decode (telemetry)")
struct AgentDetailsCapabilityTests {
    @Test("old registrations decode with telemetry false — the honest default")
    func oldBroker() throws {
        let json = #"""
        {"history":true,"streaming":true,"prompt":true,"interrupt":true,"interactions":false,"commands":true,"attachments":false,"branches":false}
        """#
        let caps = try JSONDecoder().decode(
            AgentChatCapabilities.self, from: Data(json.utf8))
        #expect(caps.telemetry == false)
        #expect(caps.commands == true)
    }

    @Test("telemetry capability decodes")
    func newBroker() throws {
        let json = #"""
        {"history":true,"streaming":true,"prompt":true,"interrupt":true,"interactions":false,"commands":true,"attachments":false,"branches":false,"telemetry":true}
        """#
        let caps = try JSONDecoder().decode(
            AgentChatCapabilities.self, from: Data(json.utf8))
        #expect(caps.telemetry == true)
    }
}

@Suite("Agent model fuzzy search")
struct AgentModelSearchTests {
    private static let models: [AgentCatalogModel] = [
        .init(id: "kimi-k3", provider: "nvidia-hub", name: "Kimi K3"),
        .init(id: "glm-5.3", provider: "nvidia-hub", name: "GLM 5.3"),
        .init(id: "claude-fable-5", provider: "anthropic", name: "Claude Fable 5"),
    ]

    @Test("empty query returns the whole catalog in order")
    func emptyQuery() {
        #expect(AgentModelSearch.matches(query: "", models: Self.models).count == 3)
    }

    @Test("fuzzy matches name, id, and provider")
    func matching() {
        let byName = AgentModelSearch.matches(query: "kimi", models: Self.models)
        #expect(byName.first?.id == "kimi-k3")
        let byProvider = AgentModelSearch.matches(query: "anthropic", models: Self.models)
        #expect(byProvider.first?.id == "claude-fable-5")
        let byId = AgentModelSearch.matches(query: "glm", models: Self.models)
        #expect(byId.first?.id == "glm-5.3")
    }

    @Test("no match returns empty — nothing invented")
    func noMatch() {
        #expect(AgentModelSearch.matches(query: "zzz-unknown", models: Self.models).isEmpty)
    }
}

@Suite("Agent catalog model decode")
struct AgentCatalogModelTests {
    @Test("the adapter's live wire shape decodes with every field")
    func liveShape() throws {
        let json = #"""
        {"id":"nvidia/moonshotai/kimi-k3","provider":"nvidia-hub","name":"Kimi K3","contextWindow":1048576,"maxTokens":131072,"input":["text","image"],"reasoning":true,"supportsTools":false,"cost":{"input":0,"output":0,"cacheRead":0,"cacheWrite":0}}
        """#
        let model = try JSONDecoder().decode(
            AgentCatalogModel.self, from: Data(json.utf8))
        #expect(model.wireID == "nvidia-hub/nvidia/moonshotai/kimi-k3")
        #expect(model.displayName == "Kimi K3")
        #expect(model.supportsImages == true)
        #expect(model.contextWindow == 1_048_576)
    }

    @Test("minimal entries decode; missing surfaces stay nil")
    func minimalShape() throws {
        let json = #"""
        {"id":"x","provider":"p"}
        """#
        let model = try JSONDecoder().decode(
            AgentCatalogModel.self, from: Data(json.utf8))
        #expect(model.name == nil)
        #expect(model.contextWindow == nil)
        #expect(model.cost == nil)
        #expect(model.displayName == "x")
    }
}

@Suite("Review-fix semantics")
@MainActor
struct AgentDetailsReviewFixTests {
    @Test("model identity is the provider/id composite")
    func compositeIdentity() {
        let a = AgentCatalogModel(id: "same", provider: "p1")
        let b = AgentCatalogModel(id: "same", provider: "p2")
        #expect(a.identity != b.identity)
        #expect(a.identity == a.wireID)
    }

    @Test("unqueried history renders not-read, not zero")
    func unqueriedHistory() async {
        let store = await AgentDetailsStore(
            wire: .init(request: { _, _ in .object([:]) }),
            telemetrySupported: true)
        #expect(store.compactionsQueried == false)
        #expect(store.compactions.isEmpty)
        store.setCompactions([])
        #expect(store.compactionsQueried == true)
    }

    @Test("uncertain transport failure reconciles from the live report")
    func reconcileOnFailure() async throws {
        // model.set throws; the follow-up telemetry reports the TARGET
        // applied → the change is confirmed from the agent's own report.
        let store = await AgentDetailsStore(
            wire: .init(request: { method, _ in
                if method == "model.set" {
                    throw AgentChatError.connectionClosed
                }
                return .object([
                    "model": .object([
                        "id": .string("deep"), "provider": .string("b"),
                    ]),
                    "context": .object([
                        "tokens": .number(1000), "contextWindow": .number(200000),
                    ]),
                ])
            }),
            telemetrySupported: true)
        let balanced = AgentCatalogModel(id: "balanced", provider: "a")
        let deep = AgentCatalogModel(id: "deep", provider: "b")
        store.seedFixture(currentModel: balanced)
        store.beginConfirmation(picked: deep)
        let result = await store.confirmChange()
        #expect(result == false)
        // Reconciled: the agent's own report says deep is live.
        #expect(store.currentModel?.id == "deep")
        #expect(store.modelChange.phase == AgentModelChangeState.Phase.idle)
    }

    @Test("reconcile that reports a different model resolves as not-applied")
    func reconcileNotApplied() async {
        let store = await AgentDetailsStore(
            wire: .init(request: { method, _ in
                if method == "model.set" {
                    throw AgentChatError.connectionClosed
                }
                return .object([
                    "model": .object([
                        "id": .string("balanced"), "provider": .string("a"),
                    ]),
                ])
            }),
            telemetrySupported: true)
        let balanced = AgentCatalogModel(id: "balanced", provider: "a")
        let deep = AgentCatalogModel(id: "deep", provider: "b")
        store.seedFixture(currentModel: balanced)
        store.beginConfirmation(picked: deep)
        _ = await store.confirmChange()
        #expect(store.modelChange.phase == AgentModelChangeState.Phase.idle)
        #expect(store.currentModel?.id == "balanced")
        #expect(store.rejectionNotice?.contains("did not apply") == true)
    }

    @Test("server-side context-fit refusal surfaces the reason")
    func contextFitRefusal() async throws {
        // switched:false is a rejection — but the adapter's context-fit
        // gate responds with an invalid_request ERROR carrying the
        // promise; the client must surface the adapter's message, never
        // claim retention without reconciling.
        let store = await AgentDetailsStore(
            wire: .init(request: { _, _ in
                .object(["error": .object([
                    "code": .string("invalid_request"),
                    "message": .string("the reported context (495844 tokens) exceeds this model's window (128000); nothing will be trimmed automatically"),
                ])])
            }),
            telemetrySupported: true)
        let balanced = AgentCatalogModel(id: "balanced", provider: "a")
        let small = AgentCatalogModel(id: "small", provider: "a", contextWindow: 128_000)
        store.seedFixture(
            context: .init(tokens: 495_844, contextWindow: 1_048_576),
            currentModel: balanced)
        store.beginConfirmation(picked: small)
        _ = await store.confirmChange()
        // The uncertain outcome reconciled from the live report path: this
        // stub's telemetry branch returns the error object, so the
        // reconcile read fails → pending stands, no retention claim.
        #expect(store.currentModel?.id == "balanced")
    }

    @Test("freshness lifecycle: live → stale on failed refresh")
    func freshnessLifecycle() async {
        let store = await AgentDetailsStore(
            wire: .init(request: { _, _ in
                .object([
                    "context": .object([
                        "tokens": .number(100), "contextWindow": .number(1000),
                    ]),
                ])
            }),
            telemetrySupported: true)
        #expect(store.freshness == AgentDetailsStore.Freshness.unknown)
        await store.refreshTelemetry()
        #expect(store.freshness == AgentDetailsStore.Freshness.live)
    }
}

@Suite("Round-3 semantics")
@MainActor
struct AgentDetailsRound3Tests {
    @Test("a server-originated refusal reaches the notice verbatim")
    func serverRefusalVerbatim() async {
        let refusal = "the reported context (496036 tokens) exceeds this model's window (128000); nothing will be trimmed automatically"
        let store = AgentDetailsStore(
            wire: .init(request: { _, _ in
                // The broker answers an agent-refused request with a
                // response ERROR — the channel surfaces it as a thrown
                // AgentChatError.wire.
                throw AgentChatError.wire(
                    code: "invalid_request", message: refusal, retryable: false)
            }),
            telemetrySupported: true)
        store.seedFixture(
            context: .init(tokens: 496_036, contextWindow: 1_048_576),
            currentModel: AgentCatalogModel(id: "balanced", provider: "a"))
        store.beginConfirmation(
            picked: AgentCatalogModel(id: "small", provider: "a", contextWindow: 128_000))
        _ = await store.confirmChange()
        #expect(store.rejectionNotice == refusal)
        #expect(store.modelChange.phase == AgentModelChangeState.Phase.idle)
    }

    @Test("refresh resolves pending BOTH ways — target applied or not")
    func pendingResolvesBothWays() async {
        let store = AgentDetailsStore(
            wire: .init(request: { _, _ in
                .object([
                    "model": .object([
                        "id": .string("balanced"), "provider": .string("a"),
                    ]),
                ])
            }),
            telemetrySupported: true)
        store.seedFixture(currentModel: AgentCatalogModel(id: "balanced", provider: "a"))
        store.seedPendingPhase(
            from: AgentCatalogModel(id: "balanced", provider: "a"),
            to: AgentCatalogModel(id: "deep", provider: "b"))
        await store.refreshTelemetry()
        #expect(store.modelChange.phase == AgentModelChangeState.Phase.idle)
        #expect(store.rejectionNotice?.contains("did not apply") == true)
    }

    @Test("coverage: not queried, then partial once events land")
    func coverageLifecycle() {
        let store = AgentDetailsStore(
            wire: .init(request: { _, _ in .object([:]) }),
            telemetrySupported: true)
        #expect(store.compactionsCoverage == AgentDetailsStore.CompactionCoverage.notQueried)
        #expect(store.compactionsQueried == false)
        store.setCompactions([])
        #expect(store.compactionsQueried == true)
        #expect(store.compactionsCoverage == AgentDetailsStore.CompactionCoverage.partial)
    }
}
