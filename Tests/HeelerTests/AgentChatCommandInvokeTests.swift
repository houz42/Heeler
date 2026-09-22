import Foundation
import Testing

@testable import Heeler

// SPDX-License-Identifier: Apache-2.0
//
// PoC (v3 design §8, docs/design/v3-structured-commands-and-image-blocks.md):
// a leading-`/` catalog command sends STRUCTURALLY over command.invoke —
// never as prompt text for the model. The scripted broker below drives a
// full store lifecycle (welcome → sessions.list → match → subscribe →
// history.open) so the sends run against a live .ready channel, then the
// test asserts the WIRE frames: sendCommand emits a command.invoke frame
// with the opaque commandId + a per-session-global requestKey, and the
// plain send's prompt.send frame is untouched (additive, per the preserved
// invariants).

/// A scripted broker: answers each routed request with a canned response
/// and records every frame the client wrote, keyed by method.
actor ScriptedBrokerPipe: AgentChatBytePipe {
    private var pending: [(method: String, reply: String)] = []
    private var written: [String] = []
    private var waiting: [CheckedContinuation<Data?, any Error>] = []
    private var closed = false

    var receivedLines: [String] { written }

    /// The broker's automatic answers, in order of arrival.
    private let script: [(method: String, body: String)]

    init(script: [(method: String, body: String)]) {
        self.script = script
        pending = script.map { ($0.method, $0.body) }
    }

    private func nextReplyFor(method: String) -> String? {
        // First script entry whose method matches and hasn't been used.
        if let index = pending.firstIndex(where: { $0.method == method }) {
            let reply = pending.remove(at: index).reply
            return reply
        }
        return nil
    }

    nonisolated func write(_ data: Data, timeout: Duration) async throws {
        await accept(data)
    }

    private func accept(_ data: Data) {
        let text = String(decoding: data, as: UTF8.self)
        // One write may batch several LF-terminated requests.
        for line in text.split(separator: "\n") where !line.isEmpty {
            written.append(String(line))
            guard let object = try? JSONSerialization.jsonObject(
                with: Data(line.utf8)) as? [String: Any],
                let id = object["id"] as? String,
                let method = object["method"] as? String
            else { continue }

            if let body = nextReplyFor(method: method) {
                // The wire response envelope: result OR error, with the
                // correlation id (bare result bodies never match a
                // pending request).
                let reply =
                    #"{"type":"response","id":"\#(id)","result":\#(body)}"#
                inject(reply)
            }
        }
    }

    func seed(_ text: String) {
        inject(text)
    }

    func reseed(method: String, body: String) {
        pending.insert(
            (method, #"{"sessions":[\#(body)]}"#), at: 0)
    }

    private func inject(_ text: String) {
        incoming.append(Data((text + "\n").utf8))
        pump()
    }

    private var incoming: [Data] = []

    private func pump() {
        while !incoming.isEmpty && !waiting.isEmpty {
            let chunk = incoming.removeFirst()
            let continuation = waiting.removeFirst()
            continuation.resume(returning: chunk)
        }
    }

    nonisolated func read(maximumBytes: Int, timeout: Duration) async throws -> Data? {
        try await serve()
    }

    private func serve() async throws -> Data? {
        if !incoming.isEmpty { return incoming.removeFirst() }
        if closed { return nil }
        return try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<Data?, any Error>) in
            waiting.append(continuation)
        }
    }

    nonisolated func close(timeout: Duration) async throws {
        await shutdown()
    }

    private func shutdown() {
        closed = true
        for continuation in waiting {
            continuation.resume(returning: nil)
        }
        waiting.removeAll()
    }
}

@Suite("Command invocation — structural, never prompt text (v3 PoC)")
@MainActor
struct AgentChatCommandInvokeTests {
    /// The registrations the scripted broker offers: full capabilities
    /// (prompt + commands + streaming + history), located at the pane's
    /// session file so the matcher resolves exactly one.
    private static let sessionFile = "/cmd-proof/session.jsonl"
    /// ONE physical line — NDJSON-safe: a multi-line pretty JSON would
    /// be undecodable frames on the wire and the store would never match.
    private static let registrationJSON =
        #"{"instanceId":"inst-1","sessionId":"s-1","generation":1,"locator":{"sessionFile":"\#(sessionFile)"},"agent":{"kind":"omp","version":"18"},"capabilities":{"history":true,"streaming":true,"prompt":true,"interrupt":true,"interactions":false,"commands":true,"attachments":false,"branches":false}}"#

    private func readyStore(
        pipe: ScriptedBrokerPipe
    ) async throws -> AgentChatStore {
        let store = AgentChatStore(
            pipeFactory: AgentChatPipeFactory(
                open: { _ in pipe },
                hostRecord: {
                    var host = Host(address: "127.0.0.1", username: "jhou")
                    host.brokerChatSocketPath = "/cmd-proof/broker.sock"
                    return host
                }),
            paneIdentity: {
                HerdrPaneSessionIdentity(sessionFilePath: Self.sessionFile)
            },
            requestTimeout: .seconds(5))
        await store.start()
        // The scripted broker answers every lifecycle request inline, so
        // readiness is a bounded wait on the phase.
        for _ in 0..<100 {
            if case .ready = store.phase { return store }
            try await Task.sleep(for: .milliseconds(20))
        }
        issueReadyFailure(store)
        return store
    }

