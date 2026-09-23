import CryptoKit
import Foundation
import Observation

// SPDX-License-Identifier: Apache-2.0
//
// The agent-chat v1 live-data store for one chat pane. Flow (contract
// L13): connect + welcome → sessions.list → match (locator exact /
// fail closed) → sessions.subscribe (BEFORE snapshot) → history.open
// (recent page carries throughSeq watermark) → apply buffered events
// above the watermark. history.changed re-opens (authoritative);
// disconnect/gap/session.unavailable ⇒ full re-match. prompt.send
// dedups by requestKey; interactions are optional and capability-gated
// with the honest unsupported state otherwise.

enum AgentChatPhase: Sendable, Equatable {
    case idle
    case connecting
    case loading
    case ready
    case unavailable(String)
    /// Ambiguous locator match — never picked arbitrarily.
    case ambiguous
    case disconnected(reason: String)
    case failed(reason: String)

    var isRenderable: Bool {
        switch self {
        case .ready, .disconnected: return true
        default: return false
        }
    }
}

/// One provisional in-flight stream, keyed by the adapter's streamId —
/// separate from committed items by contract.
struct AgentChatStreamTail: Sendable, Equatable {
    let streamId: String
    let authorRole: String?
    var text: String
}

/// One immutable submitted entry in the durable client outbox (v3
/// design: "Submitted-draft stack and delivery state"). Separated
/// from the EDITOR DRAFT (the composer's own persistence) and from the
/// COMMITTED TRANSCRIPT (the broker's history pages). The archive is
/// keyed by broker socket + pane session file (the conversation) —
/// never a bare pane id. The submitted CONTENT (text, ordered images,
/// ordinal) is immutable; `status` is the mutable delivery-state
/// column, driven ONLY by the matched delivery contract: the wire ack
/// means the broker QUEUED the prompt (accepted, commit still
/// pending), and send.confirmed's requestKey→recordId binding — or a
/// committed page's metadata.requestKey marker, the relaunch path — is
/// the ONLY proof of producer commitment. No text/baseline/FIFO
/// matching: a text-identical record claims nothing.
struct AgentChatOutboxEntry: Codable, Sendable, Equatable, Identifiable {
    /// The design's state table. "accepted" never appears in UI copy
    /// (the region renders "Awaiting agent"): it means the broker
    /// answered the prompt.send round-trip, which is not delivery.
    enum Status: String, Codable, Sendable, Equatable {
        /// Durable local enqueue; not yet on the wire ("Queued", or
        /// "Sending" while `isTransmitting`). Drained when the store
        /// reaches ready.
        case locallyQueued
        /// The broker answered the round-trip: queued broker-side; the
        /// agent has not committed a record yet ("Awaiting agent").
        case accepted
        /// Definitive nonacceptance — the broker answered NO (or the
        /// live registration lacks the capability). Retry is
        /// duplicate-safe (same requestKey within the registration).
        case rejected
        /// The wire died or timed out mid-flight — the broker may have
        /// accepted. Never auto-resubmitted; the explicit re-send
        /// ("Send again — may duplicate") is the user's decision.
        case outcomeUnknown
        /// PROVEN committed: requestKey→recordId bound. Sent appearance;
        /// the entry drops the moment its record renders in the page.
        case committed
    }

    let id: UUID
    /// The broker's dedup key. Reminted ONLY by the contract's own
    /// rules: a retry under registration churn, or the explicit
    /// may-duplicate re-send (a fresh key bypasses dedup by design).
    var requestKey: String
    /// The submitted text, verbatim from the editor.
    let text: String
    /// Ordered typed content: images ride the structured send as real
    /// image content blocks, never '@path' text.
    let images: [AgentChatOutgoingImage]
    /// Local submission ordinal — the pending region's display order.
    let ordinal: Int
    let submittedAt: Date
    /// The (instanceId, generation) the requestKey's dedup scope is
    /// bound to (a retry under a different snapshot mints a fresh key).
    var sendRegistration: AgentChatRegistrationSnapshot?
    var status: Status = .locallyQueued
    /// The committed record id bound by send.confirmed / the page's
    /// send-correlation marker. Present exactly when status == .committed.
    var confirmedRecordID: String?
    /// Honest copy for .rejected / .outcomeUnknown.
    var failureMessage: String?
    /// The wire attempt is in flight (transient — never persisted).
    var isTransmitting = false
    /// Display-only removal (rejected/unknown): NEVER a retraction of a
    /// delivered message; the durable record stays recoverable (show).
    var isHidden = false

    init(
        id: UUID = UUID(), requestKey: String, text: String,
        images: [AgentChatOutgoingImage] = [], ordinal: Int,
        submittedAt: Date = Date(),
        sendRegistration: AgentChatRegistrationSnapshot? = nil
    ) {
        self.id = id
        self.requestKey = requestKey
        self.text = text
        self.images = images
        self.ordinal = ordinal
        self.submittedAt = submittedAt
        self.sendRegistration = sendRegistration
    }

    private enum CodingKeys: String, CodingKey {
        case id, requestKey, text, images, ordinal, submittedAt
        case sendRegistration, status, confirmedRecordID, failureMessage
        case isHidden
    }
}

struct AgentChatOutgoingImage: Codable, Sendable, Equatable {
    var ref: String?
    var data: Data?
    var mimeType: String
    var byteLength: Int?

    init(ref: String? = nil, data: Data? = nil, mimeType: String, byteLength: Int? = nil) {
        precondition((ref == nil) != (data == nil),
            "exactly one of ref or data must carry the image")
        self.ref = ref
        self.data = data
        self.mimeType = mimeType
        self.byteLength = byteLength
    }
}
/// The (instanceId, generation) pair an outgoing requestKey is scoped
/// to. A plain struct so outbox entries stay Equatable and the
/// snapshot is comparable; Codable so an entry's registration
/// persists with it.
struct AgentChatRegistrationSnapshot: Codable, Sendable, Equatable {
    let instanceId: String
    let generation: Int
}

@MainActor
@Observable
final class AgentChatStore {
    // MARK: Observable state

    private(set) var phase: AgentChatPhase = .idle
    private(set) var content = ChatContent()
    /// Provisional streams, keyed by streamId — NEVER merged into the
    /// committed content until history.changed reconciles.
    private(set) var streamTails: [AgentChatStreamTail] = []
    private(set) var hasOlder = false
    private(set) var isLoadingOlder = false
    /// Capabilities of the matched registration (granular gating).
    private(set) var capabilities: AgentChatCapabilities?
    /// Pending interactions (only when interactions:true).
    private(set) var interactions: [AgentChatInteraction] = []
    /// Resolved asks in first-record order — the transcript row
    /// payload. A resolution is the ASK's tombstone and rendered
    /// record in one: the card is gone; the answer block is the
    /// trace. PERSISTENT across reconnects/reopen (conversation
    /// history, not connection state): `start()` never clears it; the
    /// tombstones re-arm below from the kept list.
    private(set) var interactionResolutions: [AgentChatInteractionResolution] = []

    /// The durable client outbox (v3: submitted-draft stack): every
    /// submitted entry, in local submission order. Entries persist to
    /// the outbox archive (keyed by broker socket + pane session file)
    /// on every change and are loaded on the store's first start — a
    /// relaunch reconstructs the pending region from disk. A committed
    /// entry drops the moment its record renders in the page; rejected
    /// / unknown entries keep their affordances until the user acts.
    private(set) var outbox: [AgentChatOutboxEntry] = []
    var askSupported: Bool { capabilities?.interactions == true }

    // MARK: Wiring

    private let pipeFactory: AgentChatPipeFactory
    private let paneIdentity: () -> HerdrPaneSessionIdentity?
    private let requestTimeout: Duration

