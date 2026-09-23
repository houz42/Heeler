import Foundation

// SPDX-License-Identifier: Apache-2.0
//
// Pure detail-level logic for the chat surface. Everything about what is
// visible at L0–L3 lives here; the SwiftUI rows stay dumb and style whatever
// `ChatFiltering` hands them.

/// One question of a pending ask, with the option IDs the answer
/// payload needs (single-question demos synthesize index ids).
/// The unanswered card's input shape: options, multi-select, and
/// whether the producer permits custom ("Other") text — the same
/// card family the answered record renders from (v3 Q/A card).
internal struct PendingAskQuestion: Sendable, Equatable, Identifiable {
    struct Option: Sendable, Equatable, Identifiable {
        let id: String
        let label: String
    }
    let id: String
    let text: String
    var multi: Bool = false
    var options: [Option] = []
    /// The producer permits a custom ("Other") free-text answer for
    /// this question; the card reveals the text input only when true.
    var allowCustom: Bool = false

    init(
        id: String, text: String, multi: Bool = false,
        options: [Option] = [], allowCustom: Bool = false
    ) {
        self.id = id
        self.text = text
        self.multi = multi
        self.options = options
        self.allowCustom = allowCustom
    }
}

internal struct PendingInteraction: Sendable, Equatable, Identifiable {
    let id: String
    let question: String
    let options: [String]
    /// The full ask structure (multi-question first-class); empty for
    /// legacy single-question fixtures, which synthesize it.
    var questions: [PendingAskQuestion] = []

    init(
        id: String = UUID().uuidString, question: String, options: [String],
        questions: [PendingAskQuestion] = []
    ) {
        self.id = id
        self.question = question
        self.options = options
        self.questions = questions
    }

    /// The effective question list: the real structure when present,
    /// else the single-question synthesis (index-keyed option ids).
    var effectiveQuestions: [PendingAskQuestion] {
        if !questions.isEmpty { return questions }
        return [
            PendingAskQuestion(
                id: "q0", text: question, multi: false,
                options: options.enumerated().map { index, label in
                    PendingAskQuestion.Option(id: "o\(index)", label: label)
                })
        ]
    }
}

/// One Q/A pair of a resolved ask — the paired-card design's unit.
/// The card shows Q then A on separate lines; the pair is never split
/// into separate chat bubbles. Snapshots preserve the producer's
/// labels/options AT ANSWER TIME, so later catalog changes cannot
/// rewrite history. Selected option labels render in PRODUCER
/// order (never serialized with ambiguous punctuation as a single
/// stored answer).
internal struct ResolvedAskQuestion: Sendable, Equatable, Identifiable {
    /// The published option ids (producer order) — part of the
    /// durable snapshot, so the answer record carries what the user
    /// actually saw.
    let id: String
    /// The producer's original question/summary — never an AI
    /// paraphrase.
    let question: String
    /// The selected options, in PRODUCER order: id + the label
    /// captured at answer time.
    var selectedOptions: [SelectedOption]
    /// The user's free-text answer (customText / Other input). A
    /// free-text-only response renders this as the A line; selection
    /// plus custom text renders labels then a separate
    /// "Additional answer" paragraph.
    var customAnswerText: String?
    /// The user's explanatory note — SEPARATELY labeled "Note", never
    /// promoted to a chosen option or merged into the answer text.
    /// Empty optional notes are omitted.
    var note: String?
    /// The per-question outcome the protocol reported, when the
    /// producer distinguishes per-question outcomes.
    var outcome: String?

    internal struct SelectedOption: Sendable, Equatable, Identifiable {
        let id: String
        let label: String
    }

    init(
        id: String, question: String,
        selectedOptions: [SelectedOption] = [],
        customAnswerText: String? = nil,
        note: String? = nil,
        outcome: String? = nil
    ) {
        self.id = id
        self.question = question
        self.selectedOptions = selectedOptions
        self.customAnswerText = customAnswerText
        self.note = note
        self.outcome = outcome
    }
}

