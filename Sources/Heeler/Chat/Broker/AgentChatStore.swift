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

/// One just-sent user message's local echo (items 1 + 11): the bubble
/// the user sees IMMEDIATELY, plus its honest delivery state. The
/// requestKey is the broker's dedup key; a retry reuses it ONLY while
/// the live registration still matches the one the key was minted
/// against (generation churn or dedup eviction would un-scope the
/// guarantee — the retry mints a fresh key then, review gap 5).
/// Reconciliation: an authoritative history page that contains the
/// message drops the echo (the committed record renders in its own
/// position).
struct AgentChatOutgoingMessage: Sendable, Equatable, Identifiable {
    enum DeliveryState: Sendable, Equatable {
        case sending
        case sent
        /// The wire round-trip FAILED (the broker answered no, or the
        /// channel refused the write before acceptance was possible).
        case failed
        /// The send's acceptance is UNKNOWN (the connection died or
        /// timed out mid-flight — the broker may have accepted). The
        /// honest state: never claims non-delivery, and a re-send
        /// REQUIRES an explicit user decision (it may duplicate).
        case ambiguous
        /// Removed (review round 6, finding 4): the text-correlation
        /// interim state. send.confirmed is now the only delivery
        /// authority, so there is nothing left for a text match to
        /// claim — an unproven echo stays .sending, honestly.
    }

    let id: UUID
    let requestKey: String
    let text: String
    /// Images riding the structured send (item 3): the agent receives
    /// them as real image content blocks, not '@path' text.
    let images: [AgentChatOutgoingImage]
    /// The send's wall-clock moment: the echo's chronological anchor.
    let sentAt: Date
    let sendRegistration: AgentChatRegistrationSnapshot?
    var state: DeliveryState = .sending
    /// The AUTHORITATIVE correlation (delivery contract, round 5):
    /// the committed record id the adapter bound to this send's
    /// requestKey via send.confirmed. Present exactly when state is
    /// .sent — the echo drops the moment the committed page carries
    /// THIS record (no text/baseline guessing).
    var confirmedRecordID: String?
    /// The honest failure copy when state == .failed or .ambiguous
    /// (retryable / re-send decision respectively).
    var failureMessage: String?

    init(
        id: UUID = UUID(), requestKey: String, text: String,
        images: [AgentChatOutgoingImage] = [],
        sendRegistration: AgentChatRegistrationSnapshot? = nil
    ) {
        self.id = id
        self.requestKey = requestKey
        self.text = text
        self.images = images
        self.sendRegistration = sendRegistration
        self.sentAt = Date()
    }
}

/// The (instanceId, generation) pair an outgoing requestKey is scoped
/// to. A plain struct so AgentChatOutgoingMessage stays Equatable and
/// the snapshot is comparable.
struct AgentChatRegistrationSnapshot: Sendable, Equatable {
    let instanceId: String
    let generation: Int
}

/// One image on a structured prompt.send (wire contract, live on the
/// adapter): `ref` is the img: blob-store id the broker resolves
/// server-side; `data` is inline base64. Exactly one of the two.
struct AgentChatOutgoingImage: Sendable, Equatable {
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

    /// The optimistic local echo of one just-sent message (item 11):
    /// visible IMMEDIATELY on send, before any transcript round-trip,
    /// carrying the honest delivery state (item 1). Reconciled away
    /// when the authoritative history page contains the confirmed
    /// record — the echo's bubble is replaced by the real one in its
    /// natural chronological position, never duplicated (item 15).
    private(set) var outgoing: [AgentChatOutgoingMessage] = []

