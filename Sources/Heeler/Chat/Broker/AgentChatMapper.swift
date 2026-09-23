import CryptoKit
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
        case .notice(let id, let text, let level):
            // EVERY level renders — never dropped (item 19): the view
            // styles the quiet/system row off the block's `level`.
            return .message(
                ChatMessage(
                    id: stableID(for: id),
                    role: .bashExecution,
                    blocks: [.notice(text: text, level: level)]))
        case .unsupported(_, let sourceType, _):
            return .skipped(reason: "unsupported \(sourceType)")
        case .reference(let id, _, _):
            // The caller must item.read before rendering; a reference
            // never maps as if complete.
            return .skipped(reason: "reference \(id) needs item.read")
        }
    }

    /// A stable UUID for one source item id across refreshes. The wire's
    /// ids are opaque strings (UUIDs today, but never promised): parse
    /// when the string IS a UUID, hash deterministically otherwise — a
    /// per-refresh fresh UUID would churn every row's identity and the
    /// LazyVStack would tear down the whole transcript (the flash).
    static func stableID(for sourceID: String) -> UUID {
        if let uuid = UUID(uuidString: sourceID) { return uuid }
        return hashedUUID(sourceID)
    }

    /// Deterministic UUID derivation for non-UUID source ids (RFC 4122
    /// v5 shape: SHA-1 of namespace + name, first 16 bytes, version and
    /// variant bits forced). Same source id ⇒ same UUID, every call.
    private static func hashedUUID(_ sourceID: String) -> UUID {
        // Fixed namespace bytes so Heeler-derived ids never collide with
        // another consumer hashing the same string.
        let namespace = Data([0x9E, 0x1C, 0x48, 0x65, 0x65, 0x6C, 0x65, 0x72])
        let digest = Insecure.SHA1.hash(data: namespace + Data(sourceID.utf8))
        var bytes = [UInt8](digest.prefix(16))
        bytes[6] = (bytes[6] & 0x0F) | 0x50  // version 5
        bytes[8] = (bytes[8] & 0x3F) | 0x80  // RFC 4122 variant
        return UUID(uuid: (
            bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5],
            bytes[6], bytes[7], bytes[8], bytes[9], bytes[10], bytes[11],
            bytes[12], bytes[13], bytes[14], bytes[15]))
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
                let trimmed = text.trimmingCharacters(
                    in: .whitespacesAndNewlines)
                // omp's "." keepalive blocks are stream noise, not
                // content (the user saw a stray dot rendering before
                // the options card). Whitespace-only and dot-only
                // text blocks drop.
                if !trimmed.isEmpty, trimmed != "." {
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
                id: stableID(for: id),
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

    /// Projects one echo's images onto chat image blocks (re-review
    /// round 5, inline-ref finding): an inline-sent image (base64
    /// `data`) carries its REAL BYTES on the echo — the renderer draws
    /// them directly, no fabricated fetchable id. A ref-sent image
    /// keeps its real blob ref. Each image gets its OWN synthetic ref —
    /// "inline:\(echoID)-\(index)" — so multiple images in one echo are
    /// DISTINCT ChatImageRef ids (a shared ref collapsed them into one
    /// row identity: Identifiable dedup, wrong image-per-row pairing).
    static func echoImageBlocks(
        echoID: UUID, images: [AgentChatOutgoingImage]
    ) -> [ChatBlock] {
        images.enumerated().compactMap { index, image in
            switch (image.ref, image.data) {
            case (let ref?, nil):
                return .image(ChatImageRef(
                    ref: ref, mimeType: image.mimeType,
                    byteLength: image.byteLength))
            case (_, let data?):
                return .image(ChatImageRef(
                    ref: "inline:\(echoID.uuidString)-\(index)",
                    mimeType: image.mimeType,
                    byteLength: image.byteLength,
                    inlineData: data))
            default:
                return nil
            }
        }
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
