import Foundation
import HeelerSSH
import Testing

@testable import Heeler

// SPDX-License-Identifier: Apache-2.0
//
// Channel-level tests over a scripted pipe: typed welcome negotiation
// (version mismatch fails closed — no legacy arm), request
// correlation, and push delivery.

/// An in-memory pipe: writes append to a readable buffer; test code
/// injects incoming bytes (LF-terminated like the real wire).
actor ScriptedChatPipe: AgentChatBytePipe {
    private var incoming: [Data] = []
    private var waiting: [CheckedContinuation<Data?, any Error>] = []
    private var written: [Data] = []
    private var closed = false

    var receivedFrames: [String] {
        written.map { String(decoding: $0, as: UTF8.self) }
    }

    func brokerSend(_ text: String) {
        incoming.append(Data((text + "\n").utf8))
        pump()
    }

    private func pump() {
        while !incoming.isEmpty && !waiting.isEmpty {
            let chunk = incoming.removeFirst()
            let continuation = waiting.removeFirst()
            continuation.resume(returning: chunk)
        }
    }

    func write(_ data: Data, timeout: Duration) async throws {
        guard !closed else { throw AgentChatError.connectionClosed }
        written.append(data)
    }

    func read(maximumBytes: Int, timeout: Duration) async throws -> Data? {
        if !incoming.isEmpty {
            return incoming.removeFirst()
        }
        if closed { return nil }
        return try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<Data?, any Error>) in
            waiting.append(continuation)
        }
    }

    func close(timeout: Duration) async throws {
        closed = true
        for continuation in waiting {
            continuation.resume(returning: nil)
        }
        waiting.removeAll()
    }
}

