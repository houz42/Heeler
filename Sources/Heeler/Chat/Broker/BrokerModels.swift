import Foundation

// SPDX-License-Identifier: Apache-2.0
//
// Domain types for the broker chat backend: session registrations,
// history pages (stub-aware per the v1 contract), entry detail (v1 byte
// slices vs the v0 bounded object), and the client error taxonomy.

/// One registration from the `sessions` result. v1 adds sessionFile /
/// paneId / pid; all three are optional-additive so decoding tolerates a
/// v0 broker.
struct BrokerSessionRegistration: Sendable, Equatable, Decodable {
    let instanceId: String
    let sessionId: String
    let generation: Int
    let capabilities: [String]
    let sessionFile: String?
    let paneId: String?
    let pid: Int?

    init(
        instanceId: String, sessionId: String, generation: Int,
        capabilities: [String] = [], sessionFile: String? = nil,
        paneId: String? = nil, pid: Int? = nil
    ) {
        self.instanceId = instanceId
        self.sessionId = sessionId
        self.generation = generation
        self.capabilities = capabilities
        self.sessionFile = sessionFile
        self.paneId = paneId
        self.pid = pid
    }

    private enum CodingKeys: String, CodingKey {
        case instanceId, sessionId, generation, capabilities
        case sessionFile, paneId, pid
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        instanceId = try container.decode(String.self, forKey: .instanceId)
        sessionId = try container.decode(String.self, forKey: .sessionId)
        generation = try container.decode(Int.self, forKey: .generation)
        capabilities = try container.decodeIfPresent([String].self, forKey: .capabilities) ?? []
        sessionFile = try container.decodeIfPresent(String.self, forKey: .sessionFile)
        paneId = try container.decodeIfPresent(String.self, forKey: .paneId)
        pid = try container.decodeIfPresent(Int.self, forKey: .pid)
    }

    var hasHistory: Bool { capabilities.contains("history") }
    var hasEvents: Bool { capabilities.contains("events") }
    var hasPrompt: Bool { capabilities.contains("prompt") }
}

/// `sessions` result.
struct BrokerSessionsResult: Decodable, Sendable {
    let sessions: [BrokerSessionRegistration]
}

// MARK: - Session matching

/// The herdr-side identity of the pane whose chat is being opened: the
/// `agent_session` file path (exact) plus the sessionId extracted from
/// it (fallback key).
struct HerdrPaneSessionIdentity: Sendable, Equatable {
    let sessionFilePath: String
    let sessionId: String?

    init(sessionFilePath: String) {
        self.sessionFilePath = sessionFilePath
        self.sessionId = Self.sessionId(fromPath: sessionFilePath)
    }

    /// omp session files end in `<ISO>_<uuid>.jsonl`; the uuid is the
    /// broker's sessionId. Non-matching paths yield nil — matching then
    /// falls back to v0 fail-closed behavior.
    static func sessionId(fromPath path: String) -> String? {
        guard path.hasSuffix(".jsonl"),
            let name = path.split(separator: "/").last,
            let underscore = name.lastIndex(of: "_")
        else { return nil }
        let candidate = name[name.index(after: underscore)..<name.index(name.endIndex, offsetBy: -6)]
        return Self.isUUID(candidate) ? String(candidate) : nil
    }

    private static func isUUID(_ text: Substring) -> Bool {
        text.count == 36
            && text.split(separator: "-", omittingEmptySubsequences: false).count == 5
            && text.allSatisfy { $0.isHexDigit || $0 == "-" }
    }
}

/// The outcome of matching a pane against the broker's registrations.
/// Duplicate sessionIds are NEVER picked arbitrarily — ambiguous fails
/// closed (the UI shows an honest unresolved state).
enum BrokerSessionMatch: Sendable, Equatable {
    case matched(BrokerSessionRegistration)
    case noRegistration
    case ambiguous(reason: String)
}

enum BrokerSessionMatcher: Sendable {
    /// sessionFile (exact string, v1) wins; sessionId alone (v0) requires
    /// exactly one live registration — two or more means ambiguous.
    static func match(
        pane: HerdrPaneSessionIdentity,
        registrations: [BrokerSessionRegistration]
    ) -> BrokerSessionMatch {
        // v1 identity: exact session-file match. Two registrations naming
        // the same file is still ambiguous (a re-registration gap).
        let byFile = registrations.filter { $0.sessionFile == pane.sessionFilePath }
        let uniqueByFile = Dictionary(grouping: byFile, by: \.instanceId)
        if uniqueByFile.count == 1 {
            return .matched(uniqueByFile.values.first![0])
        }
        if uniqueByFile.count > 1 {
            return .ambiguous(
                reason: "Multiple agents claim the same session file. Wait for "
                    + "the stale one to disconnect, then reopen.")
        }

        // v0 fallback: sessionId extracted from the path, unique only.
        guard let sessionId = pane.sessionId else {
            return .noRegistration
        }
        let byId = Dictionary(
            grouping: registrations.filter { $0.sessionId == sessionId },
            by: \.instanceId)
        if byId.isEmpty {
            // No file match AND no id match: the pane is not registered.
            // (byFile was empty here, so this is genuinely absent.)
            return .noRegistration
        }
        if byId.count > 1 {
            return .ambiguous(
                reason: "More than one agent is registered for this session. "
                    + "Heeler cannot tell which one is live, so it will not guess.")
        }
        return .matched(byId.values.first![0])
    }
}

