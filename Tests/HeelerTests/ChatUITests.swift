import Foundation
import Testing

@testable import Heeler

/// ChatFiltering is the single source of detail-level truth — these tests
/// pin the contract: L0 is text-only (hard zero chrome), levels nest
/// monotonically, and tool results pair by the opaque toolCallId.
@Suite("Chat Filtering")
struct ChatUITests {
    // MARK: fixture builders

    private func call(_ id: String, name: String = "read") -> ToolCall {
        ToolCall(id: id, name: name, arguments: .object(["path": .string("/tmp/x")]))
    }

    /// A representative assistant turn: thinking, a tool call, then text.
    private func assistantTurn() -> ChatMessage {
        ChatMessage(
            id: UUID(uuidString: "AAAAAAAA-0000-0000-0000-000000000001")!,
            role: .assistant,
            blocks: [
                .thinking("I should read the file first."),
                .toolCall(call("read_0#f3b6e1dc")),
                .text("Here is what I found."),
            ],
            timestamp: Date(timeIntervalSince1970: 100))
    }

    private func pairedResults() -> [ToolResult] {
        [
            ToolResult(
                toolCallId: "read_0#f3b6e1dc", toolName: "read", isError: false,
                content: "file body"),
        ]
    }

    // MARK: L0 — assistant text only, hard-asserted