    @ObservationIgnored private var channel: AgentChatChannel?
    @ObservationIgnored private var registration: AgentChatRegistration?
    @ObservationIgnored private var reconcile = AgentChatReconcileState(
        instanceId: "", generation: 1)
    @ObservationIgnored private var olderCursor: String?
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var lifecycleTask: Task<Void, Never>?
    @ObservationIgnored private var bufferedEvents: [AgentChatEventFrame] = []
    /// RequestIds resolved during this connection (any outcome). A
    /// resolution racing an in-flight interactions.list must win over
    /// the stale snapshot — the card may never resurrect.
    @ObservationIgnored private var resolvedInteractionTombstones: Set<String> = []
    /// The persisted-history identity: the broker socket + pane session
    /// the archive file is keyed by. Set on the first start() that
    /// resolves availability + pane identity.
    @ObservationIgnored private var archiveIdentity:
        (socketPath: String, sessionFile: String)?
    @ObservationIgnored private var didLoadArchivedResolutions = false
    /// Answers THIS store has submitted but not yet acknowledged (the
    /// broker emits interaction.resolved synchronously with accepting,
    /// so the event can beat the submit's own reply). The resolved
    /// handler records these NEUTRALLY — the broadcast cannot identify
    /// the winner — and only this store's accepted acknowledgement
    /// (the answer path) upgrades the record to our labels.
    @ObservationIgnored private var submittedAnswers:
        [String: AgentChatInteractionResolution] = [:]
    @ObservationIgnored private var subscribed = false
    @ObservationIgnored private var recentPageEpoch = 0
    /// Reconnect backoff after a broker-channel loss (contract: any
    /// lost connection means resubscribe+open). Grows per attempt,
    /// resets when a page lands again.
    @ObservationIgnored private var reconnectDelay: Duration = .seconds(1)
    @ObservationIgnored private var reconnectTask: Task<Void, Never>? = nil
    @ObservationIgnored private var outboxArchiveIdentity:
        (socketPath: String, sessionFile: String)?
    @ObservationIgnored private var didLoadOutboxArchive = false
    /// The next local submission ordinal (one per conversation archive;
    /// persisted with the archive so ordinals never reuse across
    /// relaunches).
    @ObservationIgnored private var nextOutboxOrdinal = 1
    /// The store's stable client identifier (the archive's clientId
    /// dimension): one per installed app, minted once. Entries from
    /// OTHER clients are not this store's to retry — they render in
    /// the pending region read-only.
    @ObservationIgnored private static let clientID: String = {
        let key = "heeler.chat.outbox.clientID"
        if let existing = UserDefaults.standard.string(forKey: key) {
            return existing
        }
        let fresh = UUID().uuidString
        UserDefaults.standard.set(fresh, forKey: key)
        return fresh
    }()
    @ObservationIgnored private var promptRequestKeys: Set<String> = []

    init(
        pipeFactory: AgentChatPipeFactory,
        paneIdentity: @escaping () -> HerdrPaneSessionIdentity?,
        requestTimeout: Duration = .seconds(30)
    ) {
        self.pipeFactory = pipeFactory
        self.paneIdentity = paneIdentity
        self.requestTimeout = requestTimeout
    }

    // MARK: Lifecycle

    func start() async {
        lifecycleTask?.cancel()
        if let channel {
            let old = channel
            self.channel = nil
            Task { await old.close() }
        }
        // Content-preserving reconnect (item 6 + seamless refresh, 13):
        // a re-match after session.unavailable / a lock-unlock cycle
        // keeps the last committed page RENDERED while the new channel
        // connects (the phase stays renderable for the old content; a
        // blank/failed-content placeholder mid-reconnect was the
        // unlock '!' bug). Only the volatile, channel-bound state
        // resets; the committed page and the durable outbox survive
        // until the fresh page lands.
        let wasRenderable = phase.isRenderable
        let heldContent = wasRenderable ? content : nil
        streamTails = []
        interactions = []
        hasOlder = false
        olderCursor = nil
        registration = nil
        capabilities = nil
        bufferedEvents = []
        submittedAnswers = [:]
        subscribed = false
        reconnectTask?.cancel()
        reconnectTask = nil
        generation &+= 1
        let myGeneration = generation

        guard let pane = paneIdentity() else {
            phase = .unavailable(
                "This agent has no session identity to match against the chat broker.")
            if heldContent != nil { content = heldContent ?? ChatContent() }
            return
        }
        guard case .available(let socketPath) = await pipeFactory.availability()
        else {
            phase = .unavailable("No chat broker is configured for this Host.")
            if heldContent != nil { content = heldContent ?? ChatContent() }
            return
        }
        // Keep the old content visible while connecting (the honest
        // "reconnecting" banner rides in the view; content never blanks).
        phase = heldContent != nil ? .disconnected(
            reason: "Reconnecting to the chat broker…") : .connecting
        content = heldContent ?? ChatContent()
        // FIRST start on this store: the durable outbox loads from its
        // archive (a NEW store — the detail reopen path, an app
        // relaunch — reconstructs the pending region from disk; later
        // start()s keep the in-memory list, which is never behind the
        // archive).
        outboxArchiveIdentity = (
            socketPath: socketPath, sessionFile: pane.sessionFilePath)
        var performedFreshOutboxLoad = false
        if !didLoadOutboxArchive {
            didLoadOutboxArchive = true
            performedFreshOutboxLoad = true
            let archived = AgentChatOutboxArchiveStore.load(
                socketPath: socketPath, sessionFile: pane.sessionFilePath)
            outbox = archived.entries
            nextOutboxOrdinal = archived.nextOrdinal
        }
        // A FRESH archive load (relaunch/reopen) is the one place a
        // never-settled wire attempt cannot be settled by its own
        // catch (the process that owned it is gone). The archive
        // persists `isTransmitting`, so an entry whose attempt was IN
        // FLIGHT when the process died reads as outcome-unknown here —
        // honest: it may have left, never auto-resubmit (the design's
        // reconnect rule). Everything else keeps its durable status:
        // a never-dispatched queued entry stays queued (dispatch is
        // this client's alone), a broker-acknowledged entry stays
        // accepted, a rejection stays a rejection, a PROVEN
        // commitment stays proven (the monotonic rule).
        if performedFreshOutboxLoad {
            var relaunchSettled = false
            for index in outbox.indices where outbox[index].isTransmitting {
                outbox[index].isTransmitting = false
                outbox[index].status = .outcomeUnknown
                outbox[index].failureMessage =
                    "The app stopped before this message's delivery could be confirmed."
                relaunchSettled = true
            }
            if relaunchSettled { persistOutbox() }
        }
        // FIRST start on this store: the persisted resolution history
        // loads from the archive (a NEW store — the detail reopen
        // path — reconstructs its history here; later start()s keep
        // the in-memory list, which is never behind the archive).
        // ORDER: the load precedes the tombstone derivation below —
        // a new store must have BOTH its rendered history AND the
        // tombstones before its first interactions snapshot, or a
        // stale pending entry could resurrect an answered card.
        archiveIdentity = (socketPath: socketPath, sessionFile: pane.sessionFilePath)
        if !didLoadArchivedResolutions {
            didLoadArchivedResolutions = true
            let archived = AgentChatResolutionArchiveStore.load(
                socketPath: socketPath, sessionFile: pane.sessionFilePath)
            if !archived.isEmpty {
                interactionResolutions = archived
            }
        }
        // Resolutions PERSIST across reconnects/reopen (they are the
        // conversation's rendered history, not connection state). The
        // tombstones re-arm from the (now archive-backed) list so a
        // snapshot racing a previously-recorded resolution — including
        // a NEW store's very first interactions.list — can never
        // resurrect an answered card.
        resolvedInteractionTombstones = Set(
            interactionResolutions.map(\.requestId))
        phase = .connecting
        lifecycleTask = Task { [weak self] in
            await self?.run(
                socketPath: socketPath, pane: pane, storeGeneration: myGeneration,
                holdsContent: heldContent != nil)
        }
    }

