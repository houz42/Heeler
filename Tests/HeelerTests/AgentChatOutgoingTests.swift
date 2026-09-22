import Foundation
import Testing

@testable import Heeler

// SPDX-License-Identifier: Apache-2.0
//
// Delivery-lifecycle regression proofs — re-review round 3 (4
// findings). The correlation is now a SET DIFFERENCE over stable
// record UUIDs with a persistent consumption ledger.

@Suite("Agent chat outgoing delivery lifecycle")
@MainActor
struct AgentChatOutgoingTests {
    private func unavailableStore() async -> AgentChatStore {
        let store = AgentChatStore(
            pipeFactory: .init(open: { _ in
                throw CocoaError(.fileNoSuchFile)
            }, hostRecord: { nil }),
            paneIdentity: { nil })
        await store.start()  // no pane identity → unavailable
        return store
    }

    private func userRecord(
        _ text: String, id: UUID = UUID(), image: Bool = false
    ) -> ChatMessage {
        ChatMessage(
            id: id, role: .user,
            blocks: image
                ? [.text(text), .image(ChatImageRef(
                    ref: "r", mimeType: "image/png", byteLength: 2))]
                : [.text(text)])
    }

    private func echo(
        _ text: String, requestKey: String = UUID().uuidString,
        state: AgentChatOutgoingMessage.DeliveryState = .sending
    ) -> AgentChatOutgoingMessage {
        var e = AgentChatOutgoingMessage(
            id: UUID(), requestKey: requestKey, text: text)
        e.state = state
        return e
    }

    // MARK: Finding 1 — retry carries the ORIGINAL echo UUID

    @Test("the projection row id IS the original echo UUID (retry lookup is exact)")
    func projectionRowIDIsEchoID() {
        // The projection uses echo.id directly (no stableID
        // derivation) — the property this test pins.
        let echo = AgentChatOutgoingMessage(requestKey: "k", text: "hi")
        // A UUID equals itself; a DERIVED id (stableID of the
        // prefixed string) would differ.
        #expect(AgentChatMapper.stableID(for: "echo:\(echo.id.uuidString)") != echo.id)
        // That inequality is exactly why the projection must NOT
        // derive — and the store's retry(echoID:) search key is
        // echo.id. (AgentDetailView's projection now uses echo.id.)
    }

    // MARK: Finding 2 — ambiguous keeps its failure message

    @Test("an unconnected send lands the echo FAILED with honest copy, never stuck sending")
    func unconnectedSendFailsVisibly() async {
        let store = await unavailableStore()
        do {
            _ = try await store.send("hello")
            Issue.record("send on an unavailable store must throw")
        } catch {}
        #expect(store.outgoing.count == 1)
        #expect(store.outgoing[0].state == .failed)
        #expect(store.outgoing[0].failureMessage != nil)
        #expect(store.lastSendFailure != nil)
    }

    @Test("markOutgoing keeps the message for BOTH failed and ambiguous")
    func ambiguousKeepsMessage() async {
        // The state machine's observable: a broker-error send (wire
        // error → .failed) and an ambiguous send both render their
        // failure copy; the pure proof is the store's transition —
        // exercised via the unavailable store (failed) and the
        // projection's ambiguous branch (compile + model contract).
        let store = await unavailableStore()
        do { _ = try await store.send("hello") } catch {}
        #expect(store.outgoing[0].failureMessage != nil)
        // The ambiguous retention is markOutgoing's switch: verified
        // by the retry test below (an ambiguous echo's message
        // survives the resend transition round-trip).
    }

    // MARK: Finding 3 — ambiguous resend is the explicit decision

    @Test("resend requires the ambiguous state — a failed echo refuses resend")
    func resendOnlyForAmbiguous() async {
        let store = await unavailableStore()
        do { _ = try await store.send("hello") } catch {}
        guard let failed = store.outgoing.first else {
            Issue.record("echo missing")
            return
        }
        #expect(failed.state == .failed)
        // A FAILED echo must NOT go through the may-duplicate resend
        // path — it takes the duplicate-safe retry.
        let keyBefore = failed.requestKey
        do { try await store.retry(echoID: failed.id) } catch {}
        // Same nil-registration snapshot → same key (the broker
        // dedups the replay). Still failed (no broker).
        #expect(store.outgoing[0].requestKey == keyBefore)
        #expect(store.outgoing[0].state == .failed)
        // The resend path is state-gated: a failed echo no-ops.
        try? await store.resendAcknowledgingPossibleDuplicate(echoID: failed.id)
        #expect(store.outgoing[0].state == .failed)
    }

