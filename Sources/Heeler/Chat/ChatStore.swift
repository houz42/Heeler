import Foundation
import Observation

// SPDX-License-Identifier: Apache-2.0
//
// The live-data owner behind one chat pane (ADR for the chat layer; Drover's
// per-agent transcript controller, native Swift). One store per
// (hostID, paneID):
//
//   appear ── read the agent's `agent_session` (only a `.path` session
//             reference names a transcript file; anything else gets the
//             graceful "transcript unavailable" empty state)
//          ── readTranscriptFile once, write it to a per-pane cache file
//             under Caches (Chat/transcripts/<host>-<pane>.jsonl, sanitized)
//          ── open JsonlTranscriptWindow over that cache and parse the
//             window's lines via OmpTranscriptParser
//   poll   ── on `pane.agent_status_changed` (the Console's existing
//             agentStatusUpdates stream — no second events channel),
//             readTranscriptFileChunk with TranscriptFetch.appendedRange
//             against the cached byte count, append the delta to the cache,
//             feed the new lines through window.append + parse
//   older  ── loadOlder() pages the window's older history when the user
//             scrolls to the top
//
// All network I/O is injected closures (the ConsoleStore-backed readTranscript
// pair), so the pure seams — cache-path sanitization, the append-range
// decision, the polled-line parse merge — are unit-testable with a stub
// transport over in-memory Data.

/// How the transcript read is reached, mirroring `readSkillFile`'s
/// projection(for:).session.withTransport pattern. The Console passes its
/// two methods; tests pass closures over in-memory Data.
struct ChatTranscriptReader: Sendable {
    /// Reads the whole transcript file. An absent file reads as empty Data
    /// (the transport's rule); only a connection failure throws.
    let readWhole: @Sendable (_ path: String) async throws -> Data
    /// Reads up to `length` bytes from `offset`. Empty Data means offset is
    /// at or past EOF.
    let readChunk: @Sendable (_ path: String, _ offset: UInt64, _ length: Int)
        async throws -> Data

    /// Reads the LAST up-to-`tailBytes` of the transcript, plus the
    /// remote byte offset the returned data begins at (0 for files
    /// smaller than the tail). The transport exposes no stat, so the
    /// EOF is located with bounded 1-byte probes (doubling then
    /// binary) — a file at or under the tail size costs one read and
    /// no probes. Replaces the old read-whole-on-start, which blocked
    /// on the ENTIRE transcript over the wire before anything
    /// rendered (the long-session hang the user hit).
    func readTail(
        _ path: String, tailBytes: Int
    ) async throws -> (data: Data, remoteStart: UInt64) {
        // Small file? One bounded read settles it (and gives the size).
        let first = try await readChunk(path, 0, tailBytes + 1)
        if first.count <= tailBytes {
            return (first, 0)
        }
        // The file is bigger than the tail: locate the exact size by
        // doubling, then binary — each probe is a 1-byte read.
        var low = UInt64(tailBytes)   // known non-empty offset
        var high = low * 2            // first candidate unknown
        while try await !readChunk(path, high, 1).isEmpty {
            low = high
            high = high * 2
        }
        // Binary search in (low, high].
        while low + 1 < high {
            let mid = (low + high) / 2
            if try await !readChunk(path, mid, 1).isEmpty {
                low = mid
            } else {
                high = mid
            }
        }
        let size = high
        let start = size - UInt64(tailBytes)
        let data = try await readChunk(path, start, tailBytes)
        return (data, start)
    }

    init(
        readWhole: @escaping @Sendable (_ path: String) async throws -> Data,
        readChunk: @escaping @Sendable (
            _ path: String, _ offset: UInt64, _ length: Int
        ) async throws -> Data
    ) {
        self.readWhole = readWhole
        self.readChunk = readChunk
    }

    /// The production reader over a ConsoleStore's live Host connection.
    @MainActor
    static func console(_ console: ConsoleStore, hostID: Host.ID) -> ChatTranscriptReader {
        ChatTranscriptReader(
            readWhole: { path in
                try await console.readTranscriptFile(atPath: path, on: hostID)
            },
            readChunk: { path, offset, length in
                try await console.readTranscriptFileChunk(
                    atPath: path, offset: offset, length: length, on: hostID)
            })
    }
}

