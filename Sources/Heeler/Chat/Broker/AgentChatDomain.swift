import Foundation

// SPDX-License-Identifier: Apache-2.0
//
// agent-chat v1 normalized domain (contract §History/normalized
// domain): ChatItem/Block unions, granular capabilities, history pages
// with the throughSeq watermark, prompt dedup keys, dynamic commands,
// and the optional interactions model. No omp parentId, no JSONL
// surfaces — the adapter owns that mapping.

// MARK: - Registration

/// Granular capabilities from the register/registration frame. Each UI
/// affordance gates on its own flag; absent means honestly unsupported.
struct AgentChatCapabilities: Decodable, Sendable, Equatable {
    var history: Bool
    var streaming: Bool
    var prompt: Bool
    var interrupt: Bool
    var interactions: Bool
    var commands: Bool
    var attachments: Bool
    var branches: Bool

    init(
        history: Bool = false, streaming: Bool = false, prompt: Bool = false,
        interrupt: Bool = false, interactions: Bool = false, commands: Bool = false,
        attachments: Bool = false, branches: Bool = false
    ) {
        self.history = history
        self.streaming = streaming
        self.prompt = prompt
        self.interrupt = interrupt
        self.interactions = interactions
        self.commands = commands
        self.attachments = attachments
        self.branches = branches
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        // All optional in decode: an absent flag is a closed gate.
        history = try container.decodeIfPresent(Bool.self, forKey: .history) ?? false
        streaming = try container.decodeIfPresent(Bool.self, forKey: .streaming) ?? false
        prompt = try container.decodeIfPresent(Bool.self, forKey: .prompt) ?? false
        interrupt = try container.decodeIfPresent(Bool.self, forKey: .interrupt) ?? false
        interactions = try container.decodeIfPresent(Bool.self, forKey: .interactions) ?? false
        commands = try container.decodeIfPresent(Bool.self, forKey: .commands) ?? false
        attachments = try container.decodeIfPresent(Bool.self, forKey: .attachments) ?? false
        branches = try container.decodeIfPresent(Bool.self, forKey: .branches) ?? false
    }

    private enum CodingKeys: String, CodingKey {
        case history, streaming, prompt, interrupt, interactions, commands
        case attachments, branches
    }
}

/// One registration from sessions.list. Locator fields are
/// discovery-only opaque metadata — matched by exact string, never
/// parsed for transcript semantics.
struct AgentChatRegistration: Decodable, Sendable, Equatable {
    struct Locator: Decodable, Sendable, Equatable {
        var paneId: String?
        var sessionFile: String?
        /// Discovery-only process id; never used for matching.
        var pid: Int?
    }

    /// The adapter's declared agent identity; `version` may be
    /// "unknown" (pi.VERSION absent) and displays as-is.
    struct AgentIdentity: Decodable, Sendable, Equatable {
        var kind: String
        var version: String?
    }

    let instanceId: String
    let sessionId: String
    let generation: Int
    var title: String?
    var locator: Locator?
    var agent: AgentIdentity?
    var capabilities: AgentChatCapabilities

    init(
        instanceId: String, sessionId: String, generation: Int,
        title: String? = nil, locator: Locator? = nil,
        agent: AgentIdentity? = nil,
        capabilities: AgentChatCapabilities = AgentChatCapabilities()
    ) {
        self.instanceId = instanceId
        self.sessionId = sessionId
        self.generation = generation
        self.title = title
        self.locator = locator
        self.agent = agent
        self.capabilities = capabilities
    }
}

struct AgentChatSessionsResult: Decodable, Sendable, Equatable {
    let sessions: [AgentChatRegistration]
}

// MARK: - Session matching

/// The herdr-side pane identity: the `agent_session` value (a transcript
/// path) — matched against a registration's locator by EXACT string;
/// never parsed for transcript semantics.
struct HerdrPaneSessionIdentity: Sendable, Equatable {
    let sessionFilePath: String

