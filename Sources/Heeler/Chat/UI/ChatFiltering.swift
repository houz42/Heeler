import Foundation

// SPDX-License-Identifier: Apache-2.0
//
// Pure detail-level logic for the chat surface. Everything about what is
// visible at L0–L3 lives here; the SwiftUI rows stay dumb and style whatever
// `ChatFiltering` hands them.

/// A blocked-agent question the user must answer before the run can continue.
/// Rendered as the raw question text plus one tappable button per option; an
/// empty `options` list renders the question alone (free-text answers go
/// through the composer, not this row).
internal struct PendingInteraction: Sendable, Equatable, Identifiable {
    let id: String
    let question: String
    let options: [String]

    init(id: String = UUID().uuidString, question: String, options: [String]) {
        self.id = id
        self.question = question
        self.options = options
    }
}

/// One renderable row of the chat surface, in display order.
///
/// Rows are block-scoped: a message's ordered blocks become one row per
/// visible block, so an assistant turn renders as its original sequence
/// (thinking, tool call, text) rather than one fused blob. Row ids are
/// `message-uuid#block-index` — stable across detail-level changes, which is
/// what makes level switching monotonic (each level only adds rows, never
/// re-keys existing ones).
internal enum ChatRow: Sendable, Equatable, Identifiable {
    /// A `ChatBlock.text` payload: user text, assistant text, or (at L2+) the
    /// flattened text of a record-carried `toolResult`/`bashExecution`
    /// message.
    case text(messageID: UUID, blockIndex: Int, role: ChatRole, text: String)
    /// An assistant `ChatBlock.thinking` payload — L3+, collapsed by default.
    case thinking(messageID: UUID, blockIndex: Int, text: String)
    /// An assistant `ChatBlock.toolCall` — at the tool's visibility level:
    /// L1 for ordinary tools; todo checklists ride L2 (they are rendered
    /// results), subagent (`task`) spawns ride L3 (they are agent
    /// internals, alongside thinking). `result` is the `toolCallId`-paired
    /// result attached at L2+; nil at L1 and for still-running calls at L2+
    /// (spinner state).
    case toolCall(messageID: UUID, blockIndex: Int, call: ToolCall, result: ToolResult?)
    /// A result whose tool call is outside the visible message window
    /// (window-boundary orphan), so it has no row to pair into — L2+.
    case orphanResult(ToolResult)
    /// A blocked-agent pending question — visible at every level; it is the
    /// live frontier of the conversation, not chrome.
    case pending(PendingInteraction)

    var id: String {
        switch self {
        case .text(let messageID, let blockIndex, _, _),
             .thinking(let messageID, let blockIndex, _),
             .toolCall(let messageID, let blockIndex, _, _):
            return "\(messageID.uuidString)#\(blockIndex)"
        case .orphanResult(let result):
            return "result#\(result.toolCallId)"
        case .pending(let interaction):
            return "pending#\(interaction.id)"
        }
    }
}

/// One chat bubble: a run of consecutive visible `.text` rows that all
/// belong to a single user/assistant message. Bubbles are the message-
/// scoped unit the per-bubble affordances (quick reactions, Quote) hang
/// off — keyed by the message, not the block. Chrome rows (thinking, tool
/// calls, results) break runs and never enter a bubble.
internal struct ChatBubble: Sendable, Equatable, Identifiable {
    /// The first row's id (`messageID#blockIndex`) — stable for the run,
    /// distinct per bubble, and a valid scroll anchor.
    let id: String
    /// The message the bubble renders (conversation identity).
    let messageID: UUID
    /// `.user` or `.assistant` — output records never bubble.
    let role: ChatRole
    /// The bubble's `.text` rows, in display order.
    let rows: [ChatRow]

    /// The bubble's quote payload: its texts joined with a blank line.
    var text: String {
        rows.compactMap { row -> String? in
            guard case .text(_, _, _, let text) = row else { return nil }
            return text
        }.joined(separator: "\n\n")
    }
}

/// What the transcript renders: bubbles for conversation text, plain rows
/// for everything else. Ordering is the row order; bubbles only replace
/// the consecutive `.text` runs they were built from.
internal enum ChatTranscriptItem: Sendable, Equatable, Identifiable {
    case bubble(ChatBubble)
    case row(ChatRow)

    var id: String {
        switch self {
        case .bubble(let bubble): bubble.id
        case .row(let row): row.id
        }
    }
}

extension DetailLevel: Comparable {
    static func < (lhs: DetailLevel, rhs: DetailLevel) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

/// The single source of truth for what the chat surface shows at each detail
/// level. Levels nest: every level is the previous one plus more row kinds,
/// so switching levels only ever adds rows (row ids are stable), and SwiftUI
/// diffs the transition without reflowing what was already on screen.
internal enum ChatFiltering {
    /// The contract's core signature: messages + tool results + level → rows.
    static func visibleRows(
        messages: [ChatMessage],
        toolResults: [ToolResult],
        level: DetailLevel
    ) -> [ChatRow] {
        visibleRows(messages: messages, toolResults: toolResults, pending: [], level: level)
    }

