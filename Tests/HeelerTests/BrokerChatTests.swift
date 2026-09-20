import Foundation
import Testing

@testable import Heeler

// SPDX-License-Identifier: Apache-2.0
//
// The broker chat backend's pure seams: frame codec (against real
// captured wire frames), session matching (fail-closed ambiguity),
// entry slice reassembly, event ordering, error taxonomy, and the
// hello-arm flip that proves the v0 deletion path.

@Suite("Broker chat wire codec")
struct BrokerChatCodecTests {
    // Captured live from the v0 prototype broker (2026-09-20 session):
    // real frame shapes, trimmed to the fields under test.
    /// Live v1 frame (2026-09-20): registration carries sessionFile/pid.
    private static let capturedSessionsFrame = """
        {"id":"r1","result":{"sessions":[{"instanceId":"bf1ad296-bfd8-4072-ae84-787d647f626f","sessionId":"01a0ae90-2e79-701e-b52b-113e520b7972","generation":1,"capabilities":["history","events","prompt","commands","entry"],"sessionFile":"/Users/jhou/.cache/heeler-chat-main-probe/history.jsonl","pid":50879}]}}
        """
    private static let capturedSubscribeAck = """
        {"id":"s1","result":{"subscribed":true}}
        """
    private static let capturedEventFrame = """
        {"type":"event","instanceId":"048628c3-1020-417d-86f2-25732e07720a","generation":1,"seq":1110,"event":{"kind":"message_delta","delta":"ong"}}
        """
    /// Live v1 frame (2026-09-20): items without role (custom entries),
    /// no legacy flat-content preview fields.
    private static let capturedOpenPageFragment = """
        {"id":"r2","result":{"sessionId":"01a0ae90-2e79-701e-b52b-113e520b7972","leafId":"f0274435","items":[{"id":"32aa23e8","parentId":"d77202e2","timestamp":"2026-09-19T17:42:28.656Z","type":"custom","customType":"session_exit","data":{"reason":"sigterm","kind":"signal","recordedAt":"2026-09-19T17:42:28.655Z"}},{"id":"9ba51e1a","parentId":"32aa23e8","timestamp":"2026-09-19T17:46:00.082Z","type":"custom","customType":"session_exit","data":{"reason":"sigterm","kind":"signal","recordedAt":"2026-09-19T17:46:00.082Z"}},{"id":"f0274435","parentId":"9ba51e1a","timestamp":"2026-09-20T02:16:03.090Z","type":"custom","customType":"session_exit","data":{"reason":"sigterm","kind":"signal","recordedAt":"2026-09-20T02:16:03.090Z"}}],"olderCursor":"eyJ2IjoxLCJzZXNzaW9uSWQiOiIwMWEwYWU5MC0yZTc5LTcwMWUtYjUyYi0xMTNlNTIwYjc5NzIiLCJsZWFmSWQiOiJmMDI3NDQzNSIsImVudHJ5SWQiOiJkNzcyMDJlMiJ9","hasOlder":true,"bytes":891,"walked":3}}
        """

