import Foundation

// SPDX-License-Identifier: Apache-2.0
//
// The v3 work inspector's DATA MAPPING (design doc: 'Tasks and
// subagents — UI first, protocol second'). READ-ONLY observation of
// what the loaded transcript can actually prove; everything else is
// explicitly marked unsupported — no guessed pane mapping, no scraped
// terminal status, no fabricated hierarchy.
//
// What the app CAN observe today (verified against real omp session
// transcripts — a census of 180 live `todo` tool results):
//
//   - `todo` tool results: the todo tool's own RENDERED checklist, a
//     stable producer format (179/180 results share it exactly):
//
//         Remaining items (N):
//           - Open item [in_progress] (Phase)
//         Overall: X/Y done, Z open.
//         Active phase N/M "Name" (x/y).
//           Phase One:
//             - [X] Completed item
//             - [ ] Open item (in progress)
//             - [ ] Blocked item (blocked: reason)
//
//     The phase sections after the "Active phase" line are the
//     authoritative full hierarchy; the "Remaining items" block
//     DUPLICATES open items and is never part of it (else leaves
//     would double count). States observed in the wild: [X] →
//     completed, "(in progress)" → in progress, "(blocked: …)" →
//     blocked, bare "[ ]" → pending.
//
//   - `task` tool calls + their paired results: STRUCTURED spawn
//     facts. The call's arguments carry {i, tasks:[{name, task,
//     agent}]} and the paired result is the spawn acknowledgment. A
//     task tool-call ID is NOT a child-run identity: the transcript
//     carries no live child-run channel (the design's proposed
//     work.snapshot contract is not implemented by the broker yet),
//     so a spawned row's runtime state stays honestly Unknown and
//     its result verdict Not reported — NEVER scraped from the
//     `hub` prose the agent may print later.
//
// Stable IDs: the producer's rendered checklist carries no durable
// task IDs (the proposed protocol adds them), so a row's ID is scoped
// to the producing tool result (callID + structural position) —
// position-keyed, never title-keyed, so content edits cannot re-key
// rows within one snapshot. Different todo results carry different
// ID scopes, by design.

// MARK: - Task states

/// One task row's producer-reported state. Only what the producer
/// actually reported — never inferred from child completion, never
/// from a client timer. `unknown` renders with the question-mark
/// glyph and a safe detail line.
enum WorkTaskState: String, Sendable, Equatable, CaseIterable {
    case pending
    case inProgress = "in_progress"
    case blocked
    case completed
    case cancelled
    case unknown

    /// The accessible state NAME (design: "Accessible labels and
    /// task details still name the state") — the LEFT icon is the
    /// only visible state carrier; this string rides the a11y label
    /// and the detail sheet.
    var accessibilityName: String {
        switch self {
        case .pending: "Pending"
        case .inProgress: "In progress"
        case .blocked: "Blocked"
        case .completed: "Completed"
        case .cancelled: "Cancelled"
        case .unknown: "Unknown"
        }
    }

    /// The left-icon glyph (design: pending square, in-progress
    /// dash, completed check, blocked exclamation; unknown renders
    /// the question mark with safe detail).
    var iconSystemName: String {
        switch self {
        case .pending: "square"
        case .inProgress: "minus"
        case .blocked: "exclamationmark"
        case .completed: "checkmark"
        case .cancelled: "xmark"
        case .unknown: "questionmark"
        }
    }
}

/// A node's kind in the task hierarchy (the proposed contract's
/// `group|task`): phases are collapsible groups; tasks are leaves.
enum WorkNodeKind: String, Sendable, Equatable {
    case group
    case task
}

/// One row of the task hierarchy. Groups (phases) may collapse;
/// tasks are leaves. Parent state is producer-reported only — the
/// todo render never marks a phase, so a non-active phase keeps
/// `unknown` even when every leaf under it is completed.
struct WorkTask: Identifiable, Sendable, Equatable {
    /// Stable within the producing todo result (callID + structural
    /// position). Never the title, never a UUID per render.
    let id: String
    let title: String
    let kind: WorkNodeKind
    var parentTaskID: String?
    var state: WorkTaskState
    /// Producer-supplied detail — today the blocked reason.
    var detail: String?
    /// Position in the producer's own depth-first render order.
    var producerOrder: Int
}

// MARK: - Subagent identity + verdict