// MARK: - History pages

/// One page item. v1 contract: an oversized item arrives as a stub
/// {id,parentId,type,role?,detailRequired:true,serializedBytes} — the
/// full item is behind the `entry` method and must never render as if
/// complete.
struct BrokerHistoryItem: Sendable, Equatable, Decodable {
    let id: String
    let parentId: String?
    let timestamp: String?
    let type: String
    let role: String?
    let detailRequired: Bool
    let serializedBytes: Int?
    /// Present when the item came inline (v0 pages, small v1 items).
    var full: JSONValue?

    init(
        id: String, parentId: String?, timestamp: String?, type: String,
        role: String?, detailRequired: Bool, serializedBytes: Int? = nil,
        full: JSONValue? = nil
    ) {
        self.id = id
        self.parentId = parentId
        self.timestamp = timestamp
        self.type = type
        self.role = role
        self.detailRequired = detailRequired
        self.serializedBytes = serializedBytes
        self.full = full
    }

    private enum CodingKeys: String, CodingKey {
        case id, parentId, timestamp, type, role, detailRequired, serializedBytes
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        parentId = try container.decodeIfPresent(String.self, forKey: .parentId)
        timestamp = try container.decodeIfPresent(String.self, forKey: .timestamp)
        type = try container.decode(String.self, forKey: .type)
        role = try container.decodeIfPresent(String.self, forKey: .role)
        detailRequired =
            try container.decodeIfPresent(Bool.self, forKey: .detailRequired) ?? false
        serializedBytes = try container.decodeIfPresent(Int.self, forKey: .serializedBytes)
        // The full item (when inline) is the whole JSON object minus the
        // stub-only fields; kept raw so mapping needs no re-decode.
        let full = try JSONValue(from: decoder)
        if case .object(var fields) = full {
            fields["detailRequired"] = nil
            fields["serializedBytes"] = nil
            self.full = .object(fields)
        } else {
            self.full = nil
        }
    }
}

/// `open`/`history` result. `olderCursor` stays opaque: the client only
/// hands it back; decode happens in codec tests only.
struct BrokerHistoryPage: Decodable, Sendable, Equatable {
    let sessionId: String
    let leafId: String?
    /// Chronological order (oldest first) per the prototype's emitted shape.
    let items: [BrokerHistoryItem]
    let olderCursor: String?
    let hasOlder: Bool

    init(
        sessionId: String, leafId: String?, items: [BrokerHistoryItem],
        olderCursor: String?, hasOlder: Bool
    ) {
        self.sessionId = sessionId
        self.leafId = leafId
        self.items = items
        self.olderCursor = olderCursor
        self.hasOlder = hasOlder
    }
}

// MARK: - Entry detail

/// v1 entry response: {entryId, encoding:"json-utf8-base64", offset,
/// totalBytes, data, nextOffset}. `data` is one base64 UTF-8 byte slice
/// of the canonical full HistoryItem JSON; slices are reassembled to
/// totalBytes, then decoded once.
struct BrokerEntrySlice: Decodable, Sendable, Equatable {
    let entryId: String
    let encoding: String
    let offset: Int
    let totalBytes: Int
    let data: String
    let nextOffset: Int?

    var isFinal: Bool { nextOffset == nil }
}

/// The v0 entry response: the full bounded detail object inline.
/// LEGACY-ARM: deleted once the deployed broker answers proto:1.
struct BrokerEntryDetailV0: Decodable, Sendable {
    let id: String
    let blocks: JSONValue?
    let content: String?
    let contentBytes: Int?
    let contentTruncated: Bool?
    let role: String?
}

/// Reassembles v1 entry slices into one canonical HistoryItem JSON.
enum BrokerEntryAssembler: Sendable {
    struct AssemblyError: Error, Equatable, Sendable {
        let reason: String
    }

    /// Appends one slice's decoded bytes at its offset; returns the
    /// complete data when the final slice arrived.
    static func assemble(
        accumulated: Data, slice: BrokerEntrySlice
    ) throws -> (data: Data?, complete: Data?) {
        guard slice.encoding == "json-utf8-base64",
            let bytes = Data(base64Encoded: slice.data)
        else {
            throw AssemblyError(reason: "entry slice is not json-utf8-base64")
        }
        var buffer = accumulated
        let end = slice.offset + bytes.count
        if end > buffer.count {
            buffer.append(Data(repeating: 0, count: end - buffer.count))
        }
        buffer.replaceSubrange(
            slice.offset..<end, with: bytes)
        guard slice.isFinal else {
            return (buffer, nil)
        }
        guard buffer.count == slice.totalBytes else {
            throw AssemblyError(
                reason: "final slice leaves \(buffer.count) bytes, expected \(slice.totalBytes)")
        }
        return (buffer, buffer)
    }
}