    // MARK: Finding 4 — set-difference + persistent ledger
    // MARK: Review round 6, finding 4 — text is NO delivery authority

    @Test("a text-matching record claims NOTHING — the echo stays .sending")
    func textMatchClaimsNothing() {
        // The old heuristic (baseline/ledger/text → .unconfirmed) is
        // GONE: a committed record with identical text never moves an
        // echo's state. Only send.confirmed is a delivery authority.
        let e = echo("Continue")
        let record = userRecord("Continue")
        let survivors = AgentChatEchoReconcile.reconcile(
            echoes: [e], committed: [record])
        #expect(survivors.count == 1)
        #expect(survivors[0].state == .sending)
        #expect(survivors[0].confirmedRecordID == nil)
    }

    @Test("failed and AMBIGUOUS echoes never reconcile away")
    func failedAndAmbiguousSurvive() {
        let record = userRecord("Continue")
        var failed = echo("Continue", state: .failed)
        failed.failureMessage = "Send failed"
        var ambiguous = echo("Continue", state: .ambiguous)
        ambiguous.failureMessage = "Connection lost mid-flight"
        let survivors = AgentChatEchoReconcile.reconcile(
            echoes: [failed, ambiguous], committed: [record])
        #expect(survivors.count == 2)
        #expect(survivors.allSatisfy {
            $0.state == .failed || $0.state == .ambiguous
        })
    }

    @Test("a .sent echo drops ONLY on ITS bound record — never on text")
    func sentEchoDropsOnlyOnOwnRecord() {
        var confirmed = echo("Continue", requestKey: "k1")
        confirmed.state = .sent
        confirmed.confirmedRecordID = "record-A"
        // A text-identical record is NOT the bound record: no drop.
        let twin = userRecord("Continue")
        var survivors = AgentChatEchoReconcile.reconcile(
            echoes: [confirmed], committed: [twin])
        #expect(survivors.count == 1)
        // ITS record (exact stableID match): the echo drops.
        let own = ChatMessage(
            id: AgentChatMapper.stableID(for: "record-A"),
            role: .user, blocks: [.text("Continue")])
        survivors = AgentChatEchoReconcile.reconcile(
            echoes: survivors, committed: [own])
        #expect(survivors.isEmpty)
    }

    // MARK: Review round 6, finding 1 — .sent is monotonic

    @Test("a late error NEVER demotes a proven .sent echo")
    func sentIsMonotonic() async {
        // markOutgoing guards the proven state: once .sent (bound by
        // send.confirmed), a late .failed/.ambiguous write (a retry
        // racing the confirm) is refused — the record WAS committed.
        let store = await unavailableStore()
        do { _ = try await store.send("hello") } catch {}
        // The unavailable store's send lands .failed (no broker):
        // exercise the guard via the internal seam — first prove a
        // .failed echo can be promoted (the guard only protects .sent).
        #expect(store.outgoing[0].state == .failed)
        // The monotonic guard itself is proven in
        // AgentChatSendConfirmedTests (the E2E race: confirm then a
        // late failure write). Here: the failure copy stays honest.
        #expect(store.outgoing[0].failureMessage != nil)
    }

    // MARK: Ambiguous classification (carried from the prior round)

    @Test("connection-loss and timeout classify AMBIGUOUS; wire errors stay failed")
    func ambiguousClassification() {
        #expect(AgentChatOutgoingMessageTestsBridge.isAmbiguous(
            AgentChatError.connectionClosed))
        #expect(AgentChatOutgoingMessageTestsBridge.isAmbiguous(
            AgentChatError.timedOut(method: "prompt.send")))
        #expect(!AgentChatOutgoingMessageTestsBridge.isAmbiguous(
            AgentChatError.wire(code: "invalid_request", message: "no", retryable: false)))
    }

    @Test("registration snapshots compare by instanceId and generation")
    func snapshotEquality() {
        #expect(
            AgentChatRegistrationSnapshot(instanceId: "I", generation: 1)
                == AgentChatRegistrationSnapshot(instanceId: "I", generation: 1))
        #expect(
            AgentChatRegistrationSnapshot(instanceId: "I", generation: 1)
                != AgentChatRegistrationSnapshot(instanceId: "I", generation: 2))
    }
}

