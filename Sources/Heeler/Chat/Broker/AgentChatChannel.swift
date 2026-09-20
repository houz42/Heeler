import Foundation
import HeelerSSH

// SPDX-License-Identifier: Apache-2.0
//
// One agent-chat v1 broker connection over a single long-lived
// direct-streamlocal channel: typed hello/welcome negotiation (no
// legacy arm — version mismatch fails closed), request correlation,
// per-request timeout, and the routed event stream.

/// A raw byte pipe to the broker socket — the seam SSH production and
/// tests share.
protocol AgentChatBytePipe: Sendable {
    func write(_ data: Data, timeout: Duration) async throws
    /// Reads the next available bytes; nil after orderly remote EOF.
    func read(maximumBytes: Int, timeout: Duration) async throws -> Data?
    func close(timeout: Duration) async throws
}

extension SSHStreamLocalChannel: AgentChatBytePipe {}

/// Events + lifecycle delivered to the owner.
struct AgentChatChannelEvent: Sendable, Equatable {
    enum kind: Sendable, Equatable {
        case pushed(AgentChatPushFrame)
        case disconnected(reason: String?)
        case protocolError(String)
    }
    let kind: AgentChatChannelEvent.kind
}

actor AgentChatChannel {
    private let pipe: AgentChatBytePipe
    private let requestTimeout: Duration
    private let continuation: AsyncStream<AgentChatChannelEvent>.Continuation

    private var nextID = 0
    private var pending: [String: PendingSlot] = [:]
    private var readerTask: Task<Void, Never>?
    private var closed = false
    private var welcomeSlot: WelcomeSlot?

    /// Negotiated after `connect`: the broker's max frame size.
    private(set) var maxFrameBytes = 1_048_576

    init(
        pipe: AgentChatBytePipe,
        requestTimeout: Duration = .seconds(30),
        onEvent: @escaping @Sendable (AgentChatChannelEvent) -> Void
    ) {
        self.pipe = pipe
        self.requestTimeout = requestTimeout
        let (stream, continuation) = AsyncStream<AgentChatChannelEvent>.makeStream()
        self.continuation = continuation
        readerTask = Task {
            for await event in stream {
                onEvent(event)
            }
        }
    }

    /// Connects and negotiates. MUST be the first call. Sends the typed
    /// hello; anything but a matching welcome fails closed
    /// (unsupportedProtocol) — no legacy arm.
    func connect() async throws {
        let slot = WelcomeSlot()
        welcomeSlot = slot
        startReader()
        try await send(try JSONEncoder().encode(AgentChatHello()))
        let timer = Task {
            try? await Task.sleep(for: .seconds(3))
            await self.expireWelcome()
        }
        defer { timer.cancel() }
        guard let welcome = await slot.awaitWelcome(),
            welcome.isCurrentProtocol
        else {
            throw AgentChatError.unsupportedProtocol
        }
        maxFrameBytes = welcome.maxFrameBytes ?? maxFrameBytes
    }

    // MARK: Welcome slot (single resumer, early-delivery buffered)

    private final class WelcomeSlot: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<AgentChatWelcome?, Never>?
        private var buffered: AgentChatWelcome?
        private var delivered = false

        func install(
            _ continuation: CheckedContinuation<AgentChatWelcome?, Never>
        ) {
            lock.lock(); defer { lock.unlock() }
            if delivered {
                continuation.resume(returning: buffered)
                return
            }
            self.continuation = continuation
        }

        func deliver(_ welcome: AgentChatWelcome?) {
            lock.lock(); defer { lock.unlock() }
            guard !delivered else { return }
            delivered = true
            buffered = welcome
            continuation?.resume(returning: welcome)
            continuation = nil
        }

        func awaitWelcome() async -> AgentChatWelcome? {
            await withTaskCancellationHandler {
                await withCheckedContinuation {
                    (continuation: CheckedContinuation<AgentChatWelcome?, Never>) in
                    install(continuation)
                }
            } onCancel: {
                deliver(nil)
            }
        }
    }

    private func resolveWelcome(_ welcome: AgentChatWelcome?) {
        welcomeSlot?.deliver(welcome)
        welcomeSlot = nil
    }

    private func expireWelcome() {
        welcomeSlot?.deliver(nil)
        welcomeSlot = nil
    }

    // MARK: Reader

    private func startReader() {
        readerTask = Task {
            var reader = AgentChatFrameReader(maxFrameBytes: 1_048_576)
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
        // Response (id matching a pending request), welcome, or push.
        if let envelope = try? JSONDecoder().decode(
            AgentChatResponseEnvelope.self, from: frame),
            envelope.type == "response",
            let id = envelope.id,
            let slot = pending.removeValue(forKey: id)
        {
            if let error = envelope.error {
                slot.resume(throwing: AgentChatError.from(error))
            } else if let result = envelope.result {
                slot.resume(returning: result)
            } else {
                slot.resume(
                    throwing: AgentChatError.wire(
                        code: "internal_error",
                        message: "reply carried neither result nor error",
                        retryable: false))
            }
            return
        }
        if let welcome = try? JSONDecoder().decode(
            AgentChatWelcome.self, from: frame), welcome.type == "welcome"
        {
            resolveWelcome(welcome)
            return
        }
        if let push = AgentChatPushFrame.decode(line: frame) {
            continuation.yield(.init(kind: .pushed(push)))
            return
        }
        // An error object without a matching request id fails the
        // negotiation or is ignored, matching fail-closed semantics.
        if let errorReply = try? JSONDecoder().decode(
            WelcomeErrorReply.self, from: frame), errorReply.error != nil
        {
            if errorReply.error?.code == "unsupported_protocol" {
                resolveWelcome(nil)
            }
        }
    }

    private struct WelcomeErrorReply: Decodable {
        let id: String?
        let error: AgentChatWireError?
    }

    private func finish(_ event: AgentChatChannelEvent.kind) {
        for (_, slot) in pending {
            slot.resume(throwing: AgentChatError.connectionClosed)
        }
        pending.removeAll()
        resolveWelcome(nil)
        continuation.yield(.init(kind: event))
        continuation.finish()
    }

    // MARK: Requests

    /// Sends one request and awaits its result value.
    func request(_ request: AgentChatRequest) async throws -> JSONValue {
        guard !closed else { throw AgentChatError.connectionClosed }
        let id = "c\(nextID)"
        nextID &+= 1
        var envelope = request
        envelope.id = id
        let bytes: Data
        do {
            bytes = try JSONEncoder().encode(envelope)
        } catch {
            throw AgentChatError.wire(
                code: "invalid_request", message: "failed to encode request",
                retryable: false)
        }
        guard bytes.count + 1 <= maxFrameBytes else {
            throw AgentChatError.frameTooLarge(
                bytes: bytes.count, cap: maxFrameBytes)
        }
        // Synchronous slot registration BEFORE the write: a fast reply
        // cannot race ahead of it (handle() is actor-isolated too).
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

    private final class PendingSlot: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<JSONValue, any Error>?
        private var buffered: Result<JSONValue, any Error>?
        private var delivered = false

        func install(
            _ continuation: CheckedContinuation<JSONValue, any Error>
        ) {
            lock.lock(); defer { lock.unlock() }
            if delivered, let buffered {
                continuation.resume(with: buffered)
                return
            }
            self.continuation = continuation
        }

        func resume(returning value: JSONValue) {
            lock.lock(); defer { lock.unlock() }
            guard !delivered else { return }
            delivered = true
            buffered = .success(value)
            continuation?.resume(returning: value)
            continuation = nil
        }

        func resume(throwing error: any Error) {
            lock.lock(); defer { lock.unlock() }
            guard !delivered else { return }
            delivered = true
            buffered = .failure(error)
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
                resume(throwing: AgentChatError.connectionClosed)
            }
        }
    }

    private func expireRequest(_ id: String) {
        if let slot = pending.removeValue(forKey: id) {
            slot.resume(throwing: AgentChatError.timedOut(method: "request \(id)"))
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
