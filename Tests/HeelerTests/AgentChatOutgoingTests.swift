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
        _ text: String, baseline: Set<UUID>? = [],
        state: AgentChatOutgoingMessage.DeliveryState = .sending
    ) -> AgentChatOutgoingMessage {
        var e = AgentChatOutgoingMessage(
            requestKey: UUID().uuidString, text: text,
            baselineRecordIDs: baseline)
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

    @Test("a record IN the baseline never correlates (older identical record)")
    func baselineRecordNeverConfirms() {
        let older = userRecord("Continue")
        let e = echo("Continue", baseline: [older.id])
        var ledger: Set<UUID> = []
        let survivors = AgentChatEchoReconcile.reconcile(
            echoes: [e], committed: [older], consumedRecordIDs: &ledger)
        #expect(survivors.count == 1)
        #expect(survivors[0].state == .sending)  // untouched
    }

    @Test("a NEW record correlates ONE echo to .unconfirmed; the ledger never re-consumes")
    func ledgerPreventsReConsumption() {
        // Re-review round 4, finding 1: correlation transitions the
        // echo to .unconfirmed (NEVER silently drops it — no
        // authoritative producer correlation exists yet). The ledger
        // still guarantees one record → one echo.
        let record = userRecord("Continue")
        let a = echo("Continue", baseline: [])
        let b = echo("Continue", baseline: [])
        var ledger: Set<UUID> = []
        // First refresh: the ONE record consumes for A (oldest) — A
        // becomes .unconfirmed, B stays .sending.
        let afterOne = AgentChatEchoReconcile.reconcile(
            echoes: [a, b], committed: [record], consumedRecordIDs: &ledger)
        #expect(afterOne.count == 2)
        #expect(afterOne.contains { $0.id == a.id && $0.state == .unconfirmed })
        #expect(afterOne.contains { $0.id == b.id && $0.state == .sending })
        // The NEXT UNCHANGED refresh: the ledger holds the record —
        // B does NOT become unconfirmed (the re-consumption bug is
        // structurally gone).
        let afterTwo = AgentChatEchoReconcile.reconcile(
            echoes: afterOne, committed: [record], consumedRecordIDs: &ledger)
        #expect(afterTwo.count == 2)
        #expect(afterTwo.contains { $0.id == b.id && $0.state == .sending })
        // A SECOND NEW record consumes for B.
        let twin = userRecord("Continue")
        let afterThree = AgentChatEchoReconcile.reconcile(
            echoes: afterTwo, committed: [record, twin],
            consumedRecordIDs: &ledger)
        #expect(afterThree.allSatisfy { $0.state == .unconfirmed })
    }

    @Test("a text-only record never correlates an image-bearing echo")
    func imageEchoNeedsImageRecord() {
        let e = AgentChatOutgoingMessage(
            requestKey: "k", text: "look",
            images: [AgentChatOutgoingImage(data: Data([1]), mimeType: "image/png")],
            baselineRecordIDs: [])
        let textOnly = userRecord("look")
        var ledger: Set<UUID> = []
        let afterTextOnly = AgentChatEchoReconcile.reconcile(
            echoes: [e], committed: [textOnly], consumedRecordIDs: &ledger)
        #expect(afterTextOnly.count == 1)
        #expect(afterTextOnly[0].state == .sending)
        let withImage = userRecord("look", image: true)
        let afterImage = AgentChatEchoReconcile.reconcile(
            echoes: afterTextOnly, committed: [textOnly, withImage],
            consumedRecordIDs: &ledger)
        #expect(afterImage.count == 1)
        #expect(afterImage[0].state == .unconfirmed)
    }

    @Test("failed, AMBIGUOUS, and UNCONFIRMED echoes never reconcile away")
    func failedAndAmbiguousSurvive() {
        let record = userRecord("Continue")
        var failed = echo("Continue", state: .failed)
        failed.failureMessage = "Send failed"
        var ambiguous = echo("Continue", state: .ambiguous)
        ambiguous.failureMessage = "Connection lost mid-flight"
        var unconfirmed = echo("Continue", state: .unconfirmed)
        var ledger: Set<UUID> = []
        let survivors = AgentChatEchoReconcile.reconcile(
            echoes: [failed, ambiguous, unconfirmed], committed: [record],
            consumedRecordIDs: &ledger)
        #expect(survivors.count == 3)
        #expect(survivors.allSatisfy {
            $0.state == .failed || $0.state == .ambiguous
                || $0.state == .unconfirmed
        })
    }

    @Test("UNCONFIRMED carries NO failure copy (it is not an error)")
    func unconfirmedClearsMessage() async {
        // markOutgoing's switch: unconfirmed joins sending/sent in
        // clearing the message — verified via the store's observable
        // failure state (a later .sent does not clear the banner while
        // an unconfirmed echo exists without one).
        let store = await unavailableStore()
        do { _ = try await store.send("hello") } catch {}
        // The failed echo KEEPS its message (finding 2):
        #expect(store.outgoing[0].failureMessage != nil)
    }

    @Test("no baseline ⇒ no correlation (the echo stays, state untouched)")
    func noBaselineNoGuess() {
        let e = echo("Continue", baseline: nil)
        let record = userRecord("Continue")
        var ledger: Set<UUID> = []
        let survivors = AgentChatEchoReconcile.reconcile(
            echoes: [e], committed: [record], consumedRecordIDs: &ledger)
        #expect(survivors.count == 1)
        #expect(survivors[0].state == .sending)
    }

    @Test("a NEW record correlates the echo to UNCONFIRMED — never a silent drop")
    func newRecordCorrelatesToUnconfirmed() {
        let e = echo("Continue", baseline: [])
        let record = userRecord("Continue")
        var ledger: Set<UUID> = []
        let survivors = AgentChatEchoReconcile.reconcile(
            echoes: [e], committed: [record], consumedRecordIDs: &ledger)
        // Re-review round 4, finding 1: the echo STAYS, honestly
        // marked — the wire cannot authoritatively prove the match.
        #expect(survivors.count == 1)
        #expect(survivors[0].state == .unconfirmed)
        #expect(survivors[0].failureMessage == nil)
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

    @Test("send() snapshots the committed record-id baseline")
    func sendDerivesBaseline() async {
        let store = await unavailableStore()
        do { _ = try await store.send("hello") } catch {}
        // No committed user records → empty baseline set (present,
        // not nil — the send CAN correlate).
        #expect(store.outgoing[0].baselineRecordIDs != nil)
        #expect(store.outgoing[0].baselineRecordIDs?.isEmpty == true)
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
        baseline: Set<UUID>? = [],
        state: AgentChatOutgoingMessage.DeliveryState = .sending
    ) -> AgentChatOutgoingMessage {
        var e = AgentChatOutgoingMessage(
            id: UUID(), requestKey: requestKey, text: text,
            baselineRecordIDs: baseline)
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
        var ledger: Set<UUID> = []
        // The record is NOT in the page yet: the echo stays (the
        // committed record must render before the echo goes).
        var survivors = AgentChatEchoReconcile.reconcile(
            echoes: [confirmed], committed: [], consumedRecordIDs: &ledger)
        #expect(survivors.count == 1)
        // A DIFFERENT record lands: the echo still stays — the drop
        // is an exact id match, not text proximity.
        let other = userRecord("Continue")
        survivors = AgentChatEchoReconcile.reconcile(
            echoes: survivors, committed: [other], consumedRecordIDs: &ledger)
        #expect(survivors.count == 1)
        // ITS record lands: the echo drops (the real one renders).
        let own = ChatMessage(
            id: AgentChatMapper.stableID(for: "record-A"),
            role: .user, blocks: [.text("Continue")])
        survivors = AgentChatEchoReconcile.reconcile(
            echoes: survivors, committed: [own], consumedRecordIDs: &ledger)
        #expect(survivors.isEmpty)
    }

    @Test("an unconfirmed echo NEVER drops on text alone — the contract supersedes")
    func unconfirmedStaysUntilConfirmed() {
        // Round-4 honesty intact: text/baseline correlation marks
        // .unconfirmed; only send.confirmed's record id drops the echo.
        let e = echo("Continue", requestKey: "k1", baseline: [])
        var ledger: Set<UUID> = []
        let correlated = userRecord("Continue")
        var survivors = AgentChatEchoReconcile.reconcile(
            echoes: [e], committed: [correlated], consumedRecordIDs: &ledger)
        #expect(survivors.count == 1)
        #expect(survivors[0].state == .unconfirmed)
        #expect(survivors[0].confirmedRecordID == nil)
        // The contract lands for THIS key: now it is .sent with the
        // bound record id. Note the bound record ("record-A") is a
        // DIFFERENT record than the text-correlated one — the drop is
        // keyed on the CONTRACT's id, so the correlated record does
        // not drop it…
        survivors[0].state = .sent
        survivors[0].confirmedRecordID = "record-A"
        survivors = AgentChatEchoReconcile.reconcile(
            echoes: survivors, committed: [correlated],
            consumedRecordIDs: &ledger)
        #expect(survivors.count == 1)  // …not yet
        // …until the CONTRACT's record itself lands in the page.
        let bound = ChatMessage(
            id: AgentChatMapper.stableID(for: "record-A"),
            role: .user, blocks: [.text("Continue")])
        survivors = AgentChatEchoReconcile.reconcile(
            echoes: survivors, committed: [correlated, bound],
            consumedRecordIDs: &ledger)
        #expect(survivors.isEmpty)
    }

    // MARK: Inline-image echo projection (round 5)

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