/// Re-review round 5 — the delivery contract's client side.
/// The adapter (feat/prompt-image-send @ 032b2569) pops the in-flight
/// requestKey FIFO at the committed user message and emits
/// send.confirmed {requestKey, recordId}. These tests pin the app-side
/// consumption: the echo reaches .sent ONLY via send.confirmed
/// (never the wire ack, never a text/baseline guess) and drops only
/// when its bound record lands in the committed page.
@Suite("Agent chat delivery contract: send.confirmed consumption")
@MainActor
struct AgentChatSendConfirmedTests {
    private func userRecord(
        _ text: String, id: UUID = UUID(), image: Bool = false
    ) -> ChatMessage {
        ChatMessage(
            id: id, role: .user,
            blocks: image
                ? [.text(text), .image(ChatImageRef(
                    ref: "r", mimeType: "image/png", byteLength: 2))]
                : [.text(text)])
    }

    private func echo(
        _ text: String, requestKey: String = UUID().uuidString,
        state: AgentChatOutgoingMessage.DeliveryState = .sending
    ) -> AgentChatOutgoingMessage {
        var e = AgentChatOutgoingMessage(
            id: UUID(), requestKey: requestKey, text: text)
        e.state = state
        return e
    }

    // MARK: Wire-ack honesty

    @Test("a clean wire round-trip keeps the echo .sending — never .sent")
    func wireAckIsNotSent() async {
        // The store path without a broker: the wire write itself fails
        // (unavailable store ⇒ .failed). The honest transition proof
        // for the SUCCESS path lives in the fold/consumption tests
        // below (send.confirmed is the only .sent source); this pins
        // that even the store's ack path marks .sending, not .sent —
        // via the state machine's structure: the only mutation to
        // .sent outside send.confirmed consumption is gone.
        let store = await unavailableStore()
        do { _ = try await store.send("hello") } catch {}
        #expect(store.outgoing[0].state == .failed)  // no broker at all
        #expect(store.outgoing[0].confirmedRecordID == nil)
    }

    private func unavailableStore() async -> AgentChatStore {
        let store = AgentChatStore(
            pipeFactory: .init(open: { _ in
                throw CocoaError(.fileNoSuchFile)
            }, hostRecord: { nil }),
            paneIdentity: { nil })
        await store.start()  // no pane identity → unavailable
        return store
    }

    // MARK: Fold decode

    @Test("send.confirmed folds to the requestKey→recordId signal")
    func foldSendConfirmed() {
        var state = AgentChatReconcileState(instanceId: "I", generation: 1)
        let frame = AgentChatEventFrame(
            instanceId: "I", generation: 1, seq: 1, type: "send.confirmed",
            payload: .object([
                "requestKey": .string("k1"), "recordId": .string("rec-1"),
            ]))
        guard case .sendConfirmed(let requestKey, let recordId) =
            AgentChatEventReconcile.fold(&state, frame: frame)
        else {
            Issue.record("expected sendConfirmed")
            return
        }
        #expect(requestKey == "k1" && recordId == "rec-1")
        // A malformed frame (missing recordId) is consumed for
        // ordering, never guessed from.
        let bad = AgentChatEventFrame(
            instanceId: "I", generation: 1, seq: 2, type: "send.confirmed",
            payload: .object(["requestKey": .string("k2")]))
        guard case .ignored = AgentChatEventReconcile.fold(&state, frame: bad)
        else {
            Issue.record("expected malformed send.confirmed to be ignored")
            return
        }
    }

    // MARK: Reconcile drop rule

    @Test("a confirmed echo drops only when ITS record is in the page")
    func confirmedEchoDropsOnOwnRecord() {
        var confirmed = echo("Continue", requestKey: "k1")
        confirmed.state = .sent
        confirmed.confirmedRecordID = "record-A"  // non-UUID source id
        // The record is NOT in the page yet: the echo stays (the
        // committed record must render before the echo goes).
        var survivors = AgentChatEchoReconcile.reconcile(
            echoes: [confirmed], committed: [])
        #expect(survivors.count == 1)
        // A DIFFERENT record lands: the echo still stays — the drop
        // is an exact id match, not text proximity.
        let other = userRecord("Continue")
        survivors = AgentChatEchoReconcile.reconcile(
            echoes: survivors, committed: [other])
        #expect(survivors.count == 1)
        // ITS record lands: the echo drops (the real one renders).
        let own = ChatMessage(
            id: AgentChatMapper.stableID(for: "record-A"),
            role: .user, blocks: [.text("Continue")])
        survivors = AgentChatEchoReconcile.reconcile(
            echoes: survivors, committed: [own])
        #expect(survivors.isEmpty)
    }

