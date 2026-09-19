import Foundation
import Testing

@testable import Heeler

// SPDX-License-Identifier: Apache-2.0
//
// The blocked-agent `ask` pipeline end to end, at the seams the layers own:
// the parser's pending extraction (grounded in verbatim live omp wire
// records), the store's merge seams recomputing pending, the queue order
// (answer first → next appears), and the delivery seam's
// tap → deliver-once → answered transition. All stubs, no network.

// MARK: - Fixtures (verbatim wire shapes from real omp session records)

/// The `ask` tool-call line observed in a live omp session record: one
/// call carrying multiple questions, options as label + description
/// pairs, a `recommended` index. This is the carrier of pending
/// interactions.
private func askCallLine(
    callID: String = "ask_0_5de86e6b",
    questionID: String = "app_state"
) -> String {
    #"{"type":"message","id":"m1","message":{"role":"assistant","content":[{"type":"text","text":"I need your input:"},{"type":"toolCall","id":"\#(callID)","name":"ask","arguments":{"questions":[{"id":"\#(questionID)","question":"Run the tests?","options":[{"label":"Run them","description":"Runs the suite now."},{"label":"Skip","description":"Defers to CI."}],"recommended":0}]}}]}}"#
}

/// The `ask` result line observed in a live omp session record: the
/// content's "User selected: <label>" carries the answer back.
private func askResultLine(
    callID: String = "ask_0_5de86e6b",
    label: String = "Run them"
) -> String {
    #"{"type":"message","id":"m2","message":{"role":"toolResult","toolCallId":"\#(callID)","toolName":"ask","content":[{"type":"text","text":"User selected: \#(label)"}],"isError":false}}"#
}

private func userLine(_ text: String) -> String {
    #"{"type":"message","message":{"role":"user","content":[{"type":"text","text":"\#(text)}"]}}"#
}

// MARK: - Parser: pending extraction

@Suite("Pending interactions: parser")
struct ChatPendingParserTests {
    @Test func askCallBecomesPendingInteraction() throws {
        let (messages, results) = OmpTranscriptParser.parse(lines: [askCallLine()])
        let pending = OmpTranscriptParser.askPendingInteractions(
            messages: messages, toolResults: results)

        #expect(pending.count == 1)
        let interaction = try #require(pending.first)
        // Identity is call id + question id: stable across polls.
        #expect(interaction.id == "ask_0_5de86e6b#app_state")
        #expect(interaction.question == "Run the tests?")
        #expect(
            interaction.options == [
                PendingInteraction.Option(label: "Run them", description: "Runs the suite now."),
                PendingInteraction.Option(label: "Skip", description: "Defers to CI."),
            ])
        #expect(interaction.answer == nil)
    }

    @Test func pairedAskResultAnswersTheInteraction() throws {
        let (messages, results) = OmpTranscriptParser.parse(
            lines: [askCallLine(), askResultLine(label: "Skip")])
        let pending = OmpTranscriptParser.askPendingInteractions(
            messages: messages, toolResults: results)

        let interaction = try #require(pending.first)
        #expect(interaction.answer == "Skip")
    }

    @Test func nonAskToolsNeverBecomePending() {
        let line = #"{"type":"message","message":{"role":"assistant","content":[{"type":"toolCall","id":"read_0","name":"read","arguments":{"path":"/x"}}]}}"#
        let (messages, results) = OmpTranscriptParser.parse(lines: [line])
        #expect(OmpTranscriptParser.askPendingInteractions(
            messages: messages, toolResults: results).isEmpty)
    }

    @Test func multipleQuestionsInOneCallQueueInWireOrder() throws {
        let line = #"{"type":"message","message":{"role":"assistant","content":[{"type":"toolCall","id":"ask_0","name":"ask","arguments":{"questions":[{"id":"q1","question":"First?","options":[{"label":"a"}]},{"id":"q2","question":"Second?","options":[{"label":"b"}]}]}}]}}"#
        let (messages, results) = OmpTranscriptParser.parse(lines: [line])
        let pending = OmpTranscriptParser.askPendingInteractions(
            messages: messages, toolResults: results)

        #expect(pending.map(\.question) == ["First?", "Second?"])
        // Sequential questions queue: only the FIRST is unanswered-blocked;
        // every one renders (the answered ones dim, the first stays loud).
        let ids = pending.map(\.id)
        #expect(ids == ["ask_0#q1", "ask_0#q2"])
    }

    @Test func questionWithoutOptionsStillBecomesPending() throws {
        // Free-text question: no tap targets, but the question still
        // blocks and must surface (answers go through the composer).
        let line = #"{"type":"message","message":{"role":"assistant","content":[{"type":"toolCall","id":"ask_1","name":"ask","arguments":{"questions":[{"id":"open","question":"What should the release be called?"}]}}]}}"#
        let (messages, results) = OmpTranscriptParser.parse(lines: [line])
        let pending = OmpTranscriptParser.askPendingInteractions(
            messages: messages, toolResults: results)

        let interaction = try #require(pending.first)
        #expect(interaction.options.isEmpty)
        #expect(interaction.question == "What should the release be called?")
    }

    @Test func bareStringOptionsAreAccepted() throws {
        // A future/older omp spelling: options as bare strings instead of
        // label + description objects. Reads as label-only.
        let line = #"{"type":"message","message":{"role":"assistant","content":[{"type":"toolCall","id":"ask_2","name":"ask","arguments":{"questions":[{"id":"q","question":"Proceed?","options":["yes","no"]}]}}]}}"#
        let (messages, results) = OmpTranscriptParser.parse(lines: [line])
        let pending = OmpTranscriptParser.askPendingInteractions(
            messages: messages, toolResults: results)

        let interaction = try #require(pending.first)
        #expect(interaction.options.map(\.label) == ["yes", "no"])
        #expect(interaction.options.allSatisfy { $0.description == nil })
    }

    @Test func malformedAskArgumentsProduceNoPending() {
        // `questions` not an array / question text missing: no interaction,
        // never a crash — a live transcript must keep loading.
        let lines = [
            #"{"type":"message","message":{"role":"assistant","content":[{"type":"toolCall","id":"ask_3","name":"ask","arguments":{"questions":"nope"}}]}}"#,
            #"{"type":"message","message":{"role":"assistant","content":[{"type":"toolCall","id":"ask_4","name":"ask","arguments":{"questions":[{"id":"q","options":[{"label":"x"}]}]}}]}}"#,
        ]
        for line in lines {
            let (messages, results) = OmpTranscriptParser.parse(lines: [line])
            #expect(OmpTranscriptParser.askPendingInteractions(
                messages: messages, toolResults: results).isEmpty)
        }
    }
}

