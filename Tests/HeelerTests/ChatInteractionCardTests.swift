import Foundation
import Testing

@testable import Heeler

// SPDX-License-Identifier: Apache-2.0
//
// Unit pins for the v3 Q/A card model + the typed Q/A record
// contract (design doc: 'Answered questions — one paired Q/A card').
// The card VIEW proofs (swipe, expand/collapse, unanswered-cases
// table) ride the UI test suite + simulator captures; these pin the
// pure contracts: producer order, label snapshots at answer time,
// custom text/note separation, the honest missing-data fallback, and
// the archive compatibility of the record.

// MARK: - The typed Q/A record contract (AgentChatInteractionResolution)

@Suite("Q/A record contract (typed answer records)")
struct ChatInteractionRecordContractTests {
    private func interaction(
        _ questions: [AgentChatQuestion]
    ) -> AgentChatInteraction {
        AgentChatInteraction(
            requestId: "r-1", generation: 1, kind: "question",
            questions: questions)
    }

    @Test("selected options snapshot in PRODUCER order — the answer's own order never leaks")
    func selectionsFollowProducerOrder() {
        // Options published in this order; the ANSWER lists them in a
        // DIFFERENT order (the wire accepts any order). The record
        // must still capture them in the question's published order.
        let questions = [
            AgentChatQuestion(
                id: "q1", text: "Pick two", multi: true,
                options: [
                    .init(id: "idx:0", label: "First"),
                    .init(id: "idx:1", label: "Second"),
                    .init(id: "idx:2", label: "Third"),
                ])
        ]
        let answers = [
            AgentChatAnswer(
                questionId: "q1",
                optionIds: ["idx:2", "idx:0"],  // scrambled arrival order
                customText: nil, note: nil)
        ]
        let resolution = AgentChatInteractionResolution(
            answered: interaction(questions), answers: answers)
        #expect(
            resolution.questionAnswers?.first?.selections.map(\.label)
                == ["First", "Third"],
            "selected labels must follow the question's published order")
    }

    @Test("questions record in the INTERACTION's order, not the answers' arrival order")
    func questionsFollowInteractionOrder() {
        let questions = [
            AgentChatQuestion(id: "q1", text: "One?", options: [
                .init(id: "idx:0", label: "a1")]),
            AgentChatQuestion(id: "q2", text: "Two?", options: [
                .init(id: "idx:0", label: "a2")]),
        ]
        let answers = [
            AgentChatAnswer(
                questionId: "q2", optionIds: ["idx:0"],
                customText: nil, note: nil),
            AgentChatAnswer(
                questionId: "q1", optionIds: ["idx:0"],
                customText: nil, note: nil),
        ]
        let resolution = AgentChatInteractionResolution(
            answered: interaction(questions), answers: answers)
        #expect(
            resolution.questionAnswers?.map(\.questionId) == ["q1", "q2"],
            "the record's pairs must follow the interaction's question order")
    }

    @Test("the question text snapshot rides the record — later catalog changes cannot rewrite history")
    func questionTextSnapshotted() {
        let questions = [
            AgentChatQuestion(id: "q1", text: "Ship the slice?", options: [
                .init(id: "idx:0", label: "Ship it")])
        ]
        let resolution = AgentChatInteractionResolution(
            answered: interaction(questions),
            answers: [
                AgentChatAnswer(
                    questionId: "q1", optionIds: ["idx:0"],
                    customText: nil, note: nil)
            ])
        #expect(
            resolution.questionAnswers?.first?.question == "Ship the slice?",
            "the producer's original question text must be captured at answer time")
    }

    @Test("custom text and note ride the record as SEPARATE fields — a note is never promoted to an option")
    func customTextAndNoteSeparate() {
        let questions = [
            AgentChatQuestion(id: "q1", text: "Scope?", options: [
                .init(id: "idx:0", label: "Video")])
        ]
        let resolution = AgentChatInteractionResolution(
            answered: interaction(questions),
            answers: [
                AgentChatAnswer(
                    questionId: "q1", optionIds: ["idx:0"],
                    customText: "Also render the first ten seconds",
                    note: "Include the validation report only")
            ])
        let pair = resolution.questionAnswers?.first
        #expect(pair?.customText == "Also render the first ten seconds")
        #expect(pair?.note == "Include the validation report only")
        #expect(pair?.selections.map(\.label) == ["Video"])
    }

    @Test("an empty note is omitted — empty optional notes never render a 'Note' line")
    func emptyNoteOmitted() {
        let questions = [
            AgentChatQuestion(id: "q1", text: "Proceed?", options: [
                .init(id: "idx:0", label: "Yes")])
        ]
        let resolution = AgentChatInteractionResolution(
            answered: interaction(questions),
            answers: [
                AgentChatAnswer(
                    questionId: "q1", optionIds: ["idx:0"],
                    customText: nil, note: "   ")
            ])
        #expect(resolution.questionAnswers?.first?.note == nil)
    }

    @Test("a free-text-only answer records with no fabricated selection")
    func freeTextOnly() {
        let questions = [
            AgentChatQuestion(id: "q1", text: "Who reviews?", options: [
                .init(id: "idx:0", label: "You"), .init(id: "idx:1", label: "Me")])
        ]
        let resolution = AgentChatInteractionResolution(
            answered: interaction(questions),
            answers: [
                AgentChatAnswer(
                    questionId: "q1", optionIds: [],
                    customText: "I'll take it after lunch", note: nil)
            ])
        let pair = resolution.questionAnswers?.first
        #expect(pair?.selections.isEmpty == true)
        #expect(pair?.customText == "I'll take it after lunch")
    }

    @Test("a question with NO recorded data is omitted from the record — no empty pair fabricated")
    func emptyQuestionOmitted() {
        let questions = [
            AgentChatQuestion(id: "q1", text: "One?", options: [
                .init(id: "idx:0", label: "a1")]),
            AgentChatQuestion(id: "q2", text: "Two?", options: [
                .init(id: "idx:0", label: "a2")]),
        ]
        // Only q1 answered; q2 has no selections and no custom text.
        let resolution = AgentChatInteractionResolution(
            answered: interaction(questions),
            answers: [
                AgentChatAnswer(
                    questionId: "q1", optionIds: ["idx:0"],
                    customText: nil, note: nil)
            ])
        #expect(
            resolution.questionAnswers?.map(\.questionId) == ["q1"])
    }

    @Test("an unknown option id is dropped, never rendered raw — no idx:n reaches the record")
    func unknownOptionDropped() {
        let questions = [
            AgentChatQuestion(id: "q1", text: "Pick", options: [
                .init(id: "idx:0", label: "Known")])
        ]
        let resolution = AgentChatInteractionResolution(
            answered: interaction(questions),
            answers: [
                AgentChatAnswer(
                    questionId: "q1", optionIds: ["idx:0", "idx:9"],
                    customText: nil, note: nil)
            ])
        #expect(
            resolution.questionAnswers?.first?.selections
                .map(\.label) == ["Known"])
        #expect(
            resolution.questionAnswers?.first?.selections
                .map(\.optionId) == ["idx:0"])
    }

    @Test("a youAnswered record with NO answer data reads 'Answer details unavailable.' — never fabricated choices")
    func missingAnswerData() {
        let resolution = AgentChatInteractionResolution(
            requestId: "r-1", kind: .youAnswered,
            questionText: "Ship it?", questionAnswers: nil)
        #expect(resolution.answerSummaryLines == [])
        #expect(resolution.transcriptBody == "You answered.")
        // The UI factory keeps the empty pair list — the card renders
        // the honest placeholder.
        let ask = ResolvedAsk(resolution: resolution)
        #expect(ask.questions.isEmpty)
        #expect(ask.outcome == .youAnswered)
    }

    @Test("a v2 flat-labels archive decodes: the labels surface through answerSummaryLines")
    func legacyLabelsArchiveDecodes() throws {
        let legacyJSON = #"{"requestId":"r-1","kind":"youAnswered","questionText":"Ship it?","labels":["Ship it + Hold"]}"#
        let decoded = try JSONDecoder().decode(
            AgentChatInteractionResolution.self,
            from: Data(legacyJSON.utf8))
        #expect(decoded.questionAnswers == nil)
        #expect(decoded.answerSummaryLines == ["Ship it + Hold"])

        // The re-encode is the v3 shape (no flat labels written).
        let reencoded = try JSONEncoder().encode(decoded)
        let json = String(data: reencoded, encoding: .utf8) ?? ""
        #expect(!json.contains("\"labels\""), "v3 writes never carry the flat legacy form")

        // The UI factory surfaces the legacy labels as the card's pairs
        // (honest to what was captured; never 'details unavailable').
        let ask = ResolvedAsk(resolution: decoded)
        #expect(ask.questions.count == 1)
        #expect(ask.questions.first?.selectedOptions.first?.label == "Ship it + Hold")
    }

    @Test("the summary line for multiline custom text collapses newlines — display-only, the record keeps the source")
    func multilineCustomSummary() {
        let questions = [
            AgentChatQuestion(id: "q1", text: "Notes for the diff?", options: [])
        ]
        let resolution = AgentChatInteractionResolution(
            answered: interaction(questions),
            answers: [
                AgentChatAnswer(
                    questionId: "q1", optionIds: [],
                    customText: "line one\nline two", note: nil)
            ])
        #expect(
            resolution.answerSummaryLines == ["line one line two"])
        #expect(
            resolution.questionAnswers?.first?.customText == "line one\nline two")
    }
}