/// One resolved ask interaction — ONE CARD per ask interaction, with
/// a Q/A pair per question (never split into separate chat bubbles).
/// Answered and unanswered states share the SAME card family: paper
/// background, subtle green border, 12pt radius, matching
/// width/insets, accent eyebrow + footer separator — only the
/// contents change after acceptance (see ChatInteractionCard).
/// Conversation history, not chrome — visible at every detail level.
/// PLACEMENT: the card anchors to its QUESTION'S OWN TURN — the
/// message that POSED the ask. The ask is an ask CARD (a tool call
/// whose ARGUMENTS carry the question text — never a plain text
/// message in real transcripts), so the anchor matches both text
/// blocks and toolCall argument string-leaves, and the card renders
/// right after that message, BEFORE the agent's reply that follows it
/// (the correct order: question → answer → reply), at every detail
/// level. Arrival time is never used. An ask whose anchor never
/// matches (legacy records with no question text, or the asking
/// message outside the visible page) parks after the transcript's
/// rows, before any pending card.
internal struct ResolvedAsk: Sendable, Equatable, Identifiable {
    /// The overall resolution kind — what happened to the ask as a
    /// whole. `.youAnswered` renders the recorded Q/A pairs;
    /// everything else renders the question plus the honest outcome
    /// (answered remotely/in terminal/cancelled/expired/unknown) —
    /// never unconfirmed choices styled as accepted.
    enum Outcome: String, Sendable, Equatable {
        case youAnswered
        case answeredInTerminal
        case answeredRemotely
        case cancelled
        case expired
        case settledElsewhere

        /// The honest outcome line for non-answered kinds — shown
        /// inside the card's answer area, never as accepted-answer
        /// styling.
        var outcomeText: String {
            switch self {
            case .youAnswered:
                return "Answered"
            case .answeredInTerminal:
                return "Answered in the agent's terminal."
            case .answeredRemotely:
                return "Answered from another client."
            case .cancelled:
                return "This question was cancelled."
            case .expired:
                return "This question expired before it was answered."
            case .settledElsewhere:
                return "This question was already answered or cancelled elsewhere."
            }
        }
    }

    let id: String
    /// The Q/A pairs, one per answered question, in PRODUCER order.
    /// A `youAnswered` record with no recorded pairs (remote answer
    /// with missing details) renders "Answer details unavailable."
    var questions: [ResolvedAskQuestion]
    /// The overall outcome (per-question outcomes ride the pairs).
    var outcome: Outcome
    /// The first question's own text — the anchor: the card renders
    /// after the message containing this text. (Producer-supplied
    /// heading/original question, never an AI paraphrase.)
    var questionText: String?

    /// The flat one-line summary ("You answered: …" / the honest
    /// outcome note) — the anchor tests' row-order probe and the
    /// search/accessibility path. DISPLAY-ONLY; the structured pairs
    /// are the record.
    var body: String {
        switch outcome {
        case .youAnswered:
            let labels = questions.map { question in
                question.selectedOptions.map(\.label)
                    + (question.customAnswerText.map { ["\($0)"] } ?? [])
            }.flatMap { $0 }
            if labels.isEmpty { return "You answered." }
            return "You answered: " + labels.joined(separator: " + ")
        default:
            return outcome.outcomeText
        }
    }

    /// Builds the UI record from the store's durable resolution
    /// record. A `youAnswered` resolution with NO answer data
    /// (answered remotely with missing details) keeps an empty
    /// pair list — the card renders "Answer details unavailable.",
    /// never fabricated choices.
    init(id: String, questions: [ResolvedAskQuestion] = [],
        outcome: Outcome, questionText: String? = nil
    ) {
        self.id = id
        self.questions = questions
        self.outcome = outcome
        self.questionText = questionText
    }
}