    private func run(
        socketPath: String, pane: HerdrPaneSessionIdentity, storeGeneration: Int,
        holdsContent: Bool
    ) async {
        do {
            let pipe = try await pipeFactory.open(socketPath)
            let channel = AgentChatChannel(
                pipe: pipe, requestTimeout: requestTimeout,
                onEvent: { [weak self] event in
                    Task { @MainActor [weak self] in
                        self?.handleChannelEvent(event, storeGeneration: storeGeneration)
                    }
                })
            self.channel = channel
            print("AGENTCHAT-DIAG channel opening to broker socket: \(socketPath)")
            try await channel.connect()  // welcome or fail closed
            print("AGENTCHAT-DIAG channel negotiated v1")
            guard generation == storeGeneration else { return }

            // Review gap 6: with held content the phase STAYS
            // .disconnected (renderable) through the whole re-match —
            // session lookup and history load happen behind the
            // retained page; the view never blanks mid-reconnect.
            // Only a fresh open (no content to hold) shows .loading.
            if !holdsContent {
                phase = .loading
            }
            // 1. sessions.list
            let sessionsValue = try await channel.request(
                AgentChatRequest(id: "", method: "sessions.list"))
            let sessions = try Self.decode(
                AgentChatSessionsResult.self, from: sessionsValue).sessions
            guard generation == storeGeneration else { return }

            // 2. match — locator exact, duplicates fail closed.
            switch AgentChatMatcher.match(pane: pane, registrations: sessions) {
            case .matched(let match):
                registration = match
                capabilities = match.capabilities
            case .noRegistration:
                phase = .unavailable(
                    "This agent is not registered with the chat broker.")
                return
            case .ambiguous:
                phase = .ambiguous
                return
            }
            guard let registration else { return }

            // 3. subscribe BEFORE the snapshot; buffer events.
            if registration.capabilities.streaming {
                _ = try await channel.request(
                    AgentChatRequest(
                        id: "", method: "sessions.subscribe",
                        target: AgentChatTarget(
                            instanceId: registration.instanceId,
                            generation: registration.generation)))
                guard generation == storeGeneration else { return }
                subscribed = true
            }

            reconcile = AgentChatReconcileState(
                instanceId: registration.instanceId,
                generation: registration.generation)

            // 4. Interactions snapshot replay — IMMEDIATELY after
            // subscribe: the live event stream alone misses
            // already-open questions (late subscriber; proven on the
            // real runtime). Runs before the history snapshot so
            // pending asks render with the first content.
            if registration.capabilities.interactions {
                try await refreshInteractions()
            }

            // 5. Snapshot: recent page + watermark + buffered replay.
            try await loadRecentPage(storeGeneration: storeGeneration)

            // 6. Park: events drive everything from here.
            await withCheckedContinuation {
                (continuation: CheckedContinuation<Void, Never>) in
                parked.append(continuation)
            }
        } catch is CancellationError {
        } catch let error as AgentChatError {
            if generation == storeGeneration {
                applyError(error)
            }
        } catch {
            if generation == storeGeneration {
                phase = .failed(reason: friendly(error))
            }
        }
    }

    @ObservationIgnored private var parked: [CheckedContinuation<Void, Never>] = []