// MARK: - The UI record projection (ResolvedAsk)

@Suite("Q/A card UI record (ResolvedAsk)")
struct ChatResolvedAskProjectionTests {
    @Test("the factory maps the structured record 1:1 — pairs, outcome, anchor")
    func factoryMapsStructuredRecord() {
        let resolution = AgentChatInteractionResolution(
            requestId: "r-9", kind: .youAnswered,
            questionText: "Which checks?",
            questionAnswers: [
                .init(
                    questionId: "q0", question: "Which checks?",
                    selections: [
                        .init(optionId: "idx:0", label: "Unit suite"),
                        .init(optionId: "idx:2", label: "Device build"),
                    ],
                    customText: nil, note: "first ten seconds only"),
                .init(
                    questionId: "q1", question: "Who reviews?",
                    selections: [],
                    customText: "I'll take it", note: nil),
            ])
        let ask = ResolvedAsk(resolution: resolution)
        #expect(ask.id == "r-9")
        #expect(ask.outcome == .youAnswered)
        #expect(ask.questionText == "Which checks?")
        #expect(ask.questions.count == 2)
        #expect(
            ask.questions[0].selectedOptions.map(\.label)
                == ["Unit suite", "Device build"])
        #expect(ask.questions[0].note == "first ten seconds only")
        #expect(ask.questions[1].customAnswerText == "I'll take it")
    }

    @Test("every resolution kind maps to its card outcome 1:1")
    func outcomeMapping() {
        let pairs: [(AgentChatInteractionResolution.Kind, ResolvedAsk.Outcome)] = [
            (.youAnswered, .youAnswered),
            (.answeredInTerminal, .answeredInTerminal),
            (.answeredRemotely, .answeredRemotely),
            (.cancelled, .cancelled),
            (.expired, .expired),
            (.settledElsewhere, .settledElsewhere),
        ]
        for (kind, expected) in pairs {
            let ask = ResolvedAsk(resolution: .init(
                requestId: "r", kind: kind, questionText: nil,
                questionAnswers: nil))
            #expect(ask.outcome == expected)
        }
    }

    @Test("a non-answered outcome never renders unconfirmed choices as accepted")
    func nonAnsweredHasNoPairs() {
        let resolution = AgentChatInteractionResolution(
            requestId: "r-1", wireOutcome: "answered", wireSource: "remote",
            questionText: "Ship it?")
        let ask = ResolvedAsk(resolution: resolution)
        #expect(ask.questions.isEmpty)
        #expect(ask.outcome == .answeredRemotely)
    }

    @Test("the collapsed body line keeps the flat summary ('You answered: …') for search/accessibility")
    func answeredBodyLine() {
        let ask = ResolvedAsk(
            id: "r1",
            questions: [
                ResolvedAskQuestion(
                    id: "q", question: "Ship it?",
                    selectedOptions: [.init(id: "o0", label: "Ship it")])
            ],
            outcome: .youAnswered)
        #expect(ask.body == "You answered: Ship it")

        let multiLabel = ResolvedAsk(
            id: "r2",
            questions: [
                ResolvedAskQuestion(
                    id: "q", question: "Pick two",
                    selectedOptions: [
                        .init(id: "o0", label: "Unit suite"),
                        .init(id: "o1", label: "Device build"),
                    ])
            ],
            outcome: .youAnswered)
        #expect(multiLabel.body == "You answered: Unit suite + Device build")
    }
}

// MARK: - PendingAskQuestion allowCustom plumbing

@Suite("Pending ask question shape")
struct PendingAskQuestionShapeTests {
    @Test("allowCustom rides the unanswered question (producer-permitted custom input)")
    func allowCustomField() {
        let question = PendingAskQuestion(
            id: "q1", text: "Who reviews?", options: [
                .init(id: "o0", label: "You"),
            ], allowCustom: true)
        #expect(question.allowCustom)
        let plain = PendingAskQuestion(id: "q2", text: "Proceed?", options: [])
        #expect(!plain.allowCustom)
    }
}
