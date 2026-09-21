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

    @Test func l1CollapsesWorkIntoTheInspectorSummary() {
        // The redesigned L1: rows still carry the calls (with their
        // paired results — the Work inspector's sheet needs them), but
        // visibleItems collapses them into ONE summary item. Thinking
        // stays hidden at L1.
        let rows = ChatFiltering.visibleRows(
            messages: [assistantTurn()], toolResults: pairedResults(), level: .l1)
        let toolRows = rows.filter {
            if case .toolCall = $0 { return true } else { return false }
        }
        #expect(toolRows.count == 1)
        guard case .toolCall(_, _, let call, let result)? = toolRows.first else {
            Issue.record("L1 must surface the tool call row for the inspector")
            return
        }
        #expect(call.name == "read")
        // The result IS paired at L1 now — the inspector sheet shows it.
        #expect(result?.toolCallId == call.id)
        #expect(rows.allSatisfy {
            if case .thinking = $0 { return false } else { return true }
        })

        // The item level collapses the calls into one Work summary.
        let items = ChatFiltering.visibleItems(from: rows, level: .l1)
        let summaries = items.filter {
            if case .workSummary = $0 { return true } else { return false }
        }
        #expect(summaries.count == 1)
        guard case .workSummary(_, let calls)? = summaries.first else {
            Issue.record("L1 must collapse tool calls into one Work summary")
            return
        }
        #expect(calls.count == 1)
        #expect(calls.first?.name == "read")
        #expect(calls.first?.result?.toolCallId == call.id)

        // The summary row's AX label is singular/plural correct — the
        // round-4 fix corrected the VISIBLE text; this pins the
        // accessibility copy too (an AX-walk review caught the stale
        // plural there).
        #expect(
            ChatWorkEntry.accessibilitySummaryLabel(count: 1)
                == "Work summary: 1 tool call, opens details")
        #expect(
            ChatWorkEntry.accessibilitySummaryLabel(count: 2)
                == "Work summary: 2 tool calls, opens details")
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

    // MARK: todo / subagent (task) visibility — folded into levels, no new
    // buttons. Evidence from real omp sessions: `todo` and `task` are
    // ordinary toolCall + toolResult records; only the visibility level
    // differs (ChatFiltering.visibilityLevel).

    private func todoCall() -> ToolCall {
        // Verbatim id + arguments from a real session record
        // (todo:0#5024a45c…, op "done", task "SFTP transport slice").
        ToolCall(
            id: "todo:0#5024a45c7c24404db0179f21b19ca365", name: "todo",
            arguments: .object([
                "op": .string("done"),
                "i": .string("Transport slice and wiring done"),
                "task": .string("SFTP transport slice"),
            ]))
    }

    private func taskCall() -> ToolCall {
        // Verbatim from the fixture's real `task` call (op-scoped spawn
        // whose result reports the spawned agents).
        ToolCall(
            id: "chatcmpl-tool-26a54d122aa141b8868476c33250ab67", name: "task",
            arguments: .object([
                "i": .string("Comparing four open-source herdr iOS clients internals"),
            ]))
    }

    private func agentManagementTurn() -> ChatMessage {
        ChatMessage(
            id: UUID(uuidString: "AAAAAAAA-0000-0000-0000-000000000002")!,
            role: .assistant,
            blocks: [
                .toolCall(todoCall()),
                .toolCall(taskCall()),
                .text("Dispatched the work."),
            ],
            timestamp: Date(timeIntervalSince1970: 200))
    }

    private func agentManagementResults() -> [ToolResult] {
        [
            ToolResult(
                toolCallId: "todo:0#5024a45c7c24404db0179f21b19ca365",
                toolName: "todo", isError: false,
                content: "Remaining items (2):\n  - Wire slices, compile-verify [in_progress] (Integration)"),
            ToolResult(
                toolCallId: "chatcmpl-tool-26a54d122aa141b8868476c33250ab67",
                toolName: "task", isError: false,
                content: "Spawned 4 background agents using scout."),
        ]
    }

    @Test func todoAndTaskRowsHideBelowTheirLevels() {
        // L0/L1: neither the todo checklist nor the subagent spawn shows —
        // only the assistant text. A todo row is NOT visible at L1 even
        // though ordinary tool names are.
        for level in [DetailLevel.l0, .l1] {
            let rows = ChatFiltering.visibleRows(
                messages: [agentManagementTurn()],
                toolResults: agentManagementResults(), level: level)
            let toolRows = rows.filter {
                if case .toolCall = $0 { return true } else { return false }
            }
            #expect(toolRows.isEmpty)
        }
    }

    @Test func l2AddsTodoChecklistWithRenderedResult() {
        let rows = ChatFiltering.visibleRows(
            messages: [agentManagementTurn()],
            toolResults: agentManagementResults(), level: .l2)

        let toolRows = rows.filter {
            if case .toolCall = $0 { return true } else { return false }
        }
        // Only the todo call: `task` stays hidden until L3.
        #expect(toolRows.count == 1)
        guard case .toolCall(_, _, let call, let result)? = toolRows.first else {
            Issue.record("L2 must surface the todo call row")
            return
        }
        #expect(call.name == "todo")
        // The todo result (the rendered checklist) pairs in at L2.
        #expect(result?.content.hasPrefix("Remaining items") == true)
    }

    @Test func l3AddsSubagentSpawnRow() {
        let rows = ChatFiltering.visibleRows(
            messages: [agentManagementTurn()],
            toolResults: agentManagementResults(), level: .l3)

        let names = rows.compactMap { row -> String? in
            guard case .toolCall(_, _, let call, _) = row else { return nil }
            return call.name
        }
        #expect(names.sorted() == ["task", "todo"])
    }

    @Test func todoAndTaskLevelsPreserveMonotonicNesting() {
        // With todo+task rows present, levels still only add rows.
        let messages = [agentManagementTurn()]
        let results = agentManagementResults()
        var previous = Set<String>()
        for level in DetailLevel.allCases {
            let rows = ChatFiltering.visibleRows(
                messages: messages, toolResults: results, level: level)
            #expect(Set(rows.map(\.id)).isSuperset(of: previous))
            previous = Set(rows.map(\.id))
        }
    }

    @Test func taskOrphanResultStaysHiddenUntilL3() {
        // A `task` result whose call is outside the visible window: the
        // orphan gate is name-aware, so it does not surface at L2 like an
        // ordinary-tool orphan would.
        let orphan = ToolResult(
            toolCallId: "chatcmpl-tool-orphaned", toolName: "task",
            isError: false, content: "Spawned 2 background agents.")
        for level in DetailLevel.allCases {
            let rows = ChatFiltering.visibleRows(
                messages: [], toolResults: [orphan], level: level)
            let orphans = rows.filter {
                if case .orphanResult = $0 { return true } else { return false }
            }
            #expect(orphans.count == (level >= .l3 ? 1 : 0))
        }
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