    /// Contract: a lost broker connection means resubscribe+open. The
    /// banner stays visible (honest state) while the retry runs.
    private func scheduleReconnect() {
        let delay = reconnectDelay
        reconnectDelay = min(reconnectDelay * 2, .seconds(30))
        let myGeneration = generation
        reconnectTask = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            guard let self, self.generation == myGeneration else { return }
            await self.start()
        }
    }

    private func endParked() {
        for continuation in parked {
            continuation.resume()
        }
        parked.removeAll()
    }

    // MARK: Older paging

    func loadOlder() async {
        guard phase == .ready, let channel, let registration,
            let currentCursor = olderCursor, !isLoadingOlder
        else { return }
        isLoadingOlder = true
        defer { isLoadingOlder = false }
        do {
            let value = try await channel.request(
                AgentChatRequest(
                    id: "", method: "history.before",
                    target: AgentChatTarget(
                        instanceId: registration.instanceId,
                        generation: registration.generation),
                    params: .object(["cursor": .string(currentCursor)])))
            let page = try Self.decode(AgentChatPage.self, from: value)
            await prependPage(page)
        } catch let error as AgentChatError where error.requiresFreshOpen {
            await start()
        } catch is CancellationError {
        } catch {
            // Transient: the next top-sentinel arrival retries.
        }
    }

    // MARK: Item detail

    /// item.read: reassembles the canonical full ChatItem behind a
    /// reference (or any oversized stub). Never renders a partial.
    func readItem(itemId: String) async throws -> AgentChatItem {
        guard let channel, let registration else {
            throw AgentChatError.connectionClosed
        }
        var accumulated = Data()
        var offset = 0
        let chunkLength = 65536
        while true {
            let value = try await channel.request(
                AgentChatRequest(
                    id: "", method: "item.read",
                    target: AgentChatTarget(
                        instanceId: registration.instanceId,
                        generation: registration.generation),
                    params: .object([
                        "itemId": .string(itemId),
                        "offset": .number(Double(offset)),
                        "length": .number(Double(chunkLength)),
                    ])))
            let chunk = try Self.decode(AgentChatChunk.self, from: value)
            let (partial, complete) = try AgentChatChunkAssembler.assemble(
                accumulated: accumulated, chunk: chunk)
            accumulated = partial ?? accumulated
            if let complete {
                return try JSONDecoder().decode(AgentChatItem.self, from: complete)
            }
            guard let next = chunk.nextOffset, next > offset else {
                throw AgentChatError.wire(
                    code: "internal_error",
                    message: "item chunk stream ended before totalBytes",
                    retryable: false)
            }
            offset = next
        }
    }

    /// blob.read: raw bytes behind an image block ref. v1: written but
    /// unsurfaced (no image row model yet).
    func readBlob(blobId: String) async throws -> Data {
        guard let channel, let registration else {
            throw AgentChatError.connectionClosed
        }
        var accumulated = Data()
        var offset = 0
        let chunkLength = 65536
        while true {
            let value = try await channel.request(
                AgentChatRequest(
                    id: "", method: "blob.read",
                    target: AgentChatTarget(
                        instanceId: registration.instanceId,
                        generation: registration.generation),
                    params: .object([
                        "blobId": .string(blobId),
                        "offset": .number(Double(offset)),
                        "length": .number(Double(chunkLength)),
                    ])))
            let chunk = try Self.decode(AgentChatChunk.self, from: value)
            guard chunk.encoding == "base64",
                let bytes = Data(base64Encoded: chunk.data)
            else {
                throw AgentChatError.wire(
                    code: "internal_error", message: "bad blob chunk",
                    retryable: false)
            }
            accumulated.append(bytes)
            if chunk.isFinal {
                return accumulated
            }
            guard let next = chunk.nextOffset, next > offset else { break }
            offset = next
        }
        return accumulated
    }

    // MARK: Outbox (v3 submitted-draft stack)

    /// Submits one message: persists it to the durable outbox FIRST
    /// (content/attachment ownership before the editor clears), then
    /// hands it to the wire. The editor clears the moment this returns
    /// — the design's "clearing on durable LOCAL enqueue": A, B and C
    /// stack in the pending region without waiting on network
    /// acceptance. Delivery failures are HONEST STATUSES on the
    /// persisted entry (rejected / outcome unknown), surfaced in the
    /// pending region with their affordances — never swallowed.
    ///
    /// THROWS only when the LOCAL enqueue itself fails (the write
    /// could not be made durable): the editor is left UNTOUCHED.
    ///
    /// Delivery contract (matched, unchanged — the ack means QUEUED,
    /// not delivered): a clean round-trip promotes the entry to
    /// .accepted ("Awaiting agent"); send.confirmed's
    /// requestKey→recordId binding — or a committed page's
    /// metadata.requestKey marker — is the ONLY commitment proof.
    @discardableResult
    func submit(
        _ text: String, images: [AgentChatOutgoingImage] = []
    ) async throws -> AgentChatOutboxEntry {
        let entry = AgentChatOutboxEntry(
            requestKey: UUID().uuidString, text: text, images: images,
            ordinal: nextOutboxOrdinal,
            sendRegistration: Self.snapshot(of: registration))
        nextOutboxOrdinal += 1
        // Durable enqueue FIRST — the write must hold before the
        // editor clears. A failure here leaves the draft untouched
        // (the thrown error is the enqueue failure, never a delivery
        // verdict).
        outbox.append(entry)
        guard persistOutbox() else {
            outbox.removeAll { $0.id == entry.id }
            nextOutboxOrdinal -= 1
            throw AgentChatError.wire(
                code: "local_enqueue_failed",
                message: "This message could not be saved for sending. It stays in your draft — nothing was sent.",
                retryable: true)
        }
        // Ownership transferred durably: hand to the wire. The wire
        // attempt is fire-and-forget FROM THE EDITOR'S perspective —
        // its outcome lands on the entry as a status, not an error
        // thrown at the composer.
        transmit(entry)
        return entry
    }

    /// Retries a REJECTED entry: the only duplicate-safe replay — the
    /// broker ANSWERED NO (or the write never left), so replaying
    /// under the SAME requestKey cannot double-deliver (the broker
    /// dedups within the registration). Registration churn mints a
    /// fresh key (the old dedup cache is out of scope; the original
    /// was rejected, so a fresh key cannot duplicate it).
    func retry(entryID: UUID) async {
        guard let index = outbox.firstIndex(where: { $0.id == entryID }),
            outbox[index].status == .rejected
        else { return }
        let liveRegistration = Self.snapshot(of: registration)
        if outbox[index].sendRegistration != liveRegistration {
            outbox[index].requestKey = UUID().uuidString
            outbox[index].sendRegistration = liveRegistration
        }
        outbox[index].isHidden = false
        _ = persistOutbox()
        let entry = outbox[index]
        transmit(entry)
    }

    /// Re-sends an OUTCOME-UNKNOWN entry: the explicit user decision
    /// ("Send again — may duplicate") — the original MAY have been
    /// accepted, so the re-send carries a FRESH requestKey that
    /// bypasses the broker's dedup BY DESIGN. Never automatic.
    func resendAcknowledgingPossibleDuplicate(entryID: UUID) async {
        guard let index = outbox.firstIndex(where: { $0.id == entryID }),
            outbox[index].status == .outcomeUnknown
        else { return }
        outbox[index].requestKey = UUID().uuidString
        outbox[index].sendRegistration = Self.snapshot(of: registration)
        outbox[index].isHidden = false
        _ = persistOutbox()
        let entry = outbox[index]
        transmit(entry)
    }

    /// Display-only removal of a rejected/unknown entry (the design's
    /// "Hide locally"): never a retraction — the entry stays durably
    /// recoverable via `showHiddenOutboxEntries()` (the region renders
    /// a warning that hiding does not retract a delivered message).
    func hideOutboxEntry(entryID: UUID) {
        guard let index = outbox.firstIndex(where: { $0.id == entryID }),
            outbox[index].status == .rejected || outbox[index].status == .outcomeUnknown
        else { return }
        outbox[index].isHidden = true
        _ = persistOutbox()
    }

    /// Restores every locally-hidden entry (the recovery path).
    func showHiddenOutboxEntries() {
        var restored = false
        for index in outbox.indices where outbox[index].isHidden {
            outbox[index].isHidden = false
            restored = true
        }
        if restored { _ = persistOutbox() }
    }

    /// One wire attempt for an entry, with honest outcome
    /// classification. Runs detached from the submit: the composer's
    /// clear-on-enqueue never waits on this. With NO live channel
    /// (submitted offline / a broker outage) the entry simply STAYS
    /// .locallyQueued — provably never dispatched (the write never
    /// left), drained when the store reaches ready. A definitive
    /// capability refusal (the live registration says this agent
    /// cannot receive prompts/images) is settled NOW — it can never
    /// succeed later and must not sit as a false "Queued".
    private func transmit(_ entry: AgentChatOutboxEntry) {
        guard let index = outbox.firstIndex(where: { $0.id == entry.id })
        else { return }
        guard !outbox[index].isTransmitting else { return }
        guard channel != nil, registration != nil else { return }
        guard registration?.capabilities.prompt == true else {
            outbox[index].status = .rejected
            outbox[index].failureMessage = "This agent cannot receive messages."
            _ = persistOutbox()
            return
        }
        if !entry.images.isEmpty, registration?.capabilities.attachments != true {
            outbox[index].status = .rejected
            outbox[index].failureMessage = "This agent cannot receive images."
            _ = persistOutbox()
            return
        }
        outbox[index].isTransmitting = true
        outbox[index].failureMessage = nil
        _ = persistOutbox()
        let entryID = entry.id
        Task { [weak self] in
            await self?.runTransmission(entryID: entryID)
        }
    }

    /// The wire round-trip. On success the entry reads .accepted
    /// (the broker QUEUED the prompt — "Awaiting agent"; commitment
    /// still pending, proven only by send.confirmed). On failure the
    /// honest classification: a definitive broker NO is .rejected
    /// (duplicate-safe retry); a mid-flight loss is .outcomeUnknown
    /// (the explicit may-duplicate re-send). A .committed entry is
    /// MONOTONIC: a late failure racing the confirmation never
    /// demotes it (a prior proof is never undone).
    private func runTransmission(entryID: UUID) async {
        guard let index = outbox.firstIndex(where: { $0.id == entryID })
        else { return }
        let entry = outbox[index]
        do {
            try await sendOnWire(entry)
            guard let liveIndex = outbox.firstIndex(where: {
                $0.id == entryID
            }) else { return }
            outbox[liveIndex].isTransmitting = false
            // Accepted ≠ committed (the matched delivery contract):
            // the ack means the broker queued the prompt. "Awaiting
            // agent" until send.confirmed binds the record.
            if outbox[liveIndex].status != .committed {
                outbox[liveIndex].status = .accepted
            }
            _ = persistOutbox()
        } catch {
            let ambiguous = Self.isAmbiguousLoss(error)
            guard let liveIndex = outbox.firstIndex(where: {
                $0.id == entryID
            }) else { return }
            outbox[liveIndex].isTransmitting = false
            // Monotonic commitment: send.confirmed already proved this
            // entry delivered — a late error on the same entry (a
            // re-send racing the confirm) never demotes it.
            if outbox[liveIndex].status == .committed { return }
            outbox[liveIndex].status = ambiguous ? .outcomeUnknown : .rejected
            outbox[liveIndex].failureMessage = Self.sendFailureText(error)
            _ = persistOutbox()
        }
    }

    /// Drains every locally-queued entry (called once the store
    /// reaches ready, and after a fresh registration): each entry
    /// transmits in local submission order — the design's pending
    /// order is the DISPLAY and DISPATCH order for THIS client.
    private func drainOutbox() {
        for entry in outbox where entry.status == .locallyQueued {
            transmit(entry)
        }
    }

    /// Whether a send failure leaves acceptance UNKNOWN: the wire
    /// died or the answer timed out MID-FLIGHT (the broker may have
    /// accepted). A broker error response (the server answered NO)
    /// is a clean, definitive rejection.
    private static func isAmbiguousLoss(_ error: any Error) -> Bool {
        guard let error = error as? AgentChatError else { return false }
        switch error {
        case .connectionClosed, .timedOut:
            return true
        default:
            return false
        }
    }

    private func sendOnWire(_ entry: AgentChatOutboxEntry) async throws {
        guard let channel, let registration, registration.capabilities.prompt
        else {
            throw AgentChatError.wire(
                code: "unsupported_capability",
                message: "This agent cannot receive messages.",
                retryable: false)
        }
        // Structured image send: with attachments-capable brokers,
        // images ride their own array (the agent receives real image
        // content blocks). Without the capability the entry rejects
        // honestly rather than degrading to '@path' text the user
        // never chose.
        if !entry.images.isEmpty,
            registration.capabilities.attachments != true
        {
            throw AgentChatError.wire(
                code: "unsupported_capability",
                message: "This agent cannot receive images.",
                retryable: false)
        }
        var params: [String: JSONValue] = [
            "text": .string(entry.text),
            "requestKey": .string(entry.requestKey),
        ]
        if !entry.images.isEmpty {
            params["images"] = .array(entry.images.map { image in
                var object: [String: JSONValue] = [
                    "mimeType": .string(image.mimeType),
                ]
                if let ref = image.ref { object["ref"] = .string(ref) }
                if let data = image.data {
                    object["data"] = .string(data.base64EncodedString())
                }
                if let byteLength = image.byteLength {
                    object["byteLength"] = .number(Double(byteLength))
                }
                return .object(object)
            })
        }
        promptRequestKeys.insert(entry.requestKey)
        _ = try await channel.request(
            AgentChatRequest(
                id: "", method: "prompt.send",
                target: AgentChatTarget(
                    instanceId: registration.instanceId,
                    generation: registration.generation),
                params: .object(params)))
    }

    private static func snapshot(
        of registration: AgentChatRegistration?
    ) -> AgentChatRegistrationSnapshot? {
        registration.map {
            AgentChatRegistrationSnapshot(
                instanceId: $0.instanceId, generation: $0.generation)
        }
    }

    /// Persists the outbox to the conversation's archive. Returns
    /// false when the write could not be made (the caller treats
    /// that as an enqueue failure); best-effort for status changes
    /// on already-durable entries.
    @discardableResult
    private func persistOutbox() -> Bool {
        guard let archive = outboxArchiveIdentity,
            let url = AgentChatOutboxArchiveStore.archiveURL(
                socketPath: archive.socketPath,
                sessionFile: archive.sessionFile)
        else { return false }
        return AgentChatOutboxArchiveStore.save(
            url: url, clientID: Self.clientID, nextOrdinal: nextOutboxOrdinal,
            entries: outbox)
    }

    // MARK: Testing seams (the delivery-lifecycle proofs drive
    // honest transitions the wire cannot yet produce on demand).

    /// Forces an entry's status (the proofs simulate a wire refusal
    /// or an outcome-unknown loss without a broker). Respects the
    /// monotonic rule: a .committed entry never demotes.
    func setOutboxStatusForTesting(
        _ status: AgentChatOutboxEntry.Status, id: UUID
    ) {
        guard let index = outbox.firstIndex(where: { $0.id == id })
        else { return }
        if outbox[index].status == .committed, status != .committed {
            return
        }
        outbox[index].status = status
    }

    /// The monotonic guard's seam: a late failure write against a
    /// PROVEN committed entry must be refused (review round 6,
    /// finding 1 — now on the outbox).
    func markOutgoingForTesting(
        id: UUID, status: AgentChatOutboxEntry.Status, message: String? = nil
    ) {
        guard let index = outbox.firstIndex(where: { $0.id == id })
        else { return }
        if outbox[index].status == .committed, status != .committed {
            return
        }
        outbox[index].status = status
        outbox[index].failureMessage = message
    }

    /// The relaunch-path proof's seam: binds an entry's requestKey to
    /// the page marker the scripted broker serves (simulating a
    /// persisted entry whose committed record carries
    /// metadata.requestKey on the next page).
    func setOutboxRequestKeyMarkerForTesting(id: UUID, marker: String) {
        guard let index = outbox.firstIndex(where: { $0.id == id })
        else { return }
        outbox[index].requestKey = marker
    }

    /// The drain proof's observable: how many entries reached accepted.
    func outgoingAllAcceptedCount() -> Int {
        outbox.filter { $0.status == .accepted }.count
    }

    private static func sendFailureText(_ error: any Error) -> String {
        if case AgentChatError.wire(_, let message, _) = error {
            return message
        }
        if let error = error as? AgentChatError {
            switch error {
            case .connectionClosed:
                // Ambiguous: the request may have reached the broker
                // before the wire died. Never claim non-delivery.
                return "The connection to the agent was lost — your message may not have been delivered."
            case .timedOut:
                return "The agent did not answer in time — your message may not have been delivered."
            default:
                return "Send failed — your message was not delivered."
            }
        }
        return "Send failed — your message was not delivered."
    }


    // MARK: Interrupt (capability-wired, no v1 button)

    func interrupt() async throws {
        guard let channel, let registration, registration.capabilities.interrupt
        else {
            throw AgentChatError.wire(
                code: "unsupported_capability",
                message: "This agent cannot be interrupted.",
                retryable: false)
        }
        _ = try await channel.request(
            AgentChatRequest(
                id: "", method: "interrupt",
                target: AgentChatTarget(
                    instanceId: registration.instanceId,
                    generation: registration.generation)))
    }

    // MARK: Interactions (optional; the honest unsupported card is the
    // UI's only ask affordance when interactions:false)

    func refreshInteractions() async throws {
        guard let channel, let registration,
            registration.capabilities.interactions
        else { return }
        let value = try await channel.request(
            AgentChatRequest(
                id: "", method: "interactions.list",
                target: AgentChatTarget(
                    instanceId: registration.instanceId,
                    generation: registration.generation)))
        let result = try Self.decode(AgentChatInteractionsResult.self, from: value)
        // Snapshot install with the two race rules:
        // - RACED-RESOLVED: a resolution that arrived while the list
        //   was in flight is tombstoned — the stale snapshot entry is
        //   excluded (never resurrect).
        // - RACED-OPENED: an interaction.opened that arrived ahead of
        //   this call survives (the list predates it).
        interactions = AgentChatInteractionMerge.install(
            snapshot: result.pending,
            live: interactions,
            tombstones: resolvedInteractionTombstones)
    }

    func answer(_ interaction: AgentChatInteraction, answers: [AgentChatAnswer]) async throws {
        guard let channel, let registration, registration.capabilities.interactions
        else {
            throw AgentChatError.wire(
                code: "unsupported_capability",
                message: "This agent cannot answer interactions.",
                retryable: false)
        }
        let params: JSONValue = .object([
            "requestId": .string(interaction.requestId),
            "answers": .array(answers.map { answer in
                var object: [String: JSONValue] = [
                    "questionId": .string(answer.questionId),
                    "optionIds": .array(answer.optionIds.map { .string($0) }),
                ]
                if let customText = answer.customText {
                    object["customText"] = .string(customText)
                }
                return .object(object)
            }),
        ])
        // In-flight marker BEFORE the request: the broker emits
        // interaction.resolved synchronously with accepting, so the
        // event can arrive BEFORE this submit's own acknowledgement
        // returns. The resolved handler records the event NEUTRALLY
        // ('Answered remotely.' — the broadcast cannot identify the
        // winner); this stash lets the ACK path — the only winner
        // confirmation the protocol offers — replace that record
        // with our labels on accepted, or the honest refusal note on
        // item_changed.
        let submission = AgentChatInteractionResolution(
            answered: interaction, answers: answers)
        submittedAnswers[interaction.requestId] = submission
        do {
            _ = try await channel.request(
                AgentChatRequest(
                    id: "", method: "interactions.answer",
                    target: AgentChatTarget(
                        instanceId: registration.instanceId,
                        generation: registration.generation),
                    params: params))
            // Accepted: the ask is SETTLED broker-side from this
            // submit. Clear the card and tombstone NOW (the resolved
            // event may be lost under event-queue pressure) and
            // record the transcript block with the resolved labels.
            submittedAnswers[interaction.requestId] = nil
            interactions.removeAll {
                $0.requestId == interaction.requestId
            }
            resolvedInteractionTombstones.insert(interaction.requestId)
            recordResolution(submission)
        } catch let error as AgentChatError {
            if staleAnswerKind(error) != nil {
                // The broker REFUSED: the ask settled, expired, or never
                // existed — this submission is definitively NOT the
                // winner. Clear the stash (it must not survive into a
                // later foreign resolution for the same id), self-heal:
                // the card is DEAD, re-list for the truth.
                submittedAnswers[interaction.requestId] = nil
                interactions.removeAll {
                    $0.requestId == interaction.requestId
                }
                resolvedInteractionTombstones.insert(interaction.requestId)
                // PRECEDENCE: an event-recorded resolution (the
                // authoritative outcome — 'The question was
                // cancelled.', 'Answered in the agent's terminal.',
                // expired, or our neutral/acknowledged answer) WINS;
                // the stale-error fallback ('settled elsewhere')
                // is weaker and only records when NOTHING stronger
                // exists. A losing ack must never overwrite what the
                // broadcast event already told us.
                if !interactionResolutions.contains(where: {
                    $0.requestId == interaction.requestId
                }) {
                    recordResolution(AgentChatInteractionResolution(
                        staleRequestId: interaction.requestId,
                        generationInvalidated: error.isStaleGeneration,
                        questionText: interaction.questions.first?.text))
                }
                try? await refreshInteractions()
            } else {
                // A transport error (lost connection, timeout) is
                // UNCERTAIN, not proof of rejection: the broker may
                // have accepted and already emitted interaction.resolved
                // (which can also be lost). The stash STAYS for THIS
                // connection — the resolved handler records neutral
                // 'Answered remotely.' for it and the ack, if it lands,
                // upgrades to our labels. On a RECONNECT the stash is
                // cleared (start() resets submittedAnswers — a stash
                // belongs to its connection): any resolution arriving
                // on the new connection reads via the honest wire
                // mapping, neutral for answered+remote.
            }
            throw error
        }
    }


    /// The honest kind for a refused answer, from the broker's REAL
    /// ask-adapter codes (ask.ts claimEntry + ERROR_CODES): 
    /// `stale_generation` — the ask's generation was invalidated:
    /// expired. `item_changed` — the ask already settled (answered or
    /// cancelled): settled, outcome unknown from here. 
    /// `item_not_found` — no such pending ask: settled elsewhere.
    /// Nil = not stale (transport blip or a validation error — the
    /// card stays, the error renders on it).
    private func staleAnswerKind(_ error: AgentChatError) -> AgentChatInteractionResolution.Kind? {
        guard case .wire(let code, _, _) = error else { return nil }
        switch code {
        case "stale_generation": return .expired
        case "item_changed", "item_not_found": return .settledElsewhere
        default: return nil
        }
    }

    /// Whether a failed answer/cancel means the request no longer
    /// exists broker-side (vs a transport blip or a validation error
    /// the user must see).
    private func isStaleInteractionError(_ error: AgentChatError) -> Bool {
        staleAnswerKind(error) != nil
    }

    func cancelInteraction(requestId: String) async throws {
        guard let channel, let registration, registration.capabilities.interactions
        else {
            throw AgentChatError.wire(
                code: "unsupported_capability",
                message: "This agent cannot cancel interactions.",
                retryable: false)
        }
        do {
            _ = try await channel.request(
                AgentChatRequest(
                    id: "", method: "interactions.cancel",
                    target: AgentChatTarget(
                        instanceId: registration.instanceId,
                        generation: registration.generation),
                        params: .object(["requestId": .string(requestId)])))
            // Accepted: the ask is cancelled broker-side. Capture the
            // question text while the pending interaction is still
            // held, clear the card, record the honest block (the
            // resolved event may be lost under event-queue pressure).
            let cancelledQuestionText = interactions.first(where: {
                $0.requestId == requestId
            })?.questions.first?.text
            interactions.removeAll { $0.requestId == requestId }
            resolvedInteractionTombstones.insert(requestId)
            recordResolution(AgentChatInteractionResolution(
                requestId: requestId, kind: .cancelled,
                questionText: cancelledQuestionText, labels: nil))
        } catch let error as AgentChatError {
            if staleAnswerKind(error) != nil {
                interactions.removeAll { $0.requestId == requestId }
                resolvedInteractionTombstones.insert(requestId)
                // PRECEDENCE: the event-recorded authoritative outcome
                // WINS over the stale-error fallback — same rule as
                // the answer path. A losing cancel ack must never
                // overwrite what the broadcast event already said.
                if !interactionResolutions.contains(where: {
                    $0.requestId == requestId
                }) {
                    recordResolution(AgentChatInteractionResolution(
                        staleRequestId: requestId,
                        generationInvalidated: error.isStaleGeneration,
                        questionText: interactions.first(where: {
                            $0.requestId == requestId
                        })?.questions.first?.text))
                }
            }
            throw error
        }
    }

    // MARK: Channel events

    private func handleChannelEvent(
        _ event: AgentChatChannelEvent, storeGeneration: Int
    ) {
        guard generation == storeGeneration else { return }
        switch event.kind {
        case .pushed(.event(let frame)):
            if !subscribed {
                // Pre-snapshot buffering: applied after the watermark.
                bufferedEvents.append(frame)
                return
            }
            applyEvent(frame, storeGeneration: storeGeneration)
        case .pushed(.sessionUnavailable):
            Task { await start() }
        case .disconnected(let reason):
            if phase.isRenderable {
                phase = .disconnected(
                    reason: "Connection to the chat broker was lost.")
                scheduleReconnect()
            } else {
                phase = .failed(reason: friendly(nil, reason: reason))
            }
            endParked()
        case .protocolError:
            phase = .failed(reason: "The chat broker sent an invalid frame.")
            endParked()
        }
    }

    private func applyEvent(
        _ frame: AgentChatEventFrame, storeGeneration: Int
    ) {
        guard generation == storeGeneration else { return }
        switch AgentChatEventReconcile.fold(&reconcile, frame: frame) {
        case .ignored:
            return
        case .resync:
            Task { await start() }
        case .refetchRecent:
            Task { [weak self] in
                await self?.refreshRecent(storeGeneration: storeGeneration)
            }
        case .stream(.started(let streamId, let role)):
            streamTails.append(
                AgentChatStreamTail(streamId: streamId, authorRole: role, text: ""))
        case .stream(.delta(let streamId, _, let blockType, let text)):
            // Only text deltas render in the provisional tail; thinking
            // streams surface at L3 after the authoritative reconcile.
            guard blockType == nil || blockType == "text" else { return }
            if let index = streamTails.firstIndex(where: { $0.streamId == streamId }) {
                streamTails[index].text += text
            }
        case .stream(.finished(let streamId)):
            // The provisional tail clears when the authoritative page
            // lands (history.changed follows); finished drops the
            // stream display only.
            streamTails.removeAll { $0.streamId == streamId }
        case .interaction(.opened(let interaction)):
            upsertInteraction(interaction)
        case .interaction(.resolved(let requestId, let outcome, let source)):
            // The ask's own question text, captured while the pending
            // interaction is still held — the transcript anchor for
            // whatever resolution this event produces.
            let questionText = interactions.first(where: {
                $0.requestId == requestId
            })?.questions.first?.text
            // Tombstone first: the snapshot install consults it, so a
            // resolution racing interactions.list can never resurrect.
            resolvedInteractionTombstones.insert(requestId)
            interactions.removeAll { $0.requestId == requestId }
            // The event's outcome+source are AUTHORITATIVE and the
            // broadcast carries NO winner correlation: answered+remote
            // means SOME remote client answered — this device or
            // another. An in-flight submission is only proof we SENT,
            // never that we WON, so the event never claims our labels.
            // The pre-ack record is NEUTRAL ('Answered remotely.');
            // this store's own acknowledgement — the only winner
            // confirmation the protocol offers — replaces it with the
            // recorded labels on accepted, or the honest refusal note
            // on item_changed. Competing answered+terminal, cancelled,
            // and expired settles record what actually happened.
            if submittedAnswers[requestId] != nil,
                outcome == "answered", source == "remote"
            {
                // Maybe ours — the ack is still coming on THIS
                // connection. Record neutral now; the stash stays for
                // the ack path's upgrade/replace. If the ack never
                // returns (transport loss mid-flight), the neutral
                // record stands — honest: we cannot prove we won.
                recordResolution(AgentChatInteractionResolution(
                    requestId: requestId, kind: .answeredRemotely,
                    questionText: questionText, labels: nil))
                return
            }
            if submittedAnswers[requestId] != nil {
                // A competing outcome settled first: our submission
                // LOST. Clear the stash and record what actually
                // happened — never our labels.
                submittedAnswers[requestId] = nil
            }
            if interactionResolutions.contains(where: {
                $0.requestId == requestId
            }), outcome == "answered", source == "remote" {
                // OUR accepted answer was recorded by the ack path;
                // this broadcast duplicate must not downgrade it to
                // the neutral note. Keep the recorded labels.
                return
            }
            // No claim to labels: the honest wire mapping
            // (answered+remote reads NEUTRAL 'Answered remotely.' —
            // the store cannot prove which remote client won).
            recordResolution(AgentChatInteractionResolution(
                requestId: requestId, wireOutcome: outcome,
                wireSource: source, questionText: questionText))
        case .sendConfirmed(let requestKey, let recordId):
            applySendConfirmed(requestKey: requestKey, recordId: recordId)
        }
    }

    /// One resolution, one rendered record: replaces any existing entry
    /// for the same requestId (the recorded answer beats a later
    /// same-id event only via explicit re-record, which never happens)
    /// and appends in first-record order — then persists the whole
    /// list to the archive so a NEW store (detail reopen, app
    /// relaunch) reconstructs the history.
    func recordResolution(_ resolution: AgentChatInteractionResolution) {
        interactionResolutions.removeAll {
            $0.requestId == resolution.requestId
        }
        interactionResolutions.append(resolution)
        if let archive = archiveIdentity {
            AgentChatResolutionArchiveStore.save(
                socketPath: archive.socketPath,
                sessionFile: archive.sessionFile,
                resolutions: interactionResolutions)
        }
    }

    /// Delivery contract (matched, unchanged): the authoritative
    /// requestKey→recordId correlation. The adapter bound this send's
    /// key to the committed user record, so the entry's delivery is
    /// PROVEN — transition to .committed and bind the record id so
    /// the entry drops the moment the committed page carries THAT
    /// record. Any unresolved state with a matching key resolves:
    /// an accepted entry is the normal case; an outcome-unknown
    /// entry (lost ack) is proven delivered — its may-duplicate
    /// affordance goes away. A rejected entry never sees its key
    /// confirmed (the adapter refused the send BEFORE queueing the
    /// key), so no special-casing is needed.
    ///
    /// Page-before-event race (review round 6, finding 2): when the
    /// PAGE came first, the record is already in held content —
    /// reconcile immediately so the entry drops on the event instead
    /// of lingering (visible duplicate) until the NEXT refresh.
    private func applySendConfirmed(requestKey: String, recordId: String) {
        guard let index = outbox.firstIndex(where: {
            $0.requestKey == requestKey
        }) else {
            // Unknown key (entry already dropped via reconcile, a
            // retry minted a fresh key, or another client's send):
            // the durable marker still binds the pair broker-side;
            // nothing to transition here.
            return
        }
        outbox[index].status = .committed
        outbox[index].confirmedRecordID = recordId
        outbox[index].failureMessage = nil
        _ = persistOutbox()
        // Page-before-event: drop the entry now if the confirmed
        // record is already rendered (the held content IS the page's
        // message set — the same exact-id drop, triggered by the
        // event instead of a fresh page).
        let confirmedID = AgentChatMapper.stableID(for: recordId)
        if content.messages.contains(where: { $0.id == confirmedID }) {
            reconcileOutbox(against: content.messages)
        }
    }

    private func upsertInteraction(_ interaction: AgentChatInteraction) {
        if let index = interactions.firstIndex(where: { $0.requestId == interaction.requestId }) {
            interactions[index] = interaction
        } else {
            interactions.append(interaction)
        }
    }

    // MARK: Pages

    private func loadRecentPage(storeGeneration: Int) async throws {
        guard let registration, let channel else { return }
        let value = try await channel.request(
            AgentChatRequest(
                id: "", method: "history.open",
                target: AgentChatTarget(
                    instanceId: registration.instanceId,
                    generation: registration.generation)))
        let page = try Self.decode(AgentChatPage.self, from: value)
        await applyPage(page, replaceRecent: true)
        reconnectDelay = .seconds(1)
        // Watermark: buffered events above throughSeq replay now; the
        // ones at or below it are already in the page.
        AgentChatEventReconcile.applyWatermark(&reconcile, throughSeq: page.throughSeq)
        phase = .ready
        // The store is live against a matched registration: submit
        // anything this client durably queued while it was not
        // (offline submit, broker outage, a relaunch's persisted
        // queue). Local submission order; no auto-replay of
        // UNKNOWN/REJECTED entries (their affordances are the user's
        // explicit decisions).
        drainOutbox()
        let buffer = bufferedEvents
        bufferedEvents = []
        for frame in buffer {
            applyEvent(frame, storeGeneration: storeGeneration)
        }
    }

    private func refreshRecent(storeGeneration: Int) async {
        guard phase == .ready, let registration, let channel,
            generation == storeGeneration
        else { return }
        recentPageEpoch &+= 1
        let epoch = recentPageEpoch
        do {
            let value = try await channel.request(
                AgentChatRequest(
                    id: "", method: "history.open",
                    target: AgentChatTarget(
                        instanceId: registration.instanceId,
                        generation: registration.generation)))
            guard epoch == recentPageEpoch, generation == storeGeneration
            else { return }
            let page = try Self.decode(AgentChatPage.self, from: value)
            await applyPage(page, replaceRecent: true)
        } catch is CancellationError {
        } catch {
            // Transient refresh failure: the next event retries.
        }
    }

    /// Maps page items into ChatContent. References (oversized items)
    /// read their full detail BEFORE rendering; a failed read skips the
    /// item rather than render a partial as complete.
    ///
    /// The page's olderCursor OWNS the paging window state: a recent
    /// page (history.open) installs it (the v2 regression — the broker
    /// cutover dropped this, so hasOlder stayed false and the top
    /// sentinel never even mounted); an older page (history.before)
    /// advances it. olderCursor nil = terminal (no more history).
    private func applyPage(_ page: AgentChatPage, replaceRecent: Bool) async {
        olderCursor = page.olderCursor
        hasOlder = page.olderCursor != nil
        var messages: [ChatMessage] = []
        for item in page.items {
            var mapped = item
            if case .reference(let id, _, _) = item {
                if let full = try? await readItem(itemId: id) {
                    mapped = full
                } else {
                    continue
                }
            }
            switch AgentChatMapper.map(item: mapped) {
            case .message(let message):
                messages.append(message)
            case .pending, .skipped:
                continue
            }
        }
        let results = AgentChatToolResultCollector.collect(from: page.items)
        if replaceRecent {
            content = ChatContent(messages: messages, toolResults: results)
        } else {
            // Older pages arrive chronologically (the adapter walks
            // newest→oldest and reverses into page order): prepend
            // ABOVE the current window, never append.
            content.messages.insert(
                contentsOf: messages, at: 0)
            content.toolResults.insert(
                contentsOf: results, at: 0)
        }
        if replaceRecent {
            settleOutbox(from: page.items)
            reconcileOutbox(against: messages)
        }
    }

    private func prependPage(_ page: AgentChatPage) async {
        await applyPage(page, replaceRecent: false)
    }

    /// Outbox → committed reconciliation. The page's items are the
    /// AUTHORITATIVE committed record set: (1) any entry whose
    /// confirmedRecordID renders in the page drops (the committed
    /// record renders in its own position — exactly one display
    /// record); (2) a page item's durable send-correlation marker
    /// (metadata.requestKey — the adapter attaches it to the
    /// correlated user record) PROVES an unresolved entry committed:
    /// the RELAUNCH path — send.confirmed events do not replay into a
    /// fresh store, so the page marker is the only authority that can
    /// settle a persisted accepted/unknown entry after a reopen. No
    /// text/FIFO matching: a text-identical record claims nothing.
    private func settleOutbox(from items: [AgentChatItem]) {
        // The page's requestKey→recordId proof set.
        var confirmedByRequestKey: [String: String] = [:]
        for item in items {
            guard case .message(let recordId, let author, _, _, let marker) = item,
                author.role == .user, let requestKey = marker
            else { continue }
            confirmedByRequestKey[requestKey] = recordId
        }
        guard !confirmedByRequestKey.isEmpty else { return }
        var settled = false
        for index in outbox.indices {
            guard let recordId = confirmedByRequestKey[outbox[index].requestKey],
                outbox[index].status != .committed
            else { continue }
            outbox[index].status = .committed
            outbox[index].confirmedRecordID = recordId
            outbox[index].failureMessage = nil
            settled = true
        }
        if settled { _ = persistOutbox() }
    }

    /// The drop rule: a committed entry leaves the outbox when its
    /// bound record renders in the page. Delegates to the pure
    /// ``AgentChatOutboxReconcile`` (unit-testable without a channel).
    private func reconcileOutbox(against messages: [ChatMessage]) {
        let survivors = AgentChatOutboxReconcile.reconcile(
            entries: outbox, committed: messages)
        if survivors.count != outbox.count {
            outbox = survivors
            _ = persistOutbox()
        }
    }

    private func applyError(_ error: AgentChatError) {
        switch error {
        case .ambiguousSession:
            phase = .ambiguous
        case .unsupportedProtocol:
            phase = .failed(
                reason: "The chat broker speaks a protocol this build cannot use.")
        default:
            phase = .failed(reason: friendly(error))
        }
        endParked()
    }

    private func friendly(
        _ error: (any Error)?, reason: String? = nil
    ) -> String {
        if let reason { return "The chat broker connection failed: \(reason)" }
        if let error = error as? TransportError {
            return "The chat broker connection failed: \(error.presentation.explanation)"
        }
        if let error = error as? AgentChatError {
            switch error {
            case .wire(_, let message, _): return message
            case .unsupportedProtocol:
                return "The chat broker speaks a protocol this build cannot use."
            case .connectionClosed: return "The chat broker connection was lost."
            case .frameTooLarge: return "The chat broker sent an oversized frame."
            case .timedOut(let method):
                return "The chat broker did not answer \(method)."
            case .ambiguousSession:
                return "More than one agent claims this session."
            }
        }
        return "The chat broker connection failed."
    }

    // MARK: Decoding

    nonisolated private static func decode<T: Decodable>(
        _ type: T.Type, from value: JSONValue
    ) throws -> T {
        try JSONDecoder().decode(type, from: JSONEncoder().encode(value))
    }
}

