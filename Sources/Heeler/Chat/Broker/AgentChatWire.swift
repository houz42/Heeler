import Foundation
import HeelerSSH

// SPDX-License-Identifier: Apache-2.0
//
// agent-chat v1 wire types (agent-chat-v1-contract.md): NDJSON, UTF-8
// strict, max frame 1 MiB including the newline. Typed envelopes:
// hello/welcome, request/response, event, register/registered. There is
// deliberately no legacy wire arm.

/// The only protocol version this build speaks.
let agentChatProtocolVersion = 1

/// One line-buffered frame reader with the contract's hard size cap.
/// Fail closed: an oversized or undecodable frame is fatal — the peer
/// is not speaking the contract, never resync.
struct AgentChatFrameReader: Sendable {
    let maxFrameBytes: Int
    private(set) var buffer = Data()

    init(maxFrameBytes: Int = 1_048_576) {
        self.maxFrameBytes = maxFrameBytes
    }

    enum FrameError: Error, Equatable, Sendable {
        case frameTooLarge(bytes: Int, cap: Int)
    }

    /// Feeds raw bytes; returns every complete frame (excluding LF).
    mutating func feed(_ chunk: Data) throws -> [Data] {
        buffer.append(chunk)
        var frames: [Data] = []
        while let newline = buffer.firstIndex(of: 0x0A) {
            let line = Data(buffer[..<newline])
            buffer.removeSubrange(...newline)
            guard line.count <= maxFrameBytes else {
                throw FrameError.frameTooLarge(bytes: line.count, cap: maxFrameBytes)
            }
            guard !line.isEmpty else { continue } // tolerate stray blank lines
            frames.append(line)
        }
        // A runaway sender without newlines must not grow unbounded.
        guard buffer.count <= maxFrameBytes else {
            throw FrameError.frameTooLarge(bytes: buffer.count, cap: maxFrameBytes)
        }
        return frames
    }
}

// MARK: - Envelopes

/// Client/adapter hello. The broker answers with ``AgentChatWelcome``;
/// any other reply or a version mismatch fails closed.
struct AgentChatHello: Encodable, Sendable {
    let type = "hello"
    /// `protocol` is a Swift keyword; the wire key is spelled via
    /// CodingKeys so the frame stays exactly the contract's shape.
    let protocolVersion = agentChatProtocolVersion
    /// This build is always the UI side.
    let peer = "client"

    private enum CodingKeys: String, CodingKey {
        case type
        case protocolVersion = "protocol"
        case peer
    }
}

/// The broker's hello ack. Version must match exactly.
struct AgentChatWelcome: Decodable, Sendable, Equatable {
    let type: String
    /// Wire key "protocol" (a Swift keyword; remapped in CodingKeys).
    let protocolVersion: Int
    let maxFrameBytes: Int?

    var isCurrentProtocol: Bool {
        type == "welcome" && protocolVersion == agentChatProtocolVersion
    }

    private enum CodingKeys: String, CodingKey {
        case type
        case protocolVersion = "protocol"
        case maxFrameBytes
    }
}

/// The routing target every agent-scoped request carries.
struct AgentChatTarget: Encodable, Equatable, Sendable {
    let instanceId: String
    let generation: Int
}

/// One request envelope. `target` is omitted for host-scoped methods
/// (sessions.list).
struct AgentChatRequest: Encodable, Sendable {
    var type = "request"
    var id: String
    var method: String
    var target: AgentChatTarget?
    var params: JSONValue?

    init(id: String, method: String, target: AgentChatTarget? = nil, params: JSONValue? = nil) {
        self.id = id
        self.method = method
        self.target = target
        self.params = params
    }
}

/// A response envelope: result OR error (never both).
struct AgentChatResponseEnvelope: Decodable, Sendable {
    let type: String?
    let id: String?
    let result: JSONValue?
    let error: AgentChatWireError?
}

struct AgentChatWireError: Decodable, Error, Sendable, Equatable {
    let code: String
    let message: String
    let retryable: Bool?
}

/// One routed event frame.
struct AgentChatEventFrame: Sendable, Equatable {
    let instanceId: String
    let generation: Int
    let seq: Int
    /// The event payload's own `type` discriminator.
    let type: String
    /// The payload minus `type`.
    let payload: JSONValue

    init(instanceId: String, generation: Int, seq: Int, type: String, payload: JSONValue = .null) {
        self.instanceId = instanceId
        self.generation = generation
        self.seq = seq
        self.type = type
        self.payload = payload
    }

    init?(json: JSONValue) {
        guard case .object(let fields) = json,
            let instanceId = fields["instanceId"]?.stringValue,
            let generation = fields["generation"]?.intValue,
            let seq = fields["seq"]?.intValue,
            case .object(let event)? = fields["event"],
            let type = event["type"]?.stringValue
        else { return nil }
        var payload = event
        payload["type"] = nil
        self.init(
            instanceId: instanceId, generation: generation, seq: seq,
            type: type, payload: .object(payload))
    }

    subscript(key: String) -> JSONValue? { payload[key] }
}

/// Non-response pushes the client consumes.
enum AgentChatPushFrame: Sendable, Equatable {
    case event(AgentChatEventFrame)
    case sessionUnavailable

    static func decode(line: Data) -> AgentChatPushFrame? {
        guard let value = try? JSONDecoder().decode(JSONValue.self, from: line),
            case .object(let fields) = value,
            let type = fields["type"]?.stringValue
        else { return nil }
        switch type {
        case "event":
            return AgentChatEventFrame(json: value).map { .event($0) }
        case "session.unavailable":
            return .sessionUnavailable
        default:
            return nil
        }
    }
}

// MARK: - Error taxonomy

/// The contract's stable error codes, mapped to client behavior.
/// Unknown codes surface as failures — never guessed.
enum AgentChatError: Error, Sendable, Equatable {
    case wire(code: String, message: String, retryable: Bool)
    case unsupportedProtocol
    case connectionClosed
    case frameTooLarge(bytes: Int, cap: Int)
    case timedOut(method: String)
    case ambiguousSession

    static func from(_ wire: AgentChatWireError) -> AgentChatError {
        if wire.code == "ambiguous_session" {
            return .ambiguousSession
        }
        return .wire(code: wire.code, message: wire.message, retryable: wire.retryable ?? false)
    }

    /// sessionId+generation churn or adapter loss ⇒ the store re-matches
    /// and re-opens (full resync).
    var requiresFullResync: Bool {
        switch self {
        case .ambiguousSession: return false  // terminal, not resynced
        case .wire(let code, _, _):
            switch code {
            case "session_unavailable", "stale_generation", "timeout":
                return true
            default:
                return false
            }
        default:
            return false
        }
    }

    /// Cursor invalidation ⇒ fresh open on the same registration.
    var requiresFreshOpen: Bool {
        guard case .wire(let code, _, _) = self else { return false }
        switch code {
        case "stale_cursor", "cursor_invalid":
            return true
        default:
            return false
        }
    }
}