// MARK: - Store seams: pending recomputed on merge

@Suite("Pending interactions: store seams")
struct ChatPendingStoreTests {
    @Test func askCallLinePopulatesPendingOnPoll() throws {
        let merged = ChatStore.mergePolledLines([askCallLine()], into: ChatContent())
        let interaction = try #require(merged.pending.first)
        #expect(interaction.question == "Run the tests?")
        #expect(interaction.answer == nil)
    }

    @Test func answerResultMarksTheInteractionAnswered() throws {
        // First poll: the question arrives. Second poll: the answer
        // record arrives. The pending list is recomputed from ALL
        // messages + results, so the answer marks the same interaction.
        var content = ChatStore.mergePolledLines([askCallLine()], into: ChatContent())
        content = ChatStore.mergePolledLines(
            [askResultLine(label: "Skip")], into: content)

        let interaction = try #require(content.pending.first)
        #expect(interaction.answer == "Skip")
    }

    @Test func queueOrderHoldsAcrossPolls() throws {
        // Two sequential asks from DIFFERENT calls: first answered, second
        // still blocking — the answered one stays (dimmed history), the
        // second keeps its tap targets, order preserved.
        let first = askCallLine(callID: "ask_a", questionID: "first")
        let second = askCallLine(callID: "ask_b", questionID: "second")
        var content = ChatStore.mergePolledLines(
            [first, second], into: ChatContent())
        content = ChatStore.mergePolledLines(
            [askResultLine(callID: "ask_a", label: "Run them")], into: content)

        #expect(content.pending.map(\.id) == ["ask_a#first", "ask_b#second"])
        #expect(content.pending[0].answer == "Run them")
        #expect(content.pending[1].answer == nil)
    }

    @Test func olderPageMergeKeepsPendingAnsweredState() throws {
        // An answered ask loaded via the older-pages path keeps its
        // answer: pending is derived from the full record set either way.
        var content = ChatContent()
        content = ChatStore.mergeOlderLines(
            [askCallLine(callID: "ask_old", questionID: "q"),
             askResultLine(callID: "ask_old", label: "Skip")],
            into: content)
        let interaction = try #require(content.pending.first)
        #expect(interaction.answer == "Skip")
    }

