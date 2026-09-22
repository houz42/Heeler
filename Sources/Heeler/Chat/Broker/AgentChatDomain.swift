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

/// command.invoke result — acceptance-only (§4a of the v3 design):
/// `accepted` is the terminal delivery state; no send.confirmed
/// correlation exists for commands (a command lands no user record,
/// or transformed text, so the prompt path's text-match origin proof
/// cannot apply).
struct AgentChatCommandResult: Decodable, Sendable, Equatable {
    let accepted: Bool
    let requestKey: String
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
/// renders — as a quiet block in the conversation flow. The KIND is
/// what the app actually knows, never the ambiguous wire `source`
/// ('remote' means any remote client — this device or another).
struct AgentChatInteractionResolution: Sendable, Equatable, Identifiable, Codable {
    /// What happened, from the app's point of view. The wire's
    /// outcome/source pair maps here at capture time; a resolution
    /// this device recorded itself is `youAnswered` (with labels).
    enum Kind: String, Sendable, Equatable, Codable {
        /// THIS device answered and the broker's acknowledgement
        /// CONFIRMED this client's submission; `labels` carries the
        /// chosen option LABELS (resolved against the interaction's
        /// questions at submit time — the wire's `idx:<n>` ids are
        /// never user-facing).
        case youAnswered
        /// Answered at the agent's own terminal.
        case answeredInTerminal
        /// Answered by SOME remote client — this device or another:
        /// the broadcast event cannot identify the winner, so before
        /// our own acknowledgement confirms the claim the honest
        /// record is neutral. Only the ack (accepted) upgrades this
        /// to `youAnswered`; a refusal keeps or replaces it.
        case answeredRemotely
        /// Cancelled (terminal or a remote client).
        case cancelled
        /// Expired before it was answered (generation churn or
        /// timeout).
        case expired
        /// The broker says the ask is no longer pending but the
        /// outcome is UNKNOWN (item_changed/item_not_found on a
        /// stale-answer self-heal — settled somewhere, proof of no
        /// particular outcome).
        case settledElsewhere
    }

    let requestId: String
    let kind: Kind
    /// The answered question's own text — the transcript anchor.
    /// The broker's resolved event carries no position, but the ask
    /// itself is IN the transcript (the agent's turn that posed it);
    /// the resolved block renders right after the message containing
    /// its question text, before the agent's reply that follows —
    /// never parked at the transcript's tail (that lands it after
    /// the very reply it produced). Nil (legacy/hand-built records
    /// or an unknown question) parks after the transcript rows as
    /// before.
    var questionText: String?
    /// The chosen option labels, one line per answered question
    /// (`youAnswered` only).
    var labels: [String]?

    var id: String { requestId }

    /// The transcript block's body: the quiet resolved record in the
    /// conversation flow.
    var transcriptBody: String {
        switch kind {
        case .youAnswered:
            if let labels, !labels.isEmpty {
                return "You answered: " + labels.joined(separator: " + ")
            }
            return "You answered."
        case .answeredInTerminal:
            return "Answered in the agent's terminal."
        case .answeredRemotely:
            return "Answered remotely."
        case .cancelled:
            return "The question was cancelled."
        case .expired:
            return "The question expired before it was answered."
        case .settledElsewhere:
            return "This question was already answered or cancelled elsewhere."
        }
    }

    /// Builds the resolution for an answer submitted by THIS device,
    /// resolving option ids to their user-facing labels against the
    /// interaction's questions. An id with no matching option is
    /// dropped, never rendered raw. Only the store's ACKNOWLEDGED
    /// answer path may record this kind — the broadcast event cannot
    /// identify the winner, so an unconfirmed submit never claims it.
    /// The FIRST question's text anchors the transcript block.
    init(
        answered interaction: AgentChatInteraction,
        answers: [AgentChatAnswer]
    ) {
        self.init(
            requestId: interaction.requestId,
            kind: .youAnswered,
            questionText: interaction.questions.first?.text,
            labels: Self.answeredLabels(
                interaction: interaction, answers: answers))
    }

    /// Maps a broker `interaction.resolved` event. source 'remote'
    /// means SOME remote client answered — this device or another —
    /// and the broadcast carries no winner correlation, so the
    /// honest pre-ack record is NEUTRAL: 'Answered remotely.' Only
    /// this store's own accepted acknowledgement upgrades the record
    /// to `youAnswered` (the store's ack path replaces this entry);
    /// a refused/uncertain submit never claims labels. The store
    /// supplies the question text (from the interaction it held)
    /// when it has one.
    init(
        requestId: String, wireOutcome: String, wireSource: String,
        questionText: String? = nil
    ) {
        let kind: Kind
        switch wireOutcome {
        case "answered":
            kind = wireSource == "remote"
                ? .answeredRemotely : .answeredInTerminal
        case "cancelled":
            kind = .cancelled
        case "expired":
            kind = .expired
        default:
            kind = .settledElsewhere
        }
        self.init(
            requestId: requestId, kind: kind,
            questionText: questionText, labels: nil)
    }

    /// The stale-answer self-heal: the broker refused the answer
    /// because the ask is no longer pending. The refusal's code says
    /// WHICH honest note applies — never a blanket 'expired'. The
    /// store supplies the question text when it held the interaction.
    init(
        staleRequestId: String, generationInvalidated: Bool,
        questionText: String? = nil
    ) {
        self.init(
            requestId: staleRequestId,
            kind: generationInvalidated ? .expired : .settledElsewhere,
            questionText: questionText,
            labels: nil)
    }

    init(
        requestId: String, kind: Kind,
        questionText: String? = nil, labels: [String]?
    ) {
        self.requestId = requestId
        self.kind = kind
        self.questionText = questionText
        self.labels = labels
    }

    private static func answeredLabels(
        interaction: AgentChatInteraction, answers: [AgentChatAnswer]
    ) -> [String]? {
        var lines: [String] = []
        for answer in answers {
            // Match the answer's question, then its options, by the
            // stable ids the interaction published.
            guard let question = interaction.questions.first(where: {
                $0.id == answer.questionId
            }) else { continue }
            let labels = answer.optionIds.compactMap { optionId in
                question.options.first(where: { $0.id == optionId })?.label
            }
            if !labels.isEmpty { lines.append(labels.joined(separator: " + ")) }
        }
        return lines.isEmpty ? nil : lines
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