@Suite("Agent chat channel negotiation + requests")
struct AgentChatChannelTests {
    @Test("welcome negotiation succeeds")
    func welcomeNegotiation() async throws {
        let pipe = ScriptedChatPipe()
        let channel = AgentChatChannel(
            pipe: pipe, onEvent: { _ in })
        await pipe.brokerSend(
            #"{"type":"welcome","protocol":1,"maxFrameBytes":1048576}"#)
        try await channel.connect()
        let frames = await pipe.receivedFrames
        // The hello carries the typed envelope: protocol + peer.
        #expect(frames.first?.contains("\"peer\":\"client\"") == true)
        #expect(frames.first?.contains("\"protocol\":1") == true)
        await channel.close()
    }

    @Test("version mismatch fails closed — no legacy arm")
    func versionMismatchFailsClosed() async throws {
        let pipe = ScriptedChatPipe()
        let channel = AgentChatChannel(
            pipe: pipe, onEvent: { _ in })
        await pipe.brokerSend(#"{"type":"welcome","protocol":9}"#)
        await #expect(throws: AgentChatError.unsupportedProtocol) {
            try await channel.connect()
        }
        await channel.close()
    }

    @Test("requests correlate by id and decode results")
    func requestCorrelation() async throws {
        let pipe = ScriptedChatPipe()
        let channel = AgentChatChannel(
            pipe: pipe, onEvent: { _ in })
        await pipe.brokerSend(#"{"type":"welcome","protocol":1}"#)
        try await channel.connect()

        let request = Task {
            try await channel.request(
                AgentChatRequest(id: "", method: "sessions.list"))
        }
        for _ in 0..<20 {
            let frames = await pipe.receivedFrames
            if frames.count > 1 { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        let frames = await pipe.receivedFrames
        guard let requestLine = frames.last,
            let id = try JSONDecoder().decode(
                [String: String].self, from: Data(requestLine.dropLast().utf8))["id"]
        else {
            Issue.record("no request id found")
            return
        }
        await pipe.brokerSend(
            #"{"type":"response","id":"\#(id)","result":{"sessions":[]}}"#)
        let result = try await request.value
        #expect(result["sessions"] != nil)
        await channel.close()
    }

    @Test("pushed events and session.unavailable surface as channel events")
    func pushesSurface() async throws {
        let pipe = ScriptedChatPipe()
        let events: AsyncStream<AgentChatChannelEvent> = AsyncStream { continuation in
            let channel = AgentChatChannel(pipe: pipe) { event in
                continuation.yield(event)
            }
            Task {
                await pipe.brokerSend(#"{"type":"welcome","protocol":1}"#)
                try await channel.connect()
                await pipe.brokerSend(
                    #"{"type":"event","instanceId":"I","generation":1,"seq":1,"event":{"type":"history.changed"}}"#)
                await pipe.brokerSend(#"{"type":"session.unavailable"}"#)
            }
        }
        var iterator = events.makeAsyncIterator()
        let first = await iterator.next()
        guard case .pushed(.event(let frame)) = first?.kind else {
            Issue.record(
                "expected event push, got \(String(describing: first))")
            return
        }
        #expect(frame.type == "history.changed")
        let second = await iterator.next()
        guard case .pushed(.sessionUnavailable) = second?.kind else {
            Issue.record(
                "expected session.unavailable, got \(String(describing: second))")
            return
        }
    }
}

/// An SSH-faithful pipe: idle reads THROW SSHError.timedOut (exactly
/// what the production SSHStreamLocalChannel → SessionDriver
/// readStreamLocal path does on deadline expiry — the fake the earlier
/// suites used ignored the timeout, hiding the idle-read defect).
actor ThrowingIdlePipe: AgentChatBytePipe {
    enum Mode {
        case idleThenEOF
        case idleThenError
        case sustainedIdle
    }
    private var incoming: [Data] = []
    private var waiting: [CheckedContinuation<Data?, any Error>] = []
    private var written: [Data] = []
    private var closed = false
    private let mode: Mode
    private var idleReads = 0

    init(mode: Mode) {
        self.mode = mode
    }

    var receivedFrames: [String] {
        written.map { String(decoding: $0, as: UTF8.self) }
    }
    var observedIdleReads: Int {
        idleReads
    }

    func brokerSend(_ text: String) {
        incoming.append(Data((text + "\n").utf8))
        pump()
    }

    private func pump() {
        while !incoming.isEmpty && !waiting.isEmpty {
            let chunk = incoming.removeFirst()
            let continuation = waiting.removeFirst()
            continuation.resume(returning: chunk)
        }
    }

    func write(_ data: Data, timeout: Duration) async throws {
        guard !closed else { throw AgentChatError.connectionClosed }
        written.append(data)
    }

    func read(maximumBytes: Int, timeout: Duration) async throws -> Data? {
        idleReads &+= 1
        if !incoming.isEmpty {
            return incoming.removeFirst()
        }
        if closed {
            return nil
        }
        switch mode {
        case .sustainedIdle:
            // Never yields data; never ends: only timeouts.
            throw SSHError.timedOut
        case .idleThenEOF:
            // One timeout tick, then orderly EOF.
            if idleReads > 6 {
                return nil
            }
            throw SSHError.timedOut
        case .idleThenError:
            if idleReads > 6 {
                throw SSHError.channelFailed
            }
            throw SSHError.timedOut
        }
    }

    func close(timeout: Duration) async throws {
        closed = true
        for continuation in waiting {
            continuation.resume(returning: nil)
        }
        waiting.removeAll()
    }
}

@Suite("Agent chat channel idle-read semantics")
struct AgentChatIdleReadTests {
    @Test("sustained idle timeouts keep the channel connected")
    func sustainedIdleStaysConnected() async throws {
        // The production streamlocal path throws SSHError.timedOut on
        // every idle read deadline. A quiet wire must NOT disconnect.
        let pipe = ThrowingIdlePipe(mode: .sustainedIdle)
        let collected = EventCollector()
        let channel = AgentChatChannel(pipe: pipe) { event in
            collected.append(event)
        }
        await pipe.brokerSend(#"{"type":"welcome","protocol":1}"#)
        try await channel.connect()
        try await Task.sleep(for: .seconds(12))
        let events = collected.drain()
        let ticks = await pipe.observedIdleReads
        #expect(ticks >= 2, "expected multiple idle timeout ticks, saw \(ticks)")
        let disconnects = events.filter {
            if case .disconnected = $0.kind { return true }
            return false
        }
        #expect(disconnects.isEmpty, "idle timeouts must not disconnect")
        await channel.close()
    }

    @Test("orderly EOF after idle still disconnects")
    func idleThenEOFDisconnects() async throws {
        let pipe = ThrowingIdlePipe(mode: .idleThenEOF)
        let expectation = AsyncStream<AgentChatChannelEvent> { continuation in
            let channel = AgentChatChannel(pipe: pipe) { event in
                continuation.yield(event)
            }
            Task {
                await pipe.brokerSend(#"{"type":"welcome","protocol":1}"#)
                try await channel.connect()
            }
        }
        var iterator = expectation.makeAsyncIterator()
        var sawDisconnected = false
        let deadline = Date().addingTimeInterval(20)
        while Date() < deadline {
            if let event = await iterator.next() {
                if case .disconnected(let reason) = event.kind {
                    sawDisconnected = true
                    #expect(reason == "broker closed the connection")
                    return
                }
            }
        }
        if !sawDisconnected {
            Issue.record("EOF after idle must disconnect")
        }
    }

    @Test("a hard transport error after idle still disconnects")
    func idleThenErrorDisconnects() async throws {
        let pipe = ThrowingIdlePipe(mode: .idleThenError)
        let expectation = AsyncStream<AgentChatChannelEvent> { continuation in
            let channel = AgentChatChannel(pipe: pipe) { event in
                continuation.yield(event)
            }
            Task {
                await pipe.brokerSend(#"{"type":"welcome","protocol":1}"#)
                try await channel.connect()
            }
        }
        var iterator = expectation.makeAsyncIterator()
        let deadline = Date().addingTimeInterval(20)
        while Date() < deadline {
            if let event = await iterator.next() {
                if case .disconnected = event.kind {
                    // The hard error surfaced as a disconnect — correct.
                    return
                }
            }
        }
        Issue.record("hard transport error after idle must disconnect")
    }
}

/// Thread-safe event capture for the idle tests.
private final class EventCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [AgentChatChannelEvent] = []
    func append(_ event: AgentChatChannelEvent) {
        lock.withLock { events.append(event) }
    }
    func drain() -> [AgentChatChannelEvent] {
        lock.withLock { let out = events; events = []; return out }
    }
}
