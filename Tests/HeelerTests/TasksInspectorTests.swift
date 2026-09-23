import Foundation
import Testing

@testable import Heeler

// SPDX-License-Identifier: Apache-2.0
//
// Unit pins for the v3 work inspector's DATA MAPPING (design doc:
// 'Tasks and subagents — UI first, protocol second'): producer-order
// hierarchy, stable position-keyed IDs, collapsible groups (direct
// children first, explicit descendant expansion), state/verdict
// separation, leaf-only progress totals, and the honest
// empty/unsupported/not-loaded distinction. The todo fixture bodies
// are the todo tool's own rendered format — taken verbatim from
// real omp sessions (census of 180 live results; the phase sections
// after the "Active phase" line are the authoritative hierarchy).

// MARK: - Fixtures

/// Builder helpers for ChatContent-based transcript fixtures.
private func todoCall(id: String) -> ToolCall {
    ToolCall(id: id, name: "todo", arguments: .object(["op": .string("view")]))
}

private func taskSpawnCall(id: String, children: [(name: String, task: String, agent: String?)]) -> ToolCall {
    ToolCall(
        id: id, name: "task",
        arguments: .object([
            "i": .string("Coordinate the slice work"),
            "tasks": .array(children.map { child in
                .object([
                    "name": .string(child.name),
                    "task": .string(child.task),
                ].merging(
                    child.agent.map { ["agent": .string($0)] } ?? [:],
                    uniquingKeysWith: { a, _ in a }))
            }),
        ]))
}

/// The real phased checklist format (verbatim shape from live omp
/// sessions): "Remaining items" duplicate summary + "Overall" +
/// "Active phase" + the authoritative phase sections.
private let realPhasedChecklist = """
    Remaining items (2):
      - Wire slices, compile-verify [in_progress] (Integration)
      - Log Phase 1 state in plan note [pending] (Integration)
    Overall: 6/8 done, 2 open.
    Active phase 3/3 "Integration" (0/2).
      Foundation:
        - [X] Worktree + Drover pin + real fixtures
        - [X] Define Swift contract
      Development:
        - [X] Parser slice (Chat/Transcript)
        - [X] Window slice (JsonlTranscriptWindow)
        - [X] SFTP transport slice
        - [X] ChatScreen UI slice
      Integration:
        - [ ] Wire slices, compile-verify (in progress)
        - [ ] Log Phase 1 state in plan note
    """

private func content(
    _ messages: [ChatMessage], results: [ToolResult] = []
) -> ChatContent {
    ChatContent(messages: messages, toolResults: results)
}

// MARK: - The checklist parser

