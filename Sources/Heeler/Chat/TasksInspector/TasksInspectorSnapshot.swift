import Foundation

// SPDX-License-Identifier: Apache-2.0
//
// The work inspector's SNAPSHOT: one projection of a loaded
// transcript (ChatContent) into the Tasks tab's rows. Pure and
// total — the caller hands it the chat's messages + tool results
// (the same ChatContent the chat surface renders; both the broker
// path and the demo route build it), and it derives:
//
//   - the task hierarchy from the LATEST todo tool result (the
//     producer's freshest rendered checklist — a todo list is a
//     single evolving document; each `todo` op's result is its full
//     newest state, so earlier results are superseded snapshots of
//     the same list, never additional rows).
//   - the subagent identity rows from every `task` spawn call, in
//     producer order (each spawn is a NEW batch of children).
//
// Producer order: rows keep the transcript's own order — tasks in
// the checklist render order, subagents in spawn order (children of
// one spawn in the arguments' array order). No arrival-time
// sorting, no alphabetical fallback.

/// The Tasks tab's full observation of one conversation.
struct WorkInspectorSnapshot: Sendable, Equatable {
    /// The task hierarchy in producer order (depth-first: a phase
    /// row, then its items, then the next phase). Empty when the
    /// conversation carries no todo result yet.
    var tasks: [WorkTask] = []
    /// Why the task list looks the way it does — the honest
    /// queried-empty vs not-loaded vs unsupported distinction.
    var taskObservation: Observation = .notLoaded
    /// Spawned subagent rows in producer order.
    var subagents: [WorkSubagent] = []
    /// The subagent observation state.
    var subagentObservation: Observation = .notLoaded

    enum Observation: Sendable, Equatable {
        /// No transcript was consulted yet.
        case notLoaded
        /// The transcript carries no todo result / no task call —
        /// the producer truly has nothing.
        case empty
        /// The latest todo result parsed into the hierarchy.
        case loaded
        /// The latest todo result is not the checklist render — the
        /// reason names what was seen. The task list stays empty
        /// (honest) rather than guessed.
        case unsupported(reason: String)
    }

    /// Leaf-only progress: counts LEAF tasks only (design: "Progress
    /// summaries count leaf tasks explicitly to avoid counting both
    /// parent and children"). Group rows never enter the count.
    var leafProgress: LeafProgress {
        let leaves = tasks.filter { $0.kind == .task }
        return LeafProgress(
            completed: leaves.filter { $0.state == .completed }.count,
            blocked: leaves.filter { $0.state == .blocked }.count,
            inProgress: leaves.filter { $0.state == .inProgress }.count,
            pending: leaves.filter { $0.state == .pending }.count,
            unknown: leaves.filter { $0.state == .unknown }.count,
            total: leaves.count)
    }

    struct LeafProgress: Sendable, Equatable {
        var completed: Int
        var blocked: Int
        var inProgress: Int
        var pending: Int
        var unknown: Int
        var total: Int

        /// The summary line, e.g. "3 of 8 completed · 2 blocked".
        /// Only leaf states ever appear (no double counting).
        var summaryLine: String {
            guard total > 0 else { return "No tasks" }
            var parts = ["\(completed) of \(total) completed"]
            if blocked > 0 { parts.append("\(blocked) blocked") }
            if inProgress > 0 { parts.append("\(inProgress) in progress") }
            return parts.joined(separator: " · ")
        }
    }
}

/// The pure projection from a chat's transcript records to the
/// work-inspector snapshot. Callers hand it the SAME ChatContent
/// the chat surface renders (messages + standalone tool results);
/// the builder pairs `task` spawn calls to their results by the
/// opaque toolCallId (matched, never parsed).
enum WorkInspectorSnapshotBuilder: Sendable {
    /// Builds the snapshot from one chat's content. Total: an empty
    /// content yields `.notLoaded` (nothing was consulted), content
    /// without todo/task records yields `.empty`.
    static func build(from content: ChatContent) -> WorkInspectorSnapshot {
        var snapshot = WorkInspectorSnapshot()

        // Pair results to calls once (result pairing by opaque id).
        let resultsByCallID = Dictionary(
            content.toolResults.map { ($0.toolCallId, $0) },
            uniquingKeysWith: { first, _ in first })

        // Walk messages in transcript order; collect todo results
        // and task spawn calls in producer order.
        var latestTodoResult: ToolResult?
        var spawnCalls: [(call: ToolCall, result: ToolResult?)] = []

        for message in content.messages {
            for block in message.blocks {
                guard case .toolCall(let call) = block else { continue }
                switch call.name {
                case "todo":
                    // The freshest todo result in TRANSCRIPT ORDER is
                    // the latest full state of the single evolving
                    // list (matched by pairing, so the latest call
                    // seen is the latest state).
                    if let result = resultsByCallID[call.id] {
                        latestTodoResult = result
                    }
                case "task":
                    spawnCalls.append(
                        (call, resultsByCallID[call.id]))
                default:
                    continue
                }
            }
        }

        // Tasks: the latest todo result only — earlier results are
        // superseded snapshots of the SAME list, never extra rows.
        if let todoResult = latestTodoResult {
            switch TodoChecklistParser.parse(
                resultContent: todoResult.content, callID: todoResult.toolCallId)
            {
            case .rows(let rows):
                snapshot.tasks = rows
                snapshot.taskObservation = .loaded
            case .cleared:
                snapshot.taskObservation = .empty
            case .unrecognized(let reason):
                snapshot.taskObservation = .unsupported(reason: reason)
            }
        } else if !content.messages.isEmpty {
            // A transcript was consulted and carries no todo record.
            snapshot.taskObservation = .empty
        }

        // Subagents: every spawn call in producer order, children of
        // one spawn in the arguments' array order.
        for (call, result) in spawnCalls {
            for child in childDescriptors(of: call) {
                snapshot.subagents.append(WorkSubagent(
                    id: "task@\(call.id)#\(child.name)",
                    displayName: child.name,
                    assignedWork: child.work,
                    kind: child.kind,
                    // Runtime state and verdict are NOT observable
                    // from the transcript — the honest unsupported
                    // state, never scraped from `hub` prose.
                    runtimeState: .unknown,
                    runtimeStateNote: WorkSubagent.transcriptObservationNote,
                    resultVerdict: nil,
                    spawnAcknowledged: result != nil))
            }
        }
        if snapshot.subagents.isEmpty, !content.messages.isEmpty {
            snapshot.subagentObservation = .empty
        } else if !snapshot.subagents.isEmpty {
            snapshot.subagentObservation = .loaded
        }

        return snapshot
    }

    /// The spawn call's structured children: `tasks:[{name, task,
    /// agent}]`. A spawn without the structured array carries no
    /// observable child identity and yields nothing (no fabricated
    /// rows from prose).
    private static func childDescriptors(
        of call: ToolCall
    ) -> [(name: String, work: String, kind: String)] {
        guard case .array(let items)? = call.arguments["tasks"] else {
            return []
        }
        return items.compactMap { item in
            guard let name = item["name"]?.stringValue,
                let work = item["task"]?.stringValue
            else { return nil }
            let kind = item["agent"]?.stringValue ?? "task"
            return (name, work, kind)
        }
    }
}
