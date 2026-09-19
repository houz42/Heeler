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
    /// One tappable answer choice. omp's `ask` tool carries label +
    /// description pairs plus a `recommended` index; the terminal dialog
    /// highlights `recommended` and selects with ↑/↓ + Enter, so answers
    /// are delivered as a key sequence against that highlight (verified
    /// against a live blocked agent).
    struct Option: Sendable, Equatable {
        let label: String
        var description: String? = nil
        /// The option's index in the dialog's list — the `down` count the
        /// answer must send (relative to `recommended`).
        var index: Int = 0

        init(label: String, description: String? = nil, index: Int = 0) {
            self.label = label
            self.description = description
            self.index = index
        }
    }

    let id: String
    /// The `ask` toolCall's opaque id — the pairing key that anchors the
    /// card INLINE at the call's transcript position (call ids contain
    /// `|`/`#`, so it is carried separately, never parsed out of `id`).
    let callID: String
    let question: String
    let options: [Option]
    /// The option the terminal dialog highlights when the question lands
    /// (omp's `recommended`); answers key off it.
    let recommendedIndex: Int
    /// The chosen option's label once answered; nil while the question
    /// blocks the run. The transcript's own answer (the `ask` result
    /// record) is set by the parser; a locally made choice lives in
    /// `PendingAnswerDelivery` until that record lands.
    var answer: String?

    init(
        id: String = UUID().uuidString,
        callID: String = "",
        question: String,
        options: [Option],
        recommendedIndex: Int = 0,
        answer: String? = nil
    ) {
        self.id = id
        self.callID = callID
        self.question = question
        self.options = options
        self.recommendedIndex = recommendedIndex
        self.answer = answer
    }

    /// The key sequence that selects `option` in the terminal dialog from
    /// the highlighted `recommendedIndex`: `down` once per step below the
    /// highlight, then `enter`. (A `down` count of zero is just `enter`.)
    /// The dialog opens highlighting `recommended`; the card answers
    /// immediately on tap, so the highlight has not moved.
    func selectionKeys(for option: Option) -> [String] {
        let steps = option.index - recommendedIndex
        if steps <= 0 { return ["enter"] }
        return Array(repeating: "down", count: steps) + ["enter"]
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
    /// interactions render at every level, INLINE at their ask call's
    /// transcript position (a question is part of the turn that asked it,
    /// answered or not); pendings whose call is outside the visible
    /// window fall to the tail as the live edge.
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
        // Pending interactions indexed by their ask call's id: the card
        // renders INLINE at the call's transcript position (a question is
        // part of the turn that asked it, answered or not — verified on
        // device: bottom-appended cards detach from their conversation).
        // Multiple questions from one call keep their wire order.
        var pendingByCall: [String: [PendingInteraction]] = [:]
        for interaction in pending {
            pendingByCall[interaction.callID, default: []].append(interaction)
        }
        var emittedPending = Set<String>()

        // Which ids exist as calls in the visible messages. Classified
        // independently of level so a result does not flip orphan/non-orphan
        // when the level changes — only whether orphans render does.
        var visibleCallIDs = Set<String>()
        for message in messages {
            for block in message.blocks {
                if case .toolCall(let call) = block { visibleCallIDs.insert(call.id) }
            }
        }

        /// Emits the interactions paired to `callID`, in wire order.
        func pendingRows(for callID: String) -> [ChatRow] {
            guard let interactions = pendingByCall[callID] else { return [] }
            emittedPending.formUnion(interactions.map(\.id))
            return interactions.map(ChatRow.pending)
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
                        // The ask call's question card rides at the call's
                        // position — visible at every level, right after the
                        // call row it belongs to, whether answered or not.
                        rows.append(contentsOf: pendingRows(for: call.id))
                    case .thinking, .toolCall:
                        // Below the call's level the row is hidden — but an
                        // `ask` card is never filtered: emit its card at
                        // this block's position anyway (pending renders at
                        // every level; only the collapsed tool-call chrome
                        // is level-gated).
                        if case .toolCall(let call) = block,
                            !(pendingByCall[call.id] ?? []).isEmpty
                        {
                            rows.append(contentsOf: pendingRows(for: call.id))
                        }
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

        // Stray pendings whose call is outside the visible window (or built
        // by hand in previews) keep the old tail placement — the live edge,
        // after everything rendered.
        rows.append(
            contentsOf: pending
                .filter { !emittedPending.contains($0.id) }
                .map(ChatRow.pending))
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
}
