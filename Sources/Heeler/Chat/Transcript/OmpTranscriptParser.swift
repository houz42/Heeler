import Foundation

// SPDX-License-Identifier: Apache-2.0
//
// Line-oriented parser for omp (Oh My Pi) JSONL session files.
//
// Ported from Drover (MIT), keinstn/drover@0fdb6a0
// (app/lib/src/agents/pi/pi_transcript.dart — PiTranscriptParser).
//
// Each line of a session file is one JSON record with a top-level `type`.
// Only `type == "message"` carries user-visible content; everything else
// (`title`, `title_change`, `custom_message`, `custom`, `session`,
// `model_change`, `thinking_level_change`, and whatever omp adds later) is
// skipped by an allowlist, never a denylist.
//
// The `custom` records are deliberate noise for this parser: a census of
// real live sessions shows `tool_execution_start` fires for EVERY tool
// invocation (bash/read/… as well as `task` subagent spawns) — it is
// per-tool timing metadata, not a subagent marker — so subagent spawns and
// todo checklists surface through their ordinary toolCall + toolResult
// records and need no parsing of `custom` at all. Visibility of those rows
// is a `ChatFiltering` concern (`visibilityLevel(toolName:)`).
// A message record nests its payload under `message`, keyed by `role`:
//   - user / assistant → a `content` array of blocks, walked in order:
//       {type:"text", text}          → ChatBlock.text
//       {type:"thinking", thinking}  → ChatBlock.thinking
//       {type:"toolCall", id, name,
//        arguments}                  → ChatBlock.toolCall. `arguments` is
//       already a decoded JSON object in the wire line (unlike Codex's
//       JSON-encoded string) and is used as-is.
//   - toolResult → its own top-level record carrying `toolCallId` +
//     `toolName`/`isError`/`content` (an array of blocks, flattened to text;
//     image blocks dropped). Returned separately so callers pair by
//     toolCallId — the id is opaque and may be hundreds of characters with
//     `|`/`#`, so it is only ever matched, never parsed.
//   - bashExecution → a user-run `!command` shell escape with
//     {command, output} instead of a content array. Kept as a message
//     carrying the command line so the turn stays visible; shapes without
//     a command are skipped.
//
// Malformed lines (truncated writes, stray non-JSON output interleaved into
// the session log) are skipped, never thrown: a live transcript must keep
// loading after one bad line.

/// The result of parsing one JSONL line: a user/assistant/bashExecution
/// message, or a tool result to pair with its call by `toolCallId`.
enum OmpParsedRecord: Sendable, Equatable {
    case message(ChatMessage)
    case toolResult(ToolResult)
}

/// Parses the user-visible portion of an omp JSONL session transcript.
/// Stateless: safe to call from any concurrency domain.
enum OmpTranscriptParser {
    /// Parses one JSONL line. Returns nil for non-`message` records,
    /// unrecognised roles, malformed JSON, and lines with no user-visible
    /// content.
    static func parse(line: some StringProtocol) -> OmpParsedRecord? {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let data = Substring(trimmed).data(using: .utf8) ?? Data(trimmed.utf8)
        guard let record = try? JSONSerialization.jsonObject(with: data) else { return nil }
        guard let fields = record as? [String: Any] else { return nil }
        // Allowlist: only message records are parsed; everything else is
        // deliberate noise (titles, model changes, custom notices).
        guard fields["type"] as? String == "message" else { return nil }
        guard let message = fields["message"] as? [String: Any] else { return nil }
        guard let role = message["role"] as? String else { return nil }

        switch role {
        case "user":
            return contentMessage(message, role: .user)
        case "assistant":
            return contentMessage(message, role: .assistant)
        case "toolResult":
            return toolResult(message).map { .toolResult($0) }
        case "bashExecution":
            return bashExecutionMessage(message)
        default:
            // A role omp may add later; unparsed by design.
            return nil
        }
    }

    /// Parses JSONL lines in order into the chat message list plus the tool
    /// results to pair onto it. Skips (never throws on) malformed lines.
    static func parse(lines: [String]) -> ([ChatMessage], [ToolResult]) {
        var messages: [ChatMessage] = []
        var results: [ToolResult] = []
        for line in lines {
            switch parse(line: line) {
            case .message(let message)?:
                messages.append(message)
            case .toolResult(let result)?:
                results.append(result)
            case nil:
                continue
            }
        }
        return (messages, results)
    }

    /// Bulk convenience for variadic calls: `parse(lines: lineA, lineB)`.
    static func parse<S: StringProtocol>(lines: S...) -> ([ChatMessage], [ToolResult]) {
        parse(lines: lines.map { String($0) })
    }

