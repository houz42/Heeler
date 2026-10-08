import Foundation
import Testing

@testable import Heeler

// SPDX-License-Identifier: Apache-2.0
//
/// THE REAL-SESSION REPRO (Main's root cause, from the design pane's
/// sim capture + broker-qa.json): the SAME question text asked at
/// five transcript positions ('Which one?' at 17/37/65/81/97); the
/// user answered the LATEST (97) but ChatFiltering's text anchor
/// consumed the FIRST text match (17) — the answered Q/A card
/// rendered at an old offscreen ask, and the user saw only the
/// agent's reply where they answered.
///
/// The fix: the resolved card anchors by the ask turn's TRANSCRIPT
/// IDENTITY (anchorMessageID — the message UUID the store claims at
/// interaction.opened time), not by repeated question text. The
/// legacy text anchor remains the fallback for records without an
/// identity claim (v2 archives, capture-time page lag).

@Suite("Resolved Q/A card identity anchoring (repeated question text)")
struct ChatAskAnchorIdentityTests {
    /// One ask turn exactly like the real broker-qa.json shape: an
    /// assistant message whose `ask` tool call carries the question
    /// id + text + labels in its arguments.
    private func askTurn(
        id: String, questionID: String, question: String,
        labels: [String]
    ) -> ChatMessage {
        ChatMessage(
            id: AgentChatMapper.stableID(for: id),
            role: .assistant,
            blocks: [
                .toolCall(ToolCall(
                    id: "call_\(id)", name: "ask",
                    arguments: .object([
                        "questions": .array([
                            .object(
                                [
                                    "id": .string(questionID),
                                    "question": .string(question),
                                    "options": .array(
                                        labels.map {
                                            .object(["label": .string($0)])
                                        }),
                                ]),
                        ]),
                    ])))
            ])
    }

    private func replyTurn(id: String, text: String) -> ChatMessage {
        ChatMessage(
            id: AgentChatMapper.stableID(for: id),
            role: .assistant,
            blocks: [.text(text)])
    }

    private func answeredAsk(
        requestID: String, anchor: UUID?, question: String, label: String
    ) -> ResolvedAsk {
        ResolvedAsk(
            id: requestID,
            questions: [
                ResolvedAskQuestion(
                    id: "twentyfirst_demo", question: question,
                    selectedOptions: [.init(id: "idx:1", label: label)])
            ],
            outcome: .youAnswered,
            anchorMessageID: anchor,
            questionText: question)
    }

    @Test("THE REPRO: five identical 'Which one?' asks, the LATEST answered — the card anchors at THAT ask, not the first")
    func latestAnsweredAskAnchorsToItsOwnAsk() {
        // The real session's shape: 'Which one?' asked at five
        // positions, interleaved with other turns and replies.
        let askIDs = ["m17", "m37", "m65", "m81", "m97"]
        var messages: [ChatMessage] = []
        for (index, askID) in askIDs.enumerated() {
            messages.append(askTurn(
                id: askID, questionID: "twentyfirst_demo",
                question: "Which one?",
                labels: ["Small", "Medium", "Large"]))
            messages.append(replyTurn(
                id: "reply\(index)", text: "You picked Medium. Continuing."))
        }
        // The user answered the LATEST ask (m97): the store claimed
        // ITS message id at opened time.
        let answered = answeredAsk(
            requestID: "req-latest",
            anchor: AgentChatMapper.stableID(for: "m97"),
            question: "Which one?", label: "Medium")

        let rows = ChatFiltering.visibleRows(
            messages: messages, toolResults: [], pending: [],
            resolvedAsks: [answered], level: .l0)

        // The card must render between the m97 ask turn and its
        // reply — i.e. AFTER the last ask turn, BEFORE the final
        // reply. The pre-fix behavior placed it right after m17 (the
        // first text match).
        let summary = rows.compactMap { row -> String? in
            switch row {
            case .resolvedAsk(let ask):
                return "card"
            case .text(_, _, _, let text):
                return "text:\(text.prefix(12))"
            default:
                return nil
            }
        }
        // L0 hides the tool-call rows; the visible order is:
        // reply texts (m17's reply … m97's reply) with the CARD
        // immediately before m97's reply — the LAST text row.
        #expect(
            summary.last == "card"
                || (summary.count >= 2
                    && summary[summary.count - 2] == "card"
                    && summary.last?.hasPrefix("text:You picked") == true),
            "the answered card must anchor at the LATEST ask (m97), before its reply — got \(summary)")