    init(sessionFilePath: String) {
        self.sessionFilePath = sessionFilePath
    }
}

enum AgentChatMatch: Sendable, Equatable {
    case matched(AgentChatRegistration)
    case noRegistration
    /// Two registrations claim this pane — never an arbitrary pick.
    case ambiguous
}

enum AgentChatMatcher: Sendable {
    /// Locator (sessionFile exact) wins; sessionId alone can no longer
    /// disambiguate (duplicate sessionId is valid per the contract), so
    /// a locator-less match with duplicates fails closed.
    static func match(
        pane: HerdrPaneSessionIdentity,
        registrations: [AgentChatRegistration]
    ) -> AgentChatMatch {
        let byFile = Dictionary(
            grouping: registrations.filter {
                $0.locator?.sessionFile == pane.sessionFilePath
            },
            by: \.instanceId)
        switch byFile.count {
        case 1:
            return .matched(byFile.values.first![0])
        case 0:
            return .noRegistration
        default:
            return .ambiguous
        }
    }
}

// MARK: - Blocks

/// The normalized Block union. `tool_result` carries its own nested
/// content — pairing is by callId inside one message, never a separate
/// transcript record.
enum AgentChatBlock: Decodable, Sendable, Equatable {
    case text(String)
    case thinking(String)
    case toolCall(callId: String, name: String, arguments: JSONValue)
    case toolResult(callId: String, name: String?, isError: Bool, content: [AgentChatBlock])
    /// Image refs are never inline; v1 UI skips them in mapping (the
    /// blob.read client code exists but no row model yet).
    case image(mimeType: String, ref: String, byteLength: Int?)
    case unsupported(String)

    private enum CodingKeys: String, CodingKey {
        case type, text, callId, name, arguments, isError, content
        case mimeType, ref, byteLength, label
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(String.self, forKey: .type) {
        case "text":
            self = .text(try container.decode(String.self, forKey: .text))
        case "thinking":
            self = .thinking(try container.decode(String.self, forKey: .text))
        case "tool_call":
            self = .toolCall(
                callId: try container.decode(String.self, forKey: .callId),
                name: try container.decode(String.self, forKey: .name),
                arguments: try container.decode(JSONValue.self, forKey: .arguments))
        case "tool_result":
            self = .toolResult(
                callId: try container.decode(String.self, forKey: .callId),
                name: try container.decodeIfPresent(String.self, forKey: .name),
                isError: try container.decodeIfPresent(Bool.self, forKey: .isError) ?? false,
                content: try container.decodeIfPresent([AgentChatBlock].self, forKey: .content) ?? [])
        case "image":
            self = .image(
                mimeType: try container.decode(String.self, forKey: .mimeType),
                ref: try container.decode(String.self, forKey: .ref),
                byteLength: try container.decodeIfPresent(Int.self, forKey: .byteLength))
        case "unsupported":
            self = .unsupported(try container.decode(String.self, forKey: .label))
        default:
            throw DecodingError.dataCorruptedError(
                forKey: .type, in: container,
                debugDescription: "unknown block type")
        }
    }
}

// MARK: - ChatItem

/// The normalized ChatItem union. Stable source IDs; `reference` marks
/// an oversized item whose full bytes are behind item.read.
enum AgentChatItem: Decodable, Sendable, Equatable {
    struct Author: Decodable, Sendable, Equatable {
        enum Role: String, Decodable, Sendable {
            case user, assistant, system, tool
        }
        let role: Role
        var name: String?
    }

    case message(id: String, author: Author, createdAt: String?, blocks: [AgentChatBlock])
    case boundary(id: String, boundary: String, summary: String?, olderAvailable: Bool)
    case notice(id: String, text: String, level: String)
    case unsupported(id: String, sourceType: String, label: String)
    case reference(id: String, itemKind: String, byteLength: Int)