/// The outbox→committed reconciliation as a PURE function (unit-
/// testable without a broker channel). The delivery contract
/// (send.confirmed / the page's send-correlation marker) is the ONLY
/// proof of commitment. An entry's ONLY way out of the outbox is:
///   - .committed (a requestKey→recordId binding proved it) AND the
///     committed page carrying THAT record (exact stableID match) —
///     the committed record renders in its own position; or
///   - it is a rejected/unknown affordance (kept for retry/re-send).
/// A text match alone claims NOTHING: an unresolved entry stays
/// queued/accepted until a requestKey proof lands (a broker WITHOUT
/// the contract surfaces the honest "Awaiting agent" state, never a
/// guess).
enum AgentChatOutboxReconcile: Sendable {
    /// One reconcile step.
    static func reconcile(
        entries: [AgentChatOutboxEntry],
        committed: [ChatMessage]
    ) -> [AgentChatOutboxEntry] {
        var survivors: [AgentChatOutboxEntry] = []
        for entry in entries {
            if entry.status == .committed, let confirmed = entry.confirmedRecordID {
                if committed.contains(where: {
                    AgentChatMapper.stableID(for: confirmed) == $0.id
                }) {
                    continue  // dropped: the real record renders
                }
                survivors.append(entry)
                continue
            }
            // Every other state stays: queued/accepted (no proof yet —
            // the ONLY delivery authority is the requestKey binding),
            // .rejected and .outcomeUnknown (their retry/re-send
            // affordances must stay).
            survivors.append(entry)
        }
        return survivors
    }
}

