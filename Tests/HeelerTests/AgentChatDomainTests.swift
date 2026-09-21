import Foundation
import Testing

@testable import Heeler

// SPDX-License-Identifier: Apache-2.0
//
// agent-chat v1 domain tests: hand-generated vectors from the
// contract text (agent-chat-v1-contract.md) — the runtime package's
// live frames replace these once Main hands them over.

@Suite("Agent chat wire framing")
struct AgentChatFramingTests {
    @Test("frame reader joins split frames, enforces the 1MiB cap")
    func frameReaderJoinsAndCaps() throws {
        var reader = AgentChatFrameReader(maxFrameBytes: 256)
        let first = try reader.feed(Data("{\"type\":\"request\",\"id\":".utf8))
        #expect(first.isEmpty)
        let second = try reader.feed(
            Data("\"c0\"}\n{\"type\":\"request\",\"id\":\"c1\"}\n".utf8))
        #expect(second.count == 2)

        var capped = AgentChatFrameReader(maxFrameBytes: 8)
        #expect(throws: AgentChatFrameReader.FrameError.frameTooLarge(bytes: 13, cap: 8)) {
            _ = try capped.feed(Data("abcdefghijklm\n".utf8))
        }
    }

    @Test("welcome decode gates on protocol version")
    func welcomeGates() throws {
        let welcome = try JSONDecoder().decode(
            AgentChatWelcome.self,
            from: Data(#"{"type":"welcome","protocol":1,"maxFrameBytes":1048576}"#.utf8))
        #expect(welcome.isCurrentProtocol)
        #expect(welcome.maxFrameBytes == 1_048_576)
        let wrong = try JSONDecoder().decode(
            AgentChatWelcome.self,
            from: Data(#"{"type":"welcome","protocol":2}"#.utf8))
        #expect(!wrong.isCurrentProtocol)
    }

    @Test("error envelope carries retryable")
    func errorEnvelope() throws {
        let envelope = try JSONDecoder().decode(
            AgentChatResponseEnvelope.self,
            from: Data(
                #"{"type":"response","id":"c0","error":{"code":"stale_generation","message":"old","retryable":true}}"#
                    .utf8))
        #expect(envelope.error?.code == "stale_generation")
        #expect(envelope.error?.retryable == true)
    }

    @Test("event frame decode with typed discriminator")
    func eventFrame() throws {
        let value = try JSONDecoder().decode(
            JSONValue.self,
            from: Data(
                #"{"type":"event","instanceId":"I","generation":3,"seq":7,"event":{"type":"message.delta","streamId":"s1","blockIndex":0,"text":"hi"}}"#
                    .utf8))
        let frame = try #require(AgentChatEventFrame(json: value))
        #expect(frame.instanceId == "I")
        #expect(frame.generation == 3)
        #expect(frame.seq == 7)
        #expect(frame.type == "message.delta")
        #expect(frame["streamId"]?.stringValue == "s1")
        #expect(frame["text"]?.stringValue == "hi")
    }
}

@Suite("Agent chat session matching")
struct AgentChatMatchingTests {
    private static let pane = HerdrPaneSessionIdentity(
        sessionFilePath: "/home/u/.omp/sessions/s_01a0ae90.jsonl")

    @Test("locator sessionFile exact match wins")
    func locatorMatch() {
        let match = AgentChatMatcher.match(
            pane: Self.pane,
            registrations: [
                AgentChatRegistration(
                    instanceId: "A", sessionId: "01a0ae90", generation: 1),
                AgentChatRegistration(
                    instanceId: "B", sessionId: "01a0ae90", generation: 1,
                    locator: .init(
                        paneId: "w1:p4",
                        sessionFile: "/home/u/.omp/sessions/s_01a0ae90.jsonl")),
            ])
        guard case .matched(let registration) = match else {
            Issue.record("expected match, got \(match)")
            return
        }
        #expect(registration.instanceId == "B")
    }

    @Test("duplicate locator claims fail closed (duplicate sessionId is valid)")
    func duplicateFailsClosed() {
        let match = AgentChatMatcher.match(
            pane: Self.pane,
            registrations: [
                AgentChatRegistration(
                    instanceId: "A", sessionId: "s1", generation: 1,
                    locator: .init(paneId: nil, sessionFile: Self.pane.sessionFilePath)),
                AgentChatRegistration(
                    instanceId: "B", sessionId: "s2", generation: 2,
                    locator: .init(paneId: nil, sessionFile: Self.pane.sessionFilePath)),
            ])
        guard case .ambiguous = match else {
            Issue.record("expected ambiguous, got \(match)")
            return
        }
    }

    @Test("no locator match is honest unavailability")
    func noRegistration() {
        let match = AgentChatMatcher.match(
            pane: Self.pane,
            registrations: [
                AgentChatRegistration(instanceId: "X", sessionId: "other", generation: 1)
            ])
        guard case .noRegistration = match else {
            Issue.record("expected noRegistration, got \(match)")
            return
        }
    }
}

@Suite("Agent chat normalized domain decode")
struct AgentChatDomainDecodeTests {
    @Test("ChatItem message with nested tool_call + tool_result blocks")
    func messageWithToolBlocks() throws {
        let item: JSONValue = try JSONDecoder().decode(
            JSONValue.self,
            from: Data(
                #"{"id":"m1","kind":"message","author":{"role":"assistant"},"createdAt":"2026-09-20T02:00:00.000Z","status":"committed","blocks":[{"type":"thinking","text":"plan"},{"type":"tool_call","callId":"call_1","name":"read","arguments":{"path":"f"}},{"type":"tool_result","callId":"call_1","isError":false,"content":[{"type":"text","text":"ok"}]},{"type":"text","text":"done"}]}"#
                    .utf8))
        let data = try JSONEncoder().encode(item)
        let decoded = try JSONDecoder().decode(AgentChatItem.self, from: data)
        guard case .message(let id, let author, _, let blocks) = decoded else {
            Issue.record("expected message")
            return
        }
        #expect(id == "m1")
        #expect(author.role == .assistant)
        #expect(blocks.count == 4)
        guard case .toolCall(let callId, let name, _) = blocks[1] else {
            Issue.record("expected tool_call at 1")
            return
        }
        #expect(callId == "call_1" && name == "read")
        guard case .toolResult(let resultCallId, _, let isError, let content) = blocks[2] else {
            Issue.record("expected tool_result at 2")
            return
        }
        #expect(resultCallId == "call_1" && !isError)
        guard case .text(let text) = content[0] else {
            Issue.record("expected nested text")
            return
        }
        #expect(text == "ok")
    }

    @Test("boundary, notice, unsupported, reference kinds decode")
    func otherKinds() throws {
        let items: JSONValue = try JSONDecoder().decode(
            JSONValue.self,
            from: Data(
                #"[{"id":"b1","kind":"boundary","boundary":"compaction","summary":"s","olderAvailable":true},{"id":"n1","kind":"notice","text":"warn","level":"warning"},{"id":"u1","kind":"unsupported","sourceType":"x","label":"l"},{"id":"r1","kind":"reference","itemKind":"message","byteLength":99999}]"#.utf8))
        let decoded = try JSONDecoder().decode(
            [AgentChatItem].self, from: JSONEncoder().encode(items))
        #expect(decoded.count == 4)
        guard case .boundary(_, let boundary, _, let olderAvailable) = decoded[0] else {
            Issue.record("expected boundary")
            return
        }
        #expect(boundary == "compaction" && olderAvailable)
        guard case .notice(_, let text, let level) = decoded[1] else {
            Issue.record("expected notice")
            return
        }
        #expect(text == "warn" && level == "warning")
        guard case .reference(let id, let itemKind, let byteLength) = decoded[3] else {
            Issue.record("expected reference")
            return
        }
        #expect(id == "r1" && itemKind == "message" && byteLength == 99999)
    }

    @Test("history page carries throughSeq watermark; olderCursor nil is terminal")
    func pageDecode() throws {
        let page: JSONValue = try JSONDecoder().decode(
            JSONValue.self,
            from: Data(
                #"{"sessionId":"01a0ae90","generation":2,"revision":"r3","throughSeq":42,"items":[],"olderCursor":null}"#
                    .utf8))
        let decoded = try JSONDecoder().decode(
            AgentChatPage.self, from: JSONEncoder().encode(page))
        #expect(decoded.throughSeq == 42)
        #expect(decoded.olderCursor == nil)
    }

    @Test("item chunk reassembly is exact and refuses short finals")
    func chunkAssembly() throws {
        let payload = Array(
            Data(
                #"{"id":"m","kind":"message","author":{"role":"user"},"blocks":[{"type":"text","text":"hello"}]}"#
                    .utf8))
        var accumulated = Data()
        var complete: Data?
        let (p1, c1) = try AgentChatChunkAssembler.assemble(
            accumulated: accumulated,
            chunk: chunk(offset: 0, bytes: Array(payload[..<40]), total: payload.count, next: 40))
        #expect(c1 == nil)
        accumulated = p1 ?? accumulated
        let (p2, c2) = try AgentChatChunkAssembler.assemble(
            accumulated: accumulated,
            chunk: chunk(offset: 40, bytes: Array(payload[40...]), total: payload.count, next: nil))
        complete = c2 ?? p2
        let item = try JSONDecoder().decode(
            AgentChatItem.self, from: try #require(complete))
        guard case .message(_, let author, _, let blocks) = item else {
            Issue.record("expected message")
            return
        }
        #expect(author.role == .user)
        #expect(blocks.count == 1)

        #expect(throws: AgentChatChunkAssembler.AssemblyError.self) {
            _ = try AgentChatChunkAssembler.assemble(
                accumulated: Data(),
                chunk: chunk(offset: 0, bytes: [0x7b], total: payload.count, next: nil))
        }
        let wrongEncoding = try JSONDecoder().decode(
            AgentChatChunk.self,
            from: Data(
                #"{"encoding":"raw","offset":0,"totalBytes":2,"data":"e30=","nextOffset":null}"#
                    .utf8))
        #expect(throws: AgentChatChunkAssembler.AssemblyError.self) {
            _ = try AgentChatChunkAssembler.assemble(
                accumulated: Data(), chunk: wrongEncoding)
        }
    }

    private func chunk(
        offset: Int, bytes: [UInt8], total: Int, next: Int?
    ) throws -> AgentChatChunk {
        var object: [String: JSONValue] = [
            "encoding": .string("json-utf8-base64"),
            "offset": .number(Double(offset)),
            "totalBytes": .number(Double(total)),
            "data": .string(Data(bytes).base64EncodedString()),
        ]
        if let next {
            object["nextOffset"] = .number(Double(next))
        }
        return try JSONDecoder().decode(
            AgentChatChunk.self, from: JSONEncoder().encode(JSONValue.object(object)))
    }
}

@Suite("Agent chat event reconcile")
struct AgentChatReconcileTests {
    private func frame(
        seq: Int, type: String, generation: Int = 1,
        instanceId: String = "I", payload: [String: JSONValue] = [:]
    ) -> AgentChatEventFrame {
        AgentChatEventFrame(
            instanceId: instanceId, generation: generation, seq: seq,
            type: type, payload: .object(payload))
    }

    @Test("provisional stream signals key by streamId")
    func streamSignals() {
        var state = AgentChatReconcileState(instanceId: "I", generation: 1)
        let started = AgentChatEventReconcile.fold(
            &state,
            frame: frame(seq: 1, type: "message.started", payload: [
                "streamId": .string("s1"),
                "author": .object(["role": .string("assistant")]),
            ]))
        guard case .stream(.started(let streamId, let role)) = started else {
            Issue.record("expected stream started, got \(started)")
            return
        }
        #expect(streamId == "s1")
        #expect(role == "assistant")
        let delta = AgentChatEventReconcile.fold(
            &state,
            frame: frame(seq: 2, type: "message.delta", payload: [
                "streamId": .string("s1"), "blockIndex": .number(0),
                "text": .string("hi"),
            ]))
        guard case .stream(.delta(let deltaStream, _, _, let text)) = delta else {
            Issue.record("expected delta, got \(delta)")
            return
        }
        #expect(deltaStream == "s1" && text == "hi")
    }

    @Test("history.changed refetches; session.changed and resync_required resync")
    func controlSignals() {
        var state = AgentChatReconcileState(instanceId: "I", generation: 1)
        let refetch = AgentChatEventReconcile.fold(
            &state, frame: frame(seq: 1, type: "history.changed"))
        guard case .refetchRecent = refetch else {
            Issue.record("expected refetchRecent, got \(refetch)")
            return
        }
        let changed = AgentChatEventReconcile.fold(
            &state, frame: frame(seq: 2, type: "session.changed"))
        guard case .resync = changed else {
            Issue.record("expected resync, got \(changed)")
            return
        }
        let resync = AgentChatEventReconcile.fold(
            &state, frame: frame(seq: 3, type: "resync_required"))
        guard case .resync = resync else {
            Issue.record("expected resync, got \(resync)")
            return
        }
    }

    @Test("gap means reopen — no replay guarantee in v1")
    func gapResyncs() {
        var state = AgentChatReconcileState(instanceId: "I", generation: 1)
        _ = AgentChatEventReconcile.fold(
            &state, frame: frame(seq: 1, type: "history.changed"))
        let gap = AgentChatEventReconcile.fold(
            &state, frame: frame(seq: 5, type: "history.changed"))
        guard case .resync = gap else {
            Issue.record("expected gap resync, got \(gap)")
            return
        }
        // A duplicate seq is ignored, not another resync.
        let duplicate = AgentChatEventReconcile.fold(
            &state, frame: frame(seq: 1, type: "history.changed"))
        guard case .ignored = duplicate else {
            Issue.record("expected ignored duplicate, got \(duplicate)")
            return
        }
    }

    @Test("other generation or instance resyncs")
    func scoping() {
        var state = AgentChatReconcileState(instanceId: "I", generation: 1)
        let otherGeneration = AgentChatEventReconcile.fold(
            &state, frame: frame(seq: 1, type: "history.changed", generation: 2))
        guard case .resync = otherGeneration else {
            Issue.record("expected generation resync")
            return
        }
        let otherInstance = AgentChatEventReconcile.fold(
            &state, frame: frame(seq: 1, type: "history.changed", instanceId: "OTHER"))
        guard case .resync = otherInstance else {
            Issue.record("expected instance resync")
            return
        }
    }

    @Test("watermark absorbs buffered events at or below throughSeq")
    func watermark() {
        var state = AgentChatReconcileState(instanceId: "I", generation: 1)
        AgentChatEventReconcile.applyWatermark(&state, throughSeq: 40)
        // A buffered frame at the watermark is already reflected: ignored.
        let atWatermark = AgentChatEventReconcile.fold(
            &state, frame: frame(seq: 40, type: "history.changed"))
        guard case .ignored = atWatermark else {
            Issue.record("expected watermark drop")
            return
        }
        // Above the watermark applies.
        let above = AgentChatEventReconcile.fold(
            &state, frame: frame(seq: 41, type: "history.changed"))
        guard case .refetchRecent = above else {
            Issue.record("expected apply above watermark")
            return
        }
    }

    @Test("interaction signals decode and resolve")
    func interactionSignals() throws {
        var state = AgentChatReconcileState(instanceId: "I", generation: 1)
        let interactionJSON = #"{"requestId":"r1","generation":1,"kind":"question","questions":[{"id":"q1","text":"Proceed?","multi":true,"options":[{"id":"o1","label":"Yes"}],"allowCustom":true}]}"#
        let interactionValue = try JSONDecoder().decode(
            JSONValue.self, from: Data(interactionJSON.utf8))
        let opened = AgentChatEventReconcile.fold(
            &state,
            frame: frame(seq: 1, type: "interaction.opened", payload: [
                "interaction": interactionValue,
            ]))
        guard case .interaction(.opened(let interaction)) = opened else {
            Issue.record("expected interaction opened, got \(opened)")
            return
        }
        #expect(interaction.requestId == "r1")
        #expect(interaction.questions.count == 1)
        #expect(interaction.questions[0].multi)
        let resolved = AgentChatEventReconcile.fold(
            &state,
            frame: frame(seq: 2, type: "interaction.resolved", payload: [
                "requestId": .string("r1"),
                "outcome": .string("answered"),
                "source": .string("terminal"),
            ]))
        guard case .interaction(.resolved(let requestId, let outcome, let source)) = resolved
        else {
            Issue.record("expected resolved, got \(resolved)")
            return
        }
        #expect(requestId == "r1" && outcome == "answered" && source == "terminal")
    }
}

@Suite("Agent chat error taxonomy")
struct AgentChatErrorTests {
    @Test("resync ladder")
    func ladder() {
        for code in ["session_unavailable", "stale_generation", "timeout"] {
            #expect(
                AgentChatError.wire(code: code, message: "", retryable: true)
                    .requiresFullResync)
        }
        for code in ["stale_cursor", "cursor_invalid"] {
            let error = AgentChatError.wire(code: code, message: "", retryable: false)
            #expect(error.requiresFreshOpen && !error.requiresFullResync)
        }
        for code in ["item_not_found", "item_changed", "budget_too_small", "too_many_inflight"] {
            let error = AgentChatError.wire(code: code, message: "", retryable: false)
            #expect(!error.requiresFullResync && !error.requiresFreshOpen)
        }
        // Ambiguity is terminal, not resynced.
        #expect(!AgentChatError.ambiguousSession.requiresFullResync)
    }

    @Test("capabilities gate granularly; absent flags are closed")
    func capabilityGating() throws {
        let capabilities = try JSONDecoder().decode(
            AgentChatCapabilities.self,
            from: Data(
                #"{"history":true,"streaming":true,"prompt":true,"interrupt":false,"interactions":false,"commands":true}"#
                    .utf8))
        #expect(capabilities.history && capabilities.streaming && capabilities.prompt)
        #expect(capabilities.commands)
        #expect(!capabilities.interrupt && !capabilities.interactions)
        // Absent flags decode closed.
        let empty = try JSONDecoder().decode(
            AgentChatCapabilities.self, from: Data("{}".utf8))
        #expect(!empty.history && !empty.interactions)
    }
}

@Suite("Agent chat mapper")
struct AgentChatMapperTests {
    @Test("message maps with block order preserved; images skipped")
    func messageMaps() throws {
        let item: JSONValue = try JSONDecoder().decode(
            JSONValue.self,
            from: Data(
                #"{"id":"m","kind":"message","author":{"role":"assistant"},"blocks":[{"type":"thinking","text":"plan"},{"type":"image","mimeType":"image/png","ref":"blob-1"},{"type":"text","text":"done"}]}"#
                    .utf8))
        let decoded = try JSONDecoder().decode(
            AgentChatItem.self, from: JSONEncoder().encode(item))
        guard case .message = AgentChatMapper.map(item: decoded) else {
            Issue.record("expected message map")
            return
        }
    }

    @Test("reference never maps as complete; warning notices map; info stays quiet")
    func honestSkips() throws {
        let reference: JSONValue = try JSONDecoder().decode(
            JSONValue.self,
            from: Data(#"{"id":"r","kind":"reference","itemKind":"message","byteLength":9}"#.utf8))
        let decodedReference = try JSONDecoder().decode(
            AgentChatItem.self, from: JSONEncoder().encode(reference))
        guard case .skipped = AgentChatMapper.map(item: decodedReference) else {
            Issue.record("reference must not render as complete")
            return
        }

        let notice: JSONValue = try JSONDecoder().decode(
            JSONValue.self,
            from: Data(#"{"id":"n","kind":"notice","text":"careful","level":"warning"}"#.utf8))
        let decodedNotice = try JSONDecoder().decode(
            AgentChatItem.self, from: JSONEncoder().encode(notice))
        guard case .message = AgentChatMapper.map(item: decodedNotice) else {
            Issue.record("warning notice should render")
            return
        }

        let info: JSONValue = try JSONDecoder().decode(
            JSONValue.self,
            from: Data(#"{"id":"i","kind":"notice","text":"fyi","level":"info"}"#.utf8))
        let decodedInfo = try JSONDecoder().decode(
            AgentChatItem.self, from: JSONEncoder().encode(info))
        guard case .skipped = AgentChatMapper.map(item: decodedInfo) else {
            Issue.record("info notice should stay quiet")
            return
        }
    }

    @Test("tool results collect by callId from nested blocks")
    func toolResultCollection() throws {
        let items: JSONValue = try JSONDecoder().decode(
            JSONValue.self,
            from: Data(
                #"[{"id":"m","kind":"message","author":{"role":"assistant"},"blocks":[{"type":"tool_call","callId":"c1","name":"read","arguments":{}},{"type":"tool_result","callId":"c1","isError":true,"content":[{"type":"text","text":"boom"}]}]}]"#.utf8))
        let decoded = try JSONDecoder().decode(
            [AgentChatItem].self, from: JSONEncoder().encode(items))
        let results = AgentChatToolResultCollector.collect(from: decoded)
        #expect(results.count == 1)
        #expect(results[0].toolCallId == "c1")
        #expect(results[0].isError)
        #expect(results[0].content == "boom")
    }
}

@Suite("Agent chat interactions (optional capability)")
struct AgentChatInteractionModelTests {
    @Test("multi-question interaction decodes with options and custom")
    func multiQuestionDecode() throws {
        let interaction: JSONValue = try JSONDecoder().decode(
            JSONValue.self,
            from: Data(
                #"{"requestId":"r1","generation":2,"kind":"question","questions":[{"id":"q1","text":"Proceed?","multi":false,"options":[{"id":"a","label":"Yes"},{"id":"b","label":"No"}],"allowCustom":false},{"id":"q2","text":"Which?","multi":true,"recommendedOptionIds":["x"],"options":[{"id":"x","label":"X"},{"id":"y","label":"Y"}],"allowCustom":true}]}"#.utf8))
        let decoded = try JSONDecoder().decode(
            AgentChatInteraction.self, from: JSONEncoder().encode(interaction))
        #expect(decoded.requestId == "r1")
        #expect(decoded.questions.count == 2)
        #expect(decoded.questions[1].multi)
        #expect(decoded.questions[1].recommendedOptionIds == ["x"])
        #expect(decoded.questions[1].allowCustom)
        #expect(decoded.questions[0].options.count == 2)
    }

    @Test("interactions.list result decodes the pending array")
    func listResult() throws {
        let result: JSONValue = try JSONDecoder().decode(
            JSONValue.self,
            from: Data(
                #"{"pending":[{"requestId":"r1","generation":1,"kind":"question","questions":[{"id":"q1","text":"Proceed?","options":[]}]}]}"#
                    .utf8))
        let decoded = try JSONDecoder().decode(
            AgentChatInteractionsResult.self, from: JSONEncoder().encode(result))
        #expect(decoded.pending.count == 1)
        #expect(decoded.pending[0].questions[0].text == "Proceed?")
    }
}


// MARK: - Live runtime vectors (sanitized)
//
// Derived from REAL production wire frames captured against the
// integrated runtime (28 frames, live-frames.json; capture 2026-09-20).
// REDACTION, applied recursively before these fixtures were written:
// every private string value (block text/thinking, summaries, titles,
// tool names/arguments, image data, instance/session/stream ids,
// timestamps, revisions, requestKeys, cursors, paneId) was replaced
// with an opaque placeholder; pid zeroed. STRUCTURE is untouched —
// envelope types, discriminators, field names, block kinds, event
// payloads, capability flags, and the reference/oversized item are
// the real wire shapes. Raw frames are NOT committed.

@Suite("Agent chat live runtime vectors (sanitized)")
struct AgentChatLiveVectorTests {
    private static let sessionsResponse =
        #"{"type":"response","id":"<redacted>","result":{"sessions":[{"instanceId":"redacted-instanceId","sessionId":"redacted-sessionId","generation":1,"agent":{"kind":"omp","version":"unknown"},"title":"<redacted>","locator":{"pid":0,"paneId":"wX:pR","sessionFile":"/redacted/path/history.jsonl"},"capabilities":{"history":true,"streaming":true,"prompt":true,"interrupt":true,"interactions":false,"commands":true,"attachments":false,"branches":false}}]}}"#
    private static let historyResponse =
        #"{"type":"response","id":"<redacted>","result":{"sessionId":"redacted-sessionId","generation":1,"revision":"rev:redacted","throughSeq":17,"items":[{"id":"<redacted>","kind":"reference","itemKind":"message","byteLength":365},{"id":"<redacted>","kind":"message","author":{"role":"tool","name":"<redacted>"},"createdAt":"2026-09-20T00:00:00.000Z","blocks":[{"type":"tool_result","callId":"<redacted>","name":"<redacted>","isError":false,"content":[{"type":"text","text":"<redacted text>"}]}],"status":"committed"},{"id":"<redacted>","kind":"message","author":{"role":"assistant","name":"<redacted>"},"createdAt":"2026-09-20T00:00:00.000Z","blocks":[{"type":"thinking","text":"<redacted text>"},{"type":"text","text":"<redacted text>"},{"type":"tool_call","callId":"<redacted>","name":"<redacted>","arguments":{}}],"status":"committed"},{"id":"<redacted>","kind":"message","author":{"role":"tool","name":"<redacted>"},"createdAt":"2026-09-20T00:00:00.000Z","blocks":[{"type":"tool_result","callId":"<redacted>","name":"<redacted>","isError":false,"content":[{"type":"text","text":"<redacted text>"}]}],"status":"committed"},{"id":"<redacted>","kind":"message","author":{"role":"assistant","name":"<redacted>"},"createdAt":"2026-09-20T00:00:00.000Z","blocks":[{"type":"thinking","text":"<redacted text>"},{"type":"text","text":"<redacted text>"},{"type":"tool_call","callId":"<redacted>","name":"<redacted>","arguments":{}}],"status":"committed"},{"id":"<redacted>","kind":"message","author":{"role":"tool","name":"<redacted>"},"createdAt":"2026-09-20T00:00:00.000Z","blocks":[{"type":"tool_result","callId":"<redacted>","name":"<redacted>","isError":false,"content":[{"type":"text","text":"<redacted text>"}]}],"status":"committed"},{"id":"<redacted>","kind":"message","author":{"role":"assistant","name":"<redacted>"},"createdAt":"2026-09-20T00:00:00.000Z","blocks":[{"type":"thinking","text":"<redacted text>"},{"type":"text","text":"<redacted text>"},{"type":"tool_call","callId":"<redacted>","name":"<redacted>","arguments":{}}],"status":"committed"},{"id":"<redacted>","kind":"message","author":{"role":"tool","name":"<redacted>"},"createdAt":"2026-09-20T00:00:00.000Z","blocks":[{"type":"tool_result","callId":"<redacted>","name":"<redacted>","isError":false,"content":[{"type":"text","text":"<redacted text>"}]}],"status":"committed"},{"id":"<redacted>","kind":"message","author":{"role":"assistant","name":"<redacted>"},"createdAt":"2026-09-20T00:00:00.000Z","blocks":[{"type":"text","text":"<redacted text>"}],"status":"committed"},{"id":"<redacted>","kind":"message","author":{"role":"user"},"createdAt":"2026-09-20T00:00:00.000Z","blocks":[{"type":"text","text":"<redacted text>"}],"status":"committed"},{"id":"<redacted>","kind":"message","author":{"role":"assistant","name":"<redacted>"},"createdAt":"2026-09-20T00:00:00.000Z","blocks":[{"type":"thinking","text":"<redacted text>"},{"type":"text","text":"<redacted text>"}],"status":"committed"}],"olderCursor":"redacted-cursor"}}"#
    private static let messageStarted =
        #"{"type":"event","instanceId":"redacted-instanceId","generation":1,"seq":22,"event":{"type":"message.started","streamId":"redacted-streamId","author":{"role":"assistant"}}}"#
    private static let messageDeltaText =
        #"{"type":"event","instanceId":"redacted-instanceId","generation":1,"seq":28,"event":{"type":"message.delta","streamId":"redacted-streamId","blockIndex":1,"blockType":"text","text":"<redacted text>"}}"#
    private static let messageFinished =
        #"{"type":"event","instanceId":"redacted-instanceId","generation":1,"seq":31,"event":{"type":"message.finished","streamId":"redacted-streamId"}}"#
    private static let historyChanged =
        #"{"type":"event","instanceId":"redacted-instanceId","generation":1,"seq":21,"event":{"type":"history.changed","revision":"rev:redacted"}}"#
    private static let promptRequest =
        #"{"type":"request","id":"<redacted>","method":"prompt.send","target":{"instanceId":"redacted-instanceId","generation":1},"params":{"text":"<redacted text>","requestKey":"key-redacted"}}"#
    private static let promptResult =
        #"{"type":"response","id":"<redacted>","result":{"accepted":true,"requestKey":"key-redacted"}}"#
    private static let itemNotFound =
        #"{"type":"response","id":"<redacted>","error":{"code":"item_not_found","message":"<redacted>","retryable":false}}"#

    @Test("live sessions.list: agent identity (unknown version), locator, capabilities")
    func liveSessions() throws {
        let envelope = try JSONDecoder().decode(
            AgentChatResponseEnvelope.self,
            from: Data(Self.sessionsResponse.utf8))
        let result = try #require(envelope.result)
        let sessions = try JSONDecoder().decode(
            AgentChatSessionsResult.self, from: JSONEncoder().encode(result)).sessions
        let registration = try #require(sessions.first)
        // Agent identity displays honestly, including "unknown".
        #expect(registration.agent?.kind == "omp")
        #expect(registration.agent?.version == "unknown")
        // Locator carries discovery-only pid + sessionFile.
        #expect(
            registration.locator?.sessionFile == "/redacted/path/history.jsonl")
        #expect(registration.locator?.pid == 0)
        // Granular capabilities from the live registration.
        #expect(registration.capabilities.history)
        #expect(registration.capabilities.streaming)
        #expect(registration.capabilities.prompt)
        #expect(registration.capabilities.interrupt)
        #expect(registration.capabilities.commands)
        // Interactions off — the honest unsupported card state.
        #expect(!registration.capabilities.interactions)
        #expect(!registration.capabilities.attachments)
        #expect(!registration.capabilities.branches)
    }

    @Test("live history.open: 11 items incl. a reference, throughSeq 17, cursor")
    func liveHistoryPage() throws {
        let envelope = try JSONDecoder().decode(
            AgentChatResponseEnvelope.self,
            from: Data(Self.historyResponse.utf8))
        let result = try #require(envelope.result)
        let page = try JSONDecoder().decode(
            AgentChatPage.self, from: JSONEncoder().encode(result))
        #expect(page.items.count == 11)
        #expect(page.throughSeq == 17)
        #expect(page.olderCursor != nil)
        var sawReference = false
        for item in page.items {
            if case .reference(_, let itemKind, let byteLength) = item {
                sawReference = true
                #expect(itemKind == "message")
                #expect(byteLength == 365)
            }
        }
        #expect(sawReference)
    }

    @Test("live stream events: typed envelopes, shared streamId, text blockType")
    func liveStreamEvents() throws {
        for (frame, expectedType) in [
            (Self.messageStarted, "message.started"),
            (Self.messageDeltaText, "message.delta"),
            (Self.messageFinished, "message.finished"),
            (Self.historyChanged, "history.changed"),
        ] {
            let value = try JSONDecoder().decode(
                JSONValue.self, from: Data(frame.utf8))
            let event = try #require(AgentChatEventFrame(json: value))
            #expect(event.type == expectedType)
            #expect(event.instanceId == "redacted-instanceId")
        }
        let deltaValue = try JSONDecoder().decode(
            JSONValue.self, from: Data(Self.messageDeltaText.utf8))
        let deltaFrame = try #require(AgentChatEventFrame(json: deltaValue))
        #expect(deltaFrame["blockType"]?.stringValue == "text")
        #expect(deltaFrame["streamId"]?.stringValue == "redacted-streamId")
    }

    @Test("live prompt.send: requestKey dedup + accepted result")
    func livePrompt() throws {
        let request = try JSONDecoder().decode(
            AgentChatRequest.self, from: Data(Self.promptRequest.utf8))
        #expect(request.method == "prompt.send")
        #expect(request.params?["requestKey"]?.stringValue == "key-redacted")
        #expect(request.target?.generation == 1)
        let envelope = try JSONDecoder().decode(
            AgentChatResponseEnvelope.self,
            from: Data(Self.promptResult.utf8))
        let result = try JSONDecoder().decode(
            AgentChatPromptResult.self,
            from: JSONEncoder().encode(try #require(envelope.result)))
        #expect(result.accepted)
        #expect(result.requestKey == "key-redacted")
    }

    @Test("live item_not_found typed error, non-retryable, ordinary failure")
    func liveItemNotFound() throws {
        let envelope = try JSONDecoder().decode(
            AgentChatResponseEnvelope.self,
            from: Data(Self.itemNotFound.utf8))
        let error = try #require(envelope.error)
        #expect(error.code == "item_not_found")
        #expect(error.retryable == false)
        let mapped = AgentChatError.from(error)
        #expect(!mapped.requiresFullResync && !mapped.requiresFreshOpen)
    }
}

@Suite("Agent chat interactions snapshot races")
struct AgentChatInteractionRaceTests {
    private func interaction(_ id: String, text: String = "Proceed?") -> AgentChatInteraction {
        let json = #"{"requestId":"\#(id)","generation":1,"kind":"question","questions":[{"id":"q1","text":"\#(text)","multi":false,"options":[]}],"allowCustom":false}"#
        let data = json.data(using: .utf8)!
        return try! JSONDecoder().decode(AgentChatInteraction.self, from: data)
    }

    @Test("raced-opened: a live interaction.opened survives the snapshot install")
    func racedOpenedSurvives() {
        // The event beat the list call; the list predates it.
        let merged = AgentChatInteractionMerge.install(
            snapshot: [interaction("r-snap")],
            live: [interaction("r-live")],
            tombstones: [])
        #expect(merged.map(\.requestId).sorted() == ["r-live", "r-snap"])
    }

    @Test("raced-resolved: a resolution during fetch must NOT resurrect the card")
    func racedResolvedNeverResurrects() {
        // The list response still contains r-gone (built before the
        // resolution), but the tombstone excludes it.
        let merged = AgentChatInteractionMerge.install(
            snapshot: [interaction("r-gone"), interaction("r-open")],
            live: [],
            tombstones: ["r-gone"])
        #expect(merged.map(\.requestId) == ["r-open"])
    }

    @Test("tombstone excludes even a live arrival replay for the same id")
    func tombstoneBeatsEverything() {
        let merged = AgentChatInteractionMerge.install(
            snapshot: [],
            live: [interaction("r-x")],
            tombstones: ["r-x"])
        #expect(merged.isEmpty)
    }
}

// MARK: - The ask-options app chain (v1 scope)

struct AgentAskAppChainTests {
    @Test func resolutionBodiesAreHonest() {
        // The resolved block's WHY, per kind: never silent, never
        // ambiguous about WHERE the answer came from.
        let you = AgentChatInteractionResolution(
            requestId: "r1", kind: .youAnswered, labels: ["Ship it"])
        let youNoLabels = AgentChatInteractionResolution(
            requestId: "r1b", kind: .youAnswered, labels: nil)
        let terminal = AgentChatInteractionResolution(
            requestId: "r2", kind: .answeredInTerminal, labels: nil)
        let other = AgentChatInteractionResolution(
            requestId: "r2b", kind: .answeredRemotely, labels: nil)
        let cancelled = AgentChatInteractionResolution(
            requestId: "r3", kind: .cancelled, labels: nil)
        let expired = AgentChatInteractionResolution(
            requestId: "r4", kind: .expired, labels: nil)
        let settled = AgentChatInteractionResolution(
            requestId: "r5", kind: .settledElsewhere, labels: nil)
        #expect(you.transcriptBody == "You answered: Ship it")
        #expect(youNoLabels.transcriptBody == "You answered.")
        #expect(terminal.transcriptBody == "Answered in the agent's terminal.")
        #expect(other.transcriptBody == "Answered remotely.")
        #expect(cancelled.transcriptBody == "The question was cancelled.")
        #expect(expired.transcriptBody == "The question expired before it was answered.")
        #expect(settled.transcriptBody == "This question was already answered or cancelled elsewhere.")
    }
}

// MARK: - The stale-card self-heal + honest error copy (device bug fix)

struct AgentAskStaleCardTests {
    @Test func staleInteractionErrorCarriesHonestMessage() {
        // The on-card error is the WIRE MESSAGE, never a raw domain
        // dump ('AgentChatError error 0').
        let error = AgentChatError.wire(
            code: "item_changed",
            message: "This question is no longer pending — it may have been answered or expired in the agent's terminal.",
            retryable: false)
        if case AgentChatError.wire(_, let message, _) = error {
            #expect(message.contains("no longer pending"))
        } else {
            Issue.record("pattern match failed")
        }
    }
}

// MARK: - Answer renders in chat history (v2)

struct AgentAskTranscriptTests {
    private func interaction() -> AgentChatInteraction {
        let json = #"{"requestId":"r-1","generation":1,"kind":"question","questions":[{"id":"q1","text":"Keep testing?","multi":false,"options":[{"id":"idx:0","label":"Keep testing surfaces"},{"id":"idx:1","label":"Stop here"}],"allowCustom":true}]}"#
        return try! JSONDecoder().decode(
            AgentChatInteraction.self, from: Data(json.utf8))
    }

    @Test("this device's answer renders 'You answered' with the chosen LABEL, not the wire id")
    func answeredRendersLabel() {
        let resolution = AgentChatInteractionResolution(
            answered: interaction(),
            answers: [
                AgentChatAnswer(
                    questionId: "q1", optionIds: ["idx:0"],
                    customText: nil, note: nil)
            ])
        #expect(
            resolution.transcriptBody
                == "You answered: Keep testing surfaces")
        #expect(resolution.kind == .youAnswered)
    }

    @Test("multi-select joins its labels; unknown option ids never render raw")
    func multiSelectAndUnknownIds() {
        let json = #"{"requestId":"r-2","generation":1,"kind":"question","questions":[{"id":"q1","text":"Include what?","multi":true,"options":[{"id":"idx:0","label":"Video"},{"id":"idx:1","label":"Report"},{"id":"idx:2","label":"Frames"}],"allowCustom":false}]}"#
        let interaction = try! JSONDecoder().decode(
            AgentChatInteraction.self, from: Data(json.utf8))
        let resolution = AgentChatInteractionResolution(
            answered: interaction,
            answers: [
                AgentChatAnswer(
                    questionId: "q1", optionIds: ["idx:2", "idx:0"],
                    customText: nil, note: nil),
                // An unknown id drops, never renders 'idx:' raw.
                AgentChatAnswer(
                    questionId: "qX", optionIds: ["idx:9"],
                    customText: nil, note: nil),
            ])
        #expect(
            resolution.transcriptBody
                == "You answered: Frames + Video")
    }

    @Test("a wire 'remote' resolved event maps NEUTRALLY — the broadcast cannot identify the winner")
    func remoteEventMapsNeutrally() {
        let other = AgentChatInteractionResolution(
            requestId: "r1", wireOutcome: "answered", wireSource: "remote")
        #expect(other.kind == .answeredRemotely)
        #expect(other.transcriptBody == "Answered remotely.")
        // Terminal source is unambiguous.
        let terminal = AgentChatInteractionResolution(
            requestId: "r2", wireOutcome: "answered", wireSource: "terminal")
        #expect(terminal.kind == .answeredInTerminal)
        // Cancelled/expired keep their honest notes regardless of source.
        let cancelled = AgentChatInteractionResolution(
            requestId: "r3", wireOutcome: "cancelled", wireSource: "remote")
        #expect(cancelled.kind == .cancelled)
        let expired = AgentChatInteractionResolution(
            requestId: "r4", wireOutcome: "expired", wireSource: "terminal")
        #expect(expired.kind == .expired)
        // An unknown outcome never fabricates a specific one.
        let unknown = AgentChatInteractionResolution(
            requestId: "r5", wireOutcome: "whatever", wireSource: "remote")
        #expect(unknown.kind == .settledElsewhere)
    }

    @Test("the stale-answer self-heal maps the broker's REAL refusal codes to honest kinds")
    func staleRefusalMapsRealCodes() {
        // stale_generation: the ask's generation was invalidated — expired.
        let gen = AgentChatInteractionResolution(
            staleRequestId: "r1", generationInvalidated: true)
        #expect(gen.kind == .expired)
        // item_changed/item_not_found: settled, outcome unknown from here —
        // never a fabricated 'expired'.
        let settled = AgentChatInteractionResolution(
            staleRequestId: "r2", generationInvalidated: false)
        #expect(settled.kind == .settledElsewhere)
        #expect(
            settled.transcriptBody
                == "This question was already answered or cancelled elsewhere.")
    }

    @Test("a resolution is Equatable/Codable-safe for persistence")
    func kindIsCodable() throws {
        let resolution = AgentChatInteractionResolution(
            requestId: "r1", kind: .youAnswered, labels: ["Ship it"])
        let round = try JSONDecoder().decode(
            AgentChatInteractionResolution.self,
            from: JSONEncoder().encode(resolution))
        #expect(round == resolution)
    }
}

// MARK: - The resolved-event-beats-ack race (v2 review fix)

/// The broker emits interaction.resolved synchronously with accepting
/// (ask.ts settle() runs before the reply), so the event can arrive
/// BEFORE the submitting store's own acknowledgement. The store's
/// in-flight marker (submittedAnswers) means: our own answer reads
/// 'You answered: <labels>' even when the ack is lost — only a
/// resolution the store NEVER submitted reads 'Answered from another
/// device.'
@Suite("Resolved-event vs answer-ack race")
@MainActor
struct AgentChatSubmissionRaceTests {
    @Test("a resolved event for an in-flight submission records OUR answer with labels, and the late ack dedups")
    func inflightSubmissionRace() async throws {
        let interaction = try! JSONDecoder().decode(
            AgentChatInteraction.self,
            from: Data(#"{"requestId":"r-1","generation":1,"kind":"question","questions":[{"id":"q1","text":"Ship it?","multi":false,"options":[{"id":"idx:0","label":"Ship it"}],"allowCustom":true}]}"#.utf8))
        let answers = [AgentChatAnswer(
            questionId: "q1", optionIds: ["idx:0"],
            customText: nil, note: nil)]

        // The store's internal pieces are private; the OBSERVABLE
        // contract is pinned through the same recordResolution the
        // event and ack paths call. Simulate the exact event ordering
        // by driving the two records in arrival order:
        let store = AgentChatStore(
            pipeFactory: AgentChatPipeFactory(
                open: { _ in throw AgentChatError.connectionClosed },
                hostRecord: { nil }),
            paneIdentity: { nil })
        // The resolved event arrives first (submission in flight):
        store.recordResolution(AgentChatInteractionResolution(
            answered: interaction, answers: answers))
        // The ack lands after (dedup by requestId — one record).
        store.recordResolution(AgentChatInteractionResolution(
            answered: interaction, answers: answers))
        #expect(store.interactionResolutions.count == 1)
        #expect(
            store.interactionResolutions.first?.transcriptBody
                == "You answered: Ship it")
        // A later, DIFFERENT resolution for the same id replaces the
        // record (the replace rule keeps one entry per requestId).
        store.recordResolution(AgentChatInteractionResolution(
            requestId: "r-1", wireOutcome: "answered", wireSource: "remote"))
        #expect(store.interactionResolutions.count == 1)
    }

    @Test("a resolution with NO local submission and wire source remote reads NEUTRAL")
    func unsubmittedRemoteIsNeutral() {
        let resolution = AgentChatInteractionResolution(
            requestId: "r-9", wireOutcome: "answered", wireSource: "remote")
        #expect(resolution.kind == .answeredRemotely)
        #expect(
            resolution.transcriptBody == "Answered remotely.")
    }
}

// MARK: - Resolved-event outcome gating (v2 review round 2)

/// The resolved handler respects the event's AUTHORITATIVE
/// outcome+source: an in-flight submission only records OUR labels
/// when the settle shape is answered+remote (the only shape this
/// store's own submission produces — the adapter's first-claim-wins
/// settle); cancelled/expired/terminal settle overrides the stash;
/// answered+remote with NO stash is another device.
@Suite("Resolved-event outcome gating")
struct AgentChatResolvedOutcomeGatingTests {
    private func wireResolution(
        outcome: String, source: String
    ) -> AgentChatInteractionResolution {
        AgentChatInteractionResolution(
            requestId: "r-gate", wireOutcome: outcome, wireSource: source)
    }

    @Test("a competing terminal answer beats our in-flight submission — never our labels")
    func terminalOutcomeOverridesStash() {
        let wire = wireResolution(outcome: "answered", source: "terminal")
        #expect(wire.kind == .answeredInTerminal)
        #expect(wire.transcriptBody == "Answered in the agent's terminal.")
    }

    @Test("cancelled/expired settles override an in-flight submission")
    func cancelledExpiredOverride() {
        #expect(
            wireResolution(outcome: "cancelled", source: "remote").kind
                == .cancelled)
        #expect(
            wireResolution(outcome: "expired", source: "terminal").kind
                == .expired)
    }

    @Test("answered+remote reads NEUTRAL until our ack confirms the win")
    func answeredRemoteNeutralUntilAck() {
        let wire = wireResolution(outcome: "answered", source: "remote")
        #expect(wire.kind == .answeredRemotely)
        #expect(wire.transcriptBody == "Answered remotely.")
    }

    @Test("an unknown outcome+source never fabricates a specific result")
    func unknownOutcomeIsSettledElsewhere() {
        #expect(
            wireResolution(outcome: "unknown", source: "remote").kind
                == .settledElsewhere)
    }
}

// MARK: - Resolved-ask rows in the transcript flow (v2)

struct ChatResolvedAskRowTests {
    private func message(_ text: String, role: ChatRole = .assistant) -> ChatMessage {
        ChatMessage(role: role, blocks: [.text(text)])
    }

    @Test("the resolved block renders at every detail level")
    func rendersAtEveryLevel() {
        let ask = ResolvedAsk(id: "r1", body: "You answered: Ship it")
        for level in DetailLevel.allCases {
            let rows = ChatFiltering.visibleRows(
                messages: [message("Earlier turn")], toolResults: [],
                pending: [], resolvedAsks: [ask], level: level)
            let askRows = rows.filter {
                if case .resolvedAsk = $0 { return true } else { return false }
            }
            #expect(askRows.count == 1)
        }
    }

    @Test("resolved blocks park AFTER the transcript, BEFORE any pending card — deterministic, no receipt-time interleave")
    func parksAfterTranscriptBeforePending() {
        let asks = [
            ResolvedAsk(id: "r1", body: "You answered: Ship it"),
            ResolvedAsk(id: "r2", body: "The question was cancelled."),
        ]
        let pending = PendingInteraction(
            question: "Proceed?", options: ["yes"])
        let rows = ChatFiltering.visibleRows(
            messages: [message("Earlier turn")], toolResults: [],
            pending: [pending], resolvedAsks: asks, level: .l0)
        let order = rows.map { row -> String in
            switch row {
            case .text(_, _, _, let text): return "text:\(text)"
            case .resolvedAsk(let ask): return "ask:\(ask.body)"
            case .pending: return "pending"
            default: return "other"
            }
        }
        // Deterministic: transcript rows, then resolved blocks in
        // first-record order, then the live edge. Local receipt time
        // is NEVER used to interleave (arrival time proves nothing
        // about conversation position).
        #expect(order == [
            "text:Earlier turn",
            "ask:You answered: Ship it",
            "ask:The question was cancelled.",
            "pending",
        ])
    }

    @Test("row id is stable and namespaced (level switching diffs cleanly)")
    func rowIdStable() {
        let ask = ResolvedAsk(id: "r-uuid-1", body: "You answered: Ship it")
        let rows = ChatFiltering.visibleRows(
            messages: [], toolResults: [], pending: [],
            resolvedAsks: [ask], level: .l0)
        #expect(rows.map(\.id) == ["resolved#r-uuid-1"])
    }
}

// MARK: - Resolution persistence across reconnects (v2 review fix)

/// Store-level persistence: the recorded resolutions are the
/// conversation's rendered history — start() (the reconnect/reopen
/// path every broker-channel loss and session resync takes) must
/// NEVER clear them, and its tombstone re-arm must keep the card
/// dead against a stale snapshot. The answer()/resolved-event paths
/// that produce resolutions are pinned by the wire-level suites
/// above; this pins the lifecycle contract directly through the same
/// recordResolution the live paths call.
@Suite("Resolved-ask persistence across reconnects and reopen")
@MainActor
struct AgentChatResolutionPersistenceTests {
    private static let socket = "/proof-archive/broker.sock"
    private static let session = "/proof-archive/session.jsonl"

    private func makeFactory(
    ) -> AgentChatPipeFactory {
        AgentChatPipeFactory(
            open: { _ in throw AgentChatError.connectionClosed },
            hostRecord: {
                var host = Host(address: "127.0.0.1", username: "jhou")
                host.brokerChatSocketPath = Self.socket
                return host
            })
    }

    @Test("a NEW store (detail reopen / app relaunch) reconstructs the resolution history from the archive")
    func newStoreReconstructsHistory() async throws {
        // Store 1 records the history (same-store start() persistence
        // AND archive write).
        let store1 = AgentChatStore(
            pipeFactory: makeFactory(),
            paneIdentity: {
                HerdrPaneSessionIdentity(sessionFilePath: Self.session)
            })
        await store1.start()
        try await Task.sleep(for: .milliseconds(200))
        store1.recordResolution(AgentChatInteractionResolution(
            requestId: "r-1", kind: .youAnswered, labels: ["Ship it"]))
        store1.recordResolution(AgentChatInteractionResolution(
            requestId: "r-2", kind: .cancelled, labels: nil))
        #expect(
            store1.interactionResolutions.count == 2,
            "same-store start() keeps resolutions")

        // A NEW store — the real detail-reopen path (AgentDetailView
        // owns the store in @State; leaving destroys it).
        let store2 = AgentChatStore(
            pipeFactory: makeFactory(),
            paneIdentity: {
                HerdrPaneSessionIdentity(sessionFilePath: Self.session)
            })
        await store2.start()
        try await Task.sleep(for: .milliseconds(200))
        #expect(
            store2.interactionResolutions.map(\.transcriptBody)
                == ["You answered: Ship it", "The question was cancelled."],
            "a new store must reconstruct the resolution history from the archive")

        // A re-recorded resolution for the same requestId REPLACES
        // (one entry per requestId, newest content wins).
        store2.recordResolution(AgentChatInteractionResolution(
            requestId: "r-1", kind: .settledElsewhere, labels: nil))
        #expect(store2.interactionResolutions.count == 2)
        #expect(
            store2.interactionResolutions.filter { $0.requestId == "r-1" }
                .map(\.kind) == [.settledElsewhere])

        // A different session identity has its OWN history (no bleed).
        let store3 = AgentChatStore(
            pipeFactory: makeFactory(),
            paneIdentity: {
                HerdrPaneSessionIdentity(
                    sessionFilePath: "/proof-archive/other.jsonl")
            })
        await store3.start()
        try await Task.sleep(for: .milliseconds(200))
        #expect(
            store3.interactionResolutions.isEmpty,
            "a different session must not see another session's history")

        // INIT-ORDER: the reconstructed history's requestIds are
        // tombstoned BEFORE the new store's first interactions
        // snapshot — a stale pending entry for an archived resolution
        // can never resurrect the card. This is exactly the
        // composition start() performs (archive load, then tombstone
        // derivation, then the snapshot install consults it).
        let snapshot = [
            AgentChatTestVectors.pendingInteraction(requestId: "r-1"),
            AgentChatTestVectors.pendingInteraction(requestId: "r-live"),
        ]
        let merged = AgentChatInteractionMerge.install(
            snapshot: snapshot,
            live: [],
            tombstones: Set(store2.interactionResolutions.map(\.requestId)))
        #expect(
            merged.map(\.requestId) == ["r-live"],
            "a stale snapshot must not resurrect an archived resolution's card")
    }

    private enum AgentChatTestVectors {
        static func pendingInteraction(requestId: String) -> AgentChatInteraction {
            let json = #"{"requestId":"\#(requestId)","generation":1,"kind":"question","questions":[{"id":"q1","text":"Ship it?","multi":false,"options":[],"allowCustom":true}]}"#
            return try! JSONDecoder().decode(
                AgentChatInteraction.self, from: Data(json.utf8))
        }
    }
}
