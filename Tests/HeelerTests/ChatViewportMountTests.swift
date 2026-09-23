import Foundation
import Testing

@testable import Heeler

// SPDX-License-Identifier: Apache-2.0
//
// Blank-viewport regression coverage (design doc: "retain regression
// coverage for initial open, refresh, ten lock/unlock and keyboard
// cycles, older paging, short/long history"). These pin the STORE
// side: the phase transitions that drive the view's mount/unmount
// branch, and the content identity across them. The VIEW side (a real
// message intersecting the viewport) is pinned by the UITest suite
// (ChatViewportProofTests) over the scripted-broker demo route.

@Suite("Blank viewport: store phase/content invariants")
@MainActor
struct ChatViewportMountTests {

    /// A scripted broker that serves one FRESH connection per open —
    /// exactly the production shape (each `start()` opens a new
    /// channel; the old one is closed). Each connection gets its own
    /// ScriptedChatPipe and its own answering task, so reconnects and
    /// concurrent stores never cross-talk on one pipe.
    private actor BrokerHarness {
        private let historyItems: Int
        private var tasks: [Task<Void, Never>] = []

        init(historyItems: Int) {
            self.historyItems = historyItems
        }

        func openConnection() -> ScriptedChatPipe {
            let pipe = ScriptedChatPipe()
            let history = historyItems
            tasks.append(Task<Void, Never> {
                await Self.serve(pipe: pipe, historyItems: history)
            })
            return pipe
        }

        func cancelAll() {
            for task in tasks { task.cancel() }
            tasks = []
        }

        /// The scripted broker: welcome → sessions.list → subscribe →
        /// history.open (a `historyItems`-message page; an empty page
        /// is TERMINAL — olderCursor null).
        private static func serve(
            pipe: ScriptedChatPipe, historyItems: Int
        ) async {
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
                switch method {
                case "sessions.list":
                    await pipe.brokerSend(
                        #"{"type":"response","id":"\#(id)","result":{"sessions":[{"instanceId":"inst-1","sessionId":"s1","generation":1,"locator":{"sessionFile":"/s/file"},"agent":{"kind":"omp","version":"1"},"capabilities":{"history":true,"streaming":true,"prompt":true,"interrupt":true,"interactions":false,"commands":true,"attachments":false,"branches":false}}]}}"#)
                case "sessions.subscribe":
                    await pipe.brokerSend(
                        #"{"type":"response","id":"\#(id)","result":{"subscribed":true}}"#)
                case "history.open":
                    var items: [String] = []
                    for index in 0..<historyItems {
                        items.append(
                            #"{"kind":"message","id":"rec-\#(index)","author":{"role":"\#(index % 2 == 0 ? "user" : "assistant")"},"createdAt":null,"blocks":[{"type":"text","text":"msg \#(index)"}]}"#)
                    }
                    // An empty page is TERMINAL (olderCursor null) —
                    // the empty-history test asserts hasOlder false.
                    let cursor = historyItems == 0 ? "null" : "\"cursor-1\""
                    await pipe.brokerSend(
                        #"{"type":"response","id":"\#(id)","result":{"sessionId":"s1","generation":1,"revision":"rev","throughSeq":\#(historyItems),"items":[\#(items.joined(separator: ","))],"olderCursor":\#(cursor)}}"#)
                default:
                    await pipe.brokerSend(
                        #"{"type":"response","id":"\#(id)","result":{}}"#)
                }
            }
        }
    }

    private func makeStore(
        harness: BrokerHarness,
        sessionFile: String = "/s/file"
    ) -> AgentChatStore {
        AgentChatStore(
            pipeFactory: AgentChatPipeFactory(
                open: { _ in await harness.openConnection() },
                hostRecord: {
                    Host(
                        address: "demo", username: "demo",
                        brokerChatSocketPath: "/tmp/demo.sock")
                }),
            paneIdentity: {
                HerdrPaneSessionIdentity(sessionFilePath: sessionFile)
            })
    }

    private func waitReady(_ store: AgentChatStore) async throws {
        for _ in 0..<400 where store.phase != .ready {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(store.phase == .ready)
    }

    // MARK: Initial open (long history)

    @Test("initial open: long history renders records and stays renderable")
    func initialOpenLongHistory() async throws {
        let harness = BrokerHarness(historyItems: 40)
        defer { Task { await harness.cancelAll() } }
        let store = makeStore(harness: harness)
        await store.start()
        try await waitReady(store)

        // Content exists and the phase is renderable — the view's
        // mount branch keeps ChatScreen up.
        #expect(!store.content.messages.isEmpty)
        #expect(store.phase.isRenderable)
        #expect(store.hasOlder)
    }

    // MARK: Refresh / lock-unlock (the reported bug)

    @Test("refresh with held content NEVER leaves the renderable phase")
    func refreshHoldsRenderablePhase() async throws {
        let harness = BrokerHarness(historyItems: 40)
        defer { Task { await harness.cancelAll() } }
        let store = makeStore(harness: harness)
        await store.start()
        try await waitReady(store)

        // THE FAILING TRANSITION (pre-fix): start() with held content
        // clobbered the phase to .connecting — a NON-renderable phase —
        // so the view unmounted the readable transcript behind a
        // full-screen banner: the reported blank page. The fixed
        // contract: with held content the phase must be renderable at
        // EVERY sample across the whole re-match.
        let messageIDs = store.content.messages.map(\.id)
        #expect(!messageIDs.isEmpty)

        await store.start()
        // Sample the phase across the async re-match window.
        var sawNonRenderable = false
        for _ in 0..<400 {
            if !store.phase.isRenderable { sawNonRenderable = true }
            if store.phase == .ready { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(
            !sawNonRenderable,
            "a re-start with held content passed through a non-renderable phase — the view would blank the transcript")
        // And it settles ready with the SAME committed records.
        try await waitReady(store)
        #expect(store.content.messages.map(\.id) == messageIDs)
    }

    @Test("ten reconnect cycles never blank (lock/unlock stand-in)")
    func tenRefreshCyclesNeverBlank() async throws {
        let harness = BrokerHarness(historyItems: 40)
        defer { Task { await harness.cancelAll() } }
        let store = makeStore(harness: harness)
        await store.start()
        try await waitReady(store)
        let messageIDs = store.content.messages.map(\.id)

        for _ in 0..<10 {
            await store.start()
            // Every cycle: renderable at every observed sample, then
            // ready again with the same records.
            var sawNonRenderable = false
            for _ in 0..<400 {
                if !store.phase.isRenderable { sawNonRenderable = true }
                if store.phase == .ready { break }
                try await Task.sleep(for: .milliseconds(10))
            }
            #expect(!sawNonRenderable)
            #expect(store.phase == .ready)
            #expect(store.content.messages.map(\.id) == messageIDs)
        }
    }

    // MARK: Initial empty / short history

    @Test("initial empty history: honest ready state, no fake content")
    func initialEmptyHistory() async throws {
        let harness = BrokerHarness(historyItems: 0)
        defer { Task { await harness.cancelAll() } }
        let store = makeStore(harness: harness)
        await store.start()
        try await waitReady(store)

        // Empty content is HONEST: the view's explicit empty state
        // renders (rows empty), never a fabricated record.
        #expect(store.content.messages.isEmpty)
        #expect(store.phase == .ready)
        #expect(!store.hasOlder)
    }

    @Test("short history: records render and stay mounted across refresh")
    func shortHistoryStaysMounted() async throws {
        let harness = BrokerHarness(historyItems: 2)
        defer { Task { await harness.cancelAll() } }
        let store = makeStore(harness: harness)
        await store.start()
        try await waitReady(store)
        #expect(store.content.messages.count == 2)

        await store.start()
        var sawNonRenderable = false
        for _ in 0..<400 {
            if !store.phase.isRenderable { sawNonRenderable = true }
            if store.phase == .ready { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(!sawNonRenderable)
        #expect(store.content.messages.count == 2)
    }

    // MARK: Older paging preserves the loaded window

    @Test("older paging keeps the phase renderable and the loaded window intact")
    func olderPagingKeepsWindow() async throws {
        let harness = BrokerHarness(historyItems: 40)
        defer { Task { await harness.cancelAll() } }
        let store = makeStore(harness: harness)
        await store.start()
        try await waitReady(store)
        #expect(store.hasOlder)

        let before = store.content.messages.map(\.id)
        await store.loadOlder()
        // A failed/empty older page must not blank or drop records
        // (the phase stays renderable throughout the fetch).
        #expect(store.content.messages.map(\.id) == before)
        #expect(store.phase == .ready)
    }

    // MARK: A different conversation changes identity deliberately

    @Test("a different session identity is a fresh mount, never the old conversation")
    func differentConversationIsDeliberate() async throws {
        let harness = BrokerHarness(historyItems: 40)
        defer { Task { await harness.cancelAll() } }
        let store = makeStore(harness: harness)
        await store.start()
        try await waitReady(store)
        #expect(!store.content.messages.isEmpty)

        // A different pane identity over its OWN connection: the
        // scripted broker serves one session (/s/file), so /other/file
        // resolves to noRegistration — an honest state, never a stale
        // render of the PREVIOUS conversation's records.
        let otherHarness = BrokerHarness(historyItems: 40)
        defer { Task { await otherHarness.cancelAll() } }
        let other = makeStore(harness: otherHarness, sessionFile: "/other/file")
        await other.start()
        for _ in 0..<400 {
            if case .unavailable = other.phase { break }
            try await Task.sleep(for: .milliseconds(10))
        }

        switch other.phase {
        case .unavailable, .ambiguous:
            break  // honest non-matching states
        default:
            Issue.record(
                "a different conversation should not render the previous one's records; got \(other.phase)")
        }
        #expect(other.content.messages.isEmpty)
    }
}