@Suite
struct TodoChecklistParserTests {
    @Test func parsesRealPhasedChecklistInProducerOrder() {
        let outcome = TodoChecklistParser.parse(
            resultContent: realPhasedChecklist, callID: "todo:0#abc")
        guard case .rows(let rows) = outcome else {
            Issue.record("expected rows, got \(outcome)")
            return
        }
        // Producer order: Foundation group + 2 items, Development
        // group + 4 items, Integration group + 2 items — depth-first.
        let order = rows.map(\.title)
        #expect(order == [
            "Foundation",
            "Worktree + Drover pin + real fixtures",
            "Define Swift contract",
            "Development",
            "Parser slice (Chat/Transcript)",
            "Window slice (JsonlTranscriptWindow)",
            "SFTP transport slice",
            "ChatScreen UI slice",
            "Integration",
            "Wire slices, compile-verify",
            "Log Phase 1 state in plan note",
        ])
        // Kinds: 3 groups, 8 leaf tasks.
        #expect(rows.filter { $0.kind == .group }.count == 3)
        #expect(rows.filter { $0.kind == .task }.count == 8)
    }

    @Test func theRemainingItemsDuplicateIsNeverParsedAsHierarchy() {
        // The "Remaining items" block repeats open items with
        // INLINE states; the authoritative phase sections carry the
        // same items. Parsing both would double-count leaves.
        let outcome = TodoChecklistParser.parse(
            resultContent: realPhasedChecklist, callID: "c")
        guard case .rows(let rows) = outcome else {
            Issue.record("expected rows")
            return
        }
        // 8 leaves — NOT 10 (the two Remaining-items lines are
        // duplicates, not extra rows).
        #expect(rows.filter { $0.kind == .task }.count == 8)
    }

    @Test func leafStatesMapFromProducerMarks() {
        let outcome = TodoChecklistParser.parse(
            resultContent: realPhasedChecklist, callID: "c")
        guard case .rows(let rows) = outcome else {
            Issue.record("expected rows")
            return
        }
        let byTitle = Dictionary(uniqueKeysWithValues: rows.map { ($0.title, $0) })
        #expect(byTitle["Worktree + Drover pin + real fixtures"]?.state == .completed)
        #expect(byTitle["Wire slices, compile-verify"]?.state == .inProgress)
        #expect(byTitle["Log Phase 1 state in plan note"]?.state == .pending)
    }

    @Test func blockedReasonBecomesDetailNotTitle() {
        let body = """
            Remaining items (1):
              - Slash: probe path (blocked: awaiting user pick)
            Overall: 3/11 done, 8 blocked.
            Active phase 2/2 "Follow-ups" (0/8).
              Merge to main:
                - [X] Merge verified feature branches into fork main
              Follow-ups:
                - [ ] Slash: probe path (blocked: awaiting user pick)
            """
        let outcome = TodoChecklistParser.parse(resultContent: body, callID: "c")
        guard case .rows(let rows) = outcome else {
            Issue.record("expected rows")
            return
        }
        let blocked = rows.first { $0.state == .blocked }
        #expect(blocked?.title == "Slash: probe path")
        #expect(blocked?.detail == "awaiting user pick")
    }

    @Test func activePhaseIsProducerReportedNotInferred() {
        let outcome = TodoChecklistParser.parse(
            resultContent: realPhasedChecklist, callID: "c")
        guard case .rows(let rows) = outcome else {
            Issue.record("expected rows")
            return
        }
        let integration = rows.first { $0.title == "Integration" }
        let foundation = rows.first { $0.title == "Foundation" }
        // The render reports Integration as the ACTIVE phase.
        #expect(integration?.state == .inProgress)
        // Foundation's leaves are all completed, but the producer
        // never marked the GROUP — parent state is never inferred
        // from child completion.
        #expect(foundation?.state == .unknown)
    }

    @Test func clearedListIsAValidEmptySnapshot() {
        let outcome = TodoChecklistParser.parse(
            resultContent: "Todo list cleared.", callID: "c")
        #expect(outcome == .cleared)
    }

    @Test func unrecognizedFormatIsReportedNeverGuessed() {
        let outcome = TodoChecklistParser.parse(
            resultContent: "Error: todo store unavailable", callID: "c")
        guard case .unrecognized(let reason) = outcome else {
            Issue.record("expected unrecognized, got \(outcome)")
            return
        }
        #expect(!reason.isEmpty)
    }

    @Test func idsAreStableAndPositionKeyedNeverTitleKeyed() {
        // Same body, same call → identical IDs (stability).
        let first = TodoChecklistParser.parse(
            resultContent: realPhasedChecklist, callID: "c")
        let second = TodoChecklistParser.parse(
            resultContent: realPhasedChecklist, callID: "c")
        #expect(first == second)

        // Title edits within one snapshot cannot re-key rows: the
        // FIRST leaf keeps its position-derived ID even when an
        // earlier title changes.
        let edited = realPhasedChecklist
            .replacingOccurrences(of: "Define Swift contract", with: "Renamed contract step")
        let outcome = TodoChecklistParser.parse(resultContent: edited, callID: "c")
        guard case .rows(let rows) = outcome else {
            Issue.record("expected rows")
            return
        }
        let byID = Dictionary(uniqueKeysWithValues: rows.map { ($0.id, $0) })
        #expect(byID["todo@c#g0#i1"]?.title == "Renamed contract step")
    }

    @Test func differentCallsCarryDifferentIDScopes() {
        let a = TodoChecklistParser.parse(
            resultContent: realPhasedChecklist, callID: "call-a")
        let b = TodoChecklistParser.parse(
            resultContent: realPhasedChecklist, callID: "call-b")
        guard case .rows(let rowsA) = a, case .rows(let rowsB) = b else {
            Issue.record("expected rows")
            return
        }
        #expect(rowsA.map(\.id) != rowsB.map(\.id))
        #expect(Set(rowsA.map(\.id)).intersection(Set(rowsB.map(\.id))).isEmpty)
    }
}

// MARK: - The snapshot builder

@Suite
struct WorkInspectorSnapshotBuilderTests {
    @Test func latestTodoResultWinsEarlierOnesAreSuperseded() {
        // Two todo results in transcript order: the LATER one is the
        // same list's newest state — the snapshot shows ONE list,
        // never both.
        let earlier = ToolResult(
            toolCallId: "todo:0", toolName: "todo", isError: false,
            content: realPhasedChecklist)
        let laterBody = """
            Remaining items: none.
            Overall: 8/8 done, 0 open.
            Active phase 3/3 "Integration" (2/2).
              Foundation:
                - [X] Worktree + Drover pin + real fixtures
                - [X] Define Swift contract
              Development:
                - [X] Parser slice (Chat/Transcript)
                - [X] Window slice (JsonlTranscriptWindow)
                - [X] SFTP transport slice
                - [X] ChatScreen UI slice
              Integration:
                - [X] Wire slices, compile-verify
                - [X] Log Phase 1 state in plan note
            """
        let later = ToolResult(
            toolCallId: "todo:1", toolName: "todo", isError: false,
            content: laterBody)
        let transcript = content(
            [ChatMessage(role: .assistant, blocks: [
                .toolCall(todoCall(id: "todo:0")),
                .toolCall(todoCall(id: "todo:1")),
            ])],
            results: [earlier, later])
        let snapshot = WorkInspectorSnapshotBuilder.build(from: transcript)
        #expect(snapshot.taskObservation == .loaded)
        // Only the LATER snapshot's 8 leaves — the earlier result's
        // rows never mix in.
        #expect(snapshot.leafProgress.total == 8)
        #expect(snapshot.leafProgress.completed == 8)
    }