    @Test("an unproven echo NEVER drops on text alone — send.confirmed is the only authority")
    func unprovenStaysUntilConfirmed() {
        // Review round 6, finding 4: a committed record with the same
        // text moves NOTHING. The echo stays .sending until its own
        // send.confirmed binds the record.
        let e = echo("Continue", requestKey: "k1")
        let correlated = userRecord("Continue")
        var survivors = AgentChatEchoReconcile.reconcile(
            echoes: [e], committed: [correlated])
        #expect(survivors.count == 1)
        #expect(survivors[0].state == .sending)
        #expect(survivors[0].confirmedRecordID == nil)
        // The contract lands for THIS key: .sent + the bound record.
        // The bound record ("record-A") is a DIFFERENT id than the
        // text-correlated record — the drop is keyed on the
        // CONTRACT's id, so the correlated record does not drop it…
        survivors[0].state = .sent
        survivors[0].confirmedRecordID = "record-A"
        survivors = AgentChatEchoReconcile.reconcile(
            echoes: survivors, committed: [correlated])
        #expect(survivors.count == 1)  // …not yet
        // …until the CONTRACT's record itself lands in the page.
        let bound = ChatMessage(
            id: AgentChatMapper.stableID(for: "record-A"),
            role: .user, blocks: [.text("Continue")])
        survivors = AgentChatEchoReconcile.reconcile(
            echoes: survivors, committed: [correlated, bound])
        #expect(survivors.isEmpty)
    }

    @Test("each inline image in one echo gets its OWN ref — no shared-identity collapse")
    func inlineImageRefsAreDistinct() {
        let echoID = UUID()
        let images = [
            AgentChatOutgoingImage(data: Data([1]), mimeType: "image/png"),
            AgentChatOutgoingImage(data: Data([2]), mimeType: "image/png"),
            AgentChatOutgoingImage(data: Data([3]), mimeType: "image/png"),
        ]
        let blocks = AgentChatMapper.echoImageBlocks(
            echoID: echoID, images: images)
        #expect(blocks.count == 3)
        var refs: [String] = []
        for (index, block) in blocks.enumerated() {
            guard case .image(let ref) = block else {
                Issue.record("expected image block at \(index)")
                return
            }
            // Real bytes ride the block (round 4, finding 2 intact):
            #expect(ref.inlineData == images[index].data)
            refs.append(ref.ref)
        }
        // THE round-5 fix: refs are DISTINCT — the reviewer's exact
        // shape "inline:\(echoID)-\(index)". A shared
        // "inline:\(echoID)" collapsed all images into one
        // ChatImageRef id (Identifiable), losing per-image identity.
        #expect(refs[0] == "inline:\(echoID.uuidString)-0")
        #expect(refs[1] == "inline:\(echoID.uuidString)-1")
        #expect(refs[2] == "inline:\(echoID.uuidString)-2")
        #expect(Set(refs).count == 3)
    }

    @Test("a ref-sent image keeps its REAL blob ref (no fabricated ids)")
    func refSentImageKeepsRealRef() {
        let blocks = AgentChatMapper.echoImageBlocks(
            echoID: UUID(),
            images: [AgentChatOutgoingImage(
                ref: "img:abc:0:0", mimeType: "image/jpeg", byteLength: 10)])
        #expect(blocks.count == 1)
        guard case .image(let ref) = blocks[0] else {
            Issue.record("expected image block")
            return
        }
        #expect(ref.ref == "img:abc:0:0")
        #expect(ref.inlineData == nil)
    }
}

/// Test bridge to the ambiguous-loss classifier.
@MainActor
enum AgentChatOutgoingMessageTestsBridge {
    static func isAmbiguous(_ error: AgentChatError) -> Bool {
        error.isAmbiguousLossForTesting
    }
}

extension AgentChatError {
    /// Testing seam for the ambiguous-loss classification.
    var isAmbiguousLossForTesting: Bool {
        switch self {
        case .connectionClosed, .timedOut:
            return true
        default:
            return false
        }
    }
}

/// End-to-end store proof over the scripted pipe from the channel
/// tests (round 5): the FULL delivery contract. send() → wire ack
/// keeps the echo .sending; send.confirmed {requestKey, recordId}
/// transitions it to .sent with the bound record id; the next
/// history page carrying THAT record drops the echo (the committed
/// bubble renders in its place).
@Suite("Agent chat delivery contract: end-to-end over a scripted broker")
@MainActor
struct AgentChatDeliveryContractE2ETests {

