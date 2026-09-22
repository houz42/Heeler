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
        case failed
    }

    let id: UUID
    let requestKey: String
    let text: String
    /// Images riding the structured send (item 3): the agent receives
    /// them as real image content blocks, not '@path' text.
    let images: [AgentChatOutgoingImage]
    /// The send's wall-clock moment: the echo's chronological anchor.
    let sentAt: Date
    /// The registration the requestKey was minted against (review
    /// gap 5): the broker's dedup cache is bounded and cleared on
    /// generation change, so key reuse is only safe while this still
    /// matches the live registration.
    let sendRegistration: AgentChatRegistrationSnapshot?
    var state: DeliveryState = .sending
    /// The honest failure copy when state == .failed (retryable).
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
    /// Recently resolved asks (honest state notes: answered elsewhere /
    /// cancelled / expired — the card vanishing silently is the gap
    /// this closes). Capped; the newest resolution wins.
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
        resolvedInteractionTombstones = []
        interactionResolutions = []
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
            olderCursor = page.olderCursor
            hasOlder = page.olderCursor != nil
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
    /// the prompt.send round-trip then confirms or fails it (item 1).
    /// A failure keeps the echo as failed+retryable — NEVER silent
    /// (the real silent-loss escalation: prompt.send throwing into a
    /// swallowed catch, a dead channel, or a broker-offline path all
    /// land here visibly). The requestKey dedups retries within this
    /// store's life; a retry reuses the SAME key so the broker cannot
    /// double-deliver.
    @discardableResult
    func send(
        _ text: String, images: [AgentChatOutgoingImage] = []
    ) async throws -> AgentChatOutgoingMessage {
        let echo = AgentChatOutgoingMessage(
            id: UUID(), requestKey: UUID().uuidString, text: text, images: images,
            sendRegistration: Self.snapshot(of: registration))
        outgoing.append(echo)
        do {
            try await sendOnWire(echo)
            markOutgoing(id: echo.id, state: .sent)
            return echo
        } catch {
            markOutgoing(
                id: echo.id,
                state: .failed,
                message: Self.sendFailureText(error))
            throw error
        }
    }

    /// Retries a failed echo. Key safety (review gap 5): the requestKey
    /// is reused ONLY while the live registration still matches the
    /// one the key was minted against — the adapter's dedup cache is
    /// bounded and cleared on generation change, so reusing a key
    /// across churn could double-deliver. On churn the retry mints a
    /// FRESH key (a new user action by definition; the old send's
    /// acceptance state is reconciled by the history page).
    func retry(_ message: AgentChatOutgoingMessage) async throws {
        guard let index = outgoing.firstIndex(where: { $0.id == message.id }),
            outgoing[index].state == .failed
        else { return }
        var echo = outgoing[index]
        let liveRegistration = Self.snapshot(of: registration)
        if echo.sendRegistration != liveRegistration {
            // Generation churn (or a first send that never matched):
            // the old key's dedup guarantee is gone. Fresh key, scoped
            // to the live registration.
            echo = AgentChatOutgoingMessage(
                id: echo.id, requestKey: UUID().uuidString, text: echo.text,
                images: echo.images, sendRegistration: liveRegistration)
        }
        outgoing[index] = echo
        markOutgoing(id: echo.id, state: .sending, message: nil)
        do {
            try await sendOnWire(echo)
            markOutgoing(id: echo.id, state: .sent)
        } catch {
            markOutgoing(
                id: echo.id,
                state: .failed,
                message: Self.sendFailureText(error))
            throw error
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
        outgoing[index].state = state
        outgoing[index].failureMessage = state == .failed ? message : nil
        if state == .failed {
            lastSendFailure = message
        } else if outgoing.allSatisfy({ $0.state != .failed }) {
            // A later success supersedes the stale failure banner.
            lastSendFailure = nil
        }
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
        do {
            _ = try await channel.request(
                AgentChatRequest(
                    id: "", method: "interactions.answer",
                    target: AgentChatTarget(
                        instanceId: registration.instanceId,
                        generation: registration.generation),
                    params: params))
        } catch let error as AgentChatError {
            if isStaleInteractionError(error) {
                // The broker says this requestId is no longer pending
                // (answered/expired elsewhere while the card was up —
                // the resolved event can be missed under event-queue
                // pressure). Self-heal: the card is DEAD, drop it,
                // show the honest note, re-list for the truth.
                interactions.removeAll {
                    $0.requestId == interaction.requestId
                }
                resolvedInteractionTombstones.insert(interaction.requestId)
                interactionResolutions.removeAll {
                    $0.requestId == interaction.requestId
                }
                interactionResolutions.append(AgentChatInteractionResolution(
                    requestId: interaction.requestId,
                    outcome: "expired",
                    source: "remote"))
                try? await refreshInteractions()
            }
            throw error
        }
    }

    /// Whether a failed answer/cancel means the request no longer
    /// exists broker-side (vs a transport blip).
    private func isStaleInteractionError(_ error: AgentChatError) -> Bool {
        if case .wire(let code, _, _) = error {
            return [
                "unknown_request", "unknown_request_id", "not_found",
                "stale_interaction", "settled", "invalid_request",
                "unsupported_request",
            ].contains(code)
        }
        return false
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
        } catch let error as AgentChatError {
            if isStaleInteractionError(error) {
                interactions.removeAll { $0.requestId == requestId }
                resolvedInteractionTombstones.insert(requestId)
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
            // Tombstone first: the snapshot install consults it, so a
            // resolution racing interactions.list can never resurrect.
            resolvedInteractionTombstones.insert(requestId)
            interactions.removeAll { $0.requestId == requestId }
            // The honest resolved note replaces the vanished card.
            let resolution = AgentChatInteractionResolution(
                requestId: requestId, outcome: outcome, source: source)
            interactionResolutions.removeAll {
                $0.requestId == resolution.requestId
            }
            interactionResolutions.append(resolution)
            if interactionResolutions.count > 4 {
                interactionResolutions.removeFirst(
                    interactionResolutions.count - 4)
            }
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
    private func applyPage(_ page: AgentChatPage, replaceRecent: Bool) async {
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
            content.messages.append(contentsOf: messages)
            content.toolResults.append(contentsOf: results)
        }
        if replaceRecent {
            reconcileOutgoing(against: messages)
        }
    }

    /// Echo → committed reconciliation: delegates to the pure
    /// ``AgentChatEchoReconcile`` (unit-testable without a channel).
    private func reconcileOutgoing(against messages: [ChatMessage]) {
        outgoing = AgentChatEchoReconcile.reconcile(
            echoes: outgoing, committed: messages)
        if outgoing.allSatisfy({ $0.state != .failed }) {
            lastSendFailure = nil
        }
    }

    /// Older pages prepend (above the rendered window).
    private func prependPage(_ page: AgentChatPage) async {
        await applyPage(page, replaceRecent: false)
    }

    // MARK: Errors

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

/// The echo→committed reconciliation as a PURE function (review gap 3
/// regression proof, unit-testable without a broker channel): v1's
/// committed records carry no client echo id, so correlation is
/// text-based — but POSITIONAL, not set-membership:
/// - an echo only matches a committed user record whose timestamp is
///   at/after the echo's send (an older identical 'Continue' can
///   never eat a newer echo);
/// - each committed record consumes AT MOST ONE echo, oldest echo
///   first (two identical sends never collapse into one drop);
/// - failed echoes NEVER drop (the retry affordance stays).
/// Records without a parseable timestamp are eligible (the page's
/// ordering is chronological; the time check refines, never gates).
enum AgentChatEchoReconcile: Sendable {
    static func reconcile(
        echoes: [AgentChatOutgoingMessage], committed: [ChatMessage]
    ) -> [AgentChatOutgoingMessage] {
        var unmatched: [(text: String, at: Date?)] = []
        for message in committed where message.role == .user {
            let text = message.blocks.compactMap {
                if case .text(let value) = $0 { return value }
                return nil
            }.joined(separator: "\n")
            guard !text.isEmpty else { continue }
            unmatched.append((text, message.timestamp))
        }
        guard !unmatched.isEmpty else { return echoes }
        var survivors: [AgentChatOutgoingMessage] = []
        for echo in echoes.sorted(by: { $0.sentAt < $1.sentAt }) {
            if echo.state == .failed {
                survivors.append(echo)
                continue
            }
            if let index = unmatched.firstIndex(where: { record in
                record.text == echo.text
                    && (record.at == nil
                        || record.at! >= echo.sentAt.addingTimeInterval(-1))
            }) {
                unmatched.remove(at: index)
                // Consumed: the committed record replaces the echo.
            } else {
                survivors.append(echo)
            }
        }
        return survivors
    }
}