    @Test func todoResultWithoutActivePhaseRendersUnsupportedNotGuesses() {
        let oddResult = ToolResult(
            toolCallId: "t1", toolName: "todo", isError: false,
            content: "Something else entirely")
        let transcript = content(
            [ChatMessage(role: .assistant, blocks: [.toolCall(todoCall(id: "t1"))])],
            results: [oddResult])
        let snapshot = WorkInspectorSnapshotBuilder.build(from: transcript)
        guard case .unsupported(let reason) = snapshot.taskObservation else {
            Issue.record("expected unsupported, got \(snapshot.taskObservation)")
            return
        }
        #expect(!reason.isEmpty)
        #expect(snapshot.tasks.isEmpty)
    }

    @Test func emptyTranscriptIsNotLoadedLoadedTranscriptWithoutTodoIsEmpty() {
        #expect(
            WorkInspectorSnapshotBuilder.build(from: ChatContent()).taskObservation
                == .notLoaded)
        let noTodo = content([
            ChatMessage(role: .user, blocks: [.text("hello")]),
            ChatMessage(role: .assistant, blocks: [.text("hi")]),
        ])
        #expect(
            WorkInspectorSnapshotBuilder.build(from: noTodo).taskObservation
                == .empty)
    }

    // MARK: subagents

    @Test func subagentIdentityFromStructuredSpawnArguments() {
        // Verbatim argument shape from a real omp `task` call.
        let call = taskSpawnCall(
            id: "chatcmpl-tool-26a5",
            children: [
                ("DroverInternals", "Research the Drover iOS app internals", "scout"),
                ("HeelerInternals", "Research the Heeler iOS app internals", "scout"),
                ("WhipInternals", "Research the Whip mobile app internals", nil),
            ])
        let spawnResult = ToolResult(
            toolCallId: call.id, toolName: "task", isError: false,
            content: "Spawned 3 background agents using scout.")
        let transcript = content(
            [ChatMessage(role: .assistant, blocks: [.toolCall(call)])],
            results: [spawnResult])
        let snapshot = WorkInspectorSnapshotBuilder.build(from: transcript)
        #expect(snapshot.subagentObservation == .loaded)
        #expect(snapshot.subagents.count == 3)
        // Producer order: the arguments' array order.
        #expect(snapshot.subagents.map(\.displayName) == [
            "DroverInternals", "HeelerInternals", "WhipInternals"])
        #expect(snapshot.subagents.map(\.assignedWork) == [
            "Research the Drover iOS app internals",
            "Research the Heeler iOS app internals",
            "Research the Whip mobile app internals"])
        // Declared kind; undeclared → "task".
        #expect(snapshot.subagents.map(\.kind) == ["scout", "scout", "task"])
        // Every spawn acknowledged by its paired result.
        #expect(snapshot.subagents.allSatisfy { $0.spawnAcknowledged })
    }

    @Test func runtimeStateAndResultVerdictAreSeparateAndHonest() {
        let call = taskSpawnCall(
            id: "spawn-1", children: [("ScoutA", "Do research", "scout")])
        let transcript = content(
            [ChatMessage(role: .assistant, blocks: [.toolCall(call)])],
            results: [ToolResult(
                toolCallId: "spawn-1", toolName: "task", isError: false,
                content: "Spawned 1 background agent using scout.")])
        let snapshot = WorkInspectorSnapshotBuilder.build(from: transcript)
        let subagent = snapshot.subagents[0]
        // A task tool-call ID is NOT a child-run identity: runtime
        // state stays UNKNOWN (never scraped from later `hub`
        // prose), and the result verdict stays NOT REPORTED — the
        // spawn acknowledgment is not acceptance.
        #expect(subagent.runtimeState == .unknown)
        #expect(subagent.resultVerdict == nil)
        #expect(subagent.runtimeStateNote != nil)
    }

    @Test func hubProseAboutAChildNeverBecomesASubagentRow() {
        // The agent's own `hub` tool calls are model tool calls, NOT
        // child-run observations (design: "Do not confuse model tool
        // calls with real subagents") — they spawn nothing.
        let hubCall = ToolCall(
            id: "hub-1", name: "hub",
            arguments: .object(["op": .string("list")]))
        let transcript = content(
            [ChatMessage(role: .assistant, blocks: [.toolCall(hubCall)])],
            results: [ToolResult(
                toolCallId: "hub-1", toolName: "hub", isError: false,
                content: "## Completed (1) WhipInternals — completed")])
        let snapshot = WorkInspectorSnapshotBuilder.build(from: transcript)
        #expect(snapshot.subagents.isEmpty)
        #expect(snapshot.subagentObservation == .empty)
    }

    @Test func spawnWithoutStructuredTasksArrayYieldsNothing() {
        let call = ToolCall(
            id: "s", name: "task",
            arguments: .object(["i": .string("no structured children")]))
        let transcript = content(
            [ChatMessage(role: .assistant, blocks: [.toolCall(call)])])
        let snapshot = WorkInspectorSnapshotBuilder.build(from: transcript)
        #expect(snapshot.subagents.isEmpty)
    }

    @Test func unacknowledgedSpawnIsStillShownWithHonestFlag() {
        // The spawn call's result hasn't arrived (still running in
        // the transcript's own timeline) — the row shows, with the
        // acknowledgment honestly false.
        let call = taskSpawnCall(
            id: "spawn-2", children: [("ScoutB", "Do work", "scout")])
        let transcript = content(
            [ChatMessage(role: .assistant, blocks: [.toolCall(call)])])
        let snapshot = WorkInspectorSnapshotBuilder.build(from: transcript)
        #expect(snapshot.subagents.count == 1)
        #expect(snapshot.subagents[0].spawnAcknowledged == false)
    }

    @Test func sameChildNameAcrossSpawnsStaysDistinct() {
        let first = taskSpawnCall(id: "spawn-a", children: [("Researcher", "Task A", "scout")])
        let second = taskSpawnCall(id: "spawn-b", children: [("Researcher", "Task B", "scout")])
        let transcript = content([ChatMessage(role: .assistant, blocks: [
            .toolCall(first), .toolCall(second),
        ])])
        let snapshot = WorkInspectorSnapshotBuilder.build(from: transcript)
        #expect(snapshot.subagents.count == 2)
        #expect(Set(snapshot.subagents.map(\.id)).count == 2)
    }

    // MARK: leaf totals

    @Test func progressCountsLeavesOnlyNeverGroups() {
        let outcome = TodoChecklistParser.parse(
            resultContent: realPhasedChecklist, callID: "c")
        guard case .rows(let rows) = outcome else {
            Issue.record("expected rows")
            return
        }
        let snapshot = WorkInspectorSnapshot(
            tasks: rows, taskObservation: .loaded)
        let progress = snapshot.leafProgress
        // 8 leaves: 6 completed, 1 in progress, 1 pending. The 3
        // GROUP rows never enter any count.
        #expect(progress.total == 8)
        #expect(progress.completed == 6)
        #expect(progress.inProgress == 1)
        #expect(progress.pending == 1)
        #expect(progress.blocked == 0)
        #expect(progress.summaryLine == "6 of 8 completed · 1 in progress")
    }

    @Test func emptyProgressSummaryNamesItself() {
        let snapshot = WorkInspectorSnapshot(
            taskObservation: .loaded)
        #expect(snapshot.leafProgress.summaryLine == "No tasks")
    }
}