    /// Retryable failure text for the most recent failed send, visible
    /// on the echo bubble (never silent; the escalation's contract).
    private(set) var lastSendFailure: String?
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
        // resets; the committed page and outgoing echoes survive
        // until the fresh page lands.
        let wasRenderable = phase.isRenderable
        let heldContent = wasRenderable ? content : nil
        let heldOutgoing = outgoing
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
            outgoing = heldOutgoing
            return
        }
        guard case .available(let socketPath) = await pipeFactory.availability()
        else {
            phase = .unavailable("No chat broker is configured for this Host.")
            if heldContent != nil { content = heldContent ?? ChatContent() }
            outgoing = heldOutgoing
            return
        }
        // Keep the old content visible while connecting (the honest
        // "reconnecting" banner rides in the view; content never blanks).
        phase = heldContent != nil ? .disconnected(
            reason: "Reconnecting to the chat broker…") : .connecting
        content = heldContent ?? ChatContent()
        outgoing = heldOutgoing
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
        // The phase holds .disconnected when content was held (the
        // blank-viewport fix): the view branch for .connecting/.loading
        // would UNMOUNT the mounted transcript mid-reconnect — exactly
        // the reported blank-on-refresh/lifecycle bug. The retained page
        // stays the reading surface; the honest "reconnecting" banner
        // rides as an overlay. A FRESH open (no held content) shows the
        // honest initial .connecting state below.
        if heldContent == nil {
            phase = .connecting
        }
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

    // MARK: Prompt

    /// Delivers one user message with the honest delivery lifecycle:
    /// the optimistic echo renders IMMEDIATELY as sending (item 11);
    /// the prompt.send round-trip then fails it visibly on a broker
    /// NO. A failure keeps the echo as failed+retryable — NEVER
    /// silent. The requestKey dedups retries within this store's
    /// life; a retry reuses the SAME key so the broker cannot
    /// double-deliver.
    ///
    /// Delivery contract (round 5): the wire ack alone does NOT mark
    /// the echo .sent — acceptance means the broker QUEUED the prompt,
    /// not that the agent committed a user record for it. The
    /// authoritative transition is the adapter's send.confirmed event
    /// (requestKey → committed record id), consumed in applyEvent. So
    /// a clean round-trip leaves the echo .sending; until send.confirmed
    /// lands it is NEVER declared sent.
    @discardableResult
    func send(
        _ text: String, images: [AgentChatOutgoingImage] = []
    ) async throws -> AgentChatOutgoingMessage {
        // Review round 6, finding 4: no text/baseline correlation —
        // send.confirmed is the only delivery authority. The echo
        // starts .sending and only send.confirmed proves it.
        let echo = AgentChatOutgoingMessage(
            id: UUID(), requestKey: UUID().uuidString, text: text, images: images,
            sendRegistration: Self.snapshot(of: registration))
        outgoing.append(echo)
        do {
            try await sendOnWire(echo)
            // Accepted, not committed: NO state change on the ack —
            // the echo stays .sending until send.confirmed binds its
            // record (see the doc above).
            return echo
        } catch {
            let state: AgentChatOutgoingMessage.DeliveryState =
                Self.isAmbiguousLoss(error) ? .ambiguous : .failed
            markOutgoing(
                id: echo.id, state: state,
                message: Self.sendFailureText(error))
            throw error
        }
    }

    /// Retries a FAILED echo (re-review round 3, finding 3): the only
    /// duplicate-SAFE retry — the broker ANSWERED NO (or the write
    /// never left), so replaying is always safe. The key rules hold:
    /// same registration → SAME key (the broker dedups the replay);
    /// churn → fresh key (the old dedup cache reset; the original was
    /// rejected, so a fresh key cannot duplicate it).
    func retry(echoID: UUID) async throws {
        guard let index = outgoing.firstIndex(where: { $0.id == echoID }),
            outgoing[index].state == .failed
        else { return }
        var echo = outgoing[index]
        let liveRegistration = Self.snapshot(of: registration)
        if echo.sendRegistration != liveRegistration {
            echo = AgentChatOutgoingMessage(
                id: echo.id, requestKey: UUID().uuidString, text: echo.text,
                images: echo.images, sendRegistration: liveRegistration)
        }
        outgoing[index] = echo
        markOutgoing(id: echo.id, state: .sending, message: nil)
        do {
            try await sendOnWire(echo)
            // Delivery contract (round 5): acceptance ≠ commitment —
            // NO state change on the ack; send.confirmed binds the
            // record.
        } catch {
            let state: AgentChatOutgoingMessage.DeliveryState =
                Self.isAmbiguousLoss(error) ? .ambiguous : .failed
            markOutgoing(
                id: echo.id, state: state,
                message: Self.sendFailureText(error))
            throw error
        }
    }

    /// Re-sends an AMBIGUOUS echo (re-review round 3, finding 3):
    /// acceptance was UNKNOWN, so a re-send MAY DUPLICATE — this is
    /// the explicit user decision, not a "safe retry". The action
    /// requires its own affordance copy ("Send again — may
    /// duplicate"); the fresh key bypasses dedup by design.
    func resendAcknowledgingPossibleDuplicate(echoID: UUID) async throws {
        guard let index = outgoing.firstIndex(where: { $0.id == echoID }),
            outgoing[index].state == .ambiguous
        else { return }
        let old = outgoing[index]
        let echo = AgentChatOutgoingMessage(
            id: old.id, requestKey: UUID().uuidString, text: old.text,
            images: old.images,
            sendRegistration: Self.snapshot(of: registration))
        outgoing[index] = echo
        markOutgoing(id: echo.id, state: .sending, message: nil)
        do {
            try await sendOnWire(echo)
            // Delivery contract (round 5): acceptance ≠ commitment —
            // NO state change on the ack; send.confirmed binds the
            // record.
        } catch {
            let state: AgentChatOutgoingMessage.DeliveryState =
                Self.isAmbiguousLoss(error) ? .ambiguous : .failed
            markOutgoing(
                id: echo.id, state: state,
                message: Self.sendFailureText(error))
            throw error
        }
    }


    /// Whether a send failure leaves acceptance UNKNOWN: the wire
    /// died or the answer timed out MID-FLIGHT (the broker may have
    /// accepted). A broker error response (the server answered NO)
    /// is a clean failure.
    private static func isAmbiguousLoss(_ error: any Error) -> Bool {
        guard let error = error as? AgentChatError else { return false }
        switch error {
        case .connectionClosed, .timedOut:
            return true
        default:
            return false
        }
    }

    private func sendOnWire(_ echo: AgentChatOutgoingMessage) async throws {
        guard let channel, let registration, registration.capabilities.prompt
        else {
            throw AgentChatError.wire(
                code: "unsupported_capability",
                message: "This agent cannot receive messages.",
                retryable: false)
        }
        // Structured image send (item 3): with attachments-capable
        // brokers, images ride their own array (the agent receives real
        // image content blocks). Without the capability the send
        // fails honestly rather than degrading to '@path' text the user
        // never chose.
        if !echo.images.isEmpty,
            registration.capabilities.attachments != true
        {
            throw AgentChatError.wire(
                code: "unsupported_capability",
                message: "This agent cannot receive images.",
                retryable: false)
        }
        var params: [String: JSONValue] = [
            "text": .string(echo.text),
            "requestKey": .string(echo.requestKey),
        ]
        if !echo.images.isEmpty {
            params["images"] = .array(echo.images.map { image in
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
        promptRequestKeys.insert(echo.requestKey)
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


    private func markOutgoing(
        id: UUID, state: AgentChatOutgoingMessage.DeliveryState, message: String? = nil
    ) {
        // The echo's OWN state/failure first (the auto-repair-mangled
        // first version silently dropped this — every echo stayed
        // .sending forever; review gap 1).
        guard let index = outgoing.firstIndex(where: { $0.id == id }) else { return }
        // Review round 6, finding 1: .sent is PROVEN (send.confirmed
        // bound the committed record) — it is MONOTONIC. A late error
        // on the same echo (a retry/resend racing the confirm, a late
        // failure write) must never demote it: the agent DID commit
        // the record, and a demotion would resurrect the
        // retry/may-duplicate affordance for a delivered message.
        if outgoing[index].state == .sent, state != .sent {
            return
        }
        outgoing[index].state = state
        // Re-review round 3, finding 2: BOTH .failed and .ambiguous
        // carry their message — the ambiguous explanation must render
        // (it was being cleared). Only the transient states clear it.
        switch state {
        case .failed, .ambiguous:
            outgoing[index].failureMessage = message
        case .sending, .sent:
            break
        }
        if state == .failed {
            lastSendFailure = message
        } else if outgoing.allSatisfy({
            $0.state != .failed && $0.state != .ambiguous
        }) {
            // A later success supersedes the stale failure banner.
            lastSendFailure = nil
        }
    }

    /// Testing seam (review round 6, finding 1): exposes the
    /// monotonic markOutgoing to unit tests — the ack-late-error race
    /// proof drives a late failure write against a proven .sent echo.
    func markOutgoingForTesting(
        id: UUID, state: AgentChatOutgoingMessage.DeliveryState, message: String? = nil
    ) {
        markOutgoing(id: id, state: state, message: message)
    }

    private static func sendFailureText(_ error: any Error) -> String {
        if case AgentChatError.wire(_, let message, _) = error {
            return message
        }
        if let error = error as? AgentChatError {
            switch error {
            case .connectionClosed:
                // Ambiguous (review gap 5): the request may have reached
                // the broker before the wire died. Never claim
                // non-delivery — reconciliation will settle it.
                return "The connection to the agent was lost — your message may not have been delivered. Retry when ready."
            case .timedOut:
                return "The agent did not answer in time — your message may not have been delivered. Retry when ready."
            default:
                return "Send failed — your message may not have been delivered. Retry when ready."
            }
        }
        return "Send failed — your message may not have been delivered. Retry when ready."
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

    /// Delivery contract (round 5): the authoritative requestKey→record
    /// correlation. The adapter popped this send's key from its FIFO
    /// when the agent COMMITTED the user record, so the echo's delivery
    /// is proven — transition to .sent and bind the record id so the
    /// echo drops the moment the committed page carries THAT record.
    /// Any state with a matching key resolves: a .sending echo is the
    /// normal case; an .ambiguous echo (lost ACK) is proven
    /// delivered — the may-duplicate affordance goes away. A .failed
    /// echo never sees its key confirmed (the adapter rejected the
    /// send BEFORE queueing the key), so no special-casing is needed.
    ///
    /// Review round 6, finding 2: the event and the history page race.
    /// When the PAGE came first, the record is already in held content
    /// — reconcile immediately so the echo drops on the event instead
    /// of lingering (visible duplicate) until the NEXT refresh.
    private func applySendConfirmed(requestKey: String, recordId: String) {
        guard let index = outgoing.firstIndex(where: {
            $0.requestKey == requestKey
        }) else {
            // Unknown key (echo already dropped via reconcile, a
            // retry minted a fresh key, or a pre-contract echo): the
            // durable marker still binds the pair broker-side; nothing
            // to transition here.
            return
        }
        outgoing[index].state = .sent
        outgoing[index].confirmedRecordID = recordId
        outgoing[index].failureMessage = nil
        // Page-before-event: drop the echo now if the confirmed record
        // is already rendered. Same exact-id rule as the page path
        // (AgentChatEchoReconcile) — the held content IS the page's
        // message set, so this is the same drop, just triggered by the
        // event instead of a fresh page.
        let confirmedID = AgentChatMapper.stableID(for: recordId)
        if content.messages.contains(where: { $0.id == confirmedID }) {
            reconcileOutgoing(against: content.messages)
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
            reconcileOutgoing(against: messages)
        }
    }

    private func prependPage(_ page: AgentChatPage) async {
        await applyPage(page, replaceRecent: false)
    }

    /// Echo → committed reconciliation: delegates to the pure
    /// ``AgentChatEchoReconcile`` (unit-testable without a channel).
    private func reconcileOutgoing(against messages: [ChatMessage]) {
        outgoing = AgentChatEchoReconcile.reconcile(
            echoes: outgoing, committed: messages)
        if outgoing.allSatisfy({ $0.state != .failed && $0.state != .ambiguous }) {
            lastSendFailure = nil
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

/// The echo→committed reconciliation as a PURE function (unit-testable
/// without a broker channel). Review round 6, finding 4: the
/// text/baseline/ledger heuristic is NO LONGER a delivery authority —
/// the delivery contract (send.confirmed) is the ONLY proof of
/// delivery. An echo's ONLY way out of the outgoing list is:
///   - .sent (send.confirmed bound confirmedRecordID) AND the
///     committed page carrying THAT record (exact stableID match) —
///     the committed record renders in its own position; or
///   - it is a failed/ambiguous affordance (kept for retry/re-send).
/// A text match alone claims NOTHING: an unmatched echo stays .sending
/// until its send.confirmed lands (a broker WITHOUT the contract
/// surfaces the honest "still sending" state, never a guess).
enum AgentChatEchoReconcile: Sendable {
    /// One reconcile step.
    static func reconcile(
        echoes: [AgentChatOutgoingMessage],
        committed: [ChatMessage]
    ) -> [AgentChatOutgoingMessage] {
        var survivors: [AgentChatOutgoingMessage] = []
        for echo in echoes {
            if echo.state == .sent, let confirmed = echo.confirmedRecordID {
                if committed.contains(where: {
                    AgentChatMapper.stableID(for: confirmed) == $0.id
                }) {
                    continue  // dropped: the real record renders
                }
                survivors.append(echo)
                continue
            }
            // Every other state stays: .sending (no proof yet — the
            // ONLY delivery authority is send.confirmed), .failed and
            // .ambiguous (their retry/re-send affordances must stay).
            survivors.append(echo)
        }
        return survivors
    }
}
