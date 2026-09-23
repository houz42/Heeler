import Foundation
import Testing

@testable import Heeler

// SPDX-License-Identifier: Apache-2.0
//
// Delivery-lifecycle regression proofs — v3 submitted-draft stack
// (durable outbox). The matched delivery contract is unchanged and
// these keep pinning it: the wire ack means QUEUED (accepted), never
// delivered; send.confirmed's requestKey→recordId binding — or a
// committed page's metadata.requestKey marker, the relaunch path —
// is the ONLY proof of producer commitment; .committed is monotonic;
// an entry drops only when ITS bound record renders; no text/FIFO
// matching claims anything.

@Suite("Agent chat outbox delivery lifecycle")
@MainActor
struct AgentChatOutgoingTests {
    /// The OFFLINE store: the conversation identity IS known (pane
    /// session file + broker socket — the archive key resolves), but
    /// the pipe is dead (start() fails to open it). This is the real
    /// offline-submission scenario: submit durably enqueues (the
    /// archive write holds), the entry stays locallyQueued (no
    /// channel), and NOTHING throws.
    private func offlineStore() async -> AgentChatStore {
        let store = AgentChatStore(
            pipeFactory: .init(open: { _ in
                throw CocoaError(.fileNoSuchFile)
            }, hostRecord: {
                Host(address: "h", username: "u",
                    brokerChatSocketPath: "/tmp/chat.sock")
            }),
            paneIdentity: {
                // Unique per store instance: the archive is REAL
                // disk state keyed socket+sessionFile — a fixed path
                // leaks entries between this suite's own tests.
                HerdrPaneSessionIdentity(
                    sessionFilePath: "/s/offline-\(UUID().uuidString)")
            })
        await store.start()  // archive identity resolves; pipe open fails
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

    private func entry(
        _ text: String, requestKey: String = UUID().uuidString,
        status: AgentChatOutboxEntry.Status = .accepted
    ) -> AgentChatOutboxEntry {
        var e = AgentChatOutboxEntry(
            requestKey: requestKey, text: text, ordinal: 1)
        e.status = status
        return e
    }

    // MARK: The outbox's own model contract

    @Test("submit enqueues durably BEFORE the wire: the editor may clear")
    func submitEnqueuesLocally() async {
        let store = await offlineStore()
        // Submit on an UNAVAILABLE store: the local enqueue still
        // holds (the design's A/B/C stacking without a network), the
        // entry stays locallyQueued (provably never dispatched — no
        // channel exists), and NOTHING throws (only a failed LOCAL
        // enqueue throws).
        let submitted = try? await store.submit("hello")
        #expect(submitted != nil)
        #expect(store.outbox.count == 1)
        #expect(store.outbox[0].status == .locallyQueued)
        #expect(store.outbox[0].text == "hello")
        #expect(store.outbox[0].ordinal == 1)
        // Ordinals advance per submission, never reused.
        _ = try? await store.submit("second")
        #expect(store.outbox.count == 2)
        #expect(store.outbox[1].ordinal == 2)
    }

    @Test("a submitted image keeps its ordered inline content")
    func submitKeepsImages() async {
        let store = await offlineStore()
        let images = [
            AgentChatOutgoingImage(data: Data([1]), mimeType: "image/png"),
            AgentChatOutgoingImage(data: Data([2]), mimeType: "image/png"),
        ]
        _ = try? await store.submit("", images: images)
        #expect(store.outbox[0].images.count == 2)
        #expect(store.outbox[0].images[0].data == Data([1]))
        #expect(store.outbox[0].images[1].data == Data([2]))
    }

    @Test("the archive round-trips entries + ordinal (relaunch reconstructs the pending region)")
    func archiveRoundTrip() {
        var e = AgentChatOutboxEntry(
            requestKey: "k-1", text: "queued while offline", ordinal: 3)
        e.status = .locallyQueued
        var rejected = AgentChatOutboxEntry(
            requestKey: "k-2", text: "nope", ordinal: 4)
        rejected.status = .rejected
        rejected.failureMessage = "This agent cannot receive messages."
        let url = AgentChatOutboxArchiveStore.archiveURL(
            socketPath: "/tmp/sock", sessionFile: "/s/file")
        guard let url else {
            Issue.record("archive URL must resolve")
            return
        }
        let saved = AgentChatOutboxArchiveStore.save(
            url: url, clientID: "client-1", nextOrdinal: 5, entries: [e, rejected])
        #expect(saved)
        let loaded = AgentChatOutboxArchiveStore.load(
            socketPath: "/tmp/sock", sessionFile: "/s/file")
        #expect(loaded.entries == [e, rejected])
        #expect(loaded.nextOrdinal == 5)
        #expect(loaded.clientID == "client-1")
    }

    @Test("distinct conversations keep distinct archives (host+conversation key)")
    func archivesAreKeyedPerConversation() {
        let a = AgentChatOutboxArchiveStore.archiveURL(
            socketPath: "/tmp/sock", sessionFile: "/s/one")
        let b = AgentChatOutboxArchiveStore.archiveURL(
            socketPath: "/tmp/sock", sessionFile: "/s/two")
        let c = AgentChatOutboxArchiveStore.archiveURL(
            socketPath: "/tmp/other", sessionFile: "/s/one")
        #expect(a != b)
        #expect(a != c)
        #expect(b != c)
    }

    @Test("a corrupt archive reads as empty — the surface starts fresh, never crashes")
    func corruptArchiveReadsEmpty() throws {
        let url = try #require(AgentChatOutboxArchiveStore.archiveURL(
            socketPath: "/tmp/corrupt-key-test", sessionFile: "/s/corrupt"))
        try Data("not json".utf8).write(to: url)
        let loaded = AgentChatOutboxArchiveStore.load(
            socketPath: "/tmp/corrupt-key-test", sessionFile: "/s/corrupt")
        #expect(loaded.entries.isEmpty)
        #expect(loaded.nextOrdinal == 1)
    }

    // MARK: Hide/show is display-only

    @Test("hide is display-only and recovery restores — never a retraction")
    func hideAndRecover() async {
        let store = await offlineStore()
        _ = try? await store.submit("hello")
        // A queued entry cannot be hidden (hide is for the states the
        // design allows: rejected/unknown).
        store.hideOutboxEntry(entryID: store.outbox[0].id)
        #expect(store.outbox[0].isHidden == false)
        // Simulate a rejected entry (the wire refusal path).
        store.setOutboxStatusForTesting(.rejected, id: store.outbox[0].id)
        store.hideOutboxEntry(entryID: store.outbox[0].id)
        #expect(store.outbox[0].isHidden == true)
        // The entry is still THERE (durable, recoverable).
        #expect(store.outbox.count == 1)
        store.showHiddenOutboxEntries()
        #expect(store.outbox[0].isHidden == false)
    }

    // MARK: No-text-authority (kept from the prior contract proofs)

    @Test("a text-matching record claims NOTHING — the entry stays unresolved")
    func textMatchClaimsNothing() {
        let e = entry("Continue")
        let record = userRecord("Continue")
        let survivors = AgentChatOutboxReconcile.reconcile(
            entries: [e], committed: [record])
        #expect(survivors.count == 1)
        #expect(survivors[0].status != .committed)
        #expect(survivors[0].confirmedRecordID == nil)
    }

    @Test("rejected and OUTCOME-UNKNOWN entries never reconcile away")
    func rejectedAndUnknownSurvive() {
        let record = userRecord("Continue")
        var rejected = entry("Continue", status: .rejected)
        rejected.failureMessage = "Send failed"
        var unknown = entry("Continue", status: .outcomeUnknown)
        unknown.failureMessage = "Connection lost mid-flight"
        let survivors = AgentChatOutboxReconcile.reconcile(
            entries: [rejected, unknown], committed: [record])
        #expect(survivors.count == 2)
        #expect(survivors.allSatisfy {
            $0.status == .rejected || $0.status == .outcomeUnknown
        })
    }

    @Test("a committed entry drops ONLY on ITS bound record — never on text")
    func committedDropsOnlyOnOwnRecord() {
        var confirmed = entry("Continue", requestKey: "k1", status: .committed)
        confirmed.confirmedRecordID = "record-A"
        // A text-identical record is NOT the bound record: no drop.
        let twin = userRecord("Continue")
        var survivors = AgentChatOutboxReconcile.reconcile(
            entries: [confirmed], committed: [twin])
        #expect(survivors.count == 1)
        // ITS record (exact stableID match): the entry drops.
        let own = ChatMessage(
            id: AgentChatMapper.stableID(for: "record-A"),
            role: .user, blocks: [.text("Continue")])
        survivors = AgentChatOutboxReconcile.reconcile(
            entries: survivors, committed: [own])
        #expect(survivors.isEmpty)
    }

    // MARK: The state-gated affordances

    @Test("resend requires outcome-unknown — a rejected entry takes the safe retry")
    func resendOnlyForUnknown() async {
        let store = await offlineStore()
        _ = try? await store.submit("hello")
        store.setOutboxStatusForTesting(.rejected, id: store.outbox[0].id)
        let keyBefore = store.outbox[0].requestKey
        await store.resendAcknowledgingPossibleDuplicate(
            entryID: store.outbox[0].id)
        // A rejected entry never goes through the may-duplicate path:
        // nothing changed (the retry seam is the duplicate-safe one).
        #expect(store.outbox[0].requestKey == keyBefore)
        #expect(store.outbox[0].status == .rejected)
        // The retry seam is the rejected entry's path (same key).
        await store.retry(entryID: store.outbox[0].id)
        #expect(store.outbox[0].requestKey == keyBefore)
    }

    @Test("an outcome-unknown resend mints a FRESH key (bypasses dedup by design)")
    func unknownResendMintsFreshKey() async {
        let store = await offlineStore()
        _ = try? await store.submit("hello")
        store.setOutboxStatusForTesting(.outcomeUnknown, id: store.outbox[0].id)
        let keyBefore = store.outbox[0].requestKey
        await store.resendAcknowledgingPossibleDuplicate(
            entryID: store.outbox[0].id)
        #expect(store.outbox[0].requestKey != keyBefore)
    }

    // MARK: Ambiguous classification (carried from the prior round)

    @Test("connection-loss and timeout classify OUTCOME-UNKNOWN; wire errors stay rejected")
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