    // MARK: - Pending interactions (blocked-agent `ask` questions)

    /// Derives the blocked-agent pending interactions from a parsed turn
    /// set: an `ask` tool call is the question carrier (call → question,
    /// one `arguments.questions` entry → one interaction), and the tool
    /// result that pairs with the call is the answer. Pure, over already
    /// parsed records, so both the store's merge seams and tests share one
    /// derivation.
    ///
    /// Wire shapes (verbatim from live omp sessions):
    ///   call: {"type":"toolCall","id":"ask_0_5de86e6b","name":"ask",
    ///          "arguments":{"questions":[{"id":"app_state",
    ///          "question":"…","options":[{"label":"…","description":"…"}],
    ///          "recommended":4}]}}
    ///   result: {"role":"toolResult","toolCallId":"ask_0_5de86e6b",
    ///          "toolName":"ask","content":[{"type":"text",
    ///          "text":"User selected: Scanned, error shown"}]}
    static func askPendingInteractions(
        messages: [ChatMessage], toolResults: [ToolResult]
    ) -> [PendingInteraction] {
        var answers = [String: String]()
        for result in toolResults where result.toolName == "ask" {
            // First record wins if a call somehow produced duplicate
            // results — deterministic, matching result pairing.
            if answers[result.toolCallId] == nil {
                answers[result.toolCallId] = Self.answerLabel(in: result.content)
            }
        }

        var interactions: [PendingInteraction] = []
        for message in messages {
            for block in message.blocks {
                guard case .toolCall(let call) = block, call.name == "ask" else {
                    continue
                }
                interactions.append(
                    contentsOf: Self.pendingInteractions(from: call, answer: answers[call.id]))
            }
        }
        return interactions
    }

    /// One call's `arguments.questions` entries → interactions, in wire
    /// order. Interaction ids are `callId#questionId` so they are stable
    /// across polls. A question without an id (unobserved live) falls back
    /// to the call id, keeping ids unique and non-empty.
    private static func pendingInteractions(
        from call: ToolCall, answer: String?
    ) -> [PendingInteraction] {
        guard case .array(let questions) = call.arguments["questions"] else {
            return []
        }
        var interactions: [PendingInteraction] = []
        for (index, question) in questions.enumerated() {
            guard case .object(let fields) = question,
                let questionText = fields["question"]?.stringValue,
                !questionText.isEmpty
            else { continue }
            let questionID = fields["id"]?.stringValue ?? String(index)
            // `recommended` is the dialog's starting highlight; answers
            // key off it. Absent/out-of-range reads as the first option.
            let recommended = fields["recommended"]
                .flatMap { if case .number(let value) = $0 { Int(value) } else { nil } } ?? 0
            let options = Self.pendingOptions(
                from: fields["options"], recommended: recommended)
            interactions.append(PendingInteraction(
                id: "\(call.id)#\(questionID)",
                question: questionText,
                options: options,
                recommendedIndex: recommended,
                answer: answer))
        }
        return interactions
    }

    /// `options` accepts both live shapes: omp's `ask` carries label +
    /// description pairs; a bare-string list (any future/older spelling)
    /// reads as label-only. Each option carries its dialog index so the
    /// answer's key sequence can be computed. Non-string entries are
    /// dropped (indexes stay the dialog's own).
    private static func pendingOptions(
        from value: JSONValue?, recommended: Int
    ) -> [PendingInteraction.Option] {
        guard case .array(let options)? = value else { return [] }
        var parsed: [PendingInteraction.Option] = []
        for (index, option) in options.enumerated() {
            switch option {
            case .object(let fields):
                guard let label = fields["label"]?.stringValue, !label.isEmpty else {
                    continue
                }
                parsed.append(PendingInteraction.Option(
                    label: label,
                    description: fields["description"]?.stringValue,
                    index: index))
            case .string(let label):
                parsed.append(PendingInteraction.Option(label: label, index: index))
            default:
                continue
            }
        }
        return parsed
    }

    /// Extracts the chosen option's label from an answered `ask` result's
    /// content: "User selected: <label>" → "<label>" (the "User selected: "
    /// prefix is omp's own; anything unprefixed is kept whole so a future
    /// wording still reads).
    private static func answerLabel(in content: String) -> String {
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        let prefix = "User selected: "
        return trimmed.hasPrefix(prefix) ? String(trimmed.dropFirst(prefix.count)) : trimmed
    }