    @Test func pendingSurvivesUnrelatedPolledLines() throws {
        var content = ChatStore.mergePolledLines([askCallLine()], into: ChatContent())
        content = ChatStore.mergePolledLines(
            [userLine("anyone home?")], into: content)
        #expect(content.pending.count == 1)
        #expect(content.pending.first?.answer == nil)
    }
}

// MARK: - Delivery seam: tap → deliver once → answered

@Suite("Pending interactions: delivery seam")
@MainActor
struct ChatPendingDeliveryTests {
    /// A deliver stub that records every delivered text, optionally
    /// throwing on demand. @unchecked Sendable under the @MainActor
    /// test isolation.
    private final class DeliverSpy: @unchecked Sendable {
        var delivered: [String] = []
        var error: (any Error)?
        func deliver(_ text: String) async throws {
            if let error { throw error }
            delivered.append(text)
        }
    }

    private func interaction(
        options: [PendingInteraction.Option] = [
            PendingInteraction.Option(label: "Run them"),
            PendingInteraction.Option(label: "Skip"),
        ]
    ) -> PendingInteraction {
        PendingInteraction(id: "ask_0#q", question: "Run the tests?", options: options)
    }

    @Test func optionTapSendsTheOptionLabelExactlyOnce() async throws {
        let spy = DeliverSpy()
        let store = PendingAnswerDelivery(deliver: { text in try await spy.deliver(text) })
        let pending = interaction()
        let option = try #require(pending.options.first)

        let outcome = await store.choose(option, for: pending)
        #expect(outcome == .delivered)
        // The option's TEXT is what the agent receives (the brief's
        // explicit choice; the demo agent matches on label).
        #expect(spy.delivered == ["Run them"])

        // A second tap on the same (now answered) interaction is a no-op.
        let second = await store.choose(option, for: pending)
        #expect(second == .alreadyAnswered)
        #expect(spy.delivered.count == 1)
    }