extension ResolvedAsk {
    /// Maps the store's durable resolution record to the card's UI
    /// record — the single projection `AgentDetailView.brokerContent`
    /// uses. All accepted answers read identically regardless of
    /// origin; provenance stays internal to the record.
    init(resolution: AgentChatInteractionResolution) {
        let pairs: [ResolvedAskQuestion] =
            (resolution.questionAnswers ?? []).map { answer in
                ResolvedAskQuestion(
                    id: answer.questionId,
                    question: answer.question,
                    selectedOptions: answer.selections.map { selection in
                        .init(id: selection.optionId, label: selection.label)
                    },
                    customAnswerText: answer.customText,
                    note: answer.note)
            }
        // A youAnswered record with no structured pairs may still
        // carry the legacy flat labels (a v2 archive): surface them as
        // a single pair so the card renders the captured answer
        // rather than "details unavailable" — honest to what was
        // recorded, never reconstructed from prose.
        let effectivePairs: [ResolvedAskQuestion]
        if pairs.isEmpty, resolution.kind == .youAnswered {
            let labels = resolution.answerSummaryLines
            if !labels.isEmpty {
                effectivePairs = [
                    ResolvedAskQuestion(
                        id: "q",
                        question: resolution.questionText ?? "",
                        selectedOptions: labels.enumerated().map {
                            index, label in
                            .init(id: "legacy\(index)", label: label)
                        })
                ]
            } else {
                effectivePairs = pairs
            }
        } else {
            effectivePairs = pairs
        }
        self.init(
            id: resolution.requestId,
            questions: effectivePairs,
            outcome: .init(resolution.kind),
            questionText: resolution.questionText)
    }
}