    private enum CodingKeys: String, CodingKey {
        case id, kind, author, createdAt, blocks, status
        case boundary, summary, olderAvailable
        case text, level, sourceType, label, itemKind, byteLength
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let id = try container.decode(String.self, forKey: .id)
        switch try container.decode(String.self, forKey: .kind) {
        case "message":
            self = .message(
                id: id,
                author: try container.decode(Author.self, forKey: .author),
                createdAt: try container.decodeIfPresent(String.self, forKey: .createdAt),
                blocks: try container.decode([AgentChatBlock].self, forKey: .blocks))
        case "boundary":
            self = .boundary(
                id: id,
                boundary: try container.decode(String.self, forKey: .boundary),
                summary: try container.decodeIfPresent(String.self, forKey: .summary),
                olderAvailable: try container.decode(Bool.self, forKey: .olderAvailable))
        case "notice":
            self = .notice(
                id: id,
                text: try container.decode(String.self, forKey: .text),
                level: try container.decode(String.self, forKey: .level))
        case "unsupported":
            self = .unsupported(
                id: id,
                sourceType: try container.decode(String.self, forKey: .sourceType),
                label: try container.decode(String.self, forKey: .label))
        case "reference":
            self = .reference(
                id: id,
                itemKind: try container.decode(String.self, forKey: .itemKind),
                byteLength: try container.decode(Int.self, forKey: .byteLength))
        default:
            throw DecodingError.dataCorruptedError(
                forKey: .kind, in: container,
                debugDescription: "unknown item kind")
        }
    }

    var id: String {
        switch self {
        case .message(let id, _, _, _), .boundary(let id, _, _, _),
            .notice(let id, _, _), .unsupported(let id, _, _), .reference(let id, _, _):
            return id
        }
    }
}

// MARK: - Pages

/// history.open / history.before result. `olderCursor: nil` is the
/// terminal signal (no hasOlder field exists). `throughSeq` is the
/// event watermark at page build: buffered events with seq <= it are
/// already reflected in the page.
struct AgentChatPage: Decodable, Sendable, Equatable {
    let sessionId: String
    let generation: Int
    let revision: String
    let throughSeq: Int
    let items: [AgentChatItem]
    let olderCursor: String?
}

// MARK: - Item reads

/// item.read / blob.read chunk response.
struct AgentChatChunk: Decodable, Sendable, Equatable {
    let encoding: String
    let offset: Int
    let totalBytes: Int
    let data: String
    let nextOffset: Int?

    var isFinal: Bool { nextOffset == nil }
}

/// Reassembles item.read chunk sequences into one canonical ChatItem.
/// A short final chunk or a wrong encoding is refused, never padded.
enum AgentChatChunkAssembler: Sendable {
    struct AssemblyError: Error, Equatable, Sendable {
        let reason: String
    }

    static func assemble(
        accumulated: Data, chunk: AgentChatChunk
    ) throws -> (partial: Data?, complete: Data?) {
        guard chunk.encoding == "json-utf8-base64",
            let bytes = Data(base64Encoded: chunk.data)
        else {
            throw AssemblyError(reason: "chunk is not json-utf8-base64")
        }
        var buffer = accumulated
        let end = chunk.offset + bytes.count
        if end > buffer.count {
            buffer.append(Data(repeating: 0, count: end - buffer.count))
        }
        buffer.replaceSubrange(chunk.offset..<end, with: bytes)
        guard chunk.isFinal else {
            return (buffer, nil)
        }
        guard buffer.count == chunk.totalBytes else {
            throw AssemblyError(
                reason: "final chunk leaves \(buffer.count) bytes, expected \(chunk.totalBytes)")
        }
        return (buffer, buffer)
    }
}

// MARK: - Prompt

struct AgentChatPromptResult: Decodable, Sendable, Equatable {
    let accepted: Bool
    let requestKey: String
}

// MARK: - Commands

/// commands.list is dynamic-only by construction ({complete:false}).
struct AgentChatCommandsResult: Decodable, Sendable, Equatable {
    struct Command: Decodable, Sendable, Equatable {
        let id: String
        let label: String
        var description: String?
    }
    let complete: Bool
    let commands: [Command]
}