    @Test("frame reader joins split frames and enforces the cap")
    func frameReaderJoinsAndCaps() throws {
        var reader = BrokerFrameReader(maxFrameBytes: 256)
        // A frame split across two feeds.
        let first = try reader.feed(Data("{\"id\":\"a\",".utf8))
        #expect(first.isEmpty)
        let second = try reader.feed(
            Data("\"result\":1}\n{\"id\":\"b\",\"result\":2}\n".utf8))
        #expect(second.count == 2)

        // Oversized frame: fatal, never resync.
        var capped = BrokerFrameReader(maxFrameBytes: 8)
        #expect(throws: BrokerFrameReader.FrameError.frameTooLarge(bytes: 13, cap: 8)) {
            _ = try capped.feed(Data("abcdefghijklm\n".utf8))
        }
    }

    @Test("captured sessions frame decodes registrations")
    func sessionsFrameDecodes() throws {
        // The store decodes the envelope's `result` (not the raw frame),
        // so the vector goes through the same hop.
        let envelope = try JSONDecoder().decode(
            BrokerResponseEnvelope.self, from: Data(Self.capturedSessionsFrame.utf8))
        let result = try #require(envelope.result)
        let decoded = try JSONDecoder().decode(
            BrokerSessionsResult.self, from: JSONEncoder().encode(result))
        let session = try #require(decoded.sessions.first)
        #expect(session.sessionId == "01a0ae90-2e79-701e-b52b-113e520b7972")
        #expect(session.hasHistory && session.hasEvents && session.hasPrompt)
        // v1 registration metadata: sessionFile + pid decode (paneId
        // remains optional-additive and absent here).
        #expect(
            session.sessionFile
                == "/Users/jhou/.cache/heeler-chat-main-probe/history.jsonl")
        #expect(session.pid == 50879)
        #expect(session.paneId == nil)
    }

    @Test("captured event frame decodes with payload access")
    func eventFrameDecodes() throws {
        let value = try JSONDecoder().decode(JSONValue.self, from: Data(Self.capturedEventFrame.utf8))
        let frame = try #require(BrokerEventFrame(json: value))
        #expect(frame.instanceId == "048628c3-1020-417d-86f2-25732e07720a")
        #expect(frame.generation == 1)
        #expect(frame.seq == 1110)
        #expect(frame.kind == "message_delta")
        #expect(frame["delta"]?.stringValue == "ong")
    }

    @Test("captured open page decodes with cursor paging fields")
    func openPageDecodes() throws {
        let envelope = try JSONDecoder().decode(
            BrokerResponseEnvelope.self, from: Data(Self.capturedOpenPageFragment.utf8))
        let result = try #require(envelope.result)
        let page = try JSONDecoder().decode(
            BrokerHistoryPage.self, from: JSONEncoder().encode(result))
        #expect(page.hasOlder)
        #expect(page.olderCursor?.isEmpty == false)
        let item = try #require(page.items.first)
        #expect(!item.detailRequired)
        // v1 page items carry no flat-content preview; custom entries
        // expose type/customType/data. The cursor stays opaque.
        #expect(item.type == "custom")
        #expect(page.items.count == 3)
    }

    @Test("v1 hello ack flips the arm; silent broker keeps v0")
    func helloAckDecodes() throws {
        let ack = try JSONDecoder().decode(
            BrokerHelloAck.self,
            from: Data(#"{"type":"hello","proto":1,"maxFrameBytes":1048576}"#.utf8))
        #expect(ack.isV1)
        #expect(ack.maxFrameBytes == 1_048_576)
        // A wrong-proto ack is not a v1 ack.
        let wrong = try JSONDecoder().decode(
            BrokerHelloAck.self,
            from: Data(#"{"type":"hello","proto":2}"#.utf8))
        #expect(!wrong.isV1)
    }
}

@Suite("Broker session matching")
struct BrokerSessionMatchingTests {
    private static let panePath =
        "/Users/jhou/.omp/agent/sessions/-src/2026-09-17T14-29-22-773Z_01a0afc5-acd5-723d-b3e3-44416bcfbda8.jsonl"

    @Test("sessionId extraction from the transcript path")
    func sessionIdExtraction() {
        let identity = HerdrPaneSessionIdentity(sessionFilePath: Self.panePath)
        #expect(identity.sessionId == "01a0afc5-acd5-723d-b3e3-44416bcfbda8")
        // Non-session-file shapes yield nil (no fallback key).
        #expect(
            HerdrPaneSessionIdentity(sessionFilePath: "/tmp/nope.jsonl").sessionId
                == nil)
    }

    @Test("unique sessionId matches (v0 arm)")
    func uniqueMatch() {
        let pane = HerdrPaneSessionIdentity(sessionFilePath: Self.panePath)
        let registration = BrokerSessionRegistration(
            instanceId: "A", sessionId: "01a0afc5-acd5-723d-b3e3-44416bcfbda8",
            generation: 1)
        let match = BrokerSessionMatcher.match(pane: pane, registrations: [registration])
        guard case .matched(let found) = match else {
            Issue.record("expected match, got \(match)")
            return
        }
        #expect(found.instanceId == "A")
    }

    @Test("duplicate sessionIds fail closed — never an arbitrary pick")
    func duplicateFailsClosed() {
        // The live Mac broker's actual state: two instanceIds, one
        // sessionId. Matching must fail, not choose.
        let pane = HerdrPaneSessionIdentity(sessionFilePath: Self.panePath)
        let match = BrokerSessionMatcher.match(
            pane: pane,
            registrations: [
                BrokerSessionRegistration(
                    instanceId: "289fcf4e", sessionId: "01a0afc5-acd5-723d-b3e3-44416bcfbda8",
                    generation: 1),
                BrokerSessionRegistration(
                    instanceId: "048628c3", sessionId: "01a0afc5-acd5-723d-b3e3-44416bcfbda8",
                    generation: 1),
            ])
        guard case .ambiguous = match else {
            Issue.record("expected ambiguous fail-closed, got \(match)")
            return
        }
    }

    @Test("v1 sessionFile exact match wins over id ambiguity")
    func sessionFileExactWins() {
        let pane = HerdrPaneSessionIdentity(sessionFilePath: Self.panePath)
        // Same sessionId twice, but only one names the exact file.
        let match = BrokerSessionMatcher.match(
            pane: pane,
            registrations: [
                BrokerSessionRegistration(
                    instanceId: "A", sessionId: "01a0afc5-acd5-723d-b3e3-44416bcfbda8",
                    generation: 1),
                BrokerSessionRegistration(
                    instanceId: "B", sessionId: "01a0afc5-acd5-723d-b3e3-44416bcfbda8",
                    generation: 1, sessionFile: Self.panePath, paneId: "w1:p4"),
            ])
        guard case .matched(let found) = match else {
            Issue.record("expected file match, got \(match)")
            return
        }
        #expect(found.instanceId == "B")
        #expect(found.paneId == "w1:p4")
    }

    @Test("two registrations claiming the same file stay ambiguous")
    func duplicateFilesFailClosed() {
        let pane = HerdrPaneSessionIdentity(sessionFilePath: Self.panePath)
        let match = BrokerSessionMatcher.match(
            pane: pane,
            registrations: [
                BrokerSessionRegistration(
                    instanceId: "A", sessionId: "s1", generation: 1, sessionFile: Self.panePath),
                BrokerSessionRegistration(
                    instanceId: "B", sessionId: "s1", generation: 2, sessionFile: Self.panePath),
            ])
        guard case .ambiguous = match else {
            Issue.record("expected ambiguous, got \(match)")
            return
        }
    }

    @Test("no registration at all is honest unavailability")
    func noRegistration() {
        let pane = HerdrPaneSessionIdentity(sessionFilePath: Self.panePath)
        let match = BrokerSessionMatcher.match(
            pane: pane,
            registrations: [
                BrokerSessionRegistration(instanceId: "X", sessionId: "other", generation: 1)
            ])
        guard case .noRegistration = match else {
            Issue.record("expected noRegistration, got \(match)")
            return
        }
    }
}

@Suite("Broker entry slice reassembly")
struct BrokerEntryAssemblyTests {
    private func slice(
        offset: Int, bytes: [UInt8], total: Int, next: Int?
    ) throws -> BrokerEntrySlice {
        var object: [String: JSONValue] = [
            "entryId": .string("e"),
            "encoding": .string("json-utf8-base64"),
            "offset": .number(Double(offset)),
            "totalBytes": .number(Double(total)),
            "data": .string(Data(bytes).base64EncodedString()),
        ]
        if let next {
            object["nextOffset"] = .number(Double(next))
        }
        return try JSONDecoder().decode(
            BrokerEntrySlice.self, from: JSONEncoder().encode(JSONValue.object(object)))
    }

    @Test("two slices reassemble into the complete JSON")
    func reassembly() throws {
        let payload = Array(#"{"id":"e","type":"message","role":"user","blocks":[{"type":"text","text":"hello"}]}"#.utf8)
        var accumulated = Data()
        var complete: Data?
        let (p1, c1) = try BrokerEntryAssembler.assemble(
            accumulated: accumulated,
            slice: slice(offset: 0, bytes: Array(payload[..<40]), total: payload.count, next: 40))
        #expect(c1 == nil)
        accumulated = p1 ?? accumulated
        let (_, c2) = try BrokerEntryAssembler.assemble(
            accumulated: accumulated,
            slice: slice(offset: 40, bytes: Array(payload[40...]), total: payload.count, next: nil))
        complete = c2
        let data = try #require(complete)
        let json = try JSONDecoder().decode(JSONValue.self, from: data)
        #expect(json["role"]?.stringValue == "user")
    }

    @Test("a short final slice is refused, not padded silently")
    func truncatedRefused() throws {
        let full = Array(Data("{}".utf8))
        #expect(throws: BrokerEntryAssembler.AssemblyError.self) {
            _ = try BrokerEntryAssembler.assemble(
                accumulated: Data(),
                slice: slice(offset: 0, bytes: [UInt8(UInt8(ascii: "{"))], total: full.count, next: nil))
        }
    }

    @Test("wrong encoding is refused")
    func wrongEncodingRefused() throws {
        let slice = try JSONDecoder().decode(
            BrokerEntrySlice.self,
            from: Data(#"{"entryId":"e","encoding":"raw","offset":0,"totalBytes":2,"data":"e30=","nextOffset":null}"#.utf8))
        #expect(throws: BrokerEntryAssembler.AssemblyError.self) {
            _ = try BrokerEntryAssembler.assemble(accumulated: Data(), slice: slice)
        }
    }
}

@Suite("Broker event ordering + reconcile")
struct BrokerEventReconcileTests {
    private func frame(
        seq: Int, kind: String, generation: Int = 1,
        instanceId: String = "I", payload: [String: JSONValue] = [:]
    ) -> BrokerEventFrame {
        BrokerEventFrame(
            instanceId: instanceId, generation: generation, seq: seq,
            kind: kind, payload: .object(payload))
    }

    @Test("in-order durable transitions trigger a recent re-open")
    func durableTransitionRefetches() {
        var state = BrokerReconcileState(instanceId: "I", generation: 1)
        let effect = BrokerEventReconcile.fold(
            &state, frame: frame(seq: 1, kind: "message_end", payload: ["leafId": .string("x")]))
        guard case .refetchRecent = effect else {
            Issue.record("expected refetchRecent, got \(effect)")
            return
        }
        #expect(state.lastSeq == 1)
    }

    @Test("out-of-order frames are dropped, order restored after")
    func outOfOrderDropped() {
        var state = BrokerReconcileState(instanceId: "I", generation: 1)
        _ = BrokerEventReconcile.fold(&state, frame: frame(seq: 1, kind: "agent_start"))
        // A late duplicate and a replayed older frame: ignored.
        if case .ignored = BrokerEventReconcile.fold(
            &state, frame: frame(seq: 1, kind: "agent_start")) {} else {
            Issue.record("duplicate seq must be ignored")
        }
        if case .ignored = BrokerEventReconcile.fold(
            &state, frame: frame(seq: 0, kind: "turn_start")) {} else {
            Issue.record("older seq must be ignored")
        }
        // A gap buffers instead of applying; the fill unblocks it.
        if case .ignored = BrokerEventReconcile.fold(
            &state, frame: frame(seq: 4, kind: "message_end")) {} else {
            Issue.record("gap frame must be buffered")
        }
        #expect(state.buffered.count == 1)
        _ = BrokerEventReconcile.fold(&state, frame: frame(seq: 2, kind: "message_start"))
        #expect(state.buffered.count == 1)
        _ = BrokerEventReconcile.fold(&state, frame: frame(seq: 3, kind: "message_delta"))
        #expect(state.buffered.isEmpty)
        #expect(state.lastSeq == 4)
    }

    @Test("other instance and other generation frames are ignored/resync")
    func scoping() {
        var state = BrokerReconcileState(instanceId: "I", generation: 1)
        if case .ignored = BrokerEventReconcile.fold(
            &state, frame: frame(seq: 1, kind: "agent_start", instanceId: "OTHER")) {} else {
            Issue.record("other instance must be ignored")
        }
        if case .resync = BrokerEventReconcile.fold(
            &state, frame: frame(seq: 1, kind: "agent_start", generation: 2)) {} else {
            Issue.record("other generation must resync")
        }
    }

    @Test("resync_required and session_identity force a full resync")
    func resyncKinds() {
        var state = BrokerReconcileState(instanceId: "I", generation: 1)
        if case .resync = BrokerEventReconcile.fold(
            &state, frame: frame(seq: 1, kind: "resync_required")) {} else {
            Issue.record("resync_required must resync")
        }
        state = BrokerReconcileState(instanceId: "I", generation: 1)
        if case .resync = BrokerEventReconcile.fold(
            &state, frame: frame(seq: 1, kind: "session_identity")) {} else {
            Issue.record("session_identity must resync")
        }
    }

    @Test("provisional kinds apply without durable work")
    func provisionalKinds() {
        var state = BrokerReconcileState(instanceId: "I", generation: 1)
        if case .accepted = BrokerEventReconcile.fold(
            &state, frame: frame(seq: 1, kind: "message_delta", payload: ["delta": .string("hi")])) {} else {
            Issue.record("message_delta must be accepted")
        }
        #expect(state.lastSeq == 1)
    }
}

@Suite("Broker error taxonomy")
struct BrokerErrorTaxonomyTests {
    @Test("resync ladder classification")
    func resyncClassification() {
        let resyncCodes = [
            "stale_generation", "generation_mismatch", "session_unavailable",
            "unknown_session", "timeout",
        ]
        for code in resyncCodes {
            #expect(BrokerClientError.broker(code: code, message: "").requiresFullResync)
        }
        // Cursor codes: fresh open on the same registration, not full resync.
        for code in ["cursor_invalid", "cursor_branch_invalidated", "cursor_session_mismatch"] {
            let error = BrokerClientError.broker(code: code, message: "")
            #expect(error.requiresFreshOpen && !error.requiresFullResync)
        }
        // Unknown/other codes: neither — surfaced as failures.
        let other = BrokerClientError.broker(code: "param_invalid", message: "")
        #expect(!other.requiresFullResync && !other.requiresFreshOpen)
        // v1 entry codes (verified live 2026-09-20): a missing entry is
        // an ordinary failure (the store skips the stub); budget codes
        // surface honestly for the caller to adjust.
        for code in ["entry_not_found", "budget_too_small", "payload_too_large"] {
            let error = BrokerClientError.broker(code: code, message: "")
            #expect(!error.requiresFullResync && !error.requiresFreshOpen)
        }
    }

    @Test("ask unsupported is the honest capability signal")
    func askUnsupported() {
        #expect(
            BrokerClientError.broker(code: "unsupported_capability", message: "")
                .isAskUnsupported)
    }
}

@Suite("Broker history item mapping")
struct BrokerChatMapperTests {
    @Test("stub items carry no renderable content")
    func stubItems() throws {
        // v1 oversized item: minimal stub. Mapping must produce nothing —
        // the store fetches detail first; a stub never renders.
        let stub = try JSONDecoder().decode(
            BrokerHistoryItem.self,
            from: Data(
                #"{"id":"e1","parentId":"p","type":"message","role":"assistant","detailRequired":true,"serializedBytes":99999}"#
                    .utf8))
        #expect(stub.detailRequired)
        guard case .skipped = BrokerChatMapper.map(item: .object([
            "id": .string("e1"), "type": .string("message"),
        ])) else {
            Issue.record("typeless stub must skip")
            return
        }
    }

    @Test("full message item maps with block order preserved")
    func fullMessageMaps() throws {
        let item: JSONValue = try JSONDecoder().decode(
            JSONValue.self,
            from: Data(
                #"{"id":"m","type":"message","role":"assistant","blocks":[{"type":"thinking","thinking":"plan"},{"type":"toolCall","id":"call_1","name":"read","arguments":{"path":"f"}},{"type":"text","text":"done"}]}"#
                    .utf8))
        guard case .message(let message) = BrokerChatMapper.map(item: item) else {
            Issue.record("expected message")
            return
        }
        #expect(message.role == .assistant)
        #expect(message.blocks.count == 3)
        guard case .toolCall(let call) = message.blocks[1] else {
            Issue.record("expected toolCall at index 1")
            return
        }
        #expect(call.name == "read")
        #expect(call.arguments["path"]?.stringValue == "f")
    }

    @Test("toolResult maps with pairing id")
    func toolResultMaps() throws {
        let item: JSONValue = try JSONDecoder().decode(
            JSONValue.self,
            from: Data(
                #"{"id":"r","type":"message","role":"toolResult","toolCallId":"call_1","toolName":"read","isError":false,"blocks":[{"type":"text","text":"contents"}]}"#
                    .utf8))
        guard case .toolResult(let result) = BrokerChatMapper.map(item: item) else {
            Issue.record("expected toolResult")
            return
        }
        #expect(result.toolCallId == "call_1")
        #expect(result.content == "contents")
    }
}
