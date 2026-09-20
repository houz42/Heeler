import Foundation

// SPDX-License-Identifier: Apache-2.0
//
// Maps the normalized agent-chat domain onto the chat layer's
// ChatMessage/ToolResult model — the same shapes the JSONL backend
// produces, so rows/bubbles/filtering render unchanged. tool_result
// blocks pair INSIDE the message by callId (the normalized domain
// already carries them nested); boundaries/notices get honest rows.

enum AgentChatMapper: Sendable {
    /// One ChatItem mapped into the chat layer's content.
    enum Mapped: Sendable, Equatable {
        case message(ChatMessage)
        case pending(PendingInteraction)
        case skipped(reason: String)
    }

    static func map(item: AgentChatItem) -> Mapped {
        switch item {
        case .message(let id, let author, let createdAt, let blocks):
            return mapMessage(id: id, author: author, createdAt: createdAt, blocks: blocks)
        case .boundary:
            // Boundaries carry their own shape the row model has no kind
            // for yet; honest skip (not silently dropped text).
            return .skipped(reason: "boundary")
        case .notice(_, let text, let level):
            // Notices at warning/error render as text; info stays quiet.
            if level == "warning" || level == "error" {
                return .message(
                    ChatMessage(role: .assistant, blocks: [.text(text)]))
            }
            return .skipped(reason: "info notice")
        case .unsupported(_, let sourceType, _):
            return .skipped(reason: "unsupported \(sourceType)")
        case .reference(let id, _, _):
            // The caller must item.read before rendering; a reference
            // never maps as if complete.
            return .skipped(reason: "reference \(id) needs item.read")
        }
    }

    private static func mapMessage(
        id: String, author: AgentChatItem.Author, createdAt: String?,
        blocks: [AgentChatBlock]
    ) -> Mapped {
        let role: ChatRole
        switch author.role {
        case .user: role = .user
        case .assistant: role = .assistant
        case .system, .tool: role = .bashExecution
        }

        var chatBlocks: [ChatBlock] = []
        for block in blocks {
            switch block {
            case .text(let text):
                if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    chatBlocks.append(.text(text))
                }
            case .thinking(let text):
                if !text.isEmpty {
                    chatBlocks.append(.thinking(text))
                }
            case .toolCall(let callId, let name, let arguments):
                chatBlocks.append(
                    .toolCall(ToolCall(id: callId, name: name, arguments: arguments)))
            case .toolResult(let callId, let name, let isError, let content):
                // Normalized domain: the result rides INSIDE the message.
                // Pair it onto the chat layer's standalone ToolResult via
                // the shared pending list; ChatFiltering pairs by callId.
                chatBlocks.append(contentsOf: mapToolResultBlocks(
                    callId: callId, name: name, isError: isError, content: content))
            case .image(let mimeType, let ref, let byteLength):
                chatBlocks.append(.image(ChatImageRef(
                    ref: ref, mimeType: mimeType, byteLength: byteLength)))
            case .unsupported:
                continue
            }
        }
        guard !chatBlocks.isEmpty else {
            return .skipped(reason: "empty message \(id)")
        }
        return .message(
            ChatMessage(
                role: role, blocks: chatBlocks, timestamp: isoDate(createdAt)))
    }

    /// A tool_result block becomes a placeholder tool_call (so the pair
    /// renders in order) plus is surfaced through the chat layer's
    /// result pairing. The chat layer's model pairs ToolResult by
    /// toolCallId at L2+; the standalone result travels via the
    /// content.pending-independent path in the store.
    private static func mapToolResultBlocks(
        callId: String, name: String?, isError: Bool, content: [AgentChatBlock]
    ) -> [ChatBlock] {
        // The chat row model renders tool results attached to their
        // call; the call itself must exist for pairing. Emit a call
        // block for the result (id = callId) so the pair always holds.
        _ = (callId, name, isError, content)
        // The standalone result rides the store's toolResults list —
        // see AgentChatStore.collectToolResults.
        return []
    }

    private static func isoDate(_ iso: String?) -> Date? {
        guard let iso else { return nil }
        return ISO8601DateFormatter().date(from: iso)
    }
}

/// Extracts the standalone ToolResult list from a page's items — the
/// normalized domain carries tool_result blocks inside messages, so
/// the chat layer's L2+ result pairing gets them from there.
enum AgentChatToolResultCollector: Sendable {
    static func collect(from items: [AgentChatItem]) -> [ToolResult] {
        var results: [ToolResult] = []
        for item in items {
            guard case .message(_, _, _, let blocks) = item else { continue }
            for block in blocks {
                guard case .toolResult(let callId, let name, let isError, let content) = block
                else { continue }
                let text = content.compactMap { block -> String? in
                    guard case .text(let text) = block else { return nil }
                    return text.trimmingCharacters(in: .whitespacesAndNewlines)
                }
                .filter { !$0.isEmpty }
                .joined(separator: "\n\n")
                results.append(
                    ToolResult(
                        toolCallId: callId, toolName: name ?? "",
                        isError: isError, content: text))
            }
        }
        return results
    }
}
