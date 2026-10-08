import Foundation
import Testing

@testable import Heeler

// SPDX-License-Identifier: Apache-2.0
//
/// The store-side IDENTITY anchor on the real wire shape: a scripted
/// broker whose committed page carries TWO ask turns with the SAME
/// question text (the real-session repro shape). The interaction
/// opens for the SECOND ask; the store must claim THAT ask turn's
/// message id, and the recorded resolution — through the
/// brokerContent projection into ChatFiltering — renders the
/// answered card at the SECOND ask, never the first text match.

@MainActor
@Suite("Real ask anchor claim (scripted broker, repeated question text)")
struct ChatRealAskAnchorTests {
    @MainActor private final class Harness {
        let pipe: ScriptedChatPipe
        let store: AgentChatStore
        private let broker: Task<Void, Never>

        init(sessionFile: String) async {
            let pipe = ScriptedChatPipe()
            self.pipe = pipe
            // Two IDENTICAL ask turns in the page (same question id,
            // same text — the real repro: 'Which one?' × N).
            let askTurn = { (messageID: String, callID: String) in
                #"{"kind":"message","id":"\#(messageID)","author":{"role":"assistant"},"createdAt":null,"blocks":[{"type":"tool_call","callId":"\#(callID)","name":"ask","arguments":{"questions":[{"id":"twentyfirst_demo","question":"Which one?","options":[{"label":"Small"},{"label":"Medium"},{"label":"Large"}]}]}}]}"#
            }
            let ask1 = askTurn("msg-ask-1", "ask_0_one")
            let ask2 = askTurn("msg-ask-2", "ask_0_two")
            let interactionJSON = #"""
            {"requestId":"ask-latest","generation":1,"kind":"question","questions":[{"id":"twentyfirst_demo","text":"Which one?","multi":false,"options":[{"id":"idx:0","label":"Small"},{"id":"idx:1","label":"Medium"},{"id":"idx:2","label":"Large"}],"allowCustom":true}]}
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
                        await pipe.brokerSend(
                            #"{"type":"event","seq":1,"event":{"type":"interaction.opened","interaction":\#(interactionJSON)}}"#)
                    case "history.open":
                        await pipe.brokerSend(
                            #"{"type":"response","id":"\#(id)","result":{"sessionId":"s1","generation":1,"revision":"rev-1","throughSeq":1,"items":[\#(ask1),\#(ask2)],"olderCursor":null}}"#)
                    case "interactions.list":
                        await pipe.brokerSend(
                            #"{"type":"response","id":"\#(id)","result":{"pending":[\#(interactionJSON)]}}"#)
                    case "interactions.answer":
                        await pipe.brokerSend(
                            #"{"type":"event","seq":2,"event":{"type":"interaction.resolved","requestId":"ask-latest","outcome":"answered","source":"remote"}}"#)
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

    @Test("answering the LATEST of two identical asks: the record claims THAT ask turn's message and the card renders there")
    func latestIdenticalAskClaimsItsOwnTurn() async throws {
        let harness = await Harness(
            sessionFile: "/s/anchor-\(UUID().uuidString)")
        defer { await harness.tearDown() }
        let store = harness.store

        let interaction = try #require(store.interactions.first)
        #expect(interaction.requestId == "ask-latest")

        // THE REAL PATH: answer through the store.
        try await store.answer(
            interaction,
            answers: [
                AgentChatAnswer(
                    questionId: "twentyfirst_demo", optionIds: ["idx:1"],
                    customText: nil, note: nil)
            ])

        // (a) The resolution carries the IDENTITY anchor — the SECOND
        // ask turn's message (msg-ask-2), never the first text match.
        let resolution = store.interactionResolutions.first {
            $0.requestId == "ask-latest"
        }
        #expect(resolution != nil)
        let expectedAnchor = AgentChatMapper.stableID(for: "msg-ask-2")
        #expect(
            resolution?.anchorMessageID == expectedAnchor,
            "the store must claim the LATEST identical ask turn (msg-ask-2), not the first text match")

        // (b) THE RENDER: the projection renders the answered card
        // between the SECOND ask turn and the tail — one card, at the
        // ask the user answered.
        let content = ChatContent(
            messages: store.content.messages,
            toolResults: store.content.toolResults,
            resolvedAsks: store.interactionResolutions.map {
                ResolvedAsk(resolution: $0)
            })
        let rows = ChatFiltering.visibleRows(
            messages: content.messages,
            toolResults: content.toolResults,
            pending: [], resolvedAsks: content.resolvedAsks, level: .l2)
        let anchorIndex = rows.firstIndex {
            if case .toolCall(let messageID, _, _, _) = $0 {
                return messageID == expectedAnchor
            }
            return false
        }
        let cardIndex = rows.firstIndex {
            if case .resolvedAsk = $0 { return true }
            return false
        }
        #expect(anchorIndex != nil, "the second ask turn must render at L2")
        #expect(cardIndex != nil, "the answered card must render")
        if let anchorIndex, let cardIndex {
            #expect(
                cardIndex > anchorIndex,
                "the card renders AFTER its own ask turn")
            #expect(
                cardIndex - anchorIndex <= 1,
                "the card renders DIRECTLY after its ask turn — not after the earlier identical one")
        }
        #expect(
            rows.filter {
                if case .resolvedAsk = $0 { return true } else { return false }
            }.count == 1,
            "exactly one answered card")
    }
}