// MARK: - Collapsible hierarchy walk

@Suite
struct WorkVisibleRowsTests {
    private func fixture() -> [WorkTask] {
        let outcome = TodoChecklistParser.parse(
            resultContent: realPhasedChecklist, callID: "c")
        guard case .rows(let rows) = outcome else {
            Issue.record("expected rows")
            return []
        }
        return rows
    }

    @Test func walkIsDepthFirstProducerOrder() {
        let rows = fixture()
        let visible = WorkVisibleRows.walk(rows, collapsedGroupIDs: [])
        // Expanded groups show DIRECT children first, then the
        // subtree (depth-first): group row, its items, next group.
        #expect(visible.map(\.task.title) == [
            "Foundation",
            "Worktree + Drover pin + real fixtures",
            "Define Swift contract",
            "Development",
            "Parser slice (Chat/Transcript)",
            "Window slice (JsonlTranscriptWindow)",
            "SFTP transport slice",
            "ChatScreen UI slice",
            "Integration",
            "Wire slices, compile-verify",
            "Log Phase 1 state in plan note",
        ])
        // Depths: groups at 0, their items at 1.
        #expect(visible.map(\.depth) == [
            0, 1, 1, 0, 1, 1, 1, 1, 0, 1, 1,
        ])
    }

    @Test func collapsedGroupHidesItsEntireSubtree() {
        let rows = fixture()
        let visible = WorkVisibleRows.walk(
            rows, collapsedGroupIDs: ["todo@c#g1"])  // Development
        // The collapsed group's row stays; its children are gone.
        #expect(visible.map(\.task.title).contains("Development"))
        #expect(!visible.map(\.task.title).contains("Parser slice (Chat/Transcript)"))
        #expect(visible.map(\.task.title).contains("Integration"))
        // 3 group rows + Foundation's 2 leaves + Integration's 2
        // leaves (Development's 4 are hidden by the collapse).
        #expect(visible.count == 7)
    }

    @Test func collapsingOneGroupLeavesOthersExpanded() {
        let rows = fixture()
        let visible = WorkVisibleRows.walk(
            rows, collapsedGroupIDs: ["todo@c#g0"])  // Foundation only
        #expect(visible.map(\.task.title) == [
            "Foundation",
            "Development",
            "Parser slice (Chat/Transcript)",
            "Window slice (JsonlTranscriptWindow)",
            "SFTP transport slice",
            "ChatScreen UI slice",
            "Integration",
            "Wire slices, compile-verify",
            "Log Phase 1 state in plan note",
        ])
    }

    @Test func cycleMalformedParentNeverLoops() {
        // A malformed snapshot: two tasks claiming each other as
        // parent. The walk renders each node once and terminates.
        let malformed = [
            WorkTask(
                id: "a", title: "A", kind: .group, parentTaskID: "b",
                state: .pending, detail: nil, producerOrder: 0),
            WorkTask(
                id: "b", title: "B", kind: .group, parentTaskID: "a",
                state: .pending, detail: nil, producerOrder: 1),
        ]
        let visible = WorkVisibleRows.walk(malformed, collapsedGroupIDs: [])
        #expect(visible.count <= 2)
        #expect(visible.map(\.task.id).count
            == Set(visible.map(\.task.id)).count)
    }

    @Test func missingParentChildrenStillSurfaceAsRoots() {
        // A task whose parentTaskID names nothing real: no guessed
        // position — it is NOT rendered (its position depends on a
        // parent the producer never sent).
        let orphan = WorkTask(
            id: "x", title: "Orphan", kind: .task, parentTaskID: "ghost",
            state: .pending, detail: nil, producerOrder: 0)
        let visible = WorkVisibleRows.walk([orphan], collapsedGroupIDs: [])
        #expect(visible.isEmpty)
    }

    @MainActor @Test func expansionStatePrunesVanishedGroups() {
        let expansion = WorkInspectorExpansion()
        expansion.toggle("gone")
        expansion.prune(validGroupIDs: ["kept"])
        #expect(expansion.isCollapsed("gone") == false)
        #expect(expansion.isCollapsed("kept") == false)
    }
}

