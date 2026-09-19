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
                PendingInteraction.Option(label: "Run them", description: "Runs the suite now.", index: 0),
                PendingInteraction.Option(label: "Skip", description: "Defers to CI.", index: 1),
            ])
        #expect(interaction.recommendedIndex == 0)
        #expect(interaction.answer == nil)
    }

    @Test func recommendedIndexIsCarriedFromTheWire() throws {
        // The live record's `recommended: 4` — the dialog's starting
        // highlight — must survive parsing; answers key off it.
        let line = askCallLine()
            .replacingOccurrences(of: #""recommended":0"#, with: #""recommended":1"#)
        let (messages, results) = OmpTranscriptParser.parse(lines: [line])
        let pending = OmpTranscriptParser.askPendingInteractions(
            messages: messages, toolResults: results)
        #expect(try #require(pending.first).recommendedIndex == 1)
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
    /// A key-channel stub that records every key sent, optionally
    /// throwing on demand. @unchecked Sendable under the @MainActor
    /// test isolation.
    private final class KeySpy: @unchecked Sendable {
        var sent: [String] = []
        var error: (any Error)?
        func send(_ key: String) async throws {
            if let error { throw error }
            sent.append(key)
        }
    }

    /// A question whose dialog highlights index 1 ("Skip") — exercising
    /// the down-key arithmetic in both directions.
    private func interaction() -> PendingInteraction {
        PendingInteraction(
            id: "ask_0#q", question: "Run the tests?",
            options: [
                PendingInteraction.Option(label: "Run them", index: 0),
                PendingInteraction.Option(label: "Skip", index: 1),
                PendingInteraction.Option(label: "Later", index: 2),
            ],
            recommendedIndex: 1)
    }

    @Test func optionTapSendsTheSelectionKeySequenceExactlyOnce() async throws {
        let spy = KeySpy()
        let store = PendingAnswerDelivery(sendKey: { key in try await spy.send(key) })
        let pending = interaction()

        // An option ABOVE the highlight selects with Enter alone.
        let top = try #require(pending.options.first)
        let topOutcome = await store.choose(top, for: pending)
        #expect(topOutcome == .delivered)
        #expect(spy.sent == ["enter"])
        #expect(store.answer(for: pending) == "Run them")

        // A second tap on the answered question is a no-op — one
        // selection per question, ever.
        let second = await store.choose(top, for: pending)
        #expect(second == .alreadyAnswered)
        #expect(spy.sent == ["enter"])
    }

    @Test func optionBelowTheHighlightStepsDownThenEnters() async throws {
        let spy = KeySpy()
        let store = PendingAnswerDelivery(sendKey: { key in try await spy.send(key) })
        let pending = interaction()

        // "Later" is one step below the highlighted "Skip": down, enter.
        try await store.choose(try #require(pending.options.last), for: pending)
        #expect(spy.sent == ["down", "enter"])
    }

    @Test func selectionKeysMatchTheLiveDialogArithmetic() {
        // Pinned against the live-verified behavior: the dialog opens
        // highlighting `recommended`; N steps below needs exactly N
        // downs before Enter, at-or-above needs Enter alone.
        let pending = interaction()
        #expect(pending.selectionKeys(for: pending.options[0]) == ["enter"])
        #expect(pending.selectionKeys(for: pending.options[1]) == ["enter"])
        #expect(pending.selectionKeys(for: pending.options[2]) == ["down", "enter"])
    }

    @Test func failedKeySendRollsBackSoTheQuestionStaysAnswerable() async throws {
        let spy = KeySpy()
        spy.error = CocoaError(.fileNoSuchFile)
        let store = PendingAnswerDelivery(
            sendKey: { key in try await spy.send(key) },
            describeError: { _ in "offline" })
        let pending = interaction()
        let option = try #require(pending.options.last)

        let outcome = await store.choose(option, for: pending)
        #expect(outcome == .failed("offline"))
        #expect(store.answer(for: pending) == nil)

        // Retry after the failure delivers exactly once when it
        // succeeds.
        spy.error = nil
        let retry = await store.choose(option, for: pending)
        #expect(retry == .delivered)
        #expect(spy.sent == ["down", "enter"])
    }

    @Test func transcriptAnswerIsAnswerEvenBeforeAnyTap() {
        // The transcript's own answer record wins without any local state.
        let store = PendingAnswerDelivery(sendKey: { _ in })
        let answered = PendingInteraction(
            id: "ask_1#q", question: "Run the tests?",
            options: [PendingInteraction.Option(label: "Run them")],
            answer: "Run them")
        #expect(store.answer(for: answered) == "Run them")
    }

    @Test func otherOptionsStayAnswerableUntilOneIsChosen() async throws {
        // Tapping option A answers; tapping option B afterwards must NOT
        // send more keys — the question is answered.
        let spy = KeySpy()
        let store = PendingAnswerDelivery(sendKey: { key in try await spy.send(key) })
        let pending = interaction()

        try await store.choose(try #require(pending.options.first), for: pending)
        let outcome = await store.choose(
            try #require(pending.options.last), for: pending)
        #expect(outcome == .alreadyAnswered)
        #expect(spy.sent == ["enter"])
    }

    @Test func failedDeliveryIsVisibleAndRetrySucceeds() async throws {
        // A failed tap must not roll back silently: the failure message is
        // exposed for the card to render, and retry after the failure
        // clears it.
        let spy = KeySpy()
        spy.error = CocoaError(.fileNoSuchFile)
        let store = PendingAnswerDelivery(
            sendKey: { key in try await spy.send(key) },
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
        // While the key sequence is in flight, the card must be able to
        // render progress (and a concurrent second tap is a no-op).
        let spy = KeySpy()
        var release: (@Sendable () -> Void) = {}
        let stream = AsyncStream<Void> { continuation in
            release = { continuation.finish() }
        }
        let store = PendingAnswerDelivery(sendKey: { key in
            try await spy.send(key)
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

// MARK: - Production wiring: the AgentDetailView answer-key path

/// The key closure shape AgentDetailView hands ChatScreen, driven through
/// a real ConsoleStore over a scripted transport — the exact production
/// path (console.sendAgentKeys → transport agent.send_keys), not an
/// injected stub. A blocked agent refuses agent.prompt (`agent_blocked`),
/// so the ask answer is the dialog's selection keys: pinned that the
/// down/enter sequence reaches the wire addressed to the pane, that
/// agent.prompt is NEVER used for answers, and that a transport failure
/// surfaces through the seam rather than vanishing.
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

    /// Waits until the Host's console connection is live — a key send
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

    /// The answer-key closure AgentDetailView builds for ChatScreen
    /// (ChatScreen(sendAnswerKey:) parameter), verbatim.
    private func detailSendKeyClosure(
        console: ConsoleStore, hostID: Host.ID, paneID: String
    ) -> (_ key: String) async throws -> Void {
        { key in
            try await console.sendAgentKeys(paneID, key: key, on: hostID)
        }
    }

    @Test func answerKeysReachTheWireNotAgentPrompt() async throws {
        let (hostID, console, transport) = await hostAndConsole()
        try await waitUntilConnected(console, hostID: hostID)

        // Mirror AgentDetailView's chat surface wiring: the
        // sendAnswerKey closure passed to ChatScreen.
        let sendKey = detailSendKeyClosure(
            console: console, hostID: hostID, paneID: "w1:p1")
        let store = PendingAnswerDelivery(sendKey: sendKey)
        // An option two steps below the highlight: down, down, enter.
        let pending = PendingInteraction(
            id: "ask_0#q", question: "Which option?",
            options: [
                PendingInteraction.Option(label: "A", index: 0),
                PendingInteraction.Option(label: "B", index: 1),
                PendingInteraction.Option(label: "C", index: 2),
            ],
            recommendedIndex: 0)

        let outcome = await store.choose(
            try #require(pending.options.last), for: pending)
        #expect(outcome == .delivered)

        // The selection keys arrived at the transport as one
        // agent.send_keys call per key, addressed to the agent's pane.
        let sends = await transport.agentKeyParams
        #expect(sends.map(\.keys) == [["down"], ["down"], ["enter"]])
        #expect(sends.allSatisfy { $0.target == "w1:p1" })
        // THE pinned contract: an ask answer never routes through
        // agent.prompt — a blocked agent would refuse it.
        #expect(await transport.agentPromptParams.isEmpty)
    }

    @Test func transportFailureSurfacesNotSilentlyRollsBack() async throws {
        let (hostID, console, transport) = await hostAndConsole()
        try await waitUntilConnected(console, hostID: hostID)
        await transport.setAgentKeyFailure(
            TransportError.sshUnreachable(detail: "connection lost"))

        let sendKey = detailSendKeyClosure(
            console: console, hostID: hostID, paneID: "w1:p1")
        let store = PendingAnswerDelivery(sendKey: sendKey)
        let pending = PendingInteraction(
            id: "ask_1#q", question: "Which option?",
            options: [PendingInteraction.Option(label: "A", index: 0)])
        let outcome = await store.choose(
            try #require(pending.options.first), for: pending)
        #expect(outcome != .delivered)
        // The failure is user-visible through the seam, the question
        // stays answerable, and nothing was recorded as answered.
        #expect(store.failureMessage(for: pending) != nil)
        #expect(store.answer(for: pending) == nil)
        #expect(await transport.agentKeyParams.count == 1)
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
            sendAnswerKey: { _ in })
        #expect(screen.pendingAnswersForTesting != nil)

        // And a nil sendAnswerKey (previews, unwired hosts) keeps it nil
        // — the read-only card renders instead.
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

    // MARK: inline placement (device-verified defect: bottom-appended
    // cards detached from their conversation)

    private func askTurn(
        callID: String, answer: String? = nil
    ) -> (ChatMessage, ChatMessage) {
        // An assistant turn ending in an ask call, and the follow-up turn.
        let asking = ChatMessage(
            id: UUID(), role: .assistant,
            blocks: [
                .text("I need a decision:"),
                .toolCall(ToolCall(
                    id: callID, name: "ask",
                    arguments: .object([:])),
                ),
            ])
        let followUp = ChatMessage(
            id: UUID(), role: .assistant, blocks: [.text("Continuing.")])
        _ = answer
        return (asking, followUp)
    }

    @Test func pendingCardRendersInlineAtTheAskCallPosition() throws {
        // [user → ask call → agent] must render the card BETWEEN the
        // turns, at every level (the ask row itself is level-gated; the
        // card never is).
        let user = ChatMessage(id: UUID(), role: .user, blocks: [.text("Ask me")])
        let (asking, followUp) = askTurn(callID: "ask_0#x")
        let question = PendingInteraction(
            id: "ask_0#x#q", callID: "ask_0#x", question: "Which?",
            options: [PendingInteraction.Option(label: "A", index: 0)])

        for level in DetailLevel.allCases {
            let rows = ChatFiltering.visibleRows(
                messages: [user, asking, followUp], toolResults: [],
                pending: [question], level: level)

            let pendingIndex = try #require(
                rows.firstIndex { if case .pending = $0 { return true } else { return false } },
                "level \(level): card must render")
            let textIndices = rows.indices.filter {
                if case .text = rows[$0] { return true } else { return false }
            }
            // User text before the card, the follow-up turn after it.
            #expect(textIndices.contains { $0 < pendingIndex })
            #expect(textIndices.contains { $0 > pendingIndex })
        }
    }

    @Test func answeredCardsStayInlineInConversationOrder() {
        // The device screenshot's shape: two ask turns with answered
        // cards, each card at ITS call's position — not stacked at the
        // bottom.
        let (first, firstFollow) = askTurn(callID: "ask_a")
        let (second, secondFollow) = askTurn(callID: "ask_b")
        let answeredA = PendingInteraction(
            id: "ask_a#q", callID: "ask_a", question: "Pick one?",
            options: [PendingInteraction.Option(label: "B", index: 1)],
            answer: "B")
        let answeredB = PendingInteraction(
            id: "ask_b#q", callID: "ask_b", question: "Pick again?",
            options: [PendingInteraction.Option(label: "Green", index: 0)],
            answer: "Green")

        let rows = ChatFiltering.visibleRows(
            messages: [first, firstFollow, second, secondFollow],
            toolResults: [], pending: [answeredA, answeredB], level: .l0)

        let pendingIDs = rows.compactMap { row -> String? in
            guard case .pending(let interaction) = row else { return nil }
            return interaction.id
        }
        #expect(pendingIDs == ["ask_a#q", "ask_b#q"])
        // Both were emitted inline — nothing fell to the tail.
        #expect(pendingIDs.count == 2)

        // And the order interleaves: ask_a's card before ask_b's card,
        // each followed by its own turn's continuation.
        let kinds = rows.map { row -> String in
            switch row {
            case .text(_, _, let role, let text):
                return role == .user ? "user" : "text:\(text.prefix(12))"
            case .pending(let interaction):
                return "card:\(interaction.callID)"
            default:
                return "other"
            }
        }
        #expect(kinds == [
            "text:I need a dec", "card:ask_a", "text:Continuing.",
            "text:I need a dec", "card:ask_b", "text:Continuing.",
        ])
    }

    @Test func strayPendingWithoutACallKeepsTailPlacement() {
        // Hand-built pendings (previews) and window-boundary strays keep
        // the old live-edge tail placement.
        let pending = PendingInteraction(question: "Proceed?", options: [])
        let rows = ChatFiltering.visibleRows(
            messages: [ChatMessage(id: UUID(), role: .assistant, blocks: [.text("hi")])],
            toolResults: [], pending: [pending], level: .l0)
        guard case .pending = rows.last else {
            Issue.record("stray pending must keep tail placement")
            return
        }
    }
}