/// The delivery contract's client side (matched, unchanged): the echo
/// reaches .committed ONLY via send.confirmed / the page's requestKey
/// marker (never the wire ack, never a text guess) and drops only when
/// its bound record lands in the committed page. The relaunch path —
/// a fresh store settling a PERSISTED entry from the page's
/// metadata.requestKey — is the v3 addition.
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

    private func entry(
        _ text: String, requestKey: String = UUID().uuidString,
        status: AgentChatOutboxEntry.Status = .accepted
    ) -> AgentChatOutboxEntry {
        var e = AgentChatOutboxEntry(
            requestKey: requestKey, text: text, ordinal: 1)
        e.status = status
        return e
    }

    @Test("a clean wire round-trip keeps the entry uncommitted — never sent")
    func wireAckIsNotCommitment() async throws {
        let store = try await connectedStore()
        defer { Task { await store.tearDown() } }
        _ = try await store.store.submit("hello")
        // The ack landed (the scripted broker answers immediately);
        // the entry reads accepted — NEVER committed (the design's
        // "Awaiting agent": acceptance is not delivery).
        for _ in 0..<100
        where store.store.outbox.first?.status != .accepted {
            try? await Task.sleep(for: .milliseconds(10))
        }
        #expect(store.store.outbox[0].status == .accepted)
        #expect(store.store.outbox[0].confirmedRecordID == nil)
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

    @Test("a committed entry drops only when ITS record is in the page")
    func committedEntryDropsOnOwnRecord() {
        var confirmed = entry("Continue", requestKey: "k1", status: .committed)
        confirmed.confirmedRecordID = "record-A"
        var survivors = AgentChatOutboxReconcile.reconcile(
            entries: [confirmed], committed: [])
        #expect(survivors.count == 1)
        let other = userRecord("Continue")
        survivors = AgentChatOutboxReconcile.reconcile(
            entries: survivors, committed: [other])
        #expect(survivors.count == 1)
        let own = ChatMessage(
            id: AgentChatMapper.stableID(for: "record-A"),
            role: .user, blocks: [.text("Continue")])
        survivors = AgentChatOutboxReconcile.reconcile(
            entries: survivors, committed: [own])
        #expect(survivors.isEmpty)
    }

    @Test("an unproven entry NEVER drops on text alone — the requestKey binding is the only authority")
    func unprovenStaysUntilConfirmed() {
        let e = entry("Continue", requestKey: "k1")
        let correlated = userRecord("Continue")
        var survivors = AgentChatOutboxReconcile.reconcile(
            entries: [e], committed: [correlated])
        #expect(survivors.count == 1)
        #expect(survivors[0].status != .committed)
        #expect(survivors[0].confirmedRecordID == nil)
        survivors[0].status = .committed
        survivors[0].confirmedRecordID = "record-A"
        survivors = AgentChatOutboxReconcile.reconcile(
            entries: survivors, committed: [correlated])
        #expect(survivors.count == 1)  // not on ITS record yet
        let bound = ChatMessage(
            id: AgentChatMapper.stableID(for: "record-A"),
            role: .user, blocks: [.text("Continue")])
        survivors = AgentChatOutboxReconcile.reconcile(
            entries: survivors, committed: [bound])
        #expect(survivors.isEmpty)
    }

    @Test("each inline image in one entry gets its OWN ref — no shared-identity collapse")
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
            #expect(ref.inlineData == images[index].data)
            refs.append(ref.ref)
        }
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

    @Test("the page's metadata.requestKey marker decodes onto the message item")
    func sendCorrelationMarkerDecodes() throws {
        // The adapter attaches metadata.requestKey to the correlated
        // committed user record (history.ts stashSendMarker): the
        // relaunch settle path keys on it.
        let json = #"{"kind":"message","id":"rec-1","author":{"role":"user"},"createdAt":null,"blocks":[{"type":"text","text":"hi"}],"metadata":{"requestKey":"k-9"}}"#
        let item = try JSONDecoder().decode(
            AgentChatItem.self, from: Data(json.utf8))
        guard case .message(_, _, _, _, let requestKey) = item else {
            Issue.record("expected message item")
            return
        }
        #expect(requestKey == "k-9")
        // No marker: nil, never a guess.
        let plain = #"{"kind":"message","id":"rec-2","author":{"role":"assistant"},"createdAt":null,"blocks":[{"type":"text","text":"ok"}]}"#
        let plainItem = try JSONDecoder().decode(
            AgentChatItem.self, from: Data(plain.utf8))
        guard case .message(_, _, _, _, let none) = plainItem else {
            Issue.record("expected message item")
            return
        }
        #expect(none == nil)
    }

    /// The shared connected-store harness: a scripted broker whose
    /// history.open answers phase-by-phase (first: empty; later: the
    /// page carrying record "rec-123" with its requestKey marker).
    private func connectedStore() async throws -> ConnectedStore {
        let pipe = ScriptedChatPipe()
        let historyOpens = HistoryOpenCounter()
        // ISOLATION: the outbox archive is keyed by broker socket +
        // pane session file on REAL disk (Application Support). A
        // shared "/s/file" leaks entries between tests and between
        // runs — each store instance gets a unique session file, and
        // the scripted broker advertises the SAME locator so the
        // exact-string match holds.
        let sessionFile = "/s/e2e-\(UUID().uuidString)"
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
                    sessionFile: sessionFile,
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
            paneIdentity: { HerdrPaneSessionIdentity(sessionFilePath: sessionFile) })
        await store.start()
        for _ in 0..<100 where store.phase != .ready {
            try? await Task.sleep(for: .milliseconds(20))
        }
        guard store.phase == .ready else {
            throw CocoaError(.fileReadUnknown)
        }
        return ConnectedStore(pipe: pipe, broker: broker, store: store)
    }

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
    /// prompt.send. The committed record the contract binds uses id
    /// "rec-123" — the exact id send.confirmed carries. history.open is
    /// REQUEST-COUNTER-SENSITIVE: the first call (handshake) serves
    /// the empty page; every later call (triggered by
    /// history.changed) serves the page carrying "rec-123" WITH its
    /// metadata.requestKey marker when a requestKey is stashed.
    private static func answer(
        pipe: ScriptedChatPipe, id: String, method: String, instanceId: String,
        sessionFile: String, historyOpenIndex: Int?
    ) async {
        switch method {
        case "sessions.list":
            await pipe.brokerSend(
                #"{"type":"response","id":"\#(id)","result":{"sessions":[{"instanceId":"\#(instanceId)","sessionId":"s1","generation":1,"locator":{"sessionFile":"\#(sessionFile)"},"agent":{"kind":"omp","version":"1"},"capabilities":{"history":true,"streaming":true,"prompt":true,"interrupt":true,"interactions":false,"commands":true,"attachments":true,"branches":false}}]}}"#)
        case "sessions.subscribe":
            await pipe.brokerSend(
                #"{"type":"response","id":"\#(id)","result":{"subscribed":true}}"#)
        case "history.open":
            if (historyOpenIndex ?? 0) == 0 {
                await pipe.brokerSend(
                    #"{"type":"response","id":"\#(id)","result":{"sessionId":"s1","generation":1,"revision":"rev-1","throughSeq":1,"items":[],"olderCursor":null}}"#)
            } else {
                await pipe.brokerSend(
                    #"{"type":"response","id":"\#(id)","result":{"sessionId":"s1","generation":1,"revision":"rev-2","throughSeq":3,"items":[{"kind":"message","id":"rec-123","author":{"role":"user"},"createdAt":null,"blocks":[{"type":"text","text":"hello broker"}],"metadata":{"requestKey":"MARKER"}}],"olderCursor":null}}"#)
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

/// End-to-end store proof over the scripted broker: the FULL v3
/// lifecycle. submit() → durable local enqueue → drain → ack keeps the
/// entry accepted; send.confirmed {requestKey, recordId} proves
/// commitment; the next history page carrying THAT record drops the
/// entry (the committed bubble renders in the transcript alone).
@Suite("Agent chat outbox: end-to-end over a scripted broker")
@MainActor
struct AgentChatOutboxE2ETests {

    @Test("enqueue → drain → ack → send.confirmed → committed → page drops the entry")
    func fullOutboxLifecycle() async throws {
        let store = try await connectedStore()
        defer { Task { await store.tearDown() } }

        // 1. submit(): durable local enqueue + immediate drain (the
        //    store is ready); the wire ack alone NEVER commits it.
        let submitted = try await store.store.submit("hello broker")
        #expect(store.store.outbox.count == 1)
        for _ in 0..<100
        where store.store.outbox.first?.status != .accepted {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(store.store.outbox[0].status == .accepted)
        #expect(store.store.outbox[0].ordinal == 1)

        // 2. The contract event: the committed record bound to this
        //    requestKey. The entry is PROVEN committed.
        await store.pipe.brokerSend(
            #"{"type":"event","instanceId":"inst-1","generation":1,"seq":2,"event":{"type":"send.confirmed","requestKey":"\#(submitted.requestKey)","recordId":"rec-123"}}"#)
        for _ in 0..<100
        where store.store.outbox.first?.status != .committed {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(store.store.outbox[0].status == .committed)
        #expect(store.store.outbox[0].confirmedRecordID == "rec-123")

        // 3. history.changed → the fresh page carries THE record: the
        //    entry drops, the committed bubble renders instead.
        await store.pipe.brokerSend(
            #"{"type":"event","instanceId":"inst-1","generation":1,"seq":3,"event":{"type":"history.changed","revision":"rev-2"}}"#)
        for _ in 0..<100 where !store.store.outbox.isEmpty {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(store.store.outbox.isEmpty)
        #expect(store.store.content.messages.contains {
            $0.id == AgentChatMapper.stableID(for: "rec-123")
        })
    }

    @Test("a late error NEVER demotes a proven committed entry (monotonic)")
    func committedIsMonotonicUnderLateError() async throws {
        let store = try await connectedStore()
        defer { Task { await store.tearDown() } }
        let submitted = try await store.store.submit("hello")
        await store.pipe.brokerSend(
            #"{"type":"event","instanceId":"inst-1","generation":1,"seq":2,"event":{"type":"send.confirmed","requestKey":"\#(submitted.requestKey)","recordId":"rec-mono"}}"#)
        for _ in 0..<100
        where store.store.outbox.first?.status != .committed {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(store.store.outbox[0].status == .committed)
        // A late failure write (a re-send racing the confirm): the
        // monotonic guard refuses it — demotion would resurrect the
        // may-duplicate affordance for a delivered message.
        store.store.markOutgoingForTesting(
            id: submitted.id, status: .rejected, message: "late wire error")
        #expect(store.store.outbox[0].status == .committed)
        #expect(store.store.outbox[0].failureMessage == nil)
    }

    @Test("the page's requestKey marker settles a persisted entry (the RELAUNCH path)")
    func pageMarkerSettlesWithoutEvent() async throws {
        let store = try await connectedStore()
        defer { Task { await store.tearDown() } }
        // Simulate a RELAUNCHED store's entry: accepted, no event can
        // ever arrive for it (the old connection's events are gone).
        let submitted = try await store.store.submit("hello broker")
        for _ in 0..<100
        where store.store.outbox.first?.status != .accepted {
            try await Task.sleep(for: .milliseconds(20))
        }
        // The fresh page carries the record WITH metadata.requestKey ==
        // the entry's key: the marker — not text, not the event —
        // proves commitment, and the entry drops in the same page.
        // The scripted marker page advertises metadata.requestKey
        // "MARKER" on rec-123: bind the persisted entry's key to it
        // (simulating the durable correlation the adapter recorded).
        store.store.setOutboxRequestKeyMarkerForTesting(
            id: submitted.id, marker: "MARKER")
        await store.pipe.brokerSend(
            #"{"type":"event","instanceId":"inst-1","generation":1,"seq":2,"event":{"type":"history.changed","revision":"rev-2"}}"#)
        for _ in 0..<100 where !store.store.outbox.isEmpty {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(store.store.outbox.isEmpty)
        #expect(store.store.content.messages.contains {
            $0.id == AgentChatMapper.stableID(for: "rec-123")
        })
    }

    @Test("an IMAGE-ONLY submission delivers, confirms, and drops its entry")
    func imageOnlySubmissionLifecycle() async throws {
        let store = try await connectedStore()
        defer { Task { await store.tearDown() } }
        let composedText = ChatDraftComposer.messageText(
            items: [.image(id: "i", remotePath: "/staged/shot.png", previewData: nil)],
            draft: "")
        #expect(composedText.isEmpty)
        #expect(ChatDraftComposer.isSendable(
            text: composedText,
            items: [.image(id: "i", remotePath: "/staged/shot.png", previewData: nil)]))
        let images = [AgentChatOutgoingImage(
            data: Data([0x89, 0x50, 0x4E, 0x47]), mimeType: "image/png")]
        let submitted = try await store.store.submit(composedText, images: images)
        for _ in 0..<100
        where store.store.outbox.first?.status != .accepted {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(store.store.outbox[0].status == .accepted)
        await store.pipe.brokerSend(
            #"{"type":"event","instanceId":"inst-1","generation":1,"seq":2,"event":{"type":"send.confirmed","requestKey":"\#(submitted.requestKey)","recordId":"rec-123"}}"#)
        for _ in 0..<100
        where store.store.outbox.first?.status != .committed {
            try await Task.sleep(for: .milliseconds(20))
        }
        await store.pipe.brokerSend(
            #"{"type":"event","instanceId":"inst-1","generation":1,"seq":3,"event":{"type":"history.changed","revision":"rev-2"}}"#)
        for _ in 0..<100 where !store.store.outbox.isEmpty {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(store.store.outbox.isEmpty)
    }

    @Test("offline submissions stack in order and drain on ready")
    func offlineStackDrainsInOrder() async throws {
        let store = try await connectedStore()
        defer { Task { await store.tearDown() } }
        // A, B, C stack without waiting on any network round-trip:
        // the ordinal order is the pending region's display order.
        _ = try await store.store.submit("A")
        _ = try await store.store.submit("B")
        _ = try await store.store.submit("C")
        #expect(store.store.outbox.map(\.text) == ["A", "B", "C"])
        #expect(store.store.outbox.map(\.ordinal) == [1, 2, 3])
        // All three drain (the store is ready): each reaches accepted.
        for _ in 0..<100
        where store.store.outgoingAllAcceptedCount() < 3 {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(store.store.outbox.allSatisfy { $0.status == .accepted })
    }

    private func connectedStore() async throws -> ConnectedStore {
        let pipe = ScriptedChatPipe()
        let historyOpens = HistoryOpenCounter()
        // ISOLATION: the outbox archive is keyed by broker socket +
        // pane session file on REAL disk (Application Support). A
        // shared "/s/file" leaks entries between tests and between
        // runs — each store instance gets a unique session file, and
        // the scripted broker advertises the SAME locator so the
        // exact-string match holds.
        let sessionFile = "/s/e2e-\(UUID().uuidString)"
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
                    sessionFile: sessionFile,
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
            paneIdentity: { HerdrPaneSessionIdentity(sessionFilePath: sessionFile) })
        await store.start()
        for _ in 0..<100 where store.phase != .ready {
            try? await Task.sleep(for: .milliseconds(20))
        }
        guard store.phase == .ready else {
            throw CocoaError(.fileReadUnknown)
        }
        return ConnectedStore(pipe: pipe, broker: broker, store: store)
    }

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

    private static func answer(
        pipe: ScriptedChatPipe, id: String, method: String, instanceId: String,
        sessionFile: String, historyOpenIndex: Int?
    ) async {
        switch method {
        case "sessions.list":
            await pipe.brokerSend(
                #"{"type":"response","id":"\#(id)","result":{"sessions":[{"instanceId":"\#(instanceId)","sessionId":"s1","generation":1,"locator":{"sessionFile":"\#(sessionFile)"},"agent":{"kind":"omp","version":"1"},"capabilities":{"history":true,"streaming":true,"prompt":true,"interrupt":true,"interactions":false,"commands":true,"attachments":true,"branches":false}}]}}"#)
        case "sessions.subscribe":
            await pipe.brokerSend(
                #"{"type":"response","id":"\#(id)","result":{"subscribed":true}}"#)
        case "history.open":
            if (historyOpenIndex ?? 0) == 0 {
                await pipe.brokerSend(
                    #"{"type":"response","id":"\#(id)","result":{"sessionId":"s1","generation":1,"revision":"rev-1","throughSeq":1,"items":[],"olderCursor":null}}"#)
            } else {
                await pipe.brokerSend(
                    #"{"type":"response","id":"\#(id)","result":{"sessionId":"s1","generation":1,"revision":"rev-2","throughSeq":3,"items":[{"kind":"message","id":"rec-123","author":{"role":"user"},"createdAt":null,"blocks":[{"type":"text","text":"hello broker"}],"metadata":{"requestKey":"MARKER"}}],"olderCursor":null}}"#)
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
