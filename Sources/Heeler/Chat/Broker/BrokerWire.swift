import Foundation

// SPDX-License-Identifier: Apache-2.0
//
// Wire codec for the native chat broker (v1 contract,
// broker-hardening-contract.md). Newline-delimited JSON frames, max
// 1048576 UTF-8 bytes per frame EXCLUDING the LF. Hello negotiation is
// the first step of every connection: proto:1 acked by
// {type:"hello",proto:1,maxFrameBytes}; a v0 broker sends no ack and the
// client falls back to the v0 arm (one version-gated branch, deleted once
// the deployed broker answers proto:1).

/// Protocol versions this client speaks. `v0` is the unversioned
/// prototype arm — used only when the broker sends no hello ack.
enum BrokerProto: Int, Sendable, Equatable {
    case v0 = 0
    case v1 = 1

    /// The version the client requests first on every connect.
    static let requested = BrokerProto.v1
}

/// One line-buffered frame reader with the contract's hard size cap.
/// UTF-8 frames split across reads are joined; a frame above the cap
/// (or undecodable bytes) is fatal: the peer is not speaking the
/// contract, so resyncing mid-stream would silently corrupt requests.
struct BrokerFrameReader: Sendable {
    let maxFrameBytes: Int
    private(set) var buffer = Data()

    init(maxFrameBytes: Int = 1_048_576) {
        self.maxFrameBytes = maxFrameBytes
    }

    enum FrameError: Error, Equatable, Sendable {
        case frameTooLarge(bytes: Int, cap: Int)
    }

    /// Feeds raw bytes; returns every complete frame. Throws when the
    /// pending partial frame already exceeds the cap — the caller must
    /// tear the connection down, never resync.
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

/// Encodes one outgoing frame (no trailing newline in the return value —
/// the channel appends it with the write).
enum BrokerFrameWriter {
    static func encode(_ object: some Encodable) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(object)
    }
}

// MARK: - Envelopes

/// The client hello. Fire-and-forget in v0; v1 brokers reply with
/// ``BrokerHelloAck``.
struct BrokerClientHello: Encodable, Sendable {
    let type = "client"
    var proto: Int? { protoValue }
    private let protoValue: Int?
    init(proto: BrokerProto?) {
        protoValue = proto.map(\.rawValue)
    }
}

/// The v1 broker's hello ack.
struct BrokerHelloAck: Decodable, Sendable, Equatable {
    let type: String
    let proto: Int
    /// The broker's frame cap; the client must honor it for writes.
    let maxFrameBytes: Int?

    var isV1: Bool { type == "hello" && proto == BrokerProto.v1.rawValue }
}

/// One request envelope: {id, method, instanceId?, generation?, params?}.
struct BrokerRequest: Encodable, Sendable {
    var id: String
    var method: String
    var instanceId: String?
    var generation: Int?
    var params: JSONValue?

    init(
        id: String, method: String, instanceId: String? = nil,
        generation: Int? = nil, params: JSONValue? = nil
    ) {
        self.id = id
        self.method = method
        self.instanceId = instanceId
        self.generation = generation
        self.params = params
    }
}

/// A response envelope: {id, result} or {id, error:{code,message}}.
struct BrokerResponseEnvelope: Decodable, Sendable {
    let id: String?
    let result: JSONValue?
    let error: BrokerWireError?
}

struct BrokerWireError: Decodable, Error, Sendable, Equatable {
    let code: String
    let message: String
}

/// A pushed frame that is not a response: events and session-unavailable
/// notices ride the same socket.
enum BrokerPushFrame: Sendable, Equatable {
    case event(BrokerEventFrame)
    case sessionUnavailable(instanceId: String)

    /// Decodes one frame line that carries no matching pending request.
    static func decode(line: Data) -> BrokerPushFrame? {
        guard let value = try? JSONDecoder().decode(JSONValue.self, from: line),
            case .object(let fields) = value
        else { return nil }
        switch fields["type"]?.stringValue {
        case "event":
            return BrokerEventFrame(json: value).map { .event($0) }
        case "session_unavailable":
            guard let instanceId = fields["instanceId"]?.stringValue else { return nil }
            return .sessionUnavailable(instanceId: instanceId)
        default:
            return nil
        }
    }
}

// MARK: - Event frames

/// One ordered live event: {type:"event", instanceId, generation, seq,
/// event:{kind, ...payload}}. Ordering holds only within one
/// (instanceId, generation); seq is strictly increasing there.
struct BrokerEventFrame: Sendable, Equatable {
    let instanceId: String
    let generation: Int
    let seq: Int
    let kind: String
    /// The event payload minus `kind` — schema-free like herdr events.
    let payload: JSONValue

    init(
        instanceId: String, generation: Int, seq: Int, kind: String,
        payload: JSONValue = .null
    ) {
        self.instanceId = instanceId
        self.generation = generation
        self.seq = seq
        self.kind = kind
        self.payload = payload
    }

    init?(json: JSONValue) {
        guard case .object(let fields) = json,
            let instanceId = fields["instanceId"]?.stringValue,
            let generation = fields["generation"]?.intValue,
            let seq = fields["seq"]?.intValue,
            case .object(let event)? = fields["event"],
            let kind = event["kind"]?.stringValue
        else { return nil }
        var payload = event
        payload["kind"] = nil
        self.init(
            instanceId: instanceId, generation: generation, seq: seq,
            kind: kind, payload: .object(payload))
    }

    /// Convenience field accessor into the payload.
    subscript(key: String) -> JSONValue? { payload[key] }
}

/// The event kinds the chat consumes. Unknown kinds are ignored — the
/// broker may add more; live events are provisional, history is truth.
enum BrokerEventKind: String, Sendable {
    case sessionIdentity = "session_identity"
    case agentStart = "agent_start"
    case agentEnd = "agent_end"
    case turnStart = "turn_start"
    case turnEnd = "turn_end"
    case messageStart = "message_start"
    case messageDelta = "message_delta"
    case messageEnd = "message_end"
    case toolStart = "tool_start"
    case toolUpdate = "tool_update"
    case toolEnd = "tool_end"
    case resyncRequired = "resync_required"
}
