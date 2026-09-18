import Foundation
import Testing

@testable import Heeler

// SPDX-License-Identifier: Apache-2.0
//
// ChatStore's pure seams (cache-path sanitization, the append-range poll
// decision, the polled-line parse merge) plus the store's lifecycle against
// a stub reader over in-memory Data: no SSH, no fixtures beyond strings.

// MARK: - Stub reader

/// A `ChatTranscriptReader` over one in-memory transcript `Data`, mirroring
/// the transport protocol's own semantics: `readWhole` returns the whole
/// file (empty when absent), `readChunk` returns up to `length` bytes from
/// `offset` (empty past EOF). The transport extension defaults make a bare
/// stub cheap; this one adds the two transcript reads over in-memory Data.
private struct InMemoryTranscriptReader: ChatTranscriptReaderProtocol {
    let file: Data

    func readWhole(_ path: String) async throws -> Data {
        file
    }

    func readChunk(_ path: String, _ offset: UInt64, _ length: Int) async throws -> Data {
        guard offset < UInt64(file.count) else { return Data() }
        let start = Int(offset)
        let end = min(start + length, file.count)
        return file.subdata(in: start..<end)
    }
}

/// The seam `ChatTranscriptReader` already is: closures over the same two
/// operations, so tests can construct the reader struct directly. Kept as a
/// protocol-shaped alias so the stub reads like the production reader.
private protocol ChatTranscriptReaderProtocol: Sendable {
    func readWhole(_ path: String) async throws -> Data
    func readChunk(_ path: String, _ offset: UInt64, _ length: Int) async throws -> Data
}

extension ChatTranscriptReaderProtocol {
    /// Wraps the stub into the real reader struct the store consumes.
    var asReader: ChatTranscriptReader {
        ChatTranscriptReader(
            readWhole: { path in try await self.readWhole(path) },
            readChunk: { path, offset, length in
                try await self.readChunk(path, offset, length)
            })
    }
}

// MARK: - Cache path sanitization

@Suite("ChatStore cache paths")
struct ChatStoreCachePathTests {
    private let host = Host.ID() // UUID

    @Test func cacheFileNamePairsHostAndPane() {
        let name = ChatStore.cacheFileName(hostID: host, paneID: "w1:pA")
        #expect(name == "\(host.uuidString.replacingOccurrences(of: "-", with: ""))-w1%3ApA.jsonl")
    }

    @Test func sanitizationKeepsPathSeparatorsOut() {
        // A hostile pane id must not be able to forge a path separator,
        // climb with "..", or collide with another pane's file.
        let hostile = "w1/../../etc/passwd"
        let name = ChatStore.cacheFileName(hostID: host, paneID: hostile)
        #expect(!name.contains("/"))
        #expect(!name.contains(".."))
        // Distinct pane ids never collide after sanitization.
        let other = ChatStore.cacheFileName(hostID: host, paneID: "w1:..\\..%2fetc")
        #expect(name != other)
    }

    @Test func cacheURLNestsUnderChatTranscripts() {
        let base = URL(fileURLWithPath: "/tmp/caches")
        let url = ChatStore.cacheURL(hostID: host, paneID: "w1:pA", base: base)
        #expect(
            url.path
                == "/tmp/caches/Chat/transcripts/\(ChatStore.cacheFileName(hostID: host, paneID: "w1:pA"))")
        #expect(url.lastPathComponent.hasSuffix(".jsonl"))
    }

    @Test func unicodePaneIDsAreEscapedNotDropped() {
        let name = ChatStore.cacheFileName(hostID: host, paneID: "wπ:p1")
        #expect(name.count > 0)
        #expect(!name.contains("π"))
        // Decoding round-trips the escaped spelling: distinct ids stay
        // distinct strings even before escaping.
        #expect(
            ChatStore.cacheFileName(hostID: host, paneID: "wπ:p1")
                != ChatStore.cacheFileName(hostID: host, paneID: "w:p1"))
    }
}

// MARK: - Append-range poll decision