    @Test func l0ShowsOnlyAssistantTextZeroChrome() {
        let rows = ChatFiltering.visibleRows(
            messages: [assistantTurn()], toolResults: pairedResults(), level: .l0)

        // Hard assert: zero thinking, zero toolcall, zero result chrome.
        #expect(rows.count == 1)
        #expect(rows.allSatisfy {
            if case .text = $0 { return true } else { return false }
        })

        guard case .text(_, _, let role, let text)? = rows.first else {
            Issue.record("L0 must surface the assistant text row")
            return
        }
        #expect(role == .assistant)
        #expect(text == "Here is what I found.")
    }

    @Test func l0ShowsUserTextButNoToolResultRecords() {
        let user = ChatMessage(id: UUID(), role: .user, blocks: [.text("fix it")])
        let toolRecord = ChatMessage(
            id: UUID(), role: .toolResult,
            blocks: [.text("read output")], timestamp: nil)
        let rows = ChatFiltering.visibleRows(
            messages: [user, toolRecord], toolResults: [], level: .l0)

        // User text is conversation (visible), tool-result records are
        // chrome (not visible at L0).
        #expect(rows.count == 1)
        guard case .text(_, _, let role, let text)? = rows.first else {
            Issue.record("L0 must surface the user text row")
            return
        }
        #expect(role == .user)
        #expect(text == "fix it")
    }

    // MARK: level nesting is monotonic

    @Test func levelTransitionsAddRowsMonotonically() {
        let messages = [assistantTurn()]
        let results = pairedResults()
        var previous = Set<String>()
        var previousCount = 0

        for level in DetailLevel.allCases {
            let rows = ChatFiltering.visibleRows(
                messages: messages, toolResults: results, level: level)
            let ids = Set(rows.map(\.id))
            // Every level is the previous one plus rows: no row ever
            // disappears, no existing row is re-keyed.
            #expect(ids.isSuperset(of: previous))
            #expect(rows.count >= previousCount)
            previous = ids
            previousCount = rows.count
        }
    }

    @Test func l1AddsCollapsedToolCallNamesOnly() {
        let rows = ChatFiltering.visibleRows(
            messages: [assistantTurn()], toolResults: pairedResults(), level: .l1)

        let toolRows = rows.filter {
            if case .toolCall = $0 { return true } else { return false }
        }
        #expect(toolRows.count == 1)
        guard case .toolCall(_, _, let call, let result)? = toolRows.first else {
            Issue.record("L1 must surface the tool call row")
            return
        }
        #expect(call.name == "read")
        // L1 is names only: the result is NOT paired in yet, and thinking is
        // still hidden.
        #expect(result == nil)
        #expect(rows.allSatisfy {
            if case .thinking = $0 { return false } else { return true }
        })
    }

    @Test func l2PairsToolResultByToolCallId() {
        let rows = ChatFiltering.visibleRows(
            messages: [assistantTurn()], toolResults: pairedResults(), level: .l2)

        guard case .toolCall(_, _, let call, let result)? = rows.first(where: {
            if case .toolCall = $0 { return true } else { return false }
        }) else {
            Issue.record("L2 must surface the tool call row")
            return
        }
        #expect(result?.toolCallId == call.id)
        #expect(result?.content == "file body")
    }

    @Test func l3AddsThinkingBlocks() {
        let rows = ChatFiltering.visibleRows(
            messages: [assistantTurn()], toolResults: pairedResults(), level: .l3)

        let thinking = rows.filter {
            if case .thinking = $0 { return true } else { return false }
        }
        #expect(thinking.count == 1)
    }

    // MARK: pairing details

    @Test func unpairedCallAtL2RendersRunningSpinnerState() {
        // A tool call whose result has not arrived yet: L2 pairs nil → the
        // row renders the spinner state, not a lost call.
        let rows = ChatFiltering.visibleRows(
            messages: [assistantTurn()], toolResults: [], level: .l2)
        guard case .toolCall(_, _, let call, let result)? = rows.first(where: {
            if case .toolCall = $0 { return true } else { return false }
        }) else {
            Issue.record("unpaired call must still be visible at L2")
            return
        }
        #expect(call.id == "read_0#f3b6e1dc")
        #expect(result == nil)
    }

    @Test func opaqueToolCallIdsPairVerbatim() {
        // Contract: ids may contain '|' and '#' and be hundreds of chars —
        // they are matched verbatim, never parsed.
        let gnarly = String(repeating: "a|b#c-", count: 40)
        let message = ChatMessage(
            id: UUID(), role: .assistant,
            blocks: [.toolCall(call(gnarly, name: "bash")), .text("done")])
        let rows = ChatFiltering.visibleRows(
            messages: [message],
            toolResults: [
                ToolResult(toolCallId: gnarly, toolName: "bash", isError: true, content: "boom"),
                ToolResult(toolCallId: "other", toolName: "read", isError: false, content: "x"),
            ],
            level: .l2)
        guard case .toolCall(_, _, _, let result)? = rows.first(where: {
            if case .toolCall = $0 { return true } else { return false }
        }) else {
            Issue.record("gnarly-id call must be visible")
            return
        }
        #expect(result?.toolCallId == gnarly)
        #expect(result?.isError == true)
    }

    @Test func duplicateResultIdsKeepFirstRecordDeterministically() {
        let message = ChatMessage(
            id: UUID(), role: .assistant, blocks: [.toolCall(call("k"))])
        let rows = ChatFiltering.visibleRows(
            messages: [message],
            toolResults: [
                ToolResult(toolCallId: "k", toolName: "t", isError: false, content: "first"),
                ToolResult(toolCallId: "k", toolName: "t", isError: true, content: "second"),
            ],
            level: .l2)
        guard case .toolCall(_, _, _, let result)? = rows.first(where: {
            if case .toolCall = $0 { return true } else { return false }
        }) else {
            Issue.record("call must be visible")
            return
        }
        #expect(result?.content == "first")
    }

    @Test func windowBoundaryOrphanResultRendersAtL2Only() {
        // A result whose call is not in the visible messages (window
        // boundary): no orphan row at L0/L1, one at L2+.
        let orphan = ToolResult(toolCallId: "gone", toolName: "grep", isError: false, content: "match")
        for level in DetailLevel.allCases {
            let rows = ChatFiltering.visibleRows(messages: [], toolResults: [orphan], level: level)
            let orphans = rows.filter {
                if case .orphanResult = $0 { return true } else { return false }
            }
            if level >= .l2 {
                #expect(orphans.count == 1)
                guard case .orphanResult(let shown)? = orphans.first else { return }
                #expect(shown.toolCallId == "gone")
            } else {
                #expect(orphans.isEmpty)
            }
        }
    }

    // MARK: pending interactions

    @Test func pendingInteractionsRenderAtEveryLevel() {
        let pending = PendingInteraction(question: "Deploy to prod?", options: ["yes", "no"])
        for level in DetailLevel.allCases {
            let rows = ChatFiltering.visibleRows(
                messages: [assistantTurn()], toolResults: [], pending: [pending], level: level)
            let pendingRows = rows.filter {
                if case .pending = $0 { return true } else { return false }
            }
            #expect(pendingRows.count == 1)
            guard case .pending(let shown)? = pendingRows.first else { return }
            #expect(shown.question == "Deploy to prod?")
            #expect(shown.options == ["yes", "no"])
        }
    }

    @Test func pendingRowsComeAfterTranscriptRows() {
        let pending = PendingInteraction(question: "Proceed?", options: [])
        let rows = ChatFiltering.visibleRows(
            messages: [assistantTurn()], toolResults: [], pending: [pending], level: .l0)
        guard case .pending = rows.last else {
            Issue.record("pending interaction must be the final row")
            return
        }
    }

    // MARK: row stability

    @Test func rowIDsAreStableAcrossLevelsSoSwiftUIDiffsCleanly() {
        let messages = [assistantTurn()]
        let results = pairedResults()
        let l2 = ChatFiltering.visibleRows(messages: messages, toolResults: results, level: .l2)
        let l3 = ChatFiltering.visibleRows(messages: messages, toolResults: results, level: .l3)
        // The text row present at L2 keeps its identity at L3.
        let textAtL2 = l2.filter { if case .text = $0 { return true } else { return false } }
        let textAtL3 = l3.filter { if case .text = $0 { return true } else { return false } }
        #expect(textAtL2.map(\.id) == textAtL3.map(\.id))
    }

    // MARK: per-pane level persistence

    @Test func detailLevelPersistsPerPaneInNamespacedSuite() {
        let suiteName = "dev.houz42.heeler.chat.test.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = ChatDetailLevelStore(defaults: defaults)

        // Unknown pane → L0 default.
        #expect(store.level(paneID: "agent-a") == .l0)
        // Out-of-range garbage → L0 default.
        defaults.set(99, forKey: ChatDetailLevelStore.key(paneID: "agent-b"))
        #expect(store.level(paneID: "agent-b") == .l0)

        store.setLevel(.l2, paneID: "agent-a")
        #expect(store.level(paneID: "agent-a") == .l2)
        // Per-pane isolation: agent-b unaffected.
        #expect(store.level(paneID: "agent-b") == .l0)

        // Round-trips through a fresh instance of the same suite.
        let reopened = ChatDetailLevelStore(defaults: defaults)
        #expect(reopened.level(paneID: "agent-a") == .l2)
    }

    @Test func paneKeyEscapesArbitraryPaneIDs() {
        // A pane id spelling the fallback key must not be able to alias it.
        let key = ChatDetailLevelStore.key(paneID: "default")
        #expect(key == ChatDetailLevelStore.defaultKey)
        // Delimiters in pane ids cannot forge another pane's key.
        #expect(ChatDetailLevelStore.key(paneID: "a.b") != ChatDetailLevelStore.key(paneID: "a"))
    }
}