/// A spawned child's RUNTIME state — a separate axis from the result
/// verdict. The transcript proves none of these today, so production
/// rows are always `.unknown` with the unsupported note; the enum is
/// the full contract the proposed `work.snapshot` will fill.
enum WorkSubagentRuntimeState: String, Sendable, Equatable, CaseIterable {
    case starting
    case running
    case needsInput = "needs_input"
    case completed
    case failed
    case cancelled
    case unknown

    var accessibilityName: String {
        switch self {
        case .starting: "Starting"
        case .running: "Running"
        case .needsInput: "Needs input"
        case .completed: "Completed"
        case .failed: "Failed"
        case .cancelled: "Cancelled"
        case .unknown: "Unknown"
        }
    }

    /// The left rounded-icon glyph (design: clock/running,
    /// check/completed, exclamation/needs input, cross/failed,
    /// dash/cancelled, question mark/unknown).
    var iconSystemName: String {
        switch self {
        case .starting: "hourglass"
        case .running: "clock"
        case .needsInput: "exclamationmark.bubble"
        case .completed: "checkmark"
        case .failed: "xmark"
        case .cancelled: "minus"
        case .unknown: "questionmark"
        }
    }
}

/// A spawned child's RESULT VERDICT — what the producer reported
/// about the child's yielded result. Runtime completion and result
/// acceptance are DIFFERENT fields: a subagent exiting is not proof
/// its task is accepted.
enum WorkResultVerdict: String, Sendable, Equatable, CaseIterable {
    case accepted
    case rejected
    case unverified

    var accessibilityName: String {
        switch self {
        case .accepted: "Accepted"
        case .rejected: "Rejected"
        case .unverified: "Unverified"
        }
    }
}

/// One spawned child — a distinct compact two-line identity row:
/// display name + assigned work. Identity comes from the spawn
/// call's STRUCTURED arguments; the tool-call ID only namespaces
/// the row (a task tool-call ID is NOT the child-run identity).
struct WorkSubagent: Identifiable, Sendable, Equatable {
    /// `task@<spawn callID>#<child name>` — stable within the
    /// conversation; two spawns by different calls never collide even
    /// with identical child names.
    let id: String
    let displayName: String
    /// The assignment text from the spawn's structured arguments.
    let assignedWork: String
    /// The spawn's declared agent kind ("scout", …); "task" when the
    /// producer did not declare one.
    let kind: String
    /// RUNTIME state — honestly `.unknown` from transcripts, with
    /// `runtimeStateNote` naming why.
    var runtimeState: WorkSubagentRuntimeState
    var runtimeStateNote: String?
    /// RESULT VERDICT — a separate axis from runtime state; nil means
    /// the producer reported no verdict (renders "Not reported",
    /// never "Accepted").
    var resultVerdict: WorkResultVerdict?
    /// The paired spawn result arrived (the producer acknowledged
    /// the spawn); false = still unacknowledged in this transcript.
    var spawnAcknowledged: Bool

    /// The honest unsupported note for transcript-derived rows: the
    /// transcript carries no live child-run channel, so runtime
    /// state and verdict are what IS knowable — nothing. NEVER
    /// scraped from `hub` prose (a model tool call is not a
    /// child-run observation).
    static let transcriptObservationNote =
        "Live child-run state isn't observable from the transcript — the agent reports spawns here, not running children."
}

// MARK: - The checklist parser

/// Parses the todo tool's rendered checklist (the producer's own
/// output — the todo tool prints this exact format) into the
/// hierarchy. Structural and line-oriented: the phase sections after
/// the "Active phase" line are authoritative; the "Remaining items"
/// block is a duplicate summary and never parsed (leaves would
/// double count). An unrecognised format is reported as such —
/// never guessed at.
enum TodoChecklistParser: Sendable {
    enum Outcome: Sendable, Equatable {
        /// Phases + items in producer order (depth-first, phases in
        /// declaration order, items in phase order).
        case rows([WorkTask])
        /// The producer cleared the list — a valid, EMPTY snapshot.
        case cleared
        /// The result is not the checklist render; the reason names
        /// what was seen instead.
        case unrecognized(reason: String)
    }

    /// Parses one `todo` tool result body. `callID` scopes the row
    /// IDs (same body + same call → same IDs; different call →
    /// different scope).
    static func parse(resultContent: String, callID: String) -> Outcome {
        let lines = resultContent
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }

        // The cleared list is its own valid, empty snapshot.
        if lines.filter({ !$0.isEmpty }) == ["Todo list cleared."] {
            return .cleared
        }