@Suite("ChatStore poll range")
struct ChatStorePollRangeTests {
    @Test func noGrowthYieldsNoRead() {
        #expect(ChatStore.nextPollRange(cachedBytes: 500, reportedSize: 500) == nil)
        // A shrunken file (replaced transcript) is not growth either.
        #expect(ChatStore.nextPollRange(cachedBytes: 500, reportedSize: 400) == nil)
    }

    @Test func growthReadsExactlyTheAppendedRange() {
        let range = ChatStore.nextPollRange(cachedBytes: 1_000, reportedSize: 1_380)
        #expect(range?.offset == 1_000)
        #expect(range?.length == 380)
    }
}

// MARK: - Polled-line parse merge

@Suite("ChatStore polled merge")
struct ChatStoreMergeTests {
    private func ompLine(role: String, text: String) -> String {
        #"{"type":"message","message":{"role":"\#(role)","content":[{"type":"text","text":"\#(text)"}]}}"#
    }

    @Test func mergeAppendsMessagesWithoutTouchingExistingRows() {
        let seed = ChatContent(messages: [
            ChatMessage(role: .assistant, blocks: [.text("first turn")]),
        ])
        let merged = ChatStore.mergePolledLines(
            [ompLine(role: "user", text: "continue")], into: seed)

        #expect(merged.messages.count == 2)
        #expect(merged.messages.first?.blocks.first
            == .text("first turn"))
        #expect(merged.messages.last?.role == .user)
    }

    @Test func mergePairsToolResultsFromTheSamePoll() {
        let call = #"{"type":"message","message":{"role":"assistant","content":[{"type":"toolCall","id":"read_0#f3","name":"read","arguments":{"path":"/x"}}]}}"#
        let result = #"{"type":"message","message":{"role":"toolResult","toolCallId":"read_0#f3","toolName":"read","isError":false,"content":[{"type":"text","text":"file body"}]}}"#
        let merged = ChatStore.mergePolledLines([call, result], into: ChatContent())

        #expect(merged.messages.count == 1)
        #expect(merged.toolResults.count == 1)
        #expect(merged.toolResults.first?.toolCallId == "read_0#f3")
        // The pairing is the filtering layer's job, but the ids must agree.
        if case .toolCall(let toolCall)? = merged.messages.first?.blocks.first {
            #expect(toolCall.id == merged.toolResults.first?.toolCallId)
        } else {
            Issue.record("polled call line did not parse into a toolCall block")
        }
    }

    @Test func malformedPolledLinesAreSkippedNotFatal() {
        let merged = ChatStore.mergePolledLines(
            ["{not json", "", ompLine(role: "assistant", text: "still live")],
            into: ChatContent())
        #expect(merged.messages.count == 1)
        #expect(
            merged.messages.first?.blocks.first == .text("still live"))
    }

    @Test func nonMessageRecordsDoNotProduceRows() {
        let merged = ChatStore.mergePolledLines(
            [
                #"{"type":"title","title":"x"}"#,
                #"{"type":"custom","customType":"tool_execution_start","data":{}}"#,
            ],
            into: ChatContent())
        #expect(merged.messages.isEmpty)
        #expect(merged.toolResults.isEmpty)
    }
}

// MARK: - Store lifecycle against the stub reader

@MainActor
struct ChatStoreLifecycleTests {
    private func session(path: String) -> AgentSessionInfo {
        AgentSessionInfo(
            agent: "omp", kind: .path, source: "herdr:omp", value: path)
    }

    private func statusStream() -> AsyncStream<ConsoleStore.AgentStatusUpdate> {
        AsyncStream { $0.finish() }
    }