/// The durable client outbox archive: one JSON file per broker
/// session (keyed by socket path + pane session file, the
/// conversation), carrying the client's stable identifier and the
/// next submission ordinal. Load/save are synchronous small-JSON file
/// I/O on the main actor (the same contract as the resolution
/// archive): a store instance calls them where it already touches
/// outbox state. App-support, not UserDefaults: this is
/// conversation-derived data, not user preference.
struct AgentChatOutboxArchive: Codable, Sendable, Equatable {
    var sessionFile: String
    var socketPath: String
    /// The client that owns these entries (the archive's clientId
    /// dimension).
    var clientID: String
    /// One past the highest submission ordinal ever used — never
    /// reused across relaunches.
    var nextOrdinal: Int
    var entries: [AgentChatOutboxEntry]
}

enum AgentChatOutboxArchiveStore: Sendable {
    /// The archive key → file path. One outbox per broker session.
    static func archiveURL(
        socketPath: String, sessionFile: String
    ) -> URL? {
        let socket = socketPath.trimmingCharacters(in: .whitespaces)
        let session = sessionFile.trimmingCharacters(in: .whitespaces)
        guard !socket.isEmpty, !session.isEmpty else { return nil }
        let dir = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        ).first?
            .appendingPathComponent("HeelerOutbox", isDirectory: true)
        guard let dir else { return nil }
        try? FileManager.default.createDirectory(
            at: dir, withIntermediateDirectories: true)
        // Opaque stable key from the two identity strings (SHA-256 —
        // the same scheme as the resolution archive: a raw path would
        // exceed APFS's 255-byte filename cap and silently fail).
        let key = SHA256.hash(data: Data((socket + "\u{0}" + session).utf8))
            .map { String(format: "%02x", $0) }
            .joined()
        return dir.appendingPathComponent("\(key).json")
    }

    /// The persisted outbox for this broker session (empty when no
    /// archive exists yet). A corrupt or undecodable file reads as
    /// empty — the pending region starts fresh rather than crashing
    /// the chat surface.
    static func load(
        socketPath: String, sessionFile: String
    ) -> AgentChatOutboxArchive {
        guard let url = archiveURL(
            socketPath: socketPath, sessionFile: sessionFile),
            let data = try? Data(contentsOf: url),
            let archive = try? JSONDecoder().decode(
                AgentChatOutboxArchive.self, from: data)
        else {
            return AgentChatOutboxArchive(
                sessionFile: sessionFile, socketPath: socketPath,
                clientID: "", nextOrdinal: 1, entries: [])
        }
        return archive
    }

    /// Persists the full outbox state. One write per change; returns
    /// whether the write held (the submit path treats a false as an
    /// enqueue failure — the draft stays).
    static func save(
        url: URL, clientID: String, nextOrdinal: Int,
        entries: [AgentChatOutboxEntry]
    ) -> Bool {
        guard !entries.isEmpty || FileManager.default.fileExists(atPath: url.path)
        else { return true }
        let archive = AgentChatOutboxArchive(
            sessionFile: "", socketPath: "", clientID: clientID,
            nextOrdinal: nextOrdinal, entries: entries)
        guard let data = try? JSONEncoder().encode(archive) else {
            return false
        }
        do {
            try data.write(to: url, options: .atomic)
            return true
        } catch {
            return false
        }
    }
}