    /// Full form, including the blocked-agent affordance rows. Pending
    /// interactions render at every level, after all transcript rows — they
    /// are the conversation's live edge, not chrome to be filtered.
    static func visibleRows(
        messages: [ChatMessage],
        toolResults: [ToolResult],
        pending: [PendingInteraction],
        level: DetailLevel
    ) -> [ChatRow] {
        // Pair results by the opaque id. First record wins if a call somehow
        // produced duplicate results — deterministic either way.
        var resultsByCall = [String: ToolResult]()
        for result in toolResults where resultsByCall[result.toolCallId] == nil {
            resultsByCall[result.toolCallId] = result
        }
        // Which ids exist as calls in the visible messages. Classified
        // independently of level so a result does not flip orphan/non-orphan
        // when the level changes — only whether orphans render does.
        var visibleCallIDs = Set<String>()
        for message in messages {
            for block in message.blocks {
                if case .toolCall(let call) = block { visibleCallIDs.insert(call.id) }
            }
        }

        var rows: [ChatRow] = []
        for message in messages {
            switch message.role {
            case .user:
                // User turns are conversation, not chrome: their text is
                // visible at every level. Non-text blocks in a user message
                // (not produced by the parser) are dropped.
                for (index, block) in message.blocks.enumerated() {
                    if case .text(let text) = block {
                        rows.append(.text(messageID: message.id, blockIndex: index, role: .user, text: text))
                    }
                }

            case .assistant:
                for (index, block) in message.blocks.enumerated() {
                    switch block {
                    case .text(let text):
                        rows.append(.text(messageID: message.id, blockIndex: index, role: .assistant, text: text))
                    case .thinking(let text) where level >= .l3:
                        rows.append(.thinking(messageID: message.id, blockIndex: index, text: text))
                    case .toolCall(let call) where level >= Self.visibilityLevel(for: call):
                        // The result only pairs in at L2; L1 is the
                        // name-only line.
                        let result = level >= .l2 ? resultsByCall[call.id] : nil
                        rows.append(.toolCall(messageID: message.id, blockIndex: index, call: call, result: result))
                    case .thinking, .toolCall:
                        break  // below its level
                    }
                }

            case .toolResult, .bashExecution:
                // Record-carried results. bashExecution is user-driven shell
                // output — conversation, all levels. toolResult records are
                // tool output — chrome, L2+ with the other tool results.
                let visible = message.role == .bashExecution || level >= .l2
                if visible {
                    for (index, block) in message.blocks.enumerated() {
                        if case .text(let text) = block {
                            rows.append(.text(messageID: message.id, blockIndex: index, role: message.role, text: text))
                        }
                    }
                }
            }
        }

        // Window-boundary orphans: results whose call is not among the
        // visible messages, after the transcript so they never interleave
        // into a turn they don't belong to. Floored at L2 (a result body
        // is result chrome like any other) AND the call's name-based level —
        // a `task` result never surfaces before its call's level would.
        for result in toolResults
        where !visibleCallIDs.contains(result.toolCallId)
            && level >= .l2
            && level >= Self.visibilityLevel(toolName: result.toolName) {
            rows.append(.orphanResult(result))
        }

        rows.append(contentsOf: pending.map(ChatRow.pending))
        return rows
    }

    /// The detail level at which a tool call becomes visible. Ordinary tools
    /// are L1 (names) as before; `todo` checklists and `task` (subagent
    /// spawn) blocks are agent self-management — folded into the existing
    /// levels instead of new toggle buttons. Evidence from real omp
    /// sessions: both arrive as ordinary toolCall/toolResult records, so no
    /// parser change is needed — only the visibility mapping differs:
    ///   - `todo` rides L2 "Results": its result record is the rendered
    ///     checklist, which is what L2 is for.
    ///   - `task` rides L3 "Thinking": subagent activity is agent
    ///     internals, same shelf as the agent's own thinking.
    /// Level nesting is preserved: L3 ⊇ L2 ⊇ L1 ⊇ L0.
    static func visibilityLevel(for call: ToolCall) -> DetailLevel {
        visibilityLevel(toolName: call.name)
    }

    /// Tool-name form (also gates orphaned results, which carry no call
    /// object — the call sites floor it at L2 themselves).
    static func visibilityLevel(toolName: String) -> DetailLevel {
        switch toolName {
        case "task":
            return .l3
        case "todo":
            return .l2
        default:
            return .l1
        }
    }

    /// The bubble-grouped form of `visibleRows`: consecutive `.text` rows
    /// of one user/assistant message collapse into a `ChatBubble`; every
    /// other row passes through in place. Runs are keyed by message, so
    /// two adjacent messages never merge and a message interleaved with
    /// visible chrome (a tool call between two texts) yields one bubble
    /// per contiguous run. The item ids are the underlying row ids (a
    /// bubble takes its first row's), so level switching stays monotonic
    /// in the item list exactly as it is in the row list.
    static func visibleItems(from rows: [ChatRow]) -> [ChatTranscriptItem] {
        var items: [ChatTranscriptItem] = []
        var run: [ChatRow] = []

        func flush() {
            // The loop only ever buffers user/assistant `.text` rows
            // (everything else appends directly), so the run is always
            // a bubble.
            guard case .text(let messageID, _, let role, _)? = run.first
            else { return }
            items.append(.bubble(ChatBubble(
                id: run[0].id, messageID: messageID, role: role, rows: run)))
            run = []
        }

        for row in rows {
            if case .text(let messageID, _, let role, _) = row,
                role == .user || role == .assistant,
                let previous = run.last,
                case .text(let lastID, _, let lastRole, _) = previous,
                lastID == messageID, lastRole == role
            {
                run.append(row)
            } else {
                flush()
                if case .text(_, _, let role, _) = row,
                    role == .user || role == .assistant
                {
                    run = [row]
                } else {
                    items.append(.row(row))
                }
            }
        }
        flush()
        return items
    }
}
