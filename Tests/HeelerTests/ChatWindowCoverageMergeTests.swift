import Foundation
import Testing

@testable import Heeler

// SPDX-License-Identifier: Apache-2.0
//
// The recent-page refresh COVERAGE MERGE pins (the real-path
// blank-on-send-after-paging trace): a history.changed refresh used to
// REPLACE the whole loaded window with the latest page — deleting every
// previously-paged older record the reader was mid-read on, shrinking
// the document under the retained offset into a persistent blank, and
// substituting an unrelated newer row at the reader's offset. The merge
// retains the loaded PREFIX above the fresh page's oldest record, and
// the older cursor survives recent pages and reconnects.

@Suite("Recent-page refresh coverage merge")
@MainActor
struct ChatWindowCoverageMergeTests {

    /// A scripted broker with PAGING: history.open serves the recent
    /// window (N records, olderCursor present); history.before serves
    /// one older page; a history.changed push (sent on demand) makes
    /// the store refresh — and the refresh's history.open serves the
    private actor PagingBroker {
        private let recentCount: Int
        private var tasks: [Task<Void, Never>] = []
        private(set) var refreshRequests = 0
        /// The most recently opened pipe (the live connection the
        /// test pushes events to).
        private var latestPipe: ScriptedChatPipe?

        init(recentCount: Int) {
            self.recentCount = recentCount
        }

        func currentPipe() -> ScriptedChatPipe? {
            latestPipe
        }

        func openConnection() -> ScriptedChatPipe {
            let pipe = ScriptedChatPipe()
            latestPipe = pipe
            let recent = recentCount
            let onRefresh: @Sendable () -> Void = { [weak self] in
                Task { await self?.refreshRequested() }
            }
            tasks.append(Task<Void, Never> {
                await Self.serve(pipe: pipe, recent: recent, onRefresh: onRefresh)
            })
            return pipe
        }

        private func refreshRequested() {
            refreshRequests += 1
        }

        /// Pushes a history.changed (the store refreshes its recent
        /// page; the fresh page adds one new committed record).
        func pushHistoryChanged(on pipe: ScriptedChatPipe) async {
            await pipe.brokerSend(
                #"{"type":"event","instanceId":"inst-1","generation":1,"seq":\#(recentCount + 1),"event":{"type":"history.changed","revision":"rev-2"}}"#)
        }

        private static func serve(
            pipe: ScriptedChatPipe, recent: Int,
            onRefresh: @escaping () -> Void
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
                    onRefresh()
                    // The recent window: records 20..(20+recent-1) —
                    // DELIBERATELY not covering the older page's
                    // records (0..9): the trace shape where the fresh
                    // page "shrinks" the loaded window.
                    var items: [String] = []
                    for index in 20..<(20 + recent) {
                        items.append(
                            #"{"kind":"message","id":"rec-\#(index)","author":{"role":"user"},"createdAt":null,"blocks":[{"type":"text","text":"recent \#(index)"}]}"#)
                    }
                    // Once the refresh is observed, the fresh page
                    // carries ONE new committed record at its end.
                    items.append(
                        #"{"kind":"message","id":"rec-new","author":{"role":"user"},"createdAt":null,"blocks":[{"type":"text","text":"the just-sent record"}]}"#)
                    await pipe.brokerSend(
                        #"{"type":"response","id":"\#(id)","result":{"sessionId":"s1","generation":1,"revision":"rev","throughSeq":\#(20 + recent + 1),"items":[\#(items.joined(separator: ","))],"olderCursor":"cursor-recent"}}"#)
                case "history.before":
                    // ONE older page: records 0..9 (older than every
                    // recent record — the reader pages into history).
                    var items: [String] = []
                    for index in 0..<10 {
                        items.append(
                            #"{"kind":"message","id":"old-\#(index)","author":{"role":"assistant"},"createdAt":null,"blocks":[{"type":"text","text":"older \#(index)"}]}"#)
                    }
                    await pipe.brokerSend(
                        #"{"type":"response","id":"\#(id)","result":{"sessionId":"s1","generation":1,"revision":"rev","throughSeq":0,"items":[\#(items.joined(separator: ","))],"olderCursor":null}}"#)
                default:
                    await pipe.brokerSend(
                        #"{"type":"response","id":"\#(id)","result":{}}"#)
                }
            }
        }
    }

    private func makeStore(broker: PagingBroker) -> AgentChatStore {
        AgentChatStore(
            pipeFactory: AgentChatPipeFactory(
                open: { _ in await broker.openConnection() },
                hostRecord: {
                    Host(
                        address: "demo", username: "demo",
                        brokerChatSocketPath: "/tmp/demo.sock")
                }),
            paneIdentity: {
                HerdrPaneSessionIdentity(sessionFilePath: "/s/file")
            })
    }

    @Test("a refresh after older paging RETAINS the paged prefix — no shrink, reader's row survives")
    func refreshRetainsPagedPrefix() async throws {
        let broker = PagingBroker(recentCount: 8)
        let store = makeStore(broker: broker)
        await store.start()
        for _ in 0..<400 where store.phase != .ready {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(store.phase == .ready)

        // The reader pages into history: the window grows by the older
        // page's 10 records above the recent 8.
        await store.loadOlder()
        for _ in 0..<400
        where store.content.messages.count < 19 {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(store.content.messages.count == 19)
        let idsAfterPaging = store.content.messages.map(\.id)
        #expect(idsAfterPaging.first == AgentChatMapper.stableID(for: "old-0"))
        #expect(store.hasOlder == false)  // the older page was terminal

        // THE TRANSITION (the trace): a send lands → history.changed →
        // the recent page refreshes. The pre-merge behavior REPLACED
        // the window with the (smaller) recent page: the reader's
        // paged records VANISHED and the document shrank under the
        // retained offset — the persistent blank.
        if let pipe = (await brokerPipe(broker: broker)) {
            await broker.pushHistoryChanged(on: pipe)
        }
        for _ in 0..<400 where store.windowRevision == 0 {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(store.windowRevision >= 1)

        // The merge contract: the paged prefix (old-0..9) is RETAINED
        // above the fresh recent page; the fresh page's new record is
        // present; NOTHING the reader had loaded vanished.
        let ids = store.content.messages.map(\.id)
        #expect(ids.count >= 19, "the paged prefix vanished: \(ids.count) rows")
        #expect(
            ids.contains(AgentChatMapper.stableID(for: "old-0")),
            "the reader's oldest paged record was DELETED by the refresh (the blank-on-send trace)")
        #expect(
            ids.contains(AgentChatMapper.stableID(for: "rec-new")),
            "the fresh page's new record is missing")
        // The retained prefix sits ABOVE the fresh page (window order
        // preserved).
        #expect(
            ids.first == AgentChatMapper.stableID(for: "old-0"),
            "the retained prefix must lead the window")
        #expect(
            ids.last == AgentChatMapper.stableID(for: "rec-new"))

        // The older cursor is RETAINED (the prefix's provenance) even
        // though the fresh page advertised its own cursor.
        #expect(store.hasOlder == false)  // terminal older page stays terminal
    }

    @Test("a reconnect with held content keeps the paged window's provenance")
    func reconnectRetainsPagedWindow() async throws {
        let broker = PagingBroker(recentCount: 8)
        let store = makeStore(broker: broker)
        await store.start()
        for _ in 0..<400 where store.phase != .ready {
            try await Task.sleep(for: .milliseconds(10))
        }
        await store.loadOlder()
        for _ in 0..<400 where store.content.messages.count < 19 {
            try await Task.sleep(for: .milliseconds(10))
        }
        let idsAfterPaging = store.content.messages.map(\.id)

        // A reconnect (lock/unlock) with held content: the window and
        // its paging provenance survive; the fresh page MERGES.
        await store.start()
        var sawNonRenderable = false
        for _ in 0..<400 {
            if !store.phase.isRenderable { sawNonRenderable = true }
            if store.phase == .ready, store.windowRevision >= 1 { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(!sawNonRenderable)
        #expect(store.phase == .ready)

        // The paged prefix survived the reconnect's fresh page too.
        let ids = store.content.messages.map(\.id)
        #expect(
            ids.contains(AgentChatMapper.stableID(for: "old-0")),
            "the reconnect's fresh page deleted the paged prefix")
        #expect(
            ids.first == AgentChatMapper.stableID(for: "old-0"))
        _ = idsAfterPaging
    }

    /// Reaches the harness's latest pipe (each connection gets a fresh
    /// ScriptedChatPipe; the push goes to the LIVE one).
    private func brokerPipe(broker: PagingBroker) async -> ScriptedChatPipe? {
        await broker.currentPipe()
    }
}

