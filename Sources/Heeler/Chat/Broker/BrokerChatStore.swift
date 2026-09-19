import Foundation
import Observation

// SPDX-License-Identifier: Apache-2.0
//
// The live-data store for one agent's broker-backed chat pane. State
// machine (explicit, all surfaced to the UI):
//
//   idle → connecting → matching → loading → ready ⇄ refreshing
//                       ↘ ambiguous / unavailable (terminal until restart)
//   any → disconnected (channel died; restart re-opens)
//   any → failed(reason) (exhausted attempts; Retry restarts)
//
// Flow: open channel (hello negotiation first) → sessions → match the
// pane's herdr agent_session identity (fail-closed on ambiguity) →
// subscribe → open (recent-first) → stream events; durable transitions
// re-open the recent page (history is truth, deltas are provisional).
// Older pages page via the opaque olderCursor. v1 stub items fetch
// their full detail through the entry method before any rendering.

/// The store's observable phase.
enum BrokerChatPhase: Sendable, Equatable {
    case idle
    case connecting
    case loading
    case ready
    /// No registration matched this pane's session identity (the agent
    /// is not broker-connected). Honest terminal state.
    case unavailable(String)
    /// More than one registration claims this pane. NEVER picked
    /// arbitrarily; honest terminal state until the duplicate clears.
    case ambiguous(String)
    /// The channel died (broker restart, SSH drop, session_unavailable).
    case disconnected(reason: String)
    /// A request failed without a recovery path mid-flight.
    case failed(reason: String)

    var isRenderable: Bool {
        switch self {
        case .ready, .disconnected: return true
        default: return false
        }
    }
}

/// One live streaming append: the provisional tail of an assistant
/// message being generated.
struct BrokerStreamingTail: Sendable, Equatable {
    var text: String
}

@MainActor
@Observable
final class BrokerChatStore {
    // MARK: Observable state

    private(set) var phase: BrokerChatPhase = .idle
    private(set) var content = ChatContent()
    private(set) var streamingTail: BrokerStreamingTail?
    private(set) var hasOlder = false
    private(set) var isLoadingOlder = false
    private(set) var isLoadingDetail = false
    /// Honest capability state for the ask affordance: answering is
    /// unsupported in v1 — set once a registration matched, so the card
    /// renders from real capability state, not an assumption.
    private(set) var askUnsupported = false
    /// Which protocol arm this connection negotiated (v0 legacy until
    /// deployed brokers answer proto:1).
    private(set) var negotiatedProto: BrokerProto?

    // MARK: Wiring

    private let pipeFactory: BrokerPipeFactory
    private let paneSessionIdentity: () -> HerdrPaneSessionIdentity?
    private let requestTimeout: Duration

    @ObservationIgnored private var channel: BrokerChannel?
    @ObservationIgnored private var registration: BrokerSessionRegistration?
    @ObservationIgnored private var reconcile = BrokerReconcileState(
        instanceId: "", generation: 0)
    @ObservationIgnored private var olderCursor: String?
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var lifecycleTask: Task<Void, Never>?
    @ObservationIgnored private var recentPageEpoch = 0

    init(
        pipeFactory: BrokerPipeFactory,
        paneSessionIdentity: @escaping () -> HerdrPaneSessionIdentity?,
        requestTimeout: Duration = .seconds(30)
    ) {
        self.pipeFactory = pipeFactory
        self.paneSessionIdentity = paneSessionIdentity
        self.requestTimeout = requestTimeout
    }

    // MARK: Lifecycle

    /// Starts (or restarts) the store for the current pane identity.
    /// Idempotent: a live store restarts cleanly (old channel closes).
    func start() async {
        lifecycleTask?.cancel()
        if let existing = channel {
            channel = nil
            Task { await existing.close() }
        }
        content = ChatContent()
        streamingTail = nil
        hasOlder = false
        olderCursor = nil
        registration = nil
        generation &+= 1
        let myGeneration = generation
        guard let pane = paneSessionIdentity() else {
            phase = .unavailable(
                "This agent has no session file to match against the chat broker.")
            return
        }
        guard case .available(let socketPath) = await pipeFactory.availability()
        else {
            phase = .unavailable("No chat broker is configured for this Host.")
            return
        }
        phase = .connecting
        lifecycleTask = Task { [weak self] in
            await self?.run(
                socketPath: socketPath, pane: pane, storeGeneration: myGeneration)
        }
    }