/// What one chat pane is rendering, as the store's observable state.
enum ChatLoadPhase: Sendable, Equatable {
    /// Nothing loaded yet (also the initial value before `start` runs).
    case idle
    /// Fetching the first transcript copy.
    case loading
    /// Live: rows are rendering; poll is armed.
    case ready
    /// The agent has no readable transcript (no `.path` agent session, or
    /// the first read failed). The empty state is graceful: the user still
    /// sees the chat surface with its status strip.
    case unavailable(String)
}

/// The live-data store for one agent's chat pane.
@MainActor
@Observable
final class ChatStore {
    // MARK: Pure seams (static, network-free)

    /// The per-pane cache file name under `Caches/Chat/transcripts/`:
    /// `<hostID>-<paneID>.jsonl`. Pane ids are opaque strings (verified live:
    /// alphanumeric `w…:p…`, but treat them as arbitrary), so every character
    /// outside a conservative safe set is percent-escaped — an id can never
    /// forge a path separator or `..`.
    nonisolated static func cacheFileName(hostID: Host.ID, paneID: String) -> String {
        let safe = CharacterSet(
            charactersIn: "abcdefghijklmnopqrstuvwxyz"
                + "ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-")
        let host = hostID.uuidString.replacingOccurrences(of: "-", with: "")
        let pane = paneID.addingPercentEncoding(withAllowedCharacters: safe)
            ?? paneID.unicodeScalars.map { scalar in
                safe.contains(scalar) ? String(scalar) : "?"
            }.joined()
        return "\(host)-\(pane).jsonl"
    }

    /// The full per-pane cache URL under `base` (the app's Caches dir in
    /// production; a temp dir in tests).
    nonisolated static func cacheURL(hostID: Host.ID, paneID: String, base: URL) -> URL {
        base.appendingPathComponent("Chat/transcripts", isDirectory: true)
            .appendingPathComponent(cacheFileName(hostID: hostID, paneID: paneID))
    }

    /// The next poll's read after the cache holds `cachedBytes` and the
    /// transport reported `reportedSize` for the transcript file: nil when
    /// nothing grew, else the (offset, length) to request. Pure wrapper over
    /// `TranscriptFetch.appendedRange` so the store's decision is testable.
    nonisolated static func nextPollRange(
        cachedBytes: UInt64, reportedSize: UInt64
    ) -> (offset: UInt64, length: Int)? {
        TranscriptFetch.appendedRange(knownBytes: cachedBytes, reportedSize: reportedSize)
    }

    /// Merges newly polled raw JSONL lines into the parsed content:
    /// parse-only-the-delta, append to the existing arrays. Pure, so the
    /// polled-line merge is testable without a store instance.
    nonisolated static func mergePolledLines(
        _ lines: [String], into content: ChatContent
    ) -> ChatContent {
        var content = content
        let (messages, results) = OmpTranscriptParser.parse(lines: lines)
        content.messages.append(contentsOf: messages)
        content.toolResults.append(contentsOf: results)
        return content
    }

    /// Merges an older page's raw JSONL lines into the parsed content:
    /// parse-the-page, prepend to the existing arrays (older history goes
    /// above what is already rendered). Pure for the same reason as
    /// `mergePolledLines`.
    nonisolated static func mergeOlderLines(
        _ lines: [String], into content: ChatContent
    ) -> ChatContent {
        var content = content
        let (messages, results) = OmpTranscriptParser.parse(lines: lines)
        content.messages.insert(contentsOf: messages, at: 0)
        content.toolResults.insert(contentsOf: results, at: 0)
        return content
    }

    // MARK: State

    private(set) var phase: ChatLoadPhase = .idle
    private(set) var content = ChatContent()
    /// True while the window has older pages the user has not loaded.
    private(set) var hasOlder = false
    /// The remote byte offset the cache file's FIRST byte maps to (the
    /// tail-window seed): >0 means older history exists remotely
    /// beyond the cache's top, and loadOlder extends the cache
    /// backwards before paging.
    private(set) var cachedRemoteStart: UInt64 = 0
    /// True while a `loadOlder()` fetch is in flight.
    private(set) var isLoadingOlder = false

    /// The agent's transcript path when its `agent_session` is a `.path`
    /// reference; nil for every other shape (no transcript available).
    private(set) var transcriptPath: String?

    // MARK: Wiring