// MARK: - State/verdict accessibility names

@Suite
struct WorkInspectorStateNamingTests {
    @Test func everyTaskStateNamesItselfForAccessibility() {
        for state in WorkTaskState.allCases {
            #expect(!state.accessibilityName.isEmpty)
            #expect(!state.iconSystemName.isEmpty)
        }
        // The design's four glyphs: pending square, in-progress
        // dash, completed check, blocked exclamation.
        #expect(WorkTaskState.pending.iconSystemName == "square")
        #expect(WorkTaskState.inProgress.iconSystemName == "minus")
        #expect(WorkTaskState.completed.iconSystemName == "checkmark")
        #expect(WorkTaskState.blocked.iconSystemName == "exclamationmark")
    }

    @Test func everySubagentRuntimeStateAndVerdictNamesItself() {
        for state in WorkSubagentRuntimeState.allCases {
            #expect(!state.accessibilityName.isEmpty)
            #expect(!state.iconSystemName.isEmpty)
        }
        for verdict in WorkResultVerdict.allCases {
            #expect(!verdict.accessibilityName.isEmpty)
        }
        // The design's subagent glyphs: clock/running, check/
        // completed, exclamation/needs input, cross/failed, dash/
        // cancelled, question mark/unknown.
        #expect(WorkSubagentRuntimeState.running.iconSystemName == "clock")
        #expect(WorkSubagentRuntimeState.completed.iconSystemName == "checkmark")
        #expect(WorkSubagentRuntimeState.needsInput.iconSystemName == "exclamationmark.bubble")
        #expect(WorkSubagentRuntimeState.failed.iconSystemName == "xmark")
        #expect(WorkSubagentRuntimeState.cancelled.iconSystemName == "minus")
        #expect(WorkSubagentRuntimeState.unknown.iconSystemName == "questionmark")
    }
}