    /// Walks a user/assistant message's content blocks in order, emitting one
    /// ChatBlock per user-visible block. An empty or missing `content` array
    /// yields no message. Adjacent text blocks are not merged (omp has not
    /// been observed emitting two), matching Drover.
    private static func contentMessage(
        _ message: [String: Any], role: ChatRole
    ) -> OmpParsedRecord? {
        guard let content = message["content"] as? [[String: Any]] else { return nil }

        var blocks: [ChatBlock] = []
        for block in content {
            switch block["type"] as? String {
            case "text":
                // Whitespace-only text blocks carry nothing and are dropped.
                if let text = (block["text"] as? String)?.trimmingCharacters(
                    in: .whitespacesAndNewlines), !text.isEmpty {
                    blocks.append(.text(text))
                }
            case "thinking":
                if let thinking = block["thinking"] as? String, !thinking.isEmpty {
                    blocks.append(.thinking(thinking))
                }
            case "toolCall":
                guard let name = block["name"] as? String else { continue }
                // `arguments` arrives already decoded in the line, so it is
                // kept as-is; a missing or non-object arguments becomes an
                // empty object, never a re-parse.
                let arguments = decodeJSONValue(block["arguments"] ?? NSNull()) ?? .object([:])
                let id = (block["id"] as? String) ?? ""
                blocks.append(.toolCall(ToolCall(id: id, name: name, arguments: arguments)))
            default:
                // Unknown block types (e.g. images) are ignored.
                continue
            }
        }
        guard !blocks.isEmpty else { return nil }
        return .message(ChatMessage(
            role: role, blocks: blocks, timestamp: dateField(message, "timestamp")))
    }

    /// Flattens a toolResult record: keeps the pairing id plus display
    /// metadata, collapsing the content blocks' text into one string (image
    /// blocks dropped, matching Drover). Lines without a toolCallId carry
    /// nothing pairable and are skipped.
    private static func toolResult(_ message: [String: Any]) -> ToolResult? {
        guard let toolCallId = message["toolCallId"] as? String else { return nil }
        let content = (message["content"] as? [[String: Any]] ?? []).compactMap {
            ($0["text"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        }.filter { !$0.isEmpty }.joined(separator: "\n\n")
        return ToolResult(
            toolCallId: toolCallId,
            toolName: (message["toolName"] as? String) ?? "",
            isError: message["isError"] as? Bool ?? false,
            content: content)
    }

    /// A user-run `!command` shell escape. The observed wire shape carries
    /// `command`/`output` instead of a content array; the command line is
    /// kept so the turn is visible, and any other shape is skipped.
    private static func bashExecutionMessage(_ message: [String: Any]) -> OmpParsedRecord? {
        guard let command = (message["command"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines), !command.isEmpty else {
            return nil
        }
        return .message(ChatMessage(
            role: .bashExecution,
            blocks: [.text(command)],
            timestamp: dateField(message, "timestamp")))
    }

    /// omp timestamps are epoch milliseconds (e.g. 1789292098261). Fractional
    /// and negative values are accepted; anything else yields nil rather
    /// than a bogus date.
    private static func dateField(_ fields: [String: Any], _ key: String) -> Date? {
        guard let milliseconds = fields[key] as? Double else { return nil }
        return Date(timeIntervalSince1970: milliseconds / 1_000)
    }

    private static func decodeJSONValue(_ object: Any) -> JSONValue? {
        // A JSON true/false arrives from JSONSerialization as a genuine
        // CFBoolean, but a JSON 0/1 arrives as NSNumber — and the `as
        // Bool` cast succeeds on BOTH (the NSNumber-Bool bridging trap:
        // omp's `recommended: 4` decoded as .bool instead of .number).
        // Classify on the ORIGINAL object's CoreFoundation type, before
        // any Swift cast loses that information.
        if CFGetTypeID(object as CFTypeRef) == CFBooleanGetTypeID() {
            return .bool(object as! Bool)
        }
        switch object {
        case is NSNull:
            return .null
        case let value as Int:
            return .number(Double(value))
        case let value as UInt:
            return .number(Double(value))
        case let value as Double:
            return .number(value)
        case let value as String:
            return .string(value)
        case let value as [Any]:
            return .array(value.compactMap(decodeJSONValue))
        case let value as [String: Any]:
            var fields: [String: JSONValue] = [:]
            for (key, element) in value {
                guard let decoded = decodeJSONValue(element) else { return nil }
                fields[key] = decoded
            }
            return .object(fields)
        default:
            return nil
        }
    }
}