    private func issueReadyFailure(_ store: AgentChatStore) {
        Issue.record("store never reached ready: \(store.phase)")
    }

    private func makePipe() -> ScriptedBrokerPipe {
        ScriptedBrokerPipe(script: [
            ("sessions.list",
             #"{"sessions":[\#(Self.registrationJSON)]}"#),
            ("sessions.subscribe", #"{"accepted":true,"requestKey":"%ID%"}"#),
            ("history.open",
             #"{"sessionId":"s-1","generation":1,"revision":"r1","throughSeq":0,"items":[],"olderCursor":null}"#),
            ("command.invoke", #"{"accepted":true,"requestKey":"k-cmd"}"#),
            ("prompt.send", #"{"accepted":true,"requestKey":"k-prompt"}"#),
        ])
    }

    private func makeBarePipe() -> ScriptedBrokerPipe {
        ScriptedBrokerPipe(script: [
            ("sessions.subscribe", #"{"accepted":true}"#),
            ("history.open",
             #"{"sessionId":"s-2","generation":1,"revision":"r1","throughSeq":0,"items":[],"olderCursor":null}"#),
        ])
    }

    @Test("a catalog command sends command.invoke — never a prompt.send frame")
    func slashCommandIsStructural() async throws {
        let pipe = makePipe()
        // welcome is pre-injected before the client's hello is even read.
        await pipe.injectWelcome(
            #"{"type":"welcome","protocol":1,"maxFrameBytes":1048576}"#)
        let store = try await readyStore(pipe: pipe)

        let accepted = try await store.sendCommand(
            commandId: "compact", arguments: ["--keep-recent"])
        #expect(accepted == true)

        let lines = await pipe.receivedLines
        let invokeFrames = lines.filter { $0.contains("\"method\":\"command.invoke\"") }
        let promptFrames = lines.filter { $0.contains("\"method\":\"prompt.send\"") }
        #expect(invokeFrames.count == 1, "exactly one command.invoke frame")
        #expect(promptFrames.isEmpty, "the command must NEVER go out as prompt.send")

        // The frame carries the opaque id, the global-namespace
        // requestKey, and the string-array arguments (NIT1).
        let frame = invokeFrames[0]
        #expect(frame.contains("\"commandId\":\"compact\""))
        #expect(frame.contains("\"requestKey\""))
        #expect(frame.contains("\"arguments\":[\"--keep-recent\"]"))
        // Targeted at the matched registration.
        #expect(frame.contains("\"instanceId\":\"inst-1\""))
        #expect(frame.contains("\"generation\":1"))
    }

    @Test("a plain text send still emits its prompt.send frame — additive, untouched")
    func plainSendUnchanged() async throws {
        let pipe = makePipe()
        await pipe.injectWelcome(
            #"{"type":"welcome","protocol":1,"maxFrameBytes":1048576}"#)
        let store = try await readyStore(pipe: pipe)

        _ = try await store.send("hello world")
        _ = try await store.sendCommand(commandId: "compact")

        let lines = await pipe.receivedLines
        let promptFrames = lines.filter { $0.contains("\"method\":\"prompt.send\"") }
        let invokeFrames = lines.filter { $0.contains("\"method\":\"command.invoke\"") }
        #expect(promptFrames.count == 1)
        #expect(promptFrames[0].contains("\"text\":\"hello world\""))
        #expect(invokeFrames.count == 1)
    }

    @Test("sendCommand fails honestly without the commands capability")
    func commandWithoutCapabilityFails() async throws {
        let pipe = makeBarePipe()
        await pipe.injectWelcome(
            #"{"type":"welcome","protocol":1,"maxFrameBytes":1048576}"#)
        // Registration WITHOUT the commands bit: capability honesty.
        await pipe.overrideRegistration(
            #"{"instanceId":"inst-2","sessionId":"s-2","generation":1,"locator":{"sessionFile":"\#(Self.sessionFile)"},"capabilities":{"history":true,"streaming":true,"prompt":true,"commands":false}}"#)
        let store = try await readyStore(pipe: pipe)

        await #expect(throws: AgentChatError.self) {
            try await store.sendCommand(commandId: "compact")
        }
        let lines = await pipe.receivedLines
        #expect(
            lines.filter { $0.contains("\"method\":\"command.invoke\"") }.isEmpty,
            "no frame may leave the client when the capability gate is closed")
    }
}

extension ScriptedBrokerPipe {
    /// Pre-seeds the welcome so the client's connect() handshake resolves.
    nonisolated func injectWelcome(_ text: String) async {
        await seed(text)
    }

    nonisolated func overrideRegistration(_ json: String) async {
        await reseed(method: "sessions.list", body: json)
    }
}