    private let hostID: Host.ID
    private let paneID: String
    private let reader: ChatTranscriptReader
    /// The app's Caches directory the per-pane transcript cache lives under.
    private let cachesDirectory: () -> URL
    /// Latest-value view of the Host's existing `pane.agent_status_changed`
    /// subscription for this agent; drives the append-poll.
    private var statusUpdates: AsyncStream<ConsoleStore.AgentStatusUpdate>?
    private var pollTask: Task<Void, Never>?
    /// The window over the local cache file; the one file-reading owner.
    @ObservationIgnored private var window: JsonlTranscriptWindow?
    /// Bytes of the transcript the cache file holds — the `knownBytes` side
    /// of every poll's append-range decision.
    @ObservationIgnored private var cachedBytes: UInt64 = 0

    init(
        hostID: Host.ID,
        paneID: String,
        reader: ChatTranscriptReader,
        cachesDirectory: @escaping () -> URL = {
            FileManager.default.urls(
                for: .cachesDirectory, in: .userDomainMask)[0]
        }
    ) {
        self.hostID = hostID
        self.paneID = paneID
        self.reader = reader
        self.cachesDirectory = cachesDirectory
    }

    // No deinit: `pollTask` is MainActor-isolated, and a nonisolated deinit
    // cannot cancel it. The poll task is bound to the status-update stream's
    // own lifetime instead: the stream terminates when the Console drops the
    // observer, which ends the loop. The view's `.task(id:)` also cancels on
    // agent switch.

    // MARK: Lifecycle

    /// Starts (or restarts) the store for `agentSession`: reads the whole
    /// transcript once, seeds the cache file, opens the window, parses, and
    /// arms the status-event poll. A non-`.path` session (or nil) lands in
    /// the graceful unavailable state.
    func start(
        agentSession: AgentSessionInfo?,
        statusUpdates: AsyncStream<ConsoleStore.AgentStatusUpdate>
    ) async {
        pollTask?.cancel()
        window = nil
        content = ChatContent()
        hasOlder = false
        isLoadingOlder = false
        cachedBytes = 0
        cachedRemoteStart = 0

        self.statusUpdates = statusUpdates

        guard let agentSession, agentSession.kind == AgentSessionRefKind.path,
            TranscriptFetch.validatedTranscriptPath(agentSession.value) != nil
        else {
            transcriptPath = nil
            phase = .unavailable("This agent has no transcript file.")
            return
        }
        transcriptPath = agentSession.value
        phase = .loading

        do {
            // Tail-window load (the long-session fix): bounded bytes on
            // the wire — the last windowBytes, not the whole transcript.
            let tail = try await reader.readTail(
                agentSession.value, tailBytes: jsonlTranscriptWindowBytes)
            cachedRemoteStart = tail.remoteStart
            try seedCache(with: tail.data)
            try openWindowAndParse()
            phase = .ready
            armPoll()
        } catch is CancellationError {
            // A replaced store leaves quietly.
        } catch {
            phase = .unavailable("The transcript couldn't be read from the Host.")
        }
    }

    /// Pages older history into the visible window. Returns the newly
    /// prepended lines (already parsed and merged); nil when the window
    /// already reaches byte 0.
    @discardableResult
    func loadOlder() async -> [String]? {
        guard let window, phase == .ready else { return nil }
        isLoadingOlder = true
        defer { isLoadingOlder = false }
        do {
            if !window.hasOlder {
                // The cache's top is the window's top: either the remote
                // file's start (nothing older exists) or the tail-seed's
                // start (older history is REMOTE). Extend the cache
                // backwards by one window, reopen, and let the NEXT
                // loadOlder page through the extended cache — no
                // inventing history when the remote start is byte 0.
                guard cachedRemoteStart > 0, let transcriptPath else {
                    hasOlder = false
                    return nil
                }
                let fetchStart = max(0, cachedRemoteStart - UInt64(jsonlTranscriptWindowBytes))
                let fetchLength = Int(cachedRemoteStart - fetchStart)
                guard fetchLength > 0 else { hasOlder = false; return nil }
                let olderBytes = try await reader.readChunk(
                    transcriptPath, fetchStart, fetchLength)
                guard !olderBytes.isEmpty else {
                    cachedRemoteStart = 0
                    hasOlder = false
                    return nil
                }
                try prependCache(with: olderBytes)
                cachedRemoteStart = fetchStart
                try openWindowAndParse()
                hasOlder = window.hasOlder || cachedRemoteStart > 0
                return nil
            }
            guard let older = try window.loadOlder() else {
                hasOlder = cachedRemoteStart > 0
                return nil
            }
            hasOlder = window.hasOlder || cachedRemoteStart > 0
            content = Self.mergeOlderLines(older, into: content)
            return older
        } catch {
            // A failed older-page read is transient; the window keeps its
            // state and the next call retries.
            return nil
        }
    }