    /// The connect→match→subscribe→open flow, plus the event loop.
    private func run(
        socketPath: String, pane: HerdrPaneSessionIdentity, storeGeneration: Int
    ) async {
        do {
            let pipe = try await pipeFactory.open(socketPath)
            let channel = BrokerChannel(
                pipe: pipe, requestTimeout: requestTimeout,
                onEvent: { [weak self] event in
                    Task { @MainActor [weak self] in
                        self?.handleChannelEvent(event, storeGeneration: storeGeneration)
                    }
                })
            self.channel = channel
            try await channel.connect()
            negotiatedProto = await channel.proto
            guard generation == storeGeneration else { return }

            phase = .loading
            // 1. sessions
            let sessions = try await decodeSessions(
                channel.request(BrokerRequest(id: "", method: "sessions")))
            guard generation == storeGeneration else { return }

            // 2. match — fail closed, never arbitrary.
            switch BrokerSessionMatcher.match(pane: pane, registrations: sessions) {
            case .matched(let match):
                registration = match
                askUnsupported = true  // v1: ask is not a capability
            case .noRegistration:
                phase = .unavailable(
                    "This agent is not registered with the chat broker. "
                        + "It may need the native chat extension loaded.")
                return
            case .ambiguous(let reason):
                phase = .ambiguous(reason)
                return
            }
            guard let registration else { return }
            reconcile = BrokerReconcileState(
                instanceId: registration.instanceId, generation: registration.generation)

            // 3. subscribe (events) — BEFORE open, so nothing between
            //    open and subscribe is missed.
            if registration.hasEvents {
                _ = try await channel.request(
                    BrokerRequest(
                        id: "", method: "subscribe",
                        instanceId: registration.instanceId,
                        generation: registration.generation))
                guard generation == storeGeneration else { return }
            }

            // 4. open — the recent-first page.
            try await loadRecentPage(storeGeneration: storeGeneration)

            // 5. Drain loop: channel events arrive via handleChannelEvent;
            //    this task parks until the channel finishes.
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                parkedContinuations.append(continuation)
            }
        } catch is CancellationError {
            // Replaced store.
        } catch let error as BrokerClientError {
            if generation == storeGeneration {
                applyChannelError(error, storeGeneration: storeGeneration)
            }
        } catch {
            if generation == storeGeneration {
                phase = .failed(
                    reason: friendlyTransportMessage(error))
            }
        }
    }

    @ObservationIgnored private var parkedContinuations:
        [CheckedContinuation<Void, Never>] = []

    private func endParked() {
        for continuation in parkedContinuations {
            continuation.resume()
        }
        parkedContinuations.removeAll()
    }

    // MARK: Older paging

    /// Pages older history via the opaque cursor. Items with truncated
    /// previews fetch full detail first — never render a stub.
    func loadOlder() async {
        guard phase == .ready, let channel, let registration, let olderCursor,
            !isLoadingOlder
        else { return }
        isLoadingOlder = true
        defer { isLoadingOlder = false }
        do {
            let result = try await channel.request(
                BrokerRequest(
                    id: "", method: "history",
                    instanceId: registration.instanceId,
                    generation: registration.generation,
                    params: .object(["before": .string(olderCursor)])))
            let page = try decodePage(result)
            try await appendItems(page.items, prepend: true)
            self.olderCursor = page.olderCursor
            hasOlder = page.hasOlder
        } catch let error as BrokerClientError where error.requiresFreshOpen {
            // Branch invalidated the cursor: fresh open clears it.
            await start()
        } catch is CancellationError {
        } catch {
            // Transient: the next top-sentinel arrival retries.
        }
    }

    // MARK: Entry detail

    /// Fetches one stub item's full detail (v1: byte slices reassembled
    /// then decoded; v0: the bounded detail object).
    func loadDetail(entryId: String) async throws -> JSONValue {
        guard let channel, let registration else {
            throw BrokerClientError.connectionClosed
        }
        switch await channel.proto {
        case .v1:
            var accumulated = Data()
            var offset = 0
            let sliceLength = 65536
            while true {
                let result = try await channel.request(
                    BrokerRequest(
                        id: "", method: "entry",
                        instanceId: registration.instanceId,
                        generation: registration.generation,
                        params: .object([
                            "entryId": .string(entryId),
                            "offset": .number(Double(offset)),
                            "length": .number(Double(sliceLength)),
                        ])))
                let slice = try Self.decode(
                    BrokerEntrySlice.self, from: result)
                let (partial, complete) = try BrokerEntryAssembler.assemble(
                    accumulated: accumulated, slice: slice)
                accumulated = partial ?? accumulated
                if let complete {
                    return try JSONDecoder().decode(JSONValue.self, from: complete)
                }
                guard let next = slice.nextOffset, next > offset else {
                    throw BrokerClientError.broker(
                        code: "invalid_response",
                        message: "entry stream ended before totalBytes")
                }
                offset = next
            }
        case .v0:
            let result = try await channel.request(
                BrokerRequest(
                    id: "", method: "entry",
                    instanceId: registration.instanceId,
                    generation: registration.generation,
                    params: .object(["entryId": .string(entryId)])))
            return result
        }
    }

    // MARK: Prompt

    /// Delivers one plain user message through the broker's prompt
    /// method. Ask cards never route here — answering is unsupported.
    func send(_ text: String) async throws {
        guard let channel, let registration, registration.hasPrompt else {
            throw BrokerClientError.broker(
                code: "unsupported_capability",
                message: "This agent cannot receive messages.")
        }
        _ = try await channel.request(
            BrokerRequest(
                id: "", method: "prompt",
                instanceId: registration.instanceId,
                generation: registration.generation,
                params: .object(["text": .string(text)])))
    }
    // MARK: Channel events

    private func handleChannelEvent(
        _ event: BrokerChannelEvent, storeGeneration: Int
    ) {
        guard generation == storeGeneration else { return }
        switch event.kind {
        case .pushed(.event(let frame)):
            applyEvent(frame, storeGeneration: storeGeneration)
        case .pushed(.sessionUnavailable):
            // Agent gone: full resync per the contract.
            Task { await start() }
        case .disconnected(let reason):
            if phase.isRenderable {
                phase = .disconnected(
                    reason: "Connection to the chat broker was lost.")
            } else {
                phase = .failed(reason: friendlyTransportMessage(nil, reason: reason))
            }
            endParked()
        case .protocolError(let detail):
            phase = .failed(reason: "The chat broker sent an invalid frame.")
            _ = detail
            endParked()
        }
    }

    private func applyEvent(
        _ frame: BrokerEventFrame, storeGeneration: Int
    ) {
        guard generation == storeGeneration else { return }
        switch BrokerEventReconcile.fold(&reconcile, frame: frame) {
        case .ignored:
            return
        case .resync:
            Task { await start() }
        case .refetchRecent:
            // Durable transition: re-open the recent page. Keep the tail
            // clear so the settled text replaces the provisional stream.
            Task { [weak self] in
                await self?.refreshRecent(storeGeneration: storeGeneration)
            }
        case .accepted(let frame):
            switch BrokerEventKind(rawValue: frame.kind) {
            case .messageStart:
                if frame["role"]?.stringValue == "assistant" {
                    streamingTail = BrokerStreamingTail(text: "")
                }
            case .messageDelta:
                if let delta = frame["delta"]?.stringValue {
                    streamingTail?.text += delta
                }
            case .messageEnd, .turnEnd:
                streamingTail = nil
            default:
                break
            }
        }
    }

    // MARK: Page application

    private func loadRecentPage(storeGeneration: Int) async throws {
        guard let registration, let channel else { return }
        let result = try await channel.request(
            BrokerRequest(
                id: "", method: "open",
                instanceId: registration.instanceId,
                generation: registration.generation,
                params: .object([:])))
        let page = try decodePage(result)
        try await appendItems(page.items, prepend: false)
        olderCursor = page.olderCursor
        hasOlder = page.hasOlder
        phase = .ready
    }

    private func refreshRecent(storeGeneration: Int) async {
        guard phase == .ready, let registration, let channel,
            generation == storeGeneration
        else { return }
        recentPageEpoch &+= 1
        let epoch = recentPageEpoch
        do {
            let result = try await channel.request(
                BrokerRequest(
                    id: "", method: "open",
                    instanceId: registration.instanceId,
                    generation: registration.generation,
                    params: .object([:])))
            guard epoch == recentPageEpoch, generation == storeGeneration else {
                return
            }
            let page = try decodePage(result)
            try await appendItems(page.items, prepend: false, replaceRecent: true)
            olderCursor = page.olderCursor
            hasOlder = page.hasOlder
            streamingTail = nil
        } catch is CancellationError {
        } catch {
            // Transient refresh failure: the next event retries.
        }
    }

    /// Maps page items into ChatContent. Recent opens replace the
    /// recent window (reconcile); older pages prepend.
    private func appendItems(
        _ items: [BrokerHistoryItem], prepend: Bool, replaceRecent: Bool = false
    ) async throws {
        var messages: [ChatMessage] = []
        var results: [ToolResult] = []
        for item in items {
            let json: JSONValue
            if item.detailRequired, let full = try? await loadDetail(
                entryId: item.id)
            {
                json = full
            } else if let inline = item.full {
                json = inline
            } else if item.detailRequired {
                // Detail fetch failed: skip the item rather than render
                // an incomplete stub as if complete.
                continue
            } else {
                continue
            }
            switch BrokerChatMapper.map(item: json) {
            case .message(let message):
                messages.append(message)
            case .toolResult(let result):
                results.append(result)
            case .skipped:
                continue
            }
        }
        if replaceRecent {
            // Reconcile: the fresh open is the truth for the recent
            // window; older pages the user already loaded stay.
            content = ChatContent(messages: messages, toolResults: results)
        } else if prepend {
            content.messages.insert(contentsOf: messages, at: 0)
            content.toolResults.insert(contentsOf: results, at: 0)
        } else {
            content.messages.append(contentsOf: messages)
            content.toolResults.append(contentsOf: results)
        }
    }

    // MARK: Errors

    private func applyChannelError(
        _ error: BrokerClientError, storeGeneration: Int
    ) {
        guard generation == storeGeneration else { return }
        switch error {
        case .ambiguous(let reason):
            phase = .ambiguous(reason)
        case .broker(let code, let message) where code == "unsupported_protocol":
            phase = .failed(
                reason: "The chat broker speaks a protocol this build cannot use.")
        default:
            phase = .failed(reason: friendlyTransportMessage(error))
        }
        endParked()
    }

    private func friendlyTransportMessage(
        _ error: (any Error)?, reason: String? = nil
    ) -> String {
        if let reason { return "The chat broker connection failed: \(reason)" }
        if let error = error as? TransportError {
            return "The chat broker connection failed: \(error.presentation.explanation)"
        }
        if let error = error as? BrokerClientError {
            switch error {
            case .broker(_, let message): return message
            case .frameTooLarge: return "The chat broker sent an oversized frame."
            case .unsupportedProtocol:
                return "The chat broker speaks a protocol this build cannot use."
            case .connectionClosed: return "The chat broker connection was lost."
            case .timedOut(let method):
                return "The chat broker did not answer \(method)."
            case .ambiguous(let reason): return reason
            }
        }
        return "The chat broker connection failed."
    }

    // MARK: Decoding

    private func decodeSessions(_ result: JSONValue) throws -> [BrokerSessionRegistration] {
        let data = try JSONEncoder().encode(result)
        return try JSONDecoder().decode(BrokerSessionsResult.self, from: data)
            .sessions
    }

    private func decodePage(_ result: JSONValue) throws -> BrokerHistoryPage {
        try Self.decode(BrokerHistoryPage.self, from: result)
    }

    /// JSONValue round-trip helper: one encoder configuration shared by
    /// every result decode.
    nonisolated private static func decode<T: Decodable>(
        _ type: T.Type, from value: JSONValue
    ) throws -> T {
        try JSONDecoder().decode(type, from: JSONEncoder().encode(value))
    }
}
