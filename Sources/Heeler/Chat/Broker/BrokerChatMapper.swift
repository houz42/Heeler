import Foundation

// SPDX-License-Identifier: Apache-2.0
//
// Maps one canonical broker HistoryItem (the JSON domain shape from
// history.ts: {type, role?, blocks?, content?, contentTruncated?…}) onto
// the chat layer's ChatMessage/ToolResult model — the same shapes the
// JSONL backend's OmpTranscriptParser produces, so the rows, bubbles,
// filtering, and pairing all render unchanged.

enum BrokerChatMapper: Sendable {
    /// What one item mapped to: a message, a standalone result, or
    /// nothing renderable (metadata entries the chat skips).
    enum Mapped: Sendable, Equatable {
        case message(ChatMessage)
        case toolResult(ToolResult)
        case skipped
    }

    /// Maps one full HistoryItem JSON object.
    static func map(item: JSONValue) -> Mapped {
        guard case .object(let fields) = item else { return .skipped }
        switch fields["type"]?.stringValue ?? "" {
        case "message":
            return mapMessage(fields)
        case "compaction":
            // Custom/compaction boundaries stay visible-but-collapsed in
            // v1 via summary text as an assistant-scope row is a lie; the
            // chat layer has no compaction row kind yet, so honest skip.
            return .skipped
        case "branch_summary", "custom", "custom_message", "reset_boundary":
            // Boundaries the current row model does not render. Skipped
            // by allowlist, matching OmpTranscriptParser's discipline.
            return .skipped
        default:
            return .skipped
        }
    }

    private static func mapMessage(_ fields: [String: JSONValue]) -> Mapped {
        guard let roleRaw = fields["role"]?.stringValue else { return .skipped }
        let role: ChatRole
        switch roleRaw {
        case "user": role = .user
        case "assistant": role = .assistant
        case "toolResult": return mapToolResult(fields)
        case "bashExecution": role = .bashExecution
        default: return .skipped
        }

        // Typed blocks are the source of truth when present; the flat
        // `content` is only a preview and may be truncated — never
        // rendered as if complete (detail fetch happens in the store).
        guard case .array(let blocks)? = fields["blocks"] else {
            // A message with no typed blocks: nothing renderable.
            return .skipped
        }
        var chatBlocks: [ChatBlock] = []
        for block in blocks {
            guard case .object(let blockFields) = block,
                let kind = blockFields["type"]?.stringValue
            else { continue }
            switch kind {
            case "text":
                if let text = blockFields["text"]?.stringValue,
                    !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                {
                    chatBlocks.append(.text(text))
                }
            case "thinking":
                if let thinking = blockFields["thinking"]?.stringValue, !thinking.isEmpty {
                    chatBlocks.append(.thinking(thinking))
                }
            case "toolCall":
                guard let name = blockFields["name"]?.stringValue else { continue }
                let id = blockFields["id"]?.stringValue ?? ""
                let arguments = blockFields["arguments"] ?? .object([:])
                chatBlocks.append(
                    .toolCall(ToolCall(id: id, name: name, arguments: arguments)))
            default:
                continue // images and unknown kinds: no row model yet
            }
        }
        guard !chatBlocks.isEmpty else { return .skipped }
        return .message(
            ChatMessage(
                role: role, blocks: chatBlocks, timestamp: timestamp(fields)))
    }

    private static func mapToolResult(_ fields: [String: JSONValue]) -> Mapped {
        guard let toolCallId = fields["toolCallId"]?.stringValue else { return .skipped }
        let content: String
        if case .array(let blocks)? = fields["blocks"] {
            content = blocks.compactMap { block -> String? in
                guard case .object(let blockFields) = block,
                    blockFields["type"]?.stringValue == "text"
                else { return nil }
                return blockFields["text"]?.stringValue?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            }
            .filter { !$0.isEmpty }
            .joined(separator: "\n\n")
        } else {
            content = fields["content"]?.stringValue ?? ""
        }
        return .toolResult(
            ToolResult(
                toolCallId: toolCallId,
                toolName: fields["toolName"]?.stringValue ?? "",
                isError: fields["isError"]?.boolValue ?? false,
                content: content))
    }

    private static func timestamp(_ fields: [String: JSONValue]) -> Date? {
        guard let raw = fields["timestamp"]?.stringValue else { return nil }
        return ISO8601DateFormatter().date(from: raw)
    }
}
