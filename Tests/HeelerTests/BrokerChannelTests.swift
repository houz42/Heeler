import Foundation
import Testing

@testable import Heeler

// SPDX-License-Identifier: Apache-2.0
//
// Channel-level tests over a scripted pipe: the hello-arm flip (the
// v0 arm's deletion path — proto:1 ack flips, silent v0 broker keeps
// v0), request correlation, and disconnect handling.

/// An in-memory pipe: writes append to a readable buffer; test code
/// injects incoming bytes.
actor ScriptedBrokerPipe: BrokerBytePipe {
    private var incoming: [Data] = []
    private var waiting: [CheckedContinuation<Data?, any Error>] = []
    private var written: [Data] = []
    private var closed = false

    var receivedFrames: [String] {
        written.map { String(decoding: $0, as: UTF8.self) }
    }

    /// Test-side: deliver bytes as if the broker sent them.
    func brokerSend(_ text: String) {
        incoming.append(Data(text.utf8))
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
        guard !closed else { throw BrokerClientError.connectionClosed }
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

@Suite("Broker channel negotiation + requests")
struct BrokerChannelTests {
    @Test("v1 hello ack flips the arm")
    func v1AckFlipsArm() async throws {
        let pipe = ScriptedBrokerPipe()
        let channel = BrokerChannel(
            pipe: pipe, onEvent: { _ in })
        // Reply to the hello immediately (the ack rides before the
        // reader even starts; the negotiation race consumes it).
        await pipe.brokerSend(#"{"type":"hello","proto":1,"maxFrameBytes":1048576}"#)
        try await channel.connect()
        let proto = await channel.proto
        #expect(proto == .v1)
        // Hello frame went out with proto:1 first.
        let frames = await pipe.receivedFrames
        #expect(frames.first?.contains("\"proto\":1") == true)
        await channel.close()
    }

    @Test("silent v0 broker keeps the v0 arm (the deletion path)")
    func silentBrokerKeepsV0() async throws {
        let pipe = ScriptedBrokerPipe()
        let channel = BrokerChannel(
            pipe: pipe, onEvent: { _ in })
        // No ack: the hello window expires (3s) and the v0 arm engages.
        let started = Date()
        try await channel.connect()
        let proto = await channel.proto
        #expect(proto == .v0)
        #expect(Date().timeIntervalSince(started) >= 2.5)
        await channel.close()
    }

    @Test("requests correlate by id and decode results")
    func requestCorrelation() async throws {
        let pipe = ScriptedBrokerPipe()
        let channel = BrokerChannel(
            pipe: pipe, onEvent: { _ in })
        await pipe.brokerSend(#"{"type":"hello","proto":1}"#)
        try await channel.connect()

        let request = Task { try await channel.request(
            BrokerRequest(id: "", method: "sessions")) }
        // The request line must be complete before the reply is handled.
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
        await pipe.brokerSend(#"{"id":"\#(id)","result":{"sessions":[]}}"#)
        let result = try await request.value
        #expect(result["sessions"] != nil)
        await channel.close()
    }

    @Test("pushed events and session_unavailable surface as channel events")
    func pushesSurface() async throws {
        let pipe = ScriptedBrokerPipe()
        let events: AsyncStream<BrokerChannelEvent> = AsyncStream { continuation in
            let channel = BrokerChannel(pipe: pipe) { event in
                continuation.yield(event)
            }
            Task {
                await pipe.brokerSend(#"{"type":"hello","proto":1}"#)
                try await channel.connect()
                await pipe.brokerSend(
                    #"{"type":"event","instanceId":"I","generation":1,"seq":1,"event":{"kind":"agent_start"}}"#)
                await pipe.brokerSend(#"{"type":"session_unavailable","instanceId":"I"}"#)
            }
        }
        var iterator = events.makeAsyncIterator()
        let first = await iterator.next()
        guard case .pushed(.event(let frame)) = first?.kind else {
            Issue.record("expected event push, got \(String(describing: first))")
            return
        }
        #expect(frame.kind == "agent_start")
        let second = await iterator.next()
        guard case .pushed(.sessionUnavailable(let instanceId)) = second?.kind else {
            Issue.record("expected session_unavailable, got \(String(describing: second))")
            return
        }
        #expect(instanceId == "I")
    }
}
