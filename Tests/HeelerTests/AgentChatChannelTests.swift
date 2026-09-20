import Foundation
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
