import Foundation
import Testing

@testable import Heeler

// SPDX-License-Identifier: Apache-2.0
//
// The v3 structural command contract (review r2's proof demand): a
// + menu/chooser agent-command selection goes out over command.invoke —
// ONE frame carrying the commandId + per-session-global requestKey +
// string-array arguments — and NEVER as a prompt.send frame. The
// scripted broker drives a full store lifecycle
// (welcome → sessions.list → match → subscribe → history.open) so the
// sends run against a live .ready channel, then the test asserts the
// WIRE frames. The plain submit's prompt.send frame stays untouched
// (additive), and the commands-capability gate stays honest.

/// A scripted broker: answers each routed request with a canned
/// response and records every frame the client wrote.
actor ChatCommandScriptedPipe: AgentChatBytePipe {
    private var pending: [(method: String, reply: String)] = []
    private var written: [String] = []
    private var waiting: [CheckedContinuation<Data?, any Error>] = []
    private var incoming: [Data] = []
    private var closed = false

    var receivedLines: [String] { written }

    init(script: [(method: String, body: String)]) {
        pending = script.map { ($0.method, Self.responseEnvelope(id: "%ID%", body: $0.body)) }
    }

    private static func responseEnvelope(id: String, body: String) -> String {
        #"{"type":"response","id":"\#(id)","result":\#(body)}"#
    }

    private func nextReply(id: String, method: String) -> String? {
        if let index = pending.firstIndex(where: { $0.method == method }) {
            let canned = pending.remove(at: index).reply
            // %ID% substitutes the real correlation id.
            return canned.replacingOccurrences(of: "%ID%", with: id)
        }
        return nil
    }

    private func accept(_ data: Data) {
        let text = String(decoding: data, as: UTF8.self)
        for line in text.split(separator: "\n") where !line.isEmpty {
            written.append(String(line))
            guard let object = try? JSONSerialization.jsonObject(
                with: Data(line.utf8)) as? [String: Any],
                let id = object["id"] as? String,
                let method = object["method"] as? String
            else { continue }
            if let body = nextReply(id: id, method: method) {
                inject(body)
            }
        }
    }

    func seed(_ text: String) {
        inject(text)
    }

    /// Re-inserts a sessions.list answer at the front (capability
    /// overrides).
    func reseedRegistration(_ json: String) {
        pending.insert(
            ("sessions.list", Self.responseEnvelope(id: "%ID%", body: #"{"sessions":[\#(json)]}"#)),
            at: 0)
    }

    private func inject(_ text: String) {
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

    nonisolated func write(_ data: Data, timeout: Duration) async throws {
        await accept(data)
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

@Suite("Command invocation — structural, never prompt text (v3)")
@MainActor
struct AgentChatCommandInvokeTests {
    /// ONE physical registration line — NDJSON-safe on the wire; the
    /// store's matcher resolves exactly one session at this file.
    private static let sessionFile = "/cmd-proof/session.jsonl"
    private static let registrationJSON =
        #"{"instanceId":"inst-1","sessionId":"s-1","generation":1,"locator":{"sessionFile":"\#(sessionFile)"},"agent":{"kind":"omp","version":"18"},"capabilities":{"history":true,"streaming":true,"prompt":true,"interrupt":true,"interactions":false,"commands":true,"attachments":false,"branches":false}}"#

    private func makePipe() -> ChatCommandScriptedPipe {
        ChatCommandScriptedPipe(script: [
            ("sessions.list", #"{"sessions":[\#(Self.registrationJSON)]}"#),
            ("sessions.subscribe", #"{"accepted":true,"requestKey":"%ID%"}"#),
            ("history.open",
             #"{"sessionId":"s-1","generation":1,"revision":"r1","throughSeq":0,"items":[],"olderCursor":null}"#),
            ("command.invoke", #"{"accepted":true,"requestKey":"k-cmd"}"#),
            ("prompt.send", #"{"accepted":true,"requestKey":"k-prompt"}"#),
        ])
    }

    private func readyStore(
        pipe: ChatCommandScriptedPipe
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
            })
        await store.start()
        for _ in 0..<150 {
            if case .ready = store.phase { return store }
            try await Task.sleep(for: .milliseconds(20))
        }
        Issue.record("store never reached ready: \(store.phase)")
        throw CocoaError(.userActivityConnectionUnavailable)
    }

    @Test("a catalog command sends command.invoke — never a prompt.send frame")
    func commandSelectionIsStructural() async throws {
        let pipe = makePipe()
        await pipe.seed(
            #"{"type":"welcome","protocol":1,"maxFrameBytes":1048576}"#)
        let store = try await readyStore(pipe: pipe)

        let accepted = try await store.sendCommand(
            commandId: "compact", arguments: ["--keep-recent"])
        #expect(accepted == true)

        let lines = await pipe.receivedLines
        let invokeFrames = lines.filter {
            $0.contains("\"method\":\"command.invoke\"")
        }
        let promptFrames = lines.filter {
            $0.contains("\"method\":\"prompt.send\"")
        }
        #expect(invokeFrames.count == 1, "exactly one command.invoke frame")
        #expect(promptFrames.isEmpty, "the command must NEVER go out as prompt.send")

        let frame = invokeFrames[0]
        #expect(frame.contains("\"commandId\":\"compact\""))
        #expect(frame.contains("\"requestKey\""))
        #expect(frame.contains("\"arguments\":[\"--keep-recent\"]"))
        #expect(frame.contains("\"instanceId\":\"inst-1\""))
        #expect(frame.contains("\"generation\":1"))
    }

    @Test("a plain submit still emits its prompt.send frame — additive, untouched")
    func plainSubmitUnchanged() async throws {
        let pipe = makePipe()
        await pipe.seed(
            #"{"type":"welcome","protocol":1,"maxFrameBytes":1048576}"#)
        let store = try await readyStore(pipe: pipe)

        _ = try? await store.submit("hello world")
        _ = try? await store.sendCommand(commandId: "compact")

        let lines = await pipe.receivedLines
        let promptFrames = lines.filter {
            $0.contains("\"method\":\"prompt.send\"")
        }
        let invokeFrames = lines.filter {
            $0.contains("\"method\":\"command.invoke\"")
        }
        #expect(promptFrames.count == 1)
        #expect(promptFrames[0].contains("\"text\":\"hello world\""))
        #expect(invokeFrames.count == 1)
    }

    @Test("sendCommand fails honestly without the commands capability")
    func commandWithoutCapabilityFails() async throws {
        let pipe = ChatCommandScriptedPipe(script: [
            ("sessions.list",
             #"{"sessions":[{"instanceId":"inst-2","sessionId":"s-2","generation":1,"locator":{"sessionFile":"\#(Self.sessionFile)"},"capabilities":{"history":true,"streaming":true,"prompt":true,"commands":false}}]}"#),
            ("sessions.subscribe", #"{"accepted":true}"#),
            ("history.open",
             #"{"sessionId":"s-2","generation":1,"revision":"r1","throughSeq":0,"items":[],"olderCursor":null}"#),
        ])
        await pipe.seed(
            #"{"type":"welcome","protocol":1,"maxFrameBytes":1048576}"#)
        let store = try await readyStore(pipe: pipe)

        do {
            _ = try await store.sendCommand(commandId: "compact")
            Issue.record("the capability gate must throw")
        } catch let error as AgentChatError {
            // The honest code, visible to the chooser.
            #expect(String(describing: error).contains("unsupported_capability"))
        }
        let lines = await pipe.receivedLines
        #expect(
            lines.filter {
                $0.contains("\"method\":\"command.invoke\"")
            }.isEmpty,
            "no frame may leave the client when the capability gate is closed")
    }
}