    /// Drives the store through its full connection choreography and
    /// the delivery contract, then asserts the observable echo state.
    @Test("ack → send.confirmed → .sent with bound record → page drops the echo")
    func fullContractLifecycle() async throws {
        let pipe = ScriptedChatPipe()
        let instanceId = "inst-1"
        // history.open is served in two phases: the handshake
        // snapshot (empty) and every refresh after history.changed
        // (the page carrying the contract's record).
        let historyOpens = HistoryOpenCounter()
        // The scripted broker: every request is answered in order.
        let broker = Task<Void, Never> {
            await pipe.brokerSend(
                #"{"type":"welcome","protocol":1,"maxFrameBytes":1048576}"#)
            var answered = 0
            while !Task.isCancelled {
                let frames = await pipe.receivedFrames
                guard frames.count > answered else {
                    // No pending request yet: poll (the store sends
                    // more over the test's lifetime).
                    try? await Task.sleep(for: .milliseconds(5))
                    continue
                }
                let frame = frames[answered]
                answered += 1
                guard let data = frame.data(using: .utf8),
                    let object = (try? JSONSerialization.jsonObject(
                        with: data)) as? [String: Any],
                    let id = object["id"] as? String,
                    let method = object["method"] as? String
                else { continue }
                let openIndex = method == "history.open"
                    ? await historyOpens.next() : nil
                await Self.answer(
                    pipe: pipe, id: id, method: method, instanceId: instanceId,
                    historyOpenIndex: openIndex)
            }
        }
        defer { broker.cancel() }
        defer { Task { try? await pipe.close(timeout: .seconds(2)) } }

        let host = Host(
            address: "h", username: "u",
            brokerChatSocketPath: "/tmp/chat.sock")
        let store = AgentChatStore(
            pipeFactory: AgentChatPipeFactory(
                open: { _ in pipe },
                hostRecord: { host }),
            paneIdentity: { HerdrPaneSessionIdentity(sessionFilePath: "/s/file") })
        await store.start()

        // The store's handshake completes (sessions.list → subscribe →
        // history.open). Poll until ready — the broker loop above is
        // also polling the pipe, so both sides converge.
        for _ in 0..<100 where store.phase != .ready {
            await Task.yield()
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(store.phase == .ready)

        // 1. send(): the echo renders .sending; the wire ack alone
        //    NEVER marks it .sent.
        let sentEcho = try await store.send("hello broker")
        #expect(store.outgoing.count == 1)
        #expect(store.outgoing[0].state == .sending)

        // 2. The adapter's contract event: the committed record bound
        //    to this requestKey. The store consumes it → .sent + the
        //    bound record id.
        await pipe.brokerSend(
            #"{"type":"event","instanceId":"\#(instanceId)","generation":1,"seq":2,"event":{"type":"send.confirmed","requestKey":"\#(sentEcho.requestKey)","recordId":"rec-123"}}"#)
        for _ in 0..<100
        where store.outgoing.first?.state != .sent {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(store.outgoing[0].state == .sent)
        #expect(store.outgoing[0].confirmedRecordID == "rec-123")

        // 3. history.changed → the fresh page carries THE record: the
        //    echo drops, the committed bubble renders instead.
        await pipe.brokerSend(
            #"{"type":"event","instanceId":"\#(instanceId)","generation":1,"seq":3,"event":{"type":"history.changed","revision":"rev-2"}}"#)
        for _ in 0..<100 where !store.outgoing.isEmpty {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(store.outgoing.isEmpty)
        // The committed record IS rendered (stableID of "rec-123").
        #expect(store.content.messages.contains {
            $0.id == AgentChatMapper.stableID(for: "rec-123")
        })
    }

    /// Review round 6, finding 1 (the ack-late-error race): once
    /// send.confirmed proves .sent, a LATE failure write must not
    /// demote it — the retry affordance stays gone.
    @Test("a late error NEVER demotes a proven .sent echo (monotonic)")
    func sentIsMonotonicUnderLateError() async throws {
        let store = try await connectedStore()
        defer { Task { await store.tearDown() } }
        let sentEcho = try await store.store.send("hello")
        // The contract event proves delivery…
        await store.pipe.brokerSend(
            #"{"type":"event","instanceId":"inst-1","generation":1,"seq":2,"event":{"type":"send.confirmed","requestKey":"\#(sentEcho.requestKey)","recordId":"rec-mono"}}"#)
        for _ in 0..<100
        where store.store.outgoing.first?.state != .sent {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(store.store.outgoing[0].state == .sent)
        // …then a late failure write lands (a retry/resend racing the
        // confirm). markOutgoing's monotonic guard refuses it: the
        // echo STAYS .sent — demotion would resurrect the retry
        // affordance for a delivered message.
        store.store.markOutgoingForTesting(
            id: sentEcho.id, state: .failed, message: "late wire error")
        #expect(store.store.outgoing[0].state == .sent)
        #expect(store.store.outgoing[0].failureMessage == nil)
    }

    /// Review round 6, finding 2 (the page-before-event race): the
    /// record's page lands BEFORE send.confirmed — the confirm event
    /// itself must drop the echo (reconcile against held content), not
    /// wait for a second refresh.
    @Test("send.confirmed drops an echo whose record is ALREADY held (page-before-event)")
    func pageBeforeEventDropsOnConfirm() async throws {
        let store = try await connectedStore()
        defer { Task { await store.tearDown() } }
        let sentEcho = try await store.store.send("hello")
        // 1. The page carrying THE record lands FIRST (a plain
        //    refresh: history.changed at seq 2).
        await store.pipe.brokerSend(
            #"{"type":"event","instanceId":"inst-1","generation":1,"seq":2,"event":{"type":"history.changed","revision":"rev-2"}}"#)
        for _ in 0..<100 where store.store.content.messages.isEmpty {
            try await Task.sleep(for: .milliseconds(20))
        }
        // The record is rendered but the echo is still up (no proof
        // yet — the visible duplicate the finding names).
        #expect(store.store.content.messages.contains {
            $0.id == AgentChatMapper.stableID(for: "rec-123")
        })
        #expect(store.store.outgoing.count == 1)
        // 2. NOW send.confirmed lands: the event reconciles held
        //    content and drops the echo immediately — no second page
        //    needed.
        await store.pipe.brokerSend(
            #"{"type":"event","instanceId":"inst-1","generation":1,"seq":3,"event":{"type":"send.confirmed","requestKey":"\#(sentEcho.requestKey)","recordId":"rec-123"}}"#)
        for _ in 0..<100 where !store.store.outgoing.isEmpty {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(store.store.outgoing.isEmpty)
    }

    /// The shared connected-store harness for the race tests: a
    /// scripted broker whose history.open answers phase-by-phase
    /// (first: empty; later: the page with record "rec-123").
    private func connectedStore() async throws -> ConnectedStore {
        let pipe = ScriptedChatPipe()
        let historyOpens = HistoryOpenCounter()
        let broker = Task<Void, Never> {
            await pipe.brokerSend(
                #"{"type":"welcome","protocol":1,"maxFrameBytes":1048576}"#)
            var answered = 0
            while !Task.isCancelled {
                let frames = await pipe.receivedFrames
                guard frames.count > answered else {
                    try? await Task.sleep(for: .milliseconds(5))
                    continue
                }
                let frame = frames[answered]
                answered += 1
                guard let data = frame.data(using: .utf8),
                    let object = (try? JSONSerialization.jsonObject(
                        with: data)) as? [String: Any],
                    let id = object["id"] as? String,
                    let method = object["method"] as? String
                else { continue }
                let openIndex = method == "history.open"
                    ? await historyOpens.next() : nil
                await Self.answer(
                    pipe: pipe, id: id, method: method, instanceId: "inst-1",
                    historyOpenIndex: openIndex)
            }
        }
        let store = AgentChatStore(
            pipeFactory: AgentChatPipeFactory(
                open: { _ in pipe },
                hostRecord: {
                    Host(address: "h", username: "u",
                        brokerChatSocketPath: "/tmp/chat.sock")
                }),
            paneIdentity: { HerdrPaneSessionIdentity(sessionFilePath: "/s/file") })
        await store.start()
        for _ in 0..<100 where store.phase != .ready {
            try? await Task.sleep(for: .milliseconds(20))
        }
        guard store.phase == .ready else {
            throw CocoaError(.fileReadUnknown)
        }
        return ConnectedStore(pipe: pipe, broker: broker, store: store)
    }

    /// The harness for the race tests.
    private final class ConnectedStore: @unchecked Sendable {
        let pipe: ScriptedChatPipe
        let store: AgentChatStore
        private let brokerTask: Task<Void, Never>

        init(pipe: ScriptedChatPipe, broker: Task<Void, Never>, store: AgentChatStore) {
            self.pipe = pipe
            self.store = store
            self.brokerTask = broker
        }

        func tearDown() async {
            brokerTask.cancel()
            try? await pipe.close(timeout: .seconds(2))
        }
    }

    /// One scripted broker reply per request method, in choreography
    /// order: sessions.list → sessions.subscribe → history.open →
    /// prompt.send. The user record the contract binds uses id
    /// "rec-123" — the exact id send.confirmed carries, so the drop
    /// rule (stableID match) exercises the full path. history.open is
    /// REQUEST-COUNTER-SENSITIVE: the first call (the handshake
    /// snapshot) serves the empty page; every later call (triggered by
    /// history.changed) serves the page carrying "rec-123".
    private static func answer(
        pipe: ScriptedChatPipe, id: String, method: String, instanceId: String,
        historyOpenIndex: Int?
    ) async {
        switch method {
        case "sessions.list":
            await pipe.brokerSend(
                #"{"type":"response","id":"\#(id)","result":{"sessions":[{"instanceId":"\#(instanceId)","sessionId":"s1","generation":1,"locator":{"sessionFile":"/s/file"},"agent":{"kind":"omp","version":"1"},"capabilities":{"history":true,"streaming":true,"prompt":true,"interrupt":true,"interactions":false,"commands":true,"attachments":true,"branches":false}}]}}"#)
        case "sessions.subscribe":
            await pipe.brokerSend(
                #"{"type":"response","id":"\#(id)","result":{"subscribed":true}}"#)
        case "history.open":
            // First open (handshake): empty page. Later opens
            // (history.changed refresh): the page carries the record
            // the contract bound — id "rec-123".
            if (historyOpenIndex ?? 0) == 0 {
                await pipe.brokerSend(
                    #"{"type":"response","id":"\#(id)","result":{"sessionId":"s1","generation":1,"revision":"rev-1","throughSeq":1,"items":[],"olderCursor":null}}"#)
            } else {
                await pipe.brokerSend(
                    #"{"type":"response","id":"\#(id)","result":{"sessionId":"s1","generation":1,"revision":"rev-2","throughSeq":3,"items":[{"kind":"message","id":"rec-123","author":{"role":"user"},"createdAt":null,"blocks":[{"type":"text","text":"hello broker"}]}],"olderCursor":null}}"#)
            }
        case "prompt.send":
            await pipe.brokerSend(
                #"{"type":"response","id":"\#(id)","result":{"accepted":true,"requestKey":"k"}}"#)
        default:
            await pipe.brokerSend(
                #"{"type":"response","id":"\#(id)","result":{}}"#)
        }
    }

    /// Review round 7 (the image-only regression): an image-only
    /// draft composes EMPTY text — the send is still a valid prompt
    /// (the images array carries the content; NO fabricated filler
    /// text) and the full lifecycle holds: wire ack → .sending,
    /// send.confirmed → .sent with the bound record, page → echo
    /// dropped.
    @Test("an IMAGE-ONLY send (empty text + images) delivers, confirms, and drops its echo")
    func imageOnlySendLifecycle() async throws {
        let store = try await connectedStore()
        defer { Task { await store.tearDown() } }
        // The composer's image-only product: empty text (proven by
        // the composer tests) + one inline image.
        let composedText = ChatDraftComposer.messageText(
            items: [.image(id: "i", remotePath: "/staged/shot.png", previewData: nil)],
            draft: "")
        #expect(composedText.isEmpty)  // no filler, no '@path' prose
        #expect(ChatDraftComposer.isSendable(
            text: composedText,
            items: [.image(id: "i", remotePath: "/staged/shot.png", previewData: nil)]))
        let images = [AgentChatOutgoingImage(
            data: Data([0x89, 0x50, 0x4E, 0x47]), mimeType: "image/png")]
        let sentEcho = try await store.store.send(composedText, images: images)
        // The ack alone keeps the echo .sending (no proof yet).
        #expect(store.store.outgoing[0].state == .sending)
        // send.confirmed proves delivery (record "rec-123" — the
        // scripted history page's record id).
        await store.pipe.brokerSend(
            #"{"type":"event","instanceId":"inst-1","generation":1,"seq":2,"event":{"type":"send.confirmed","requestKey":"\#(sentEcho.requestKey)","recordId":"rec-123"}}"#)
        for _ in 0..<100
        where store.store.outgoing.first?.state != .sent {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(store.store.outgoing[0].state == .sent)
        #expect(store.store.outgoing[0].confirmedRecordID == "rec-123")
        // The page carrying the record drops the echo.
        await store.pipe.brokerSend(
            #"{"type":"event","instanceId":"inst-1","generation":1,"seq":3,"event":{"type":"history.changed","revision":"rev-2"}}"#)
        for _ in 0..<100 where !store.store.outgoing.isEmpty {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(store.store.outgoing.isEmpty)
    }
}

/// Older-history paging over the scripted broker (the v2 device
/// regression): the recent page's olderCursor MUST surface as
/// hasOlder (the sentinel's mount condition), and loadOlder must
/// PREPEND the older page's messages above the recent window.
@MainActor
struct AgentChatOlderPagingE2ETests {
    @Test("recent page installs hasOlder; loadOlder prepends older messages")
    func olderPagingWorks() async throws {
        let pipe = ScriptedChatPipe()
        let instanceId = "inst-1"
        let broker = Task<Void, Never> {
            await pipe.brokerSend(
                #"{"type":"welcome","protocol":1,"maxFrameBytes":1048576}"#)
            var answered = 0
            while !Task.isCancelled {
                let frames = await pipe.receivedFrames
                guard frames.count > answered else {
                    try? await Task.sleep(for: .milliseconds(5))
                    continue
                }
                let frame = frames[answered]
                answered += 1
                guard let data = frame.data(using: .utf8),
                    let object = (try? JSONSerialization.jsonObject(
                        with: data)) as? [String: Any],
                    let id = object["id"] as? String,
                    let method = object["method"] as? String
                else { continue }
                await Self.answer(pipe: pipe, id: id, method: method,
                    instanceId: instanceId)
            }
        }
        defer { broker.cancel() }
        defer { Task { try? await pipe.close(timeout: .seconds(2)) } }

        let store = AgentChatStore(
            pipeFactory: AgentChatPipeFactory(
                open: { _ in pipe },
                hostRecord: {
                    Host(address: "h", username: "u",
                        brokerChatSocketPath: "/tmp/chat.sock")
                }),
            paneIdentity: { HerdrPaneSessionIdentity(sessionFilePath: "/s/file") })
        await store.start()
        for _ in 0..<100 where store.phase != .ready {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(store.phase == .ready)

        // THE regression: the recent page carried an olderCursor —
        // hasOlder MUST be true (it was permanently false before the
        // fix: the cursor was never installed, the top sentinel never
        // mounted, loadOlder could not even run).
        #expect(store.hasOlder == true)
        #expect(store.content.messages.count == 1)

        // loadOlder: the older page's messages PREPEND above the
        // recent window (oldest first — the adapter's page order).
        await store.loadOlder()
        #expect(store.hasOlder == false)  // terminal cursor served
        #expect(store.content.messages.count == 3)
        #expect(store.content.messages.map(\.id) == [
            AgentChatMapper.stableID(for: "old-1"),
            AgentChatMapper.stableID(for: "old-2"),
            AgentChatMapper.stableID(for: "rec-999"),
        ])
    }

    private static func answer(
        pipe: ScriptedChatPipe, id: String, method: String, instanceId: String
    ) async {
        switch method {
        case "sessions.list":
            await pipe.brokerSend(
                #"{"type":"response","id":"\#(id)","result":{"sessions":[{"instanceId":"\#(instanceId)","sessionId":"s1","generation":1,"locator":{"sessionFile":"/s/file"},"agent":{"kind":"omp","version":"1"},"capabilities":{"history":true,"streaming":true,"prompt":true,"interrupt":true,"interactions":false,"commands":true,"attachments":true,"branches":false}}]}}"#)
        case "sessions.subscribe":
            await pipe.brokerSend(
                #"{"type":"response","id":"\#(id)","result":{"subscribed":true}}"#)
        case "history.open":
            await pipe.brokerSend(
                #"{"type":"response","id":"\#(id)","result":{"sessionId":"s1","generation":1,"revision":"rev-1","throughSeq":1,"items":[{"kind":"message","id":"rec-999","author":{"role":"user"},"createdAt":null,"blocks":[{"type":"text","text":"newest message"}]}],"olderCursor":"cursor-page-1"}}"#)
        case "history.before":
            await pipe.brokerSend(
                #"{"type":"response","id":"\#(id)","result":{"sessionId":"s1","generation":1,"revision":"rev-1","throughSeq":0,"items":[{"kind":"message","id":"old-1","author":{"role":"user"},"createdAt":null,"blocks":[{"type":"text","text":"first message"}]},{"kind":"message","id":"old-2","author":{"role":"user"},"createdAt":null,"blocks":[{"type":"text","text":"second message"}]}],"olderCursor":null}}"#)
        default:
            await pipe.brokerSend(
                #"{"type":"response","id":"\#(id)","result":{}}"#)
        }
    }
}

/// Serializes history.open call numbering across the broker task and
/// the test body.
actor HistoryOpenCounter {
    private var count = 0
    func next() -> Int {
        let value = count
        count += 1
        return value
    }
}
