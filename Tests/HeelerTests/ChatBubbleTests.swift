import Foundation
import Testing

@testable import Heeler

/// ChatFiltering's bubble grouping: consecutive visible text rows of ONE
/// user/assistant message become one `ChatBubble` — the unit the
/// per-message affordances (quick reactions, Quote) hang off — while
/// thinking/tool-call/result rows stay full-width chrome in place. Plus
/// the affordance model: the quote draft and the quick-reaction set.
@Suite("Chat Bubbles")
struct ChatBubbleTests {
    // MARK: fixture builders

    private func textMessage(
        _ id: UUID, role: ChatRole, _ texts: String...
    ) -> ChatMessage {
        ChatMessage(id: id, role: role, blocks: texts.map { .text($0) })
    }

    private func call(_ id: String) -> ToolCall {
        ToolCall(id: id, name: "read", arguments: .object(["path": .string("/tmp/x")]))
    }

    private func bubbles(_ items: [ChatTranscriptItem]) -> [ChatBubble] {
        items.compactMap { item -> ChatBubble? in
            guard case .bubble(let bubble) = item else { return nil }
            return bubble
        }
    }

    // MARK: grouping

    @Test func multiMessageAssistantRoundSplitsIntoPerMessageBubbles() {
        let m1 = UUID(), m2 = UUID(), m3 = UUID()
        let user = textMessage(UUID(), role: .user, "fix it")
        let round = [
            textMessage(m1, role: .assistant, "Reading the file first."),
            textMessage(m2, role: .assistant, "Found the bug in the retry loop."),
            textMessage(m3, role: .assistant, "Fixed. All tests pass."),
        ]

        let items = ChatFiltering.visibleItems(from: ChatFiltering.visibleRows(
            messages: [user] + round, toolResults: [], level: .l0))

        let found = bubbles(items)
        #expect(found.count == 4)
        #expect(found[0].role == .user)
        // Each message of the round is its own bubble, keyed by the message.
        #expect(found[1].messageID == m1)
        #expect(found[2].messageID == m2)
        #expect(found[3].messageID == m3)
        #expect(found.dropFirst().allSatisfy { $0.role == .assistant })
        #expect(found[1].text == "Reading the file first.")
        #expect(found[3].text == "Fixed. All tests pass.")
        // Bubble ids are distinct per bubble and reference their message.
        #expect(Set(found.map(\.id)).count == 4)
        #expect(found[1].id.hasPrefix(m1.uuidString))
    }

    @Test func consecutiveTextBlocksOfOneMessageShareOneBubble() {
        let id = UUID()
        let message = textMessage(id, role: .assistant, "First.", "Second.")

        let items = ChatFiltering.visibleItems(from: ChatFiltering.visibleRows(
            messages: [message], toolResults: [], level: .l0))

        let found = bubbles(items)
        #expect(found.count == 1)
        #expect(found[0].rows.count == 2)
        // The quote payload joins the run's rows with a blank line.
        #expect(found[0].text == "First.\n\nSecond.")
    }

    @Test func chromeRowsStayInPlaceBetweenBubbles() {
        // An assistant message [thinking, text, toolCall, text] at L3:
        // the bubble run splits around the tool call — thinking and the
        // call render as full-width chrome, order preserved.
        let id = UUID()
        let message = ChatMessage(
            id: id, role: .assistant,
            blocks: [
                .thinking("hmm"),
                .text("before"),
                .toolCall(call("c1")),
                .text("after"),
            ])

        let items = ChatFiltering.visibleItems(from: ChatFiltering.visibleRows(
            messages: [message],
            toolResults: [
                ToolResult(
                    toolCallId: "c1", toolName: "read", isError: false, content: "ok")
            ],
            level: .l3))

        #expect(items.count == 4)
        // Thinking chrome first, keyed by its block.
        guard case .row(let thinking)? = items.first else {
            Issue.record("thinking must stay a plain chrome row")
            return
        }
        #expect(thinking.id == "\(id.uuidString)#0")
        // Then a bubble for the text before the call.
        guard case .bubble(let first) = items[1] else {
            Issue.record("the pre-call text must group into a bubble")
            return
        }
        #expect(first.id == "\(id.uuidString)#1")
        #expect(first.text == "before")
        // The tool call between the texts, in place.
        guard case .row(let tool)? = items.dropFirst(2).first else {
            Issue.record("the tool call must stay a plain chrome row")
            return
        }
        #expect(tool.id == "\(id.uuidString)#2")
        // Then a second bubble for the text after the call.
        guard case .bubble(let second)? = items.last, second.text == "after" else {
            Issue.record("the post-call text must group into its own bubble")
            return
        }
        #expect(second.id == "\(id.uuidString)#3")
    }