        // Precise: the card's row index is after m97's message and
        // before m97's reply. Find the reply of m97 (the final
        // message) — the card row must directly precede it.
        let order = rows.map { row -> String in
            switch row {
            case .resolvedAsk: return "card"
            case .text(_, _, _, let text): return "text:\(text.prefix(10))"
            default: return "other"
            }
        }
        if let replyIndex = order.lastIndex(of: "text:You picked"),
            let cardIndex = order.lastIndex(of: "card") {
            #expect(
                cardIndex < replyIndex && replyIndex - cardIndex <= 1,
                "the card must sit between the m97 ask and its reply (card=\(cardIndex), reply=\(replyIndex))")
        } else {
            Issue.record("card or reply row missing: \(order)")
        }
    }

    @Test("identity anchor never steals: an ask whose anchor is elsewhere renders only at THAT message")
    func identityAnchorDoesNotTextMatch() {
        // Two identical asks; the EARLIER one was answered (its
        // anchor claims m1). The legacy text anchor would ALSO match
        // m2 — the identity anchor must not consume at m2.
        let messages = [
            askTurn(
                id: "m1", questionID: "q", question: "Pick one?",
                labels: ["A", "B"]),
            askTurn(
                id: "m2", questionID: "q", question: "Pick one?",
                labels: ["A", "B"]),
            replyTurn(id: "r1", text: "Done."),
        ]
        let answered = answeredAsk(
            requestID: "req-earlier",
            anchor: AgentChatMapper.stableID(for: "m1"),
            question: "Pick one?", label: "A")
        let rows = ChatFiltering.visibleRows(
            messages: messages, toolResults: [], pending: [],
            resolvedAsks: [answered], level: .l0)
        let order = rows.map { row -> String in
            switch row {
            case .resolvedAsk: return "card"
            case .text(_, _, _, let text): return "text:\(text.prefix(8))"
            default: return "other"
            }
        }
        #expect(order.first == "card", "the card anchors after m1, the claimed ask — got \(order)")
        #expect(
            order.filter { $0 == "card" }.count == 1,
            "one card only — m2 never consumes the identity-anchored ask")
    }

    @Test("LEGACY fallback: a record without an identity claim keeps the text anchor (compat)")
    func legacyTextAnchorStillWorks() {
        let messages = [
            askTurn(
                id: "m1", questionID: "q", question: "Unique question?",
                labels: ["A", "B"]),
            replyTurn(id: "r1", text: "Done."),
        ]
        let legacy = ResolvedAsk(
            id: "req-legacy",
            questions: [
                ResolvedAskQuestion(
                    id: "q", question: "Unique question?",
                    selectedOptions: [.init(id: "idx:0", label: "A")])
            ],
            outcome: .youAnswered,
            anchorMessageID: nil,
            questionText: "Unique question?")
        let rows = ChatFiltering.visibleRows(
            messages: messages, toolResults: [], pending: [],
            resolvedAsks: [legacy], level: .l0)
        let order = rows.map { row -> String in
            switch row {
            case .resolvedAsk: return "card"
            case .text(_, _, _, let text): return "text:\(text.prefix(8))"
            default: return "other"
            }
        }
        #expect(order.first == "card", "the legacy text anchor still places the card after its ask")
    }

    @Test("a parked identity anchor (its message outside the page) still parks at the tail")
    func identityAnchorOutsidePageParks() {
        let messages = [replyTurn(id: "r1", text: "Unrelated.")]
        let answered = answeredAsk(
            requestID: "req-gone",
            anchor: AgentChatMapper.stableID(for: "offscreen"),
            question: "Which one?", label: "Medium")
        let rows = ChatFiltering.visibleRows(
            messages: messages, toolResults: [], pending: [],
            resolvedAsks: [answered], level: .l0)
        guard case .resolvedAsk = rows.last else {
            Issue.record("an unmatched identity anchor must park at the tail")
            return
        }
    }
}

// MARK: - The store-side identity claim (upsertInteraction/recordResolution)

@Suite("Store ask-anchor claim (identity capture)")
struct ChatStoreAskAnchorClaimTests {
    @Test("the resolution record carries the claimed ask turn's message identity")
    func resolutionCarriesAnchor() {
        // The record-level contract: anchorMessageID persists through
        // the archive roundtrip and maps into the UI record.
        let resolution = AgentChatInteractionResolution(
            requestId: "r-1", kind: .youAnswered,
            questionText: "Which one?",
            questionAnswers: [
                .init(
                    questionId: "twentyfirst_demo",
                    question: "Which one?",
                    selections: [
                        .init(optionId: "idx:1", label: "Medium")
                    ],
                    customText: nil, note: nil)
            ])
        // Anchor stamped post-init (recordResolution's stamp is the
        // store's job; here we pin the field's contract directly).
        var stamped = resolution
        stamped.anchorMessageID = UUID()
        let data = try! JSONEncoder().encode(stamped)
        let round = try! JSONDecoder().decode(
            AgentChatInteractionResolution.self, from: data)
        #expect(round.anchorMessageID == stamped.anchorMessageID)
        #expect(
            ResolvedAsk(resolution: round).anchorMessageID
                == stamped.anchorMessageID,
            "the UI record carries the identity anchor through the projection")
    }

    @Test("a v2 archive (no anchor field) decodes with a nil anchor — legacy text fallback")
    func legacyArchiveDecodesNilAnchor() throws {
        let legacyJSON = #"{"requestId":"r-1","kind":"youAnswered","questionText":"Ship it?","labels":["Ship it + Hold"]}"#
        let decoded = try JSONDecoder().decode(
            AgentChatInteractionResolution.self,
            from: Data(legacyJSON.utf8))
        #expect(decoded.anchorMessageID == nil)
        let ask = ResolvedAsk(resolution: decoded)
        #expect(ask.anchorMessageID == nil)
        #expect(ask.questionText == "Ship it?")
    }
}