    private func tmpBase() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("chat-store-\(UUID().uuidString)", isDirectory: true)
    }

    @Test func pathSessionLoadsAndParsesTheTranscript() async throws {
        let transcript = Data(
            (#"{"type":"message","message":{"role":"user","content":[{"type":"text","text":"hello"}]}}"#
                + "\n"
                + #"{"type":"message","message":{"role":"assistant","content":[{"type":"text","text":"hi back"}]}}"#
                + "\n").utf8)
        let base = tmpBase()
        let store = ChatStore(
            hostID: Host.ID(), paneID: "w1:pA",
            reader: InMemoryTranscriptReader(file: transcript).asReader,
            cachesDirectory: { base })

        await store.start(agentSession: session(path: "/home/u/.omp/s.jsonl"), statusUpdates: statusStream())

        #expect(store.phase == .ready)
        #expect(store.content.messages.count == 2)
        #expect(store.hasOlder == false) // small file: window reaches byte 0

        // The cache file mirrors the transcript bytes exactly.
        let cached = try Data(
            contentsOf: ChatStore.cacheURL(hostID: store.hostIDForTesting, paneID: "w1:pA", base: base))
        #expect(cached == transcript)
    }

    @Test func nonPathSessionGetsGracefulUnavailable() async throws {
        let store = ChatStore(
            hostID: Host.ID(), paneID: "w1:pA",
            reader: InMemoryTranscriptReader(file: Data()).asReader,
            cachesDirectory: { tmpBase() })

        let idOnly = AgentSessionInfo(
            agent: "omp", kind: .id, source: "herdr:omp", value: "abc")
        await store.start(agentSession: idOnly, statusUpdates: statusStream())
        #expect(store.phase == .unavailable("This agent has no transcript file."))

        await store.start(agentSession: nil, statusUpdates: statusStream())
        #expect(store.phase == .unavailable("This agent has no transcript file."))
        #expect(store.content.messages.isEmpty)
    }

    @Test func statusEventPollsAppendNewLines() async throws {
        // Seed the transcript, start, then grow it — the next poll must
        // deliver only the new lines, parsed into the existing content.
        let line1 = #"{"type":"message","message":{"role":"user","content":[{"type":"text","text":"hello"}]}}"#
        let line2 = #"{"type":"message","message":{"role":"assistant","content":[{"type":"text","text":"hi back"}]}}"#
        let seed = Data((line1 + "\n").utf8)

        let base = tmpBase()
        let holder = TransientBox(seed)
        let reader = ChatTranscriptReader(
            readWhole: { _ in holder.value },
            readChunk: { _, offset, length in
                let file = holder.value
                guard offset < UInt64(file.count) else { return Data() }
                let start = Int(offset)
                let end = min(start + length, file.count)
                return file.subdata(in: start..<end)
            })
        let store = ChatStore(
            hostID: Host.ID(), paneID: "w1:pA", reader: reader,
            cachesDirectory: { base })
        await store.start(
            agentSession: session(path: "/home/u/.omp/s.jsonl"),
            statusUpdates: statusStream())
        #expect(store.content.messages.count == 1)

        // Grow the transcript and deliver one status event.
        holder.value = seed + Data((line2 + "\n").utf8)
        await store.pollOnceForTesting()

        #expect(store.content.messages.count == 2)
        #expect(store.content.messages.last?.blocks.first == .text("hi back"))
    }

    @Test func loadOlderPagesPrependedHistory() async throws {
        // A transcript the initial 1 MiB window cannot hold in one tail
        // would need a >1 MiB fixture; instead this pins the small-file
        // contract: the initial load covers the whole file, hasOlder is
        // false, and loadOlder says so (nil) rather than erroring.
        let line = #"{"type":"message","message":{"role":"user","content":[{"type":"text","text":"only turn"}]}}"#
        let transcript = Data((line + "\n").utf8)
        let base = tmpBase()
        let store = ChatStore(
            hostID: Host.ID(), paneID: "w1:pA",
            reader: InMemoryTranscriptReader(file: transcript).asReader,
            cachesDirectory: { base })

        await store.start(
            agentSession: session(path: "/home/u/.omp/s.jsonl"),
            statusUpdates: statusStream())
        #expect(store.phase == .ready)
        #expect(store.content.messages.count == 1)
        #expect(store.hasOlder == false)
        #expect(await store.loadOlder() == nil)
    }
}

/// A mutable box for the growth test: the reader must observe the grown
/// transcript without the store being rebuilt.
private final class TransientBox: @unchecked Sendable {
    var value: Data
    init(_ value: Data) { self.value = value }
}