// MARK: - The real fixture transcript round-trip

@Suite
struct WorkInspectorFixtureTranscriptTests {
    /// The repo's checked-in real omp session (agent-management
    /// fixture) carries one `task` spawn (4 scout children with
    /// structured names) and two `todo` results — the snapshot must
    /// come out with 4 subagents and the LATEST todo state.
    @Test func buildsFromTheRealAgentManagementFixture() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/Transcripts/omp-agent-management.jsonl")
        let raw = try String(contentsOf: url, encoding: .utf8)
        let lines = raw.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
        let (messages, results) = OmpTranscriptParser.parse(lines: lines)
        let snapshot = WorkInspectorSnapshotBuilder.build(from: ChatContent(
            messages: messages, toolResults: results))

        // 4 spawned scouts, in the arguments' order.
        #expect(snapshot.subagents.map(\.displayName) == [
            "DroverInternals", "HeelerInternals",
            "WhipInternals", "MultiplexInternals"])
        #expect(snapshot.subagents.allSatisfy { $0.kind == "scout" })
        // Honest runtime observation for every child.
        #expect(snapshot.subagents.allSatisfy { $0.runtimeState == .unknown })
        #expect(snapshot.subagents.allSatisfy { $0.resultVerdict == nil })

        // The LATEST todo result (7/8 done): leaf totals reflect it,
        // not the earlier 6/8 result.
        #expect(snapshot.taskObservation == .loaded)
        #expect(snapshot.leafProgress.completed == 7)
        #expect(snapshot.leafProgress.total == 8)
    }
}

// MARK: - Broker-observed child runs

/// The live child-run observation's unit pins (the v3 child-run
/// slice). The classification is the omp storage layout observed
/// live: a child run's session file sits INSIDE the parent's .jsonl
/// directory; the broker reports it in sessions.list with no paneId.
/// Registration proves IDENTITY + LIVENESS only — no exit state, no
/// verdict channel — so linking upgrades runtime state to Running
/// and NEVER touches the result verdict.
@Suite
struct WorkChildRunLinkerTests {
    private let parentFile =
        "/sessions/-src/2026-09-19T14-48-58-977Z_01a0ba24.jsonl"

    @Test func directChildOfTheParentClassifiesDirect() {
        // The live-verified shape: .../<parent>.jsonl/<Child>.jsonl.
        let link = WorkChildRunLinker.classify(
            childFile:
                "/sessions/-src/2026-09-19T14-48-58-977Z_01a0ba24.jsonl/AgentChatProduction-1.jsonl",
            parentFile: parentFile)
        #expect(link == .direct)
    }

    @Test func grandchildNestingClassifiesDescendantDepth2() {
        // A grandchild's session file nests one .jsonl directory
        // deeper: .../<parent>.jsonl/<child>.jsonl/<grand>.jsonl.
        // No live sample exists on disk yet — the shape follows the
        // layout's own one-dir-per-generation rule.
        let link = WorkChildRunLinker.classify(
            childFile:
                "/sessions/-src/2026-09-19T14-48-58-977Z_01a0ba24.jsonl/AgentChatProduction-1.jsonl/NestedWorker.jsonl",
            parentFile: parentFile)
        #expect(link == .descendant(depth: 2))
    }

    @Test func unrelatedSessionNeverClassifiesAsAChild() {
        // Another top-level session (a different pane's own file)
        // shares no nesting with the observed parent.
        #expect(WorkChildRunLinker.classify(
            childFile: "/sessions/-src/2026-09-17T04-17-31-715Z_other.jsonl",
            parentFile: parentFile) == .unrelated)
        // The parent itself is never its own child.
        #expect(WorkChildRunLinker.classify(
            childFile: parentFile, parentFile: parentFile) == .unrelated)
        // A non-.jsonl terminal path is not a session file at all.
        #expect(WorkChildRunLinker.classify(
            childFile:
                "/sessions/-src/2026-09-19T14-48-58-977Z_01a0ba24.jsonl/not-a-session.txt",
            parentFile: parentFile) == .unrelated)
        // Empty/malformed paths classify unrelated, never guessed.
        #expect(WorkChildRunLinker.classify(
            childFile: "", parentFile: parentFile) == .unrelated)
        #expect(WorkChildRunLinker.classify(
            childFile: parentFile, parentFile: "") == .unrelated)
    }

    @Test func childrenCollectsOnlyNestedRegistrations() {
        func reg(
            _ id: String, file: String, pane: String? = nil
        ) -> AgentChatRegistration {
            AgentChatRegistration(
                instanceId: id, sessionId: "s-\(id)", generation: 1,
                locator: AgentChatRegistration.Locator(
                    paneId: pane, sessionFile: file))
        }
        let parent = reg("parent", file: parentFile, pane: "w1:pP")
        let child = reg(
            "child",
            file: "/sessions/-src/2026-09-19T14-48-58-977Z_01a0ba24.jsonl/V3SubagentChildRun.jsonl")
        let stranger = reg("stranger", file: "/sessions/other.jsonl")
        let children = WorkChildRunLinker.children(
            of: parentFile, registrations: [parent, child, stranger])
        // The pane's own registration and the unrelated session
        // never enter; the nested child does, in registration order.
        #expect(children.map(\.instanceID) == ["child"])
        #expect(children[0].sessionID == "s-child")
        // A registration without a locator yields nothing.
        let noLocator = AgentChatRegistration(
            instanceId: "nolocator", sessionId: "s-n", generation: 1)
        #expect(WorkChildRunLinker.children(
            of: parentFile, registrations: [noLocator]).isEmpty)
    }
}