        // The full checklist section always follows the "Active
        // phase" line (census of 179 real results). Its absence
        // means the render is not the known format.
        guard lines.contains(where: { $0.hasPrefix("Active phase ") }) else {
            return .unrecognized(
                reason: "The todo result did not carry the rendered checklist (no \"Active phase\" section).")
        }

        var activePhaseName: String?
        var sawActiveLine = false
        var rows: [WorkTask] = []
        var phaseIndex = -1
        var itemIndexInPhase = 0
        var order = 0

        for line in lines {
            if line.hasPrefix("Active phase ") {
                // Active phase 3/3 "Integration" (0/2).
                if let open = line.firstIndex(of: "\""),
                    let close = line.lastIndex(of: "\""), open < close
                {
                    activePhaseName = String(
                        line[line.index(after: open)..<close])
                }
                sawActiveLine = true
                continue
            }
            // Phases only count inside the authoritative section.
            guard sawActiveLine else { continue }

            if let phase = phaseHeader(line) {
                phaseIndex += 1
                itemIndexInPhase = 0
                rows.append(WorkTask(
                    id: "todo@\(callID)#g\(phaseIndex)",
                    title: phase,
                    kind: .group,
                    parentTaskID: nil,
                    // Producer-reported only: the render marks the
                    // ACTIVE phase; every other phase keeps unknown
                    // even when all its leaves are done.
                    state: .unknown,
                    detail: nil,
                    producerOrder: order))
                order += 1
                continue
            }
            if let item = item(
                line, callID: callID, phaseIndex: phaseIndex,
                itemIndex: itemIndexInPhase, producerOrder: order)
            {
                rows.append(item)
                itemIndexInPhase += 1
                order += 1
            }
        }

        guard !rows.isEmpty else {
            return .unrecognized(
                reason: "The todo result's checklist section carried no phases or items.")
        }
        // The active phase is producer-reported state — apply it
        // after the walk (the name line precedes the sections).
        if let activePhaseName {
            for index in rows.indices
            where rows[index].kind == .group && rows[index].title == activePhaseName {
                rows[index].state = .inProgress
            }
        }
        return .rows(rows)
    }

    /// A phase header: exactly-two-space indent in the source, a
    /// bare name ending in ':' — never a checklist item.
    private static func phaseHeader(_ line: String) -> String? {
        guard line.hasSuffix(":") else { return nil }
        let name = String(line.dropLast())
        guard !name.isEmpty, !name.hasPrefix("- ") else { return nil }
        return name
    }

    /// A checklist item: `- [X]`/`- [ ]` plus the title, with the
    /// producer's state suffixes.
    private static func item(
        _ line: String, callID: String, phaseIndex: Int,
        itemIndex: Int, producerOrder: Int
    ) -> WorkTask? {
        guard line.hasPrefix("- [") else { return nil }
        let chars = Array(line)
        // "- [X] title" / "- [ ] title": 6 characters minimum.
        guard chars.count >= 6, chars[2] == "[",
            chars[3] == "X" || chars[3] == " ", chars[4] == "]"
        else { return nil }
        let body = String(chars[6...])

        let parent = phaseIndex >= 0 ? "todo@\(callID)#g\(phaseIndex)" : nil
        let id = parent.map { "\($0)#i\(itemIndex)" }
            ?? "todo@\(callID)#i\(itemIndex)"

        if chars[3] == "X" {
            return WorkTask(
                id: id, title: body, kind: .task, parentTaskID: parent,
                state: .completed, detail: nil, producerOrder: producerOrder)
        }
        if body.hasSuffix("(in progress)") {
            return WorkTask(
                id: id,
                title: String(body.dropLast("(in progress)".count))
                    .trimmingCharacters(in: .whitespaces),
                kind: .task, parentTaskID: parent,
                state: .inProgress, detail: nil, producerOrder: producerOrder)
        }
        if body.hasSuffix(")"), let open = body.range(of: "(blocked:") {
            let reason = String(
                body[open.upperBound..<body.index(before: body.endIndex)])
                .trimmingCharacters(in: .whitespaces)
            return WorkTask(
                id: id,
                title: String(body[..<open.lowerBound])
                    .trimmingCharacters(in: .whitespaces),
                kind: .task, parentTaskID: parent,
                state: .blocked, detail: reason, producerOrder: producerOrder)
        }
        return WorkTask(
            id: id, title: body, kind: .task, parentTaskID: parent,
            state: .pending, detail: nil, producerOrder: producerOrder)
    }
}
