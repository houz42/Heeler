import Foundation
import HeelerSSH

// SPDX-License-Identifier: Apache-2.0
//
// One broker connection: a single long-lived direct-streamlocal channel
// to the configured socket, carrying hello negotiation, correlated
// requests, and pushed events. One channel per host connection mirrors
// ADR 0011's dedicated-channel discipline (like Events).

/// A raw byte pipe to a broker socket — the seam SSH production and
/// tests share. Production is `SSHStreamLocalChannel`; tests use
/// scripted pairs.
protocol BrokerBytePipe: Sendable {
    func write(_ data: Data, timeout: Duration) async throws
    /// Reads the next available bytes; nil after orderly remote EOF.
    func read(maximumBytes: Int, timeout: Duration) async throws -> Data?
    func close(timeout: Duration) async throws
}

extension SSHStreamLocalChannel: BrokerBytePipe {}

/// Events + lifecycle delivered from the channel to its owner.
struct BrokerChannelEvent: Sendable, Equatable {
    enum kind: Sendable, Equatable {
        case pushed(BrokerPushFrame)
        case disconnected(reason: String?)
        case protocolError(String)
    }
    let kind: BrokerChannelEvent.kind
}

/// The wire channel. Owns framing, request ids, pending-request
/// correlation, timeouts, hello negotiation, and the reader loop. The
/// onEvent callback fires on the actor's executor; the store hops to
/// MainActor itself.
actor BrokerChannel {
    private let pipe: BrokerBytePipe
    private let requestTimeout: Duration
    private let continuation: AsyncStream<BrokerChannelEvent>.Continuation

    private var nextID = 0
    private var pending: [String: PendingSlot] = [:]
    private var readerTask: Task<Void, Never>?
    private var closed = false
    private var helloContinuation:
        CheckedContinuation<BrokerHelloAck?, Never>?

    /// Negotiated state, readable after `connect`.
    private(set) var proto: BrokerProto = .v0
    private(set) var maxFrameBytes = 1_048_576

    init(
        pipe: BrokerBytePipe,
        requestTimeout: Duration = .seconds(30),
        onEvent: @escaping @Sendable (BrokerChannelEvent) -> Void
    ) {
        self.pipe = pipe
        self.requestTimeout = requestTimeout
        let (stream, continuation) = AsyncStream<BrokerChannelEvent>.makeStream()
        self.continuation = continuation
        readerTask = Task {
            for await event in stream {
                onEvent(event)
            }
        }
    }

    /// Connects and negotiates. MUST be the first call. Sends hello with
    /// proto:1; a v1 ack flips the v1 arm, anything else (no ack within
    /// the window, or an unknown-method error) keeps the v0 arm — the
    /// one version-gated legacy branch, deleted once every deployed
    /// broker answers proto:1.
    func connect() async throws {
        // Reader BEFORE the race: the ack (or a v0 broker's non-reply)
        // is only observed because the reader is consuming frames while
        // connect awaits the hello continuation.
        startReader()
        try await send(BrokerFrameWriter.encode(BrokerClientHello(proto: .requested)))
        let body = Task<BrokerHelloAck?, Never> {
            await withCheckedContinuation {
                (continuation: CheckedContinuation<BrokerHelloAck?, Never>) in
                self.installHelloContinuation(continuation)
            }
        }
        let timer = Task {
            try? await Task.sleep(for: .seconds(3))
            await self.expireHello()
        }
        defer { timer.cancel() }
        let ack = await body.value
        if let ack, ack.isV1 {
            proto = .v1
            maxFrameBytes = ack.maxFrameBytes ?? maxFrameBytes
        }
        // No ack or not v1: v0 arm. A v0 broker ignores the hello frame.
    }

    private func installHelloContinuation(
        _ continuation: CheckedContinuation<BrokerHelloAck?, Never>
    ) {
        // Registered synchronously on the actor; the reader (or the
        // expiry timer) is the single resumer.
        helloContinuation = continuation
    }

    private func expireHello() {
        helloContinuation?.resume(returning: nil)
        helloContinuation = nil
    }

    /// Resolves a pending hello when the reader sees an ack (or a
    /// non-hello frame first: v0 brokers never answer hello).
    private func resolveHello(_ ack: BrokerHelloAck?) {
        helloContinuation?.resume(returning: ack)
        helloContinuation = nil
    }

    private func startReader() {
        readerTask = Task {
            var reader = BrokerFrameReader(maxFrameBytes: 1_048_576)
            while !Task.isCancelled {
                let chunk: Data?
                do {
                    chunk = try await pipe.read(
                        maximumBytes: 16 * 1024, timeout: .seconds(1))
                } catch {
                    finish(.disconnected(reason: String(describing: error)))
                    return
                }
                guard let chunk else {
                    finish(.disconnected(reason: "broker closed the connection"))
                    return
                }
                do {
                    let frames = try reader.feed(chunk)
                    for frame in frames {
                        handle(frame)
                    }
                } catch {
                    finish(.protocolError(String(describing: error)))
                    return
                }
            }
        }
    }

    private func handle(_ frame: Data) {
        // Response (an id matching a pending request), hello ack, or
        // push (event / session_unavailable).
        if let envelope = try? JSONDecoder().decode(
            BrokerResponseEnvelope.self, from: frame),
            let id = envelope.id, let entry = pending.removeValue(forKey: id)
        {
            if let error = envelope.error {
                entry.resume(throwing: BrokerClientError.from(error))
            } else if let result = envelope.result {
                entry.resume(returning: result)
            } else {
                entry.resume(
                    throwing: BrokerClientError.broker(
                        code: "invalid_response",
                        message: "reply carried neither result nor error"))
            }
            return
        }
        if let ack = try? JSONDecoder().decode(BrokerHelloAck.self, from: frame),
            ack.type == "hello"
        {
            resolveHello(ack)
            return
        }
        if let push = BrokerPushFrame.decode(line: frame) {
            continuation.yield(.init(kind: .pushed(push)))
            return
        }
        // A v0 broker's error reply to hello arrives with an unmatched
        // or missing id — resolve negotiation so the v0 arm engages
        // immediately instead of burning the full hello window.
        if let reply = try? JSONDecoder().decode(
            HelloErrorReply.self, from: frame), reply.error != nil
        {
            resolveHello(nil)
        }
    }

    private struct HelloErrorReply: Decodable {
        let id: String?
        let error: BrokerWireError?
    }

    private func finish(_ event: BrokerChannelEvent.kind) {
        for (_, entry) in pending {
            entry.resume(throwing: BrokerClientError.connectionClosed)
        }
        pending.removeAll()
        resolveHello(nil)
        continuation.yield(.init(kind: event))
        continuation.finish()
    }

    /// Sends a request envelope and awaits its result value.
    func request(_ request: BrokerRequest) async throws -> JSONValue {
        guard !closed else { throw BrokerClientError.connectionClosed }
        let id = "c\(nextID)"
        nextID &+= 1
        var envelope = request
        envelope.id = id
        let bytes: Data
        do {
            bytes = try BrokerFrameWriter.encode(envelope)
        } catch {
            throw BrokerClientError.broker(
                code: "invalid_request", message: "failed to encode request")
        }
        guard bytes.count + 1 <= maxFrameBytes else {
            throw BrokerClientError.frameTooLarge(
                bytes: bytes.count, cap: maxFrameBytes)
        }
        // Synchronous registration on the actor BEFORE any write: a
        // reply can only be handled by handle() — also actor-isolated —
        // so once pending[id] is set here, no interleaving can miss it.
        let slot = PendingSlot()
        pending[id] = slot
        let timer = Task {
            try? await Task.sleep(for: requestTimeout)
            await self.expireRequest(id)
        }
        defer {
            timer.cancel()
            if pending[id] === slot { pending[id] = nil }
        }
        try await send(bytes)
        return try await slot.awaitResult()
    }

    /// One awaited reply: `request` installs the slot synchronously (so
    /// no reply can race ahead of registration), then suspends on this
    /// continuation exactly once — resumed by handle/expire/finish.
    private final class PendingSlot: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation:
            CheckedContinuation<JSONValue, any Error>?

        func install(
            _ continuation: CheckedContinuation<JSONValue, any Error>
        ) {
            lock.lock(); defer { lock.unlock() }
            self.continuation = continuation
        }

        func resume(returning value: JSONValue) {
            lock.lock(); defer { lock.unlock() }
            continuation?.resume(returning: value)
            continuation = nil
        }

        func resume(throwing error: any Error) {
            lock.lock(); defer { lock.unlock() }
            continuation?.resume(throwing: error)
            continuation = nil
        }

        func awaitResult() async throws -> JSONValue {
            try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation {
                    (continuation: CheckedContinuation<JSONValue, any Error>) in
                    install(continuation)
                }
            } onCancel: {
                resume(throwing: BrokerClientError.connectionClosed)
            }
        }
    }

    private func expireRequest(_ id: String) {
        if let entry = pending.removeValue(forKey: id) {
            entry.resume(
                throwing: BrokerClientError.timedOut(method: "request \(id)"))
        }
    }

    private func send(_ data: Data) async throws {
        var framed = data
        framed.append(0x0A)
        try await pipe.write(framed, timeout: .seconds(10))
    }

    func close() async {
        guard !closed else { return }
        closed = true
        readerTask?.cancel()
        try? await pipe.close(timeout: .seconds(2))
        finish(.disconnected(reason: "closed by client"))
    }
}
