import Foundation
import Testing

@testable import Heeler

// SPDX-License-Identifier: Apache-2.0
//
/// THE REAL-PATH FLIP REPRO (the user regression): a scripted broker
/// with `interactions: true` opens a REAL interaction, the test
/// answers it through the REAL `store.answer(...)` — the same path
/// `AgentDetailView.onAskAnswer` drives — and pins what the store
/// state + the `brokerContent` projection render after the ack:
/// the pending card must be GONE and the answered resolution must be
/// recorded, so the transcript renders the answered card. This is the
/// link the demo seam could not prove: the store's ack path itself.

@MainActor
@Suite("Real ask answer path (scripted broker, interactions on)")
struct ChatRealAskFlipTests {
    @MainActor private final class Harness {
        let pipe: ScriptedChatPipe
        let store: AgentChatStore
        private let broker: Task<Void, Never>

        /// Distinct session identity per harness instance: the
        /// resolution archive is keyed by session file, so two
        /// harnesses sharing one identity leak resolutions and
        /// tombstones into each other (a test-fixture rule, not a
        /// product behavior).
        init(sessionFile: String) async {
            let pipe = ScriptedChatPipe()
            self.pipe = pipe
            // The interaction we'll answer (the ask.ts wire shape).
            let interactionJSON = #"""
            {"requestId":"ask-r1","generation":1,"kind":"question","questions":[{"id":"q1","text":"Ship the retry fix?","multi":false,"options":[{"id":"idx:0","label":"Ship it"},{"id":"idx:1","label":"Hold"}],"allowCustom":true}]}
            """#
            let broker = Task<Void, Never> {
                await pipe.brokerSend(
                    #"{"type":"welcome","protocol":1,"maxFrameBytes":1048576}"#)
                var answered = 0
                while !Task.isCancelled {
                    let frames = await pipe.receivedFrames
                    guard frames.count > answered else {
                        try? await Task.sleep(for: .milliseconds(4))
                        continue
                    }
                    let frame = frames[answered]
                    answered += 1
                    guard let data = frame.data(using: .utf8),
                        let object = (try? JSONSerialization.jsonObject(
                            with: data)) as? [String: Any],
                        let id = object["id"] as? String,
                        let method = object["method"] as? String
                    else { continue }
                    switch method {
                    case "sessions.list":
                        await pipe.brokerSend(
                            #"{"type":"response","id":"\#(id)","result":{"sessions":[{"instanceId":"inst-1","sessionId":"s1","generation":1,"locator":{"sessionFile":"\#(sessionFile)"},"agent":{"kind":"omp","version":"1"},"capabilities":{"history":true,"streaming":true,"prompt":true,"interrupt":true,"interactions":true,"commands":true,"attachments":true,"branches":false}}]}}"#)
                    case "sessions.subscribe":
                        await pipe.brokerSend(
                            #"{"type":"response","id":"\#(id)","result":{"subscribed":true}}"#)
                        // The ask opens IMMEDIATELY after subscribe —
                        // a real blocked agent's event.
                        await pipe.brokerSend(
                            #"{"type":"event","seq":1,"event":{"type":"interaction.opened","interaction":\#(interactionJSON)}}"#)
                    case "history.open":
                        // A real blocked agent's page: the ask TURN is
                        // committed as an assistant message whose
                        // toolCall (name "ask") carries the question
                        // text in its ARGUMENTS — the anchor the
                        // resolved card matches.
                        await pipe.brokerSend(
                            #"{"type":"response","id":"\#(id)","result":{"sessionId":"s1","generation":1,"revision":"rev-1","throughSeq":1,"items":[{"kind":"message","id":"msg-ask-1","author":{"role":"assistant"},"createdAt":null,"blocks":[{"type":"tool_call","callId":"ask_0_r1","name":"ask","arguments":{"questions":[{"id":"q1","question":"Ship the retry fix?","options":[{"label":"Ship it"},{"label":"Hold"}]}]}}]}],"olderCursor":null}}"#)
                    case "interactions.list":
                        await pipe.brokerSend(
                            #"{"type":"response","id":"\#(id)","result":{"pending":[\#(interactionJSON)]}}"#)
                    case "interactions.answer":
                        // The REAL adapter's accept: settle() emits
                        // interaction.resolved SYNCHRONOUSLY with
                        // accepting, THEN the answer ack returns.
                        await pipe.brokerSend(
                            #"{"type":"event","seq":2,"event":{"type":"interaction.resolved","requestId":"ask-r1","outcome":"answered","source":"remote"}}"#)
                        await pipe.brokerSend(
                            #"{"type":"response","id":"\#(id)","result":{}}"#)
                    default:
                        await pipe.brokerSend(
                            #"{"type":"response","id":"\#(id)","result":{}}"#)
                    }
                }
            }
            self.broker = broker
            let store = await MainActor.run {
                AgentChatStore(
                pipeFactory: AgentChatPipeFactory(
                    open: { _ in pipe },
                    hostRecord: {
                        Host(address: "h", username: "u",
                             brokerChatSocketPath: "/tmp/chat.sock")
                    }),
                paneIdentity: {
                    HerdrPaneSessionIdentity(sessionFilePath: sessionFile)
                })
            }
            self.store = store
            await store.start()
            for _ in 0..<200 where store.phase != .ready {
                try? await Task.sleep(for: .milliseconds(10))
            }
            for _ in 0..<200 where store.interactions.isEmpty {
                try? await Task.sleep(for: .milliseconds(10))
            }
        }

        deinit { broker.cancel() }

        func tearDown() async {
            broker.cancel()
            try? await pipe.close(timeout: .seconds(2))
        }
    }

    @Test("answering a REAL ask: the ack path records the answered resolution and drops the pending card — the flip's fuel")
    func realAnswerRecordsResolutionAndDropsCard() async throws {
        let harness = await Harness(
            sessionFile: "/s/flip-\(UUID().uuidString)")
        defer { await harness.tearDown() }
        let store = harness.store

        // The ask opened (the real event installed it).
        let interaction = try #require(store.interactions.first)
        #expect(interaction.requestId == "ask-r1")

        // THE REAL PATH: AgentDetailView's exact call.
        try await store.answer(
            interaction,
            answers: [
                AgentChatAnswer(
                    questionId: "q1", optionIds: ["idx:0"],
                    customText: nil, note: nil)
            ])

        // Post-ack state — what brokerContent projects to the UI:
        // (a) the pending card is GONE.
        #expect(
            !store.interactions.contains { $0.requestId == "ask-r1" },
            "the ack path must drop the pending interaction")
        // (b) the answered resolution IS recorded — the transcript's
        // resolved card renders from it.
        let resolution = store.interactionResolutions.first {
            $0.requestId == "ask-r1"
        }
        #expect(resolution != nil, "the ack must record the resolution")
        #expect(resolution?.kind == .youAnswered)
        #expect(
            resolution?.questionAnswers?.first?.selections
                .first?.label == "Ship it")

        // (c) THE RENDER (the user regression): the projection
        // AgentDetailView.brokerContent performs — pending from
        // store.interactions, resolvedAsks from the recorded
        // resolutions — feeds ChatFiltering.visibleRows; the rendered
        // rows must contain the ANSWERED card and NO pending card.
        let content = ChatContent(
            messages: store.content.messages,
            toolResults: store.content.toolResults,
            pending: store.interactions.map { interaction in
                PendingInteraction(
                    id: interaction.requestId,
                    question: interaction.questions.first?.text ?? "",
                    options: [],
                    questions: interaction.questions.map { question in
                        PendingAskQuestion(
                            id: question.id, text: question.text,
                            multi: question.multi,
                            options: question.options.map { option in
                                .init(id: option.id, label: option.label)
                            },
                            allowCustom: question.allowCustom)
                    })
            },
            resolvedAsks: store.interactionResolutions.map {
                ResolvedAsk(resolution: $0)
            })
        let rows = ChatFiltering.visibleRows(
            messages: content.messages, toolResults: content.toolResults,
            pending: content.pending, resolvedAsks: content.resolvedAsks,
            level: .l2)
        let pendingRows = rows.filter {
            if case .pending = $0 { return true } else { return false }
        }
        let answeredRows = rows.filter {
            if case .resolvedAsk(let ask) = $0 {
                return ask.id == "ask-r1" && ask.outcome == .youAnswered
            }
            return false
        }
        #expect(
            pendingRows.isEmpty,
            "the pending card must be GONE from the rendered rows")
        #expect(
            answeredRows.count == 1,
            "the ANSWERED card must render (anchored after the ask turn)")
        if case .resolvedAsk(let ask)? = answeredRows.first {
            #expect(
                ask.questions.first?.selectedOptions.first?.label
                    == "Ship it")
        }

        // (d) one resolution per interaction — no duplicate cards.
        #expect(
            store.interactionResolutions.filter { $0.requestId == "ask-r1" }
                .count == 1)
    }

    @Test("the resolved EVENT arriving before the ack (ask.ts settle order) still upgrades to the answered record on ack")
    func resolvedEventBeforeAckUpgradesOnAck() async throws {
        // The adapter settles (emits interaction.resolved) BEFORE the
        // answer's ack returns. The event records NEUTRAL
        // ('Answered remotely'); the ack replaces it with our labels.
        // This pins that the ACK path's recordResolution(submission)
        // wins — the answered card renders the user's choice, not the
        // neutral note.
        let harness = await Harness(
            sessionFile: "/s/flip-\(UUID().uuidString)")
        defer { await harness.tearDown() }
        let store = harness.store
        let interaction = try #require(store.interactions.first)

        try await store.answer(
            interaction,
            answers: [
                AgentChatAnswer(
                    questionId: "q1", optionIds: ["idx:1"],
                    customText: nil, note: nil)
            ])

        let records = store.interactionResolutions.filter {
            $0.requestId == "ask-r1"
        }
        #expect(records.count == 1)
        #expect(records.first?.kind == .youAnswered)
        #expect(
            records.first?.questionAnswers?.first?.selections
                .first?.label == "Hold")
    }
}
