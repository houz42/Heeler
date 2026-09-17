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
    /// An assistant `ChatBlock.toolCall` — L1+. `result` is the
    /// `toolCallId`-paired result attached at L2+; nil at L1 and for
    /// still-running calls at L2+ (spinner state).
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
                    case .toolCall(let call) where level >= .l1:
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
        // visible messages. L2+, after the transcript so they never
        // interleave into a turn they don't belong to.
        if level >= .l2 {
            for result in toolResults where !visibleCallIDs.contains(result.toolCallId) {
                rows.append(.orphanResult(result))
            }
        }

        rows.append(contentsOf: pending.map(ChatRow.pending))
        return rows
    }
}