// MARK: - Interactions (optional capability; gate stays closed without it)

/// One question inside a pending interaction. Multi-question and
/// multi-select are first-class — no single-ask assumption.
struct AgentChatQuestion: Decodable, Sendable, Equatable {
    struct Option: Decodable, Sendable, Equatable {
        let id: String
        let label: String
        var description: String?
    }
    let id: String
    let text: String
    var multi: Bool
    var recommendedOptionIds: [String]?
    var options: [Option]
    var allowCustom: Bool

    init(
        id: String, text: String, multi: Bool = false,
        recommendedOptionIds: [String]? = nil, options: [Option] = [],
        allowCustom: Bool = false
    ) {
        self.id = id
        self.text = text
        self.multi = multi
        self.recommendedOptionIds = recommendedOptionIds
        self.options = options
        self.allowCustom = allowCustom
    }

    private enum CodingKeys: String, CodingKey {
        case id, text, multi, recommendedOptionIds, options, allowCustom
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        text = try container.decode(String.self, forKey: .text)
        multi = try container.decodeIfPresent(Bool.self, forKey: .multi) ?? false
        recommendedOptionIds = try container.decodeIfPresent([String].self, forKey: .recommendedOptionIds)
        options = try container.decodeIfPresent([Option].self, forKey: .options) ?? []
        allowCustom = try container.decodeIfPresent(Bool.self, forKey: .allowCustom) ?? false
    }
}

/// A pending interaction: identity is the requestId; generation churn
/// invalidates the whole pending set. Replaces BrokerPendingAsk.
struct AgentChatInteraction: Decodable, Sendable, Equatable, Identifiable {
    let requestId: String
    let generation: Int
    let kind: String
    let questions: [AgentChatQuestion]

    var id: String { requestId }
}

struct AgentChatInteractionsResult: Decodable, Sendable, Equatable {
    let pending: [AgentChatInteraction]
}

/// One resolved ask (honest state): the card is gone but the WHY
/// renders — answered (with where: the agent's terminal vs this
/// client), cancelled, or expired.
struct AgentChatInteractionResolution: Sendable, Equatable, Identifiable {
    let requestId: String
    /// The wire outcome: answered / cancelled / expired.
    let outcome: String
    /// The wire source: remote (this client) / terminal.
    let source: String

    var id: String { requestId }

    /// The user-facing note.
    var message: String {
        switch outcome {
        case "answered":
            source == "remote"
                ? "Answered from this device."
                : "Answered in the agent's terminal."
        case "cancelled":
            "The question was cancelled."
        case "expired":
            "The question expired before it was answered."
        default:
            "The question was resolved."
        }
    }
}

/// One answer to one question of an interaction.
struct AgentChatAnswer: Encodable, Sendable, Equatable {
    let questionId: String
    let optionIds: [String]
    var customText: String?
    var note: String?
}


/// Pure interactions-snapshot merge with the two race rules (the
/// store's refreshInteractions delegates here):
/// - RACED-RESOLVED: tombstoned requestIds are excluded from the
///   snapshot install (a resolution racing the list never resurrects).
/// - RACED-OPENED: live arrivals not in the snapshot survive (the list
///   predates them).
enum AgentChatInteractionMerge: Sendable {
    static func install(
        snapshot: [AgentChatInteraction],
        live: [AgentChatInteraction],
        tombstones: Set<String>
    ) -> [AgentChatInteraction] {
        var byId = Dictionary(
            snapshot
                .filter { !tombstones.contains($0.requestId) }
                .map { ($0.requestId, $0) },
            uniquingKeysWith: { _, newest in newest })
        for arrival in live
        where byId[arrival.requestId] == nil
            && !tombstones.contains(arrival.requestId)
        {
            byId[arrival.requestId] = arrival
        }
        return byId.values.sorted { $0.requestId < $1.requestId }
    }
}