extension ResolvedAsk.Outcome {
    /// The store's durable kind maps 1:1 onto the UI outcome.
    init(_ kind: AgentChatInteractionResolution.Kind) {
        switch kind {
        case .youAnswered: self = .youAnswered
        case .answeredInTerminal: self = .answeredInTerminal
        case .answeredRemotely: self = .answeredRemotely
        case .cancelled: self = .cancelled
        case .expired: self = .expired
        case .settledElsewhere: self = .settledElsewhere
        }
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
    /// An image block (sent by the user, or returned by a tool):
    /// conversation content, visible at every level as gallery tiles.
    case image(messageID: UUID, blockIndex: Int, image: ChatImageRef)
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
    /// A system/structural notice (item 19): visible at EVERY level —
    /// never dropped; the view styles the quiet/warning/error wash off
    /// `level`.
    case notice(messageID: UUID, blockIndex: Int, text: String, level: String)
    /// A `<system-notice>`/`<irc>` section extracted from a text
    /// block (see `ChatSpecialSectionParser`) — chrome, not
    /// conversation: L0 hides it entirely; L1+ renders the collapsed
    /// summary chip (tap expands the full body; at L3 it starts
    /// expanded). Sits exactly where the tag sat in the source text,
    /// so it never dominates the reading flow.
    case specialSection(ChatSpecialSection)
    /// A blocked-agent pending question — visible at every level; it is the
    /// live frontier of the conversation, not chrome.
    case pending(PendingInteraction)
    /// A resolved ask's quiet record ('You answered: …' / the honest
    /// outcome note) — visible at every level; it is conversation
    /// history, not chrome.
    case resolvedAsk(ResolvedAsk)

    var id: String {
        switch self {
        case .text(let messageID, let blockIndex, _, _),
             .thinking(let messageID, let blockIndex, _),
             .toolCall(let messageID, let blockIndex, _, _),
             .image(let messageID, let blockIndex, _),
             .notice(let messageID, let blockIndex, _, _):
            return "\(messageID.uuidString)#\(blockIndex)"
        case .specialSection(let section):
            return "section#\(section.id)"
        case .orphanResult(let result):
            return "result#\(result.toolCallId)"
        case .pending(let interaction):
            return "pending#\(interaction.id)"
        case .resolvedAsk(let ask):
            return "resolved#\(ask.id)"
        }
    }

    /// The originating ChatMessage's UUID (re-review finding 1: the
 /// retry seam carries the failed echo's UUID — this is where the
    /// notice row exposes it). nil for pending rows.
    var messageID: UUID? {
        switch self {
        case .text(let id, _, _, _), .thinking(let id, _, _),
             .toolCall(let id, _, _, _), .image(let id, _, _),
             .notice(let id, _, _, _):
            return id
        case .orphanResult, .pending, .specialSection, .resolvedAsk:
            return nil
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
/// One call in an L1 Work-inspector summary.
internal struct ChatWorkEntry: Sendable, Equatable, Identifiable {
    let id: String
    let name: String
    let result: ToolResult?

    init(index: Int, name: String, result: ToolResult?) {
        self.id = "\(name)#\(index)"
        self.name = name
        self.result = result
    }

    /// The Work-summary row's accessibility label — singular/plural
    /// correct (the visible row text went singular in the redesign
    /// review round 4; this label had its own uncorrected copy).
    static func accessibilitySummaryLabel(count: Int) -> String {
        "Work summary: \(count) tool call\(count == 1 ? "" : "s"), opens details"
    }
}

internal enum ChatTranscriptItem: Sendable, Equatable, Identifiable {
    case bubble(ChatBubble)
    case row(ChatRow)
    /// The L1 Work inspector: consecutive tool calls collapsed into one
    /// compact summary; the inspector's sheet shows each call's result.
    case workSummary(id: String, calls: [ChatWorkEntry])
    /// One message's consecutive image blocks as a single small-square
    /// gallery (not one tile per row).
    case imageGallery(id: String, images: [ChatImageRef])

    var id: String {
        switch self {
        case .bubble(let bubble): bubble.id
        case .row(let row): row.id
        case .workSummary(let id, _): id
        case .imageGallery(let id, _): id
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
        visibleRows(
            messages: messages, toolResults: toolResults, pending: [],
            resolvedAsks: [], level: level)
    }

    /// Full form, including the blocked-agent affordance rows. Pending
    /// interactions render at every level, after all transcript rows — they
    /// are the conversation's live edge, not chrome to be filtered.
    /// Resolved asks render at every level too — they are conversation
    /// history: after the transcript's rows, before any pending card
    /// (deterministic placement; see ResolvedAsk for why the client
    /// never interleaves by receipt time).
    static func visibleRows(
        messages: [ChatMessage],
        toolResults: [ToolResult],
        pending: [PendingInteraction],
        resolvedAsks: [ResolvedAsk] = [],
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

        // The resolved asks split by anchor: those whose question text
        // appears in a visible message render right AFTER that message
        // (question → answer → the agent's reply that follows it);
        // those with no match park at the transcript's end, before
        // the pending cards (legacy/unknown questions — never
        // interleaved into a turn they don't belong to).
        var unanchoredAsks = resolvedAsks

        var rows: [ChatRow] = []
        for message in messages {
            switch message.role {
            case .user:
                // User turns are conversation, not chrome: their text is
                // visible at every level. Notice blocks ride user
                // messages too — a failed send's honest failure copy
                // (review gap 2) must render on the echo bubble, so the
                // user branch passes them (never drops).
                for (index, block) in message.blocks.enumerated() {
                    switch block {
                    case .text(let text):
                        appendSegmentedText(
                            messageID: message.id, blockIndex: index,
                            role: .user, text: text, level: level, into: &rows)
                    case .image(let image):
                        rows.append(.image(messageID: message.id, blockIndex: index, image: image))
                    case .notice(let text, let noticeLevel):
                        rows.append(.notice(
                            messageID: message.id, blockIndex: index,
                            text: text, level: noticeLevel))
                    default:
                        break
                    }
                }

            case .assistant:
                for (index, block) in message.blocks.enumerated() {
                    switch block {
                    case .text(let text):
                        appendSegmentedText(
                            messageID: message.id, blockIndex: index,
                            role: .assistant, text: text, level: level, into: &rows)
                    case .thinking(let text) where level >= .l3:
                        rows.append(.thinking(messageID: message.id, blockIndex: index, text: text))
                    case .toolCall(let call) where level >= Self.visibilityLevel(for: call):
                        // Results pair at every level: at L1 the call
                        // collapses into the Work-inspector summary,
                        // whose sheet needs the result; at L2+ the
                        // per-call card shows it inline.
                        let result = resultsByCall[call.id]
                        rows.append(.toolCall(messageID: message.id, blockIndex: index, call: call, result: result))
                    case .image(let image):
                        rows.append(.image(messageID: message.id, blockIndex: index, image: image))
                    case .notice(let text, let noticeLevel):
                        rows.append(.notice(
                            messageID: message.id, blockIndex: index,
                            text: text, level: noticeLevel))
                    case .thinking, .toolCall:
                        break  // below its level
                    }
                }

            case .toolResult, .bashExecution:
                // Record-carried results. bashExecution is user-driven shell
                // output — conversation, all levels. toolResult records are
                // tool output — chrome, L2+ with the other tool results.
                // Notices (item 19) ride bashExecution-role messages and
                // are conversation at every level — never dropped.
                let visible = message.role == .bashExecution || level >= .l2
                if visible {
                    for (index, block) in message.blocks.enumerated() {
                        switch block {
                        case .text(let text):
                            appendSegmentedText(
                                messageID: message.id, blockIndex: index,
                                role: message.role, text: text,
                                level: level, into: &rows)
                        case .notice(let text, let noticeLevel):
                            rows.append(.notice(
                                messageID: message.id, blockIndex: index,
                                text: text, level: noticeLevel))
                        default:
                            break
                        }
                    }
                }
            }

            // ANCHOR: after this message, render every ask anchored
            // to it. The ask is an ask CARD — a tool call whose
            // ARGUMENTS carry the question text (the ask tool's
            // parameters), not a plain text message; the anchor
            // therefore matches BOTH text blocks and toolCall
            // arguments (JSON), and lands the block at the message
            // that POSED the question — before the reply that
            // follows. Level-independent: even when the tool-call
            // rows themselves are hidden (L0), the message's
            // position in the flow is still the ask's position, and
            // a message whose only content was the ask still anchors
            // (an empty match text only skips, never parks early).
            if !unanchoredAsks.isEmpty {
                let matchText = message.blocks
                    .compactMap { block -> String? in
                        switch block {
                        case .text(let text):
                            return text
                        case .toolCall(let call):
                            // The ask tool's arguments carry the
                            // question text as a plain STRING value —
                            // extract string leaves recursively so
                            // JSON escaping never breaks the match.
                            return Self.stringLeaves(of: call.arguments)
                                .joined(separator: "\n")
                        default:
                            return nil
                        }
                    }
                    .joined(separator: "\n")
                if !matchText.isEmpty {
                    var remaining: [ResolvedAsk] = []
                    for ask in unanchoredAsks {
                        if let anchor = ask.questionText,
                            !anchor.isEmpty,
                            matchText.contains(anchor)
                        {
                            rows.append(.resolvedAsk(ask))
                        } else {
                            remaining.append(ask)
                        }
                    }
                    unanchoredAsks = remaining
                }
            }
        }
        // Asks whose anchor never matched (unknown/legacy question
        // text, or the question's message is outside the visible
        // page): park after the transcript's rows, before the
        // pending cards — deterministic.
        rows.append(contentsOf: unanchoredAsks.map(ChatRow.resolvedAsk))

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

    /// One text block through the special-section extractor
    /// (`ChatSpecialSectionParser`): the residual prose segments
    /// become `.text` rows and each extracted `<system-notice>`/`<irc>`
    /// section becomes a `.specialSection` row at its source position
    /// — the tags never reach the markdown path. Level gating: the
    /// prose is conversation (every level); the sections are chrome
    /// (L0 drops them ENTIRELY — a hidden section's prose keeps
    /// rendering with the tag occurrences removed, never as raw tag
    /// text). Segment ids stay stable across level switches: prose
    /// keeps the block's own `messageID#blockIndex` id when the block
    /// did not split, and the (rare) split residuals carry synthetic
    /// piece indices `1000 + segment` — above every real block index
    /// a message can hold, below the sections' `section#` prefix.
    /// Prose that renders to nothing (whitespace the tags left
    /// behind) drops, so a tag-only block at L0 yields zero rows.
    private static func appendSegmentedText(
        messageID: UUID, blockIndex: Int, role: ChatRole,
        text: String, level: DetailLevel, into rows: inout [ChatRow]
    ) {
        let baseID = "\(messageID.uuidString)#\(blockIndex)"
        let extraction = ChatSpecialSectionParser.extract(
            from: text, baseID: baseID)
        guard !extraction.sections.isEmpty else {
            // Fast path: no tags, one ordinary text row (byte-for-byte
            // the row the unsegmented code emitted before).
            if !text.isEmpty {
                rows.append(.text(
                    messageID: messageID, blockIndex: blockIndex,
                    role: role, text: text))
            }
            return
        }
        for (piece, segment) in extraction.segments.enumerated() {
            let trimmed = segment.text.trimmingCharacters(
                in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                rows.append(.text(
                    messageID: messageID,
                    blockIndex: piece == 0
                        ? blockIndex : 1000 + piece,
                    role: role, text: segment.text))
            }
            if let section = segment.followingSection, level >= .l1 {
                rows.append(.specialSection(section))
            }
        }
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
    /// Every string value reachable in a JSON tree (object keys
    /// excluded, string leaves only — recursion into arrays and
    /// nested objects). The resolved-ask anchor matches the ask
    /// tool's arguments against these leaves, so JSON quoting never
    /// breaks the question-text match.
    static func stringLeaves(of value: JSONValue) -> [String] {
        switch value {
        case .string(let string):
            return [string]
        case .array(let items):
            return items.flatMap { stringLeaves(of: $0) }
        case .object(let fields):
            return fields.values.flatMap { stringLeaves(of: $0) }
        case .null, .bool, .number:
            return []
        }
    }

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
    static func visibleItems(
        from rows: [ChatRow], level: DetailLevel = .l2
    ) -> [ChatTranscriptItem] {
        var items: [ChatTranscriptItem] = []
        var run: [ChatRow] = []
        // L1 Work-inspector grouping: consecutive tool rows collapse
        // into ONE compact summary. Non-tool rows and L2+ keep the
        // per-row shapes.
        var workCalls: [ChatWorkEntry] = []
        // Consecutive image rows of one message collect into a single
        // gallery item.
        var galleryImages: [ChatImageRef] = []

        func flushGallery() {
            guard !galleryImages.isEmpty else { return }
            items.append(.imageGallery(
                id: "gallery-\(items.count)", images: galleryImages))
            galleryImages = []
        }

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

        func flushWork() {
            guard !workCalls.isEmpty else { return }
            items.append(.workSummary(
                id: "work-summary-\(items.count)", calls: workCalls))
            workCalls = []
        }

        for row in rows {
            let isWorkRow: Bool
            switch row {
            case .toolCall, .orphanResult: isWorkRow = true
            default: isWorkRow = false
            }
            if isWorkRow, level == .l1 {
                flush()
                flushGallery()
                switch row {
                case .toolCall(_, _, let call, let result):
                    workCalls.append(ChatWorkEntry(
                        index: workCalls.count, name: call.name, result: result))
                case .orphanResult(let result):
                    workCalls.append(ChatWorkEntry(
                        index: workCalls.count, name: result.toolName, result: result))
                default:
                    break
                }
                continue
            }
            if case .image(_, _, let image) = row {
                flush()
                flushWork()
                galleryImages.append(image)
                continue
            }
            flushWork()
            flushGallery()
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
        flushWork()
        flushGallery()
        flush()
        return items
    }
}