// MARK: - Error taxonomy

/// The codes the client maps to behavior. Unknown codes surface as
/// errors without any guessing.
enum BrokerClientError: Error, Sendable, Equatable {
    case broker(code: String, message: String)
    case frameTooLarge(bytes: Int, cap: Int)
    case unsupportedProtocol
    case connectionClosed
    case timedOut(method: String)
    case ambiguous(reason: String)

    static func from(_ wire: BrokerWireError) -> BrokerClientError {
        .broker(code: wire.code, message: wire.message)
    }

    /// The resync ladder from the client's coordination contract:
    /// generation churn or agent loss ⇒ full resync (re-sessions,
    /// re-match, re-open); unknown session ⇒ re-sessions; branch
    /// invalidation ⇒ fresh open on the same registration; anything else
    /// is an ordinary failure.
    var requiresFullResync: Bool {
        guard case .broker(let code, _) = self else { return false }
        switch code {
        case "stale_generation", "generation_mismatch", "session_unavailable",
            "unknown_session", "timeout":
            return true
        default:
            return false
        }
    }

    var requiresFreshOpen: Bool {
        guard case .broker(let code, _) = self else { return false }
        switch code {
        case "cursor_invalid", "cursor_branch_invalidated", "cursor_session_mismatch":
            return true
        default:
            return false
        }
    }

    var isAskUnsupported: Bool {
        guard case .broker(let code, _) = self else { return false }
        return code == "unsupported_capability"
    }
}

// MARK: - Prompt + commands results

struct BrokerPromptResult: Decodable, Sendable {
    let queued: Bool
}

/// `commands` is explicitly dynamic-only ({scope:"dynamic",
/// complete:false}); the UI never treats it as the full palette.
struct BrokerCommandsResult: Decodable, Sendable {
    struct Command: Decodable, Sendable, Equatable {
        let name: String
        let description: String?
    }
    let commands: [Command]
    var scope: String?
    var complete: Bool?
}

// MARK: - Ask capability (design-time model; gate stays CLOSED)

/// One broker-side ask dialog, keyed for the future ask-wrapper protocol
/// (ask_pending/ask_resolved events + ask_pending snapshot). The card
/// model is (requestId, optionId) keyed so the later wiring is data-only;
/// the UI gate (`askUnsupported`) stays on until the integrated contract
/// lands — this type is NOT advertised as a capability yet.
///
/// Design constraints from the prototype review:
/// - A late subscriber can miss a live ask_pending event, so the store
///   renders pending asks from a SNAPSHOT first, events second.
/// - Multiple asks may be pending at once (no single-pending assumption);
///   identity is the requestId, never array position.
/// - optionId is opaque and travels with its label; option payloads are
///   omitted in v1 and must not be assumed.
struct BrokerPendingAskOption: Sendable, Equatable {
    /// Opaque wire key; travels back on the answer call untouched.
    let optionId: String
    /// Display-only label.
    let label: String

    init(optionId: String, label: String) {
        self.optionId = optionId
        self.label = label
    }
}

struct BrokerPendingAsk: Sendable, Equatable, Identifiable {
    let requestId: String
    let question: String
    /// Option pairs; payloads are omitted in v1 and never assumed.
    let options: [BrokerPendingAskOption]

    var id: String { requestId }

    init(requestId: String, question: String, options: [BrokerPendingAskOption]) {
        self.requestId = requestId
        self.question = question
        self.options = options
    }

    /// Maps onto the chat layer's PendingInteraction (label-rendering
    /// row). The optionId keying is preserved for the answer call.
    var interaction: PendingInteraction {
        PendingInteraction(
            id: requestId,
            question: question,
            options: options.map(\.label))
    }
}

/// The pending-ask state reducer: snapshot (authoritative) + live events
/// (incremental), resolution removes exactly the resolved requestId.
/// Pure so the store's ask wiring stays one-line folds.
enum BrokerPendingAsks: Sendable {
    /// Decodes a `ask_pending` snapshot array (the late-subscriber path).
    static func mergeSnapshot(
        _ asks: [BrokerPendingAsk], into pending: [BrokerPendingAsk]
    ) -> [BrokerPendingAsk] {
        var byId = Dictionary(pending.map { ($0.requestId, $0) }, uniquingKeysWith: { _, new in new })
        for ask in asks {
            byId[ask.requestId] = ask
        }
        return byId.values.sorted { $0.requestId < $1.requestId }
    }

    /// One ask_pending event: upsert keyed by requestId (a replayed or
    /// re-announced ask replaces, never duplicates).
    static func upsert(
        _ ask: BrokerPendingAsk, into pending: [BrokerPendingAsk]
    ) -> [BrokerPendingAsk] {
        mergeSnapshot([ask], into: pending)
    }

    /// One ask_resolved event: remove exactly that requestId; a
    /// resolution for an unknown id is a no-op (late replay), never an
    /// error state.
    static func resolve(
        requestId: String, in pending: [BrokerPendingAsk]
    ) -> [BrokerPendingAsk] {
        pending.filter { $0.requestId != requestId }
    }
}
