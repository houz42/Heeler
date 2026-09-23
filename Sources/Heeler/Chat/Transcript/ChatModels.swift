import Foundation

// SPDX-License-Identifier: Apache-2.0
//
// Chat-layer domain model: the shapes the transcript parser produces and the
// windowing + UI layers render. Roles and block kinds follow the omp session
// record spec (type=="message" only; roles user/assistant/toolResult/
// bashExecution; blocks text/thinking/toolCall). `ToolCall.arguments` arrives
// already decoded in the JSONL wire form and is carried as-is — never
// re-decoded.

/// The speaker of one transcript message record. `toolResult` and
/// `bashExecution` are their own top-level record roles in omp's session
/// format, not content blocks inside another message.
enum ChatRole: String, Sendable {
    case user
    case assistant
    case toolResult
    case bashExecution
}

/// One assistant-issued tool invocation. The id is omp's opaque pairing key —
/// live transcripts carry shapes as different as `read_0#f3b6e1dc…` and
/// several-hundred-character strings containing `|` — so it is never parsed,
/// only matched against `ToolResult.toolCallId`.
struct ToolCall: Sendable, Equatable, Identifiable {
    let id: String
    let name: String
    /// Already-decoded JSON object straight from the JSONL line; not a string
    /// to be parsed later.
    let arguments: JSONValue

    init(id: String, name: String, arguments: JSONValue) {
        self.id = id
        self.name = name
        self.arguments = arguments
    }
}

/// One user-visible content block of a chat message. Kept as an ordered
/// per-message array so an assistant turn can render (thinking, toolCall,
/// toolCall, text) in its original order.
/// An image block's reference: the wire keeps bytes OUT of the row
/// model (an id the fetch seam resolves; the UI loads on demand).
struct ChatImageRef: Sendable, Equatable, Identifiable {
    let ref: String
    let mimeType: String
    var byteLength: Int?
    /// Inline bytes (re-review round 4, finding 2): a locally-sent
    /// image whose REAL BYTES the client already holds — an inline
    /// send (base64 `data`, no img: blob ref). When set, renderers
    /// use these bytes directly and NEVER go through the fetch seam
    /// (a fabricated ref cannot be fetched). nil = the wire's blob
    /// ref path (fetch resolves it).
    var inlineData: Data?

    var id: String { ref }
}

enum ChatBlock: Sendable, Equatable {
    case text(String)
    case thinking(String)
    case toolCall(ToolCall)
    case image(ChatImageRef)
    /// A system/structural notice the wire carries with its severity
    /// level ("info" | "warning" | "error"). Never dropped: the view
    /// renders every level, styling the quiet/system wash off `level`.
    case notice(text: String, level: String)
}

/// A `role:"toolResult"` record, flattened for display: the id it pairs to,
/// the tool's name, whether the tool reported failure, and the result's
/// content blocks collapsed to one text string (image blocks dropped).
struct ToolResult: Sendable, Equatable, Identifiable {
    let toolCallId: String
    let toolName: String
    let isError: Bool
    let content: String

    /// Identity is the pairing key: one result per tool call.
    var id: String { toolCallId }

    init(toolCallId: String, toolName: String, isError: Bool, content: String) {
        self.toolCallId = toolCallId
        self.toolName = toolName
        self.isError = isError
        self.content = content
    }
}

/// One parsed message record: a speaker plus its ordered content blocks. Tool
/// results travel separately (their own records, paired by toolCallId), so a
/// message never contains result blocks.
struct ChatMessage: Sendable, Equatable, Identifiable {
    let id: UUID
    let role: ChatRole
    let blocks: [ChatBlock]
    let timestamp: Date?

    init(id: UUID = UUID(), role: ChatRole, blocks: [ChatBlock], timestamp: Date? = nil) {
        self.id = id
        self.role = role
        self.blocks = blocks
        self.timestamp = timestamp
    }
}

/// Chat transcript verbosity. L0 (default) is assistant text turns only;
/// each level adds the previous one's chrome. Tool calls are name-gated
/// (`ChatFiltering.visibilityLevel`): ordinary tools enter at L1, `todo`
/// checklists at L2 (they render as results), `task` (subagent spawn)
/// blocks at L3 (agent internals, alongside thinking).
enum DetailLevel: Int, Sendable, CaseIterable {
    /// Assistant text turns only — zero thinking/toolcall/diff chrome.
    case l0 = 0
    /// Adds toolcall names, one line, collapsed.
    case l1
    /// Adds tool results (collapsed, tap to expand), diffs, and `todo`
    /// checklist rows.
    case l2
    /// Adds thinking blocks and `task` (subagent spawn) rows, collapsed.
    case l3
}