@Suite
struct WorkChildRunLinkingTests {
    private let parentFile =
        "/sessions/-src/2026-09-19T14-48-58-977Z_01a0ba24.jsonl"

    private func registration(
        _ id: String, file: String
    ) -> AgentChatRegistration {
        AgentChatRegistration(
            instanceId: id, sessionId: "s-\(id)", generation: 1,
            locator: AgentChatRegistration.Locator(
                paneId: nil, sessionFile: file))
    }

    @Test func liveRegistrationUpgradesSpawnedRowToRunningVerdictUntouched() {
        // The spawn the transcript carries, and the broker's live
        // registration for the SAME name (matched by the session
        // file's base name — the identity the spawn acknowledgment
        // printed).
        let spawn = taskSpawnCall(
            id: "spawn-1", children: [("V3SubagentChildRun", "Do the slice", "task")])
        let transcript = content([
            ChatMessage(role: .assistant, blocks: [.toolCall(spawn)]),
        ])
        var snapshot = WorkInspectorSnapshotBuilder.build(from: transcript)
        snapshot = WorkInspectorSnapshotBuilder.linkChildRuns(
            into: snapshot, parentFile: parentFile,
            registrations: [
                registration(
                    "p", file: parentFile),
                registration(
                    "c",
                    file: "\(parentFile)/V3SubagentChildRun.jsonl"),
            ])

        #expect(snapshot.childRunObservation == .observed)
        let row = snapshot.subagents[0]
        // Registration proves LIVENESS → Running, with the honest
        // live≠accepted note.
        #expect(row.runtimeState == .running)
        #expect(row.observedRun?.instanceID == "c")
        #expect(row.runtimeStateNote == WorkSubagent.liveRegistrationNote)
        // The VERDICT is a separate axis: registration is not
        // acceptance, and the broker carries no verdict channel.
        #expect(row.resultVerdict == nil)
        // The linked child did NOT become a broker-only row.
        #expect(snapshot.observedSubagents.isEmpty)
    }

    @Test func absenceOfARegistrationProvesNothingRowStaysUnknown() {
        // The spawn's child has NO live registration: it may have
        // finished, failed, been cancelled, or never started — the
        // broker cannot say which, so the row stays honestly Unknown.
        let spawn = taskSpawnCall(
            id: "spawn-2", children: [("FinishedChild", "Do work", "scout")])
        let transcript = content([
            ChatMessage(role: .assistant, blocks: [.toolCall(spawn)]),
        ])
        var snapshot = WorkInspectorSnapshotBuilder.build(from: transcript)
        snapshot = WorkInspectorSnapshotBuilder.linkChildRuns(
            into: snapshot, parentFile: parentFile,
            registrations: [registration("p", file: parentFile)])

        #expect(snapshot.childRunObservation == .observed)
        let row = snapshot.subagents[0]
        #expect(row.runtimeState == .unknown)
        #expect(row.observedRun == nil)
        #expect(row.resultVerdict == nil)
        #expect(row.runtimeStateNote == WorkSubagent.transcriptObservationNote)
    }