    @Test func answeredStateIsExposedForRendering() async throws {
        let spy = DeliverSpy()
        let store = PendingAnswerDelivery(deliver: { text in try await spy.deliver(text) })
        let pending = interaction()
        #expect(store.answer(for: pending) == nil)

        try await store.choose(try #require(pending.options.last), for: pending)
        #expect(store.answer(for: pending) == "Skip")
    }

    @Test func transcriptAnswerIsAnswerEvenBeforeAnyTap() {
        // The transcript's own answer record wins without any local state.
        let spy = DeliverSpy()
        let store = PendingAnswerDelivery(deliver: { text in try await spy.deliver(text) })
        let answered = PendingInteraction(
            id: "ask_1#q", question: "Run the tests?",
            options: [PendingInteraction.Option(label: "Run them")],
            answer: "Run them")
        #expect(store.answer(for: answered) == "Run them")
    }

    @Test func failedDeliveryRollsBackSoTheQuestionStaysAnswerable() async throws {
        let spy = DeliverSpy()
        spy.error = CocoaError(.fileNoSuchFile)
        let store = PendingAnswerDelivery(
            deliver: { text in try await spy.deliver(text) },
            describeError: { _ in "offline" })
        let pending = interaction()
        let option = try #require(pending.options.first)

        let outcome = await store.choose(option, for: pending)
        #expect(outcome == .failed("offline"))
        #expect(store.answer(for: pending) == nil)

        // Retry after the failure delivers exactly once when it succeeds.
        spy.error = nil
        let retry = await store.choose(option, for: pending)
        #expect(retry == .delivered)
        #expect(spy.delivered == ["Run them"])
    }

    @Test func otherOptionsStayAnswerableUntilOneIsChosen() async throws {
        // Tapping option A answers; tapping option B afterwards must NOT
        // deliver — the question is answered.
        let spy = DeliverSpy()
        let store = PendingAnswerDelivery(deliver: { text in try await spy.deliver(text) })
        let pending = interaction()

        try await store.choose(try #require(pending.options.first), for: pending)
        let outcome = await store.choose(
            try #require(pending.options.last), for: pending)
        #expect(outcome == .alreadyAnswered)
        #expect(spy.delivered == ["Run them"])
    }

    @Test func concurrentDoubleTapDeliversOnce() async throws {
        // Two taps racing on the same interaction: the in-flight guard
        // means only one delivery lands.
        let spy = DeliverSpy()
        let store = PendingAnswerDelivery(deliver: { text in try await spy.deliver(text) })
        let pending = interaction()
        let option = try #require(pending.options.first)

        async let first = store.choose(option, for: pending)
        async let second = store.choose(option, for: pending)
        let (a, b) = await (first, second)
        #expect([a, b].contains(.delivered))
        #expect(spy.delivered.count == 1)
    }
    @Test func failedDeliveryIsVisibleAndRetrySucceeds() async throws {
        // A failed tap must not roll back silently: the failure message is
        // exposed for the card to render, and retry after the failure
        // clears it.
        let spy = DeliverSpy()
        spy.error = CocoaError(.fileNoSuchFile)
        let store = PendingAnswerDelivery(
            deliver: { text in try await spy.deliver(text) },
            describeError: { _ in "Host connection dropped" })
        let pending = interaction()
        let option = try #require(pending.options.first)

        let outcome = await store.choose(option, for: pending)
        #expect(outcome == .failed("Host connection dropped"))
        #expect(store.failureMessage(for: pending) == "Host connection dropped")
        #expect(store.answer(for: pending) == nil)

        // Retry once the transport recovers: the failure message clears.
        spy.error = nil
        let retry = await store.choose(option, for: pending)
        #expect(retry == .delivered)
        #expect(store.failureMessage(for: pending) == nil)
        #expect(store.answer(for: pending) == "Run them")
    }

    @Test func inFlightDeliveryIsVisibleWhileSuppressionHolds() async throws {
        // While the deliver closure is awaiting, the card must be able to
        // render progress (and a concurrent second tap is a no-op).
        let spy = DeliverSpy()
        var release: (@Sendable () -> Void) = {}
        let stream = AsyncStream<Void> { continuation in
            release = { continuation.finish() }
        }
        let store = PendingAnswerDelivery(deliver: { text in
            try await spy.deliver(text)
            for await _ in stream { break }
        })
        let pending = interaction()
        let option = try #require(pending.options.first)

        async let first = store.choose(option, for: pending)
        // Let the delivery reach its await point.
        try await Task.sleep(for: .milliseconds(50))
        #expect(store.isDelivering(to: pending))
        #expect(store.failureMessage(for: pending) == nil)

        let second = await store.choose(option, for: pending)
        #expect(second == .alreadyAnswered)

        release()
        let outcome = await first
        #expect(outcome == .delivered)
        #expect(!store.isDelivering(to: pending))
    }
}

// MARK: - Production wiring: the AgentDetailView deliver path

/// The closure shape AgentDetailView hands ChatScreen, driven through a
/// real ConsoleStore over a scripted transport — the exact production
/// path (console.promptAgent → transport.promptAgent), not an injected
/// stub. Pins that the option label reaches the wire with the right
/// pane target, and that a transport failure surfaces through the seam
/// rather than vanishing.
@MainActor
@Suite("Pending interactions: production wiring")
struct ChatPendingProductionWiringTests {
    private func makeConsole(
        transport: ScriptedTransport
    ) -> ConsoleStore {
        ConsoleStore(snapshotRetryDelay: .milliseconds(10)) { _, subscriptions in
            EventsSession(
                subscriptions: subscriptions,
                connect: { transport },
                reconnectPolicy: ReconnectPolicy(
                    initialDelay: .milliseconds(10), multiplier: 2,
                    maxDelay: .milliseconds(50)),
                keepalive: nil)
        }
    }

    private func hostAndConsole() async
        -> (Host.ID, ConsoleStore, ScriptedTransport)
    {
        let transport = ScriptedTransport()
        let console = makeConsole(transport: transport)
        let host = Host.fixture()
        console.setHosts([host])
        // The production flow: the app resumes the Console on appear and
        // the Host's session connects before any delivery can run.
        await console.resume()
        return (host.id, console, transport)
    }

    /// Waits until the Host's console connection is live — a prompt
    /// before the session connects fails with "The Host is not
    /// connected", which is the production precondition, not a bug.
    private func waitUntilConnected(
        _ console: ConsoleStore, hostID: Host.ID
    ) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while ContinuousClock.now < deadline {
            if console.hostStatuses[hostID] == .connected { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(console.hostStatuses[hostID] == .connected, "console must connect")
    }

    /// The deliver closure AgentDetailView builds for ChatScreen
    /// (ChatScreen(deliver:) parameter), verbatim.
    private func detailDeliverClosure(
        console: ConsoleStore, hostID: Host.ID, paneID: String
    ) -> (String) async throws -> Void {
        { text in
            try await console.promptAgent(
                AgentPromptParams(target: paneID, text: text),
                on: hostID)
        }
    }

    @Test func optionLabelReachesTheWireThroughTheProductionClosure() async throws {
        let (hostID, console, transport) = await hostAndConsole()
        try await waitUntilConnected(console, hostID: hostID)

        // Mirror AgentDetailView's chat surface wiring: the deliver
        // closure passed to ChatScreen.
        let deliver = detailDeliverClosure(
            console: console, hostID: hostID, paneID: "w1:p1")
        let store = PendingAnswerDelivery(deliver: deliver)
        let pending = PendingInteraction(
            id: "ask_0#q", question: "Run the tests?",
            options: [PendingInteraction.Option(label: "Run the tests")])

        let outcome = await store.choose(
            try #require(pending.options.first), for: pending)
        #expect(outcome == .delivered)

        // The option's label arrived at the transport, addressed to the
        // agent's pane.
        let params = try #require(
            await transport.agentPromptParams.last,
            "the tap must reach the transport's promptAgent")
        #expect(params.target == "w1:p1")
        #expect(params.text == "Run the tests")
    }

    @Test func transportFailureSurfacesNotSilentlyRollsBack() async throws {
        let (hostID, console, transport) = await hostAndConsole()
        try await waitUntilConnected(console, hostID: hostID)
        await transport.setAgentPromptFailure(
            TransportError.sshUnreachable(detail: "connection lost"))

        let deliver = detailDeliverClosure(
            console: console, hostID: hostID, paneID: "w1:p1")
        let store = PendingAnswerDelivery(deliver: deliver)
        let pending = PendingInteraction(
            id: "ask_1#q", question: "Run the tests?",
            options: [PendingInteraction.Option(label: "Run the tests")])
        let outcome = await store.choose(
            try #require(pending.options.first), for: pending)
        #expect(outcome != .delivered)
        // The failure is user-visible through the seam, the question
        // stays answerable, and nothing was recorded as answered.
        #expect(store.failureMessage(for: pending) != nil)
        #expect(store.answer(for: pending) == nil)
        #expect(await transport.agentPromptParams.count == 1)
    }

    @Test func theStoreIsBuiltAtInitSoTheFirstTapIsWired() throws {
        // The device bug: ChatScreen previously built its pending-answer
        // store in a .task, so a tap on the very first render hit the
        // read-only form (choose: { _ in }) and did nothing. The store
        // must exist the moment the screen does — assert it through the
        // store the screen hands its cards (internal test seam).
        let screen = ChatScreen(
            paneID: "w1:p1",
            agentName: "reviewer",
            state: .blocked,
            content: ChatContent(pending: []),
            initialLevel: .l0,
            changeLevel: { _, _ in },
            deliver: { _ in })
        #expect(screen.pendingAnswersForTesting != nil)

        // And a nil deliver (previews, unwired hosts) keeps it nil — the
        // read-only card renders instead.
        let readonly = ChatScreen(
            paneID: "w1:p1",
            agentName: "reviewer",
            state: .blocked,
            content: ChatContent(pending: []),
            initialLevel: .l0,
            changeLevel: { _, _ in })
        #expect(readonly.pendingAnswersForTesting == nil)
    }
}

// MARK: - Filtering: pending rows keep their every-level contract

@Suite("Pending interactions: filtering")
struct ChatPendingFilteringTests {
    @Test func answeredAndUnansweredBothRenderAtEveryLevel() {
        let answered = PendingInteraction(
            question: "Squash?", options: [PendingInteraction.Option(label: "Squash")],
            answer: "Squash")
        let blocking = PendingInteraction(
            question: "Run tests?", options: [PendingInteraction.Option(label: "Run")])
        for level in DetailLevel.allCases {
            let rows = ChatFiltering.visibleRows(
                messages: [], toolResults: [],
                pending: [answered, blocking], level: level)
            let pendingRows = rows.filter {
                if case .pending = $0 { return true } else { return false }
            }
            #expect(pendingRows.count == 2)
        }
    }

    @Test func twoQuestionsFromOneCallRenderAsTwoRowsInOrder() {
        let questions = [
            PendingInteraction(id: "ask_0#q1", question: "First?", options: []),
            PendingInteraction(id: "ask_0#q2", question: "Second?", options: []),
        ]
        let rows = ChatFiltering.visibleRows(
            messages: [], toolResults: [], pending: questions, level: .l0)
        let pendingRows = rows.compactMap { row -> PendingInteraction? in
            guard case .pending(let interaction) = row else { return nil }
            return interaction
        }
        #expect(pendingRows.map(\.id) == ["ask_0#q1", "ask_0#q2"])
    }
}