    @Test func levelFilteringShrinksTheBubbleToTheVisibleRows() {
        // The same interleaved message at L0: thinking and the tool call
        // are filtered out, so both texts are consecutive and share ONE
        // bubble — the grouping follows what is visible, and the bubble
        // carries exactly the visible rows.
        let id = UUID()
        let message = ChatMessage(
            id: id, role: .assistant,
            blocks: [
                .thinking("hmm"),
                .text("before"),
                .toolCall(call("c1")),
                .text("after"),
            ])

        let items = ChatFiltering.visibleItems(from: ChatFiltering.visibleRows(
            messages: [message], toolResults: [], level: .l0))

        #expect(items.count == 1)
        guard case .bubble(let bubble)? = items.first else {
            Issue.record("L0 must surface the message as one bubble")
            return
        }
        #expect(bubble.rows.count == 2)
        #expect(bubble.text == "before\n\nafter")
    }

    @Test func adjacentMessagesNeverMergeAcrossSpeakersOrMessages() {
        // Two adjacent user turns and an assistant turn: every message
        // is its own bubble — grouping is per message, never per speaker
        // run.
        let u1 = UUID(), u2 = UUID(), a1 = UUID()
        let items = ChatFiltering.visibleItems(from: ChatFiltering.visibleRows(
            messages: [
                textMessage(u1, role: .user, "one"),
                textMessage(u2, role: .user, "two"),
                textMessage(a1, role: .assistant, "three"),
            ],
            toolResults: [], level: .l0))

        let found = bubbles(items)
        #expect(found.count == 3)
        #expect(found.map(\.messageID) == [u1, u2, a1])
        #expect(found.map(\.role) == [.user, .user, .assistant])
    }

    @Test func outputAndChromeTextNeverBubbles() {
        // toolResult / bashExecution text and pending/orphan rows are
        // output chrome, not conversation — they stay plain rows.
        let toolRecord = ChatMessage(
            id: UUID(), role: .toolResult, blocks: [.text("read output")])
        let bash = ChatMessage(
            id: UUID(), role: .bashExecution, blocks: [.text("! ls")])
        let pending = PendingInteraction(question: "Proceed?", options: [])
        let orphan = ToolResult(
            toolCallId: "gone", toolName: "grep", isError: false, content: "match")

        let items = ChatFiltering.visibleItems(from: ChatFiltering.visibleRows(
            messages: [toolRecord, bash],
            toolResults: [orphan], pending: [pending], level: .l2))

        #expect(bubbles(items).isEmpty)
        #expect(items.allSatisfy {
            if case .row = $0 { return true } else { return false }
        })
        #expect(items.count == 4)
    }

    // MARK: quote draft

    @Test func quoteDraftBlockQuotesEachLine() {
        #expect(ChatQuote.draft(for: "Here is what I found.") == "> Here is what I found.\n\n")
        #expect(ChatQuote.draft(for: "line one\nline two") == "> line one\n> line two\n\n")
        // A blank line inside the quote stays a (blank) quoted line, so
        // the quote renders as one block quote, not two.
        #expect(
            ChatQuote.draft(for: "para one\n\npara two")
                == "> para one\n> \n> para two\n\n")
        // Trailing whitespace never leaks into the draft.
        #expect(ChatQuote.draft(for: "trimmed\n\n") == "> trimmed\n\n")
    }

    @Test func quoteDraftIsEmptyForBlankText() {
        #expect(ChatQuote.draft(for: "") == "")
        #expect(ChatQuote.draft(for: "  \n  ") == "")
    }

    // MARK: quick reactions

    @Test func quickReactionsOfferThumbsOkAndCelebration() {
        #expect(ChatReaction.allCases.map(\.rawValue) == ["👍", "✅", "🎉"])
        // Distinct spoken labels: one per reaction button.
        #expect(Set(ChatReaction.allCases.map(\.accessibilityLabel)).count == 3)
    }
}