    /// Prepend `data` to the cache file (the backwards extension of
    /// the tail window): rewrite as new+existing so the window,
    /// reopened over the cache, sees the longer file. Idempotent
    /// merges keep the content correct across the reopen.
    private func prependCache(with data: Data) throws {
        let url = Self.cacheURL(hostID: hostID, paneID: paneID, base: cachesDirectory())
        let existing = try Data(contentsOf: url)
        var combined = data
        combined.append(existing)
        try combined.write(to: url, options: .atomic)
        cachedBytes = UInt64(combined.count)
    }

    // MARK: Internals

    /// Writes the first transcript copy to the per-pane cache file and
    /// records its byte count. The cache dir is created on demand; a stale
    /// cache from a previous session of the same pane is overwritten.
    private func seedCache(with data: Data) throws {
        let url = Self.cacheURL(hostID: hostID, paneID: paneID, base: cachesDirectory())
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
        cachedBytes = UInt64(data.count)
    }

    /// Opens the window over the cache file and parses its initial lines
    /// into `content`.
    private func openWindowAndParse() throws {
        let url = Self.cacheURL(hostID: hostID, paneID: paneID, base: cachesDirectory())
        let window = try JsonlTranscriptWindow(path: url.path)
        self.window = window
        hasOlder = window.hasOlder
        content = Self.mergePolledLines(window.rawLines, into: content)
    }

    /// Consumes the status-update stream: each `pane.agent_status_changed`
    /// delivery (and each snapshot-driven republish) triggers one append
    /// poll. Latest-wins buffering keeps a burst of events from queueing
    /// redundant reads.
    private func armPoll() {
        guard let statusUpdates else { return }
        pollTask?.cancel()
        pollTask = Task { [weak self] in
            guard let self else { return }
            for await _ in statusUpdates {
                guard !Task.isCancelled else { return }
                await self.poll()
            }
        }
    }

    /// One append poll: read the transcript's growth past `cachedBytes`,
    /// append it to the cache file, feed the completing lines through the
    /// window, and parse the new lines into the visible content.
    private func poll() async {
        guard let transcriptPath, let window, phase == .ready else { return }
        do {
            // The chunk read is the growth probe: read everything past the
            // cached byte count in bounded chunks (the transport clamps each
            // request; a short read means EOF).
            var delta = Data()
            var offset = cachedBytes
            while true {
                let chunk = try await reader.readChunk(
                    transcriptPath, offset, TranscriptFetch.maximumChunkBytes)
                if chunk.isEmpty { break }
                delta.append(chunk)
                offset += UInt64(chunk.count)
                if chunk.count < TranscriptFetch.maximumChunkBytes { break }
            }
            guard !delta.isEmpty else { return }

            // The append-range decision, pure and testable: with the reported
            // size (old cache + observed growth) the delta must exactly be
            // the appended range.
            let reportedSize = cachedBytes + UInt64(delta.count)
            guard let range = Self.nextPollRange(cachedBytes: cachedBytes, reportedSize: reportedSize),
                range.offset == cachedBytes, UInt64(range.length) == UInt64(delta.count)
            else { return }

            // Append the raw delta to the cache file, then let the window
            // read it: the delta may end mid-record, and the window's own
            // remainder logic (not a line split here) carries the partial
            // line across polls. `window.append` would inject a premature
            // newline, so the store writes bytes and the window polls.
            let url = Self.cacheURL(hostID: hostID, paneID: paneID, base: cachesDirectory())
            let handle = try FileHandle(forWritingTo: url)
            do {
                try handle.seekToEnd()
                try handle.write(contentsOf: delta)
            } catch {
                try? handle.close()
                throw error
            }
            try handle.close()
            cachedBytes = reportedSize

            // The window picks the appended bytes up as file growth; it
            // returns only the lines those bytes completed (dropping and
            // re-delivering any tentative partial tail from before).
            let newLines = try window.poll()
            guard !newLines.isEmpty else { return }
            content = Self.mergePolledLines(newLines, into: content)
        } catch is CancellationError {
            // Store replaced mid-poll.
        } catch {
            // A failed poll is transient; the next status event retries.
        }
    }

    // MARK: Test seams

    /// Test-only: the identity the cache path is keyed on.
    var hostIDForTesting: Host.ID { hostID }

    /// Test-only: drives one append poll directly (the status stream in
    /// tests finishes immediately, so the poll loop has nothing to react
    /// to).
    func pollOnceForTesting() async {
        await poll()
    }
}