    @Test func duplicateChildNamesStayDistinctBySpawnCall() {
        // Two spawns carrying the SAME child name: their rows stay
        // distinct (id keyed by spawn call), and the live
        // registration links the name it matches — never merges rows.
        let first = taskSpawnCall(id: "spawn-a", children: [("Researcher", "Task A", "scout")])
        let second = taskSpawnCall(id: "spawn-b", children: [("Researcher", "Task B", "scout")])
        let transcript = content([ChatMessage(role: .assistant, blocks: [
            .toolCall(first), .toolCall(second),
        ])])
        var snapshot = WorkInspectorSnapshotBuilder.build(from: transcript)
        snapshot = WorkInspectorSnapshotBuilder.linkChildRuns(
            into: snapshot, parentFile: parentFile,
            registrations: [
                registration("p", file: parentFile),
                registration(
                    "c",
                    file: "\(parentFile)/Researcher.jsonl"),
            ])

        #expect(snapshot.subagents.count == 2)
        #expect(Set(snapshot.subagents.map(\.id)).count == 2)
        // The live Researcher links BOTH duplicate-name rows (the
        // broker cannot say which spawn it belongs to — a count, not
        // a guess — so both show Running).
        #expect(
            snapshot.subagents.allSatisfy { $0.runtimeState == .running })
        // And the registration was consumed, not duplicated into the
        // broker-only section.
        #expect(snapshot.observedSubagents.isEmpty)
    }

    @Test func brokerOnlyChildGetsItsOwnRowWithHonestAssignment() {
        // A live registration whose name no spawn row carries: the
        // row exists ONLY because the registration proves it, and
        // its assignment is honestly unobservable from the wire.
        var snapshot = WorkInspectorSnapshotBuilder.build(from: content([
            ChatMessage(role: .user, blocks: [.text("hello")]),
        ]))
        snapshot = WorkInspectorSnapshotBuilder.linkChildRuns(
            into: snapshot, parentFile: parentFile,
            registrations: [
                registration("p", file: parentFile),
                registration(
                    "orphan-run",
                    file: "\(parentFile)/QueueSyncResearch.jsonl"),
            ])

        #expect(snapshot.observedSubagents.count == 1)
        #expect(snapshot.observedSubagents[0].displayName == "QueueSyncResearch")
        #expect(snapshot.observedSubagents[0].run.instanceID == "orphan-run")
        // The observed list is registration order, never sorted.
        #expect(snapshot.observedSubagents.map(\.displayName) == ["QueueSyncResearch"])
    }

    @Test func emptyRegistrationListStillMarksTheObservationHonest() {
        // The broker answered but reports nothing nested under this
        // parent: OBSERVED (not claimed empty without asking).
        var snapshot = WorkInspectorSnapshotBuilder.build(from: ChatContent())
        snapshot = WorkInspectorSnapshotBuilder.linkChildRuns(
            into: snapshot, parentFile: parentFile, registrations: [])
        #expect(snapshot.childRunObservation == .observed)
        #expect(snapshot.observedSubagents.isEmpty)
    }

    @Test func baseNameDerivesFromTheSessionFileName() {
        // .../<Child>.jsonl → "Child": the identity the parent's
        // spawn acknowledgment printed.
        #expect(WorkInspectorSnapshotBuilder.baseName(
            of: "\(parentFile)/V3SubagentChildRun.jsonl")
            == "V3SubagentChildRun")
        #expect(WorkInspectorSnapshotBuilder.baseName(
            of: parentFile) == "2026-09-19T14-48-58-977Z_01a0ba24")
        // Non-.jsonl and edge paths return their own base, never a
        // fabricated identity.
        #expect(WorkInspectorSnapshotBuilder.baseName(of: "plain") == "plain")
        #expect(WorkInspectorSnapshotBuilder.baseName(of: "/a/b.txt") == "b.txt")
    }

    @Test func aCompletedChildNeverMarksItsParentTaskDone() {
        // Runtime completion of a child is never proof its parent
        // task is accepted: the todo checklist's own producer-
        // reported state stays authoritative, and a linked child
        // carries NO verdict. (Pin: linking touches ONLY subagent
        // rows — task rows keep their producer states.)
        let todoResult = ToolResult(
            toolCallId: "todo:0", toolName: "todo", isError: false,
            content: realPhasedChecklist)
        let spawn = taskSpawnCall(
            id: "spawn-c", children: [("Integration", "Do the integration", "task")])
        let transcript = content(
            [ChatMessage(role: .assistant, blocks: [
                .toolCall(todoCall(id: "todo:0")),
                .toolCall(spawn),
            ])],
            results: [todoResult])
        var snapshot = WorkInspectorSnapshotBuilder.build(from: transcript)
        snapshot = WorkInspectorSnapshotBuilder.linkChildRuns(
            into: snapshot, parentFile: parentFile,
            registrations: [
                registration("p", file: parentFile),
                registration("c", file: "\(parentFile)/Integration.jsonl"),
            ])
        // The child is Running (live), but the task hierarchy keeps
        // its PRODUCER states untouched: Integration is the checklist
        // producer's ACTIVE phase (reported inProgress — never
        // inferred from child completion or a live child), and the
        // leaf totals keep the producer's own counts.
        #expect(snapshot.childRunObservation == .observed)
        let integration = snapshot.tasks.first {
            $0.kind == .group && $0.title == "Integration"
        }
        #expect(integration?.state == .inProgress)
        #expect(
            snapshot.leafProgress.completed == 6
                && snapshot.leafProgress.inProgress == 1)
    }
}
