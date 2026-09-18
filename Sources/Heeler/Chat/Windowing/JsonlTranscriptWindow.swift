import Foundation

// SPDX-License-Identifier: Apache-2.0
//
// A file-backed bounded window over an append-only JSONL transcript.
// Ported from Drover (MIT), keinstn/drover@0fdb6a0
// (app/lib/src/transcript/native_transcript.dart — `JsonlTranscriptWindow`),
// with two Heeler-specific changes: the default window is 1 MiB instead of
// Drover's 512 KiB (real omp sessions run 1.2 MB+), and the byte source is a
// local FileHandle rather than Drover's remote stat/range readers.
//
// This type owns byte-window/offset/partial-line bookkeeping only. Turning a
// raw JSONL line into a chat message is the parser's job (Transcript slice);
// this window hands out raw lines.
//
//  - the very first read of a large file is a bounded tail (the last
//    `windowBytes`) rather than the whole file from offset 0, so opening a
//    50 MiB transcript never loads it all;
//  - a bounded window may begin mid-line; only the leading partial record is
//    ever discarded (the window start is snapped forward past the next
//    newline to a genuine record boundary);
//  - append-only polling (`poll()`) transfers only the bytes written after
//    the known EOF, never re-reading already-loaded chunks;
//  - explicit `loadOlder()` prepends the previous bounded chunk in
//    chronological order until offset 0 is reached (`hasOlder` false);
//  - a single record wider than `windowBytes` never truncates mid-record and
//    never causes a growing/duplicate read: `loadOlder()` walks strictly
//    backward until the record's leading boundary is found, and delivers it
//    whole (mirroring Drover's `_pendingOlderEnd` sentinel traversal);
//  - truncation or a replaced file (the file shrank below what has already
//    been read) is detected on `poll()` and resets all state before reading.

/// The default bounded-window size for the initial tail read and each older
/// page. 1 MiB: several turns of typical omp JSONL records, while opening a
/// pane never has to read more than this up front.
public let jsonlTranscriptWindowBytes: Int = 1_048_576

/// One raw bounded range read, before any record-boundary interpretation is
/// applied — the Swift shape of Drover's `_RawRead`.
private struct RawRead {
    /// The file offset the read started at.
    var offset: Int
    var bytes: [UInt8]
}

/// A resolved, boundary-clean chunk: `clean` begins at a genuine JSONL record
/// boundary at file offset `windowStart` (having discarded any partial content
/// found before it) — the Swift shape of Drover's `_ResolvedChunk`.
private struct ResolvedChunk {
    var clean: [UInt8]
    var windowStart: Int
}

/// A file-backed bounded window over an append-only JSONL transcript.
/// Yields raw unparsed lines (`[String]`); parsing is another slice's job.
///
/// `windowBytes` is exposed so tests can use a small window without a
/// multi-hundred-KiB fixture; production code should use the default.
///
/// `@unchecked Sendable` is deliberate: all mutable window state is guarded
/// by `lock`, and file handles are created per call, so instances are safe
/// to share across concurrency domains.
public final class JsonlTranscriptWindow: @unchecked Sendable {
    public let path: String
    public let windowBytes: Int

    /// Serializes access to every mutable property below.
    private let lock = NSLock()

    // The offset of the first byte covered by `lines`; nil before any load
    // has established a window. While `pendingOlderEnd` is set this is a
    // not-yet-confirmed sentinel (just enough to keep `hasOlder` true) — the
    // real next-read boundary is `pendingOlderEnd` until traversal resolves.
    private var windowStart: Int?
    // The offset one past the last byte read so far; the next poll starts
    // here and reads through to EOF.
    private var readEnd: Int = 0
    // A trailing partial JSONL line kept across reads/polls until a later
    // read completes it. The tentative tail (see `tailRemainderParsed`)
    // already yielded that partial line; the completing newline is dropped.
    private var remainder: [UInt8] = []
    private var remainderYielded = false
    // Lines delivered so far, in file (chronological) order. The tentative
    // partial-tail line sits at the end while `remainderYielded` is true and
    // is dropped/re-delivered once completed.
    private var lines: [String] = []
    // Set while traversing a record wider than `windowBytes`: the offset the
    // next older-page read should end at, in place of `windowStart` (which
    // stays an unconfirmed sentinel until a genuine record boundary is
    // found). Each unresolved read moves this strictly backward to that
    // read's own start, so the next call reads fresh, non-overlapping bytes
    // rather than stalling or re-reading the same span. Nil when there is no
    // such traversal in progress.
    private var pendingOlderEnd: Int?

    /// Creates a window over the JSONL file at `path` and performs the
    /// initial bounded-tail load. `windowBytes` defaults to
    /// `jsonlTranscriptWindowBytes` (1 MiB).
    public init(path: String, windowBytes: Int = jsonlTranscriptWindowBytes) throws {
        precondition(windowBytes > 0, "windowBytes must be positive")
        self.path = path
        self.windowBytes = windowBytes
        try loadInitial()
    }

    /// True when the window's start is not yet byte 0 of the file — i.e.
    /// `loadOlder()` has more to fetch.
    public var hasOlder: Bool {
        lock.lock()
        defer { lock.unlock() }
        return windowStart.map { $0 > 0 } ?? false
    }

    /// The file offset of the first byte covered by the window; nil before
    /// the initial load establishes one.
    public var startOffset: Int? {
        lock.lock()
        defer { lock.unlock() }
        return windowStart
    }

    /// The file offset one past the last byte read so far.
    public var endOffset: Int {
        lock.lock()
        defer { lock.unlock() }
        return readEnd
    }

    /// The raw JSONL lines delivered so far, in file (chronological) order.
    /// Parsing these is the Transcript slice's job. While the file's last
    /// record is still unterminated (no trailing newline yet), the partial
    /// tail is included tentatively — `poll()` re-syncs it once the newline
    /// arrives.
    public var rawLines: [String] {
        lock.lock()
        defer { lock.unlock() }
        return lines
    }

    /// Reads newly appended bytes (if any) into the window, returning only
    /// the lines completed by those bytes. Only bytes past `readEnd` are
    /// read — already-loaded chunks are never re-read. A file that shrank
    /// below `readEnd` (truncation or a replaced file) resets the window
    /// before reading, so a stale window is never mixed with different
    /// content; in that case every line of the fresh tail is returned.
    public func poll() throws -> [String] {
        lock.lock()
        defer { lock.unlock() }

        let file = try openFile()
        defer { try? file.close() }

        let size = try fileSize(file)
        if size < readEnd {
            reset()
        }
        guard windowStart != nil else {
            try loadInitial(file: file, size: size)
            return lines
        }
        guard size > readEnd else { return [] }

        let bytes = try readRange(file, from: readEnd, length: nil)
        readEnd += bytes.count
        return appendBytes(bytes)
    }

    /// Fetches and prepends the next older bounded chunk, returning the
    /// newly prepended lines (in chronological order). Returns nil (and
    /// fetches nothing) when `hasOlder` is false — i.e. the window already
    /// reaches byte 0.
    public func loadOlder() throws -> [String]? {
        lock.lock()
        defer { lock.unlock() }

        guard let start = windowStart, start > 0 else { return nil }
        let file = try openFile()
        defer { try? file.close() }

        if let pending = pendingOlderEnd {
            // Resolving a pending oversized-record traversal. By
            // construction `pending` only ever moved leftward across reads
            // that contained no newline at all, so [pending, start) is
            // known to be newline-free: it lies entirely inside the
            // oversized record, whose right edge is the confirmed
            // boundary `start` (the traversal's origin, untouched
            // throughout). The moment this read surfaces the record's
            // leading boundary, the whole record — however many windows
            // wide — is delivered at once. (Heeler never truncates or
            // drops a record to fit the window; Drover dropped such
            // records instead.)
            let raw = try readRaw(file: file, endOffset: pending)
            let last = raw.bytes.lastIndex(of: 0x0A)

            // Resolve target: the file offset where the oversized record
            // begins, and with it the new confirmed window start.
            var recordStart: Int?
            if raw.offset == 0 {
                // Nothing older can exist: the record (and any content
                // before it in this first-page read) reaches byte 0.
                recordStart = 0
            } else if last == raw.bytes.count - 1 {
                // The newline IS the buffer's last byte, so `pending` was
                // a genuine record boundary all along: the oversized
                // record is exactly [pending, start).
                recordStart = pending
            } else if let last {
                // The last newline in this read is the record's leading
                // boundary; any earlier newline bounds still-older
                // content that later normal loadOlder calls will page.
                recordStart = raw.offset + last + 1
            }

            if let recordStart {
                pendingOlderEnd = nil
                windowStart = recordStart
                let record = try readRange(file, from: recordStart, length: start - recordStart)
                let new = decodeLines(record)
                lines.insert(contentsOf: new, at: 0)
                return new
            }
            // No usable boundary in this chunk: still inside the oversized
            // record. Move the pending cursor strictly backward to this
            // read's own start so the next call reads fresh,
            // non-overlapping bytes instead of stalling or repeating this
            // span. `windowStart` (still the pre-traversal sentinel) is
            // untouched, so `hasOlder` stays true.
            pendingOlderEnd = raw.offset
            return []
        }
        let raw = try readRaw(file: file, endOffset: start)
        if let resolved = resolveFromConfirmedEdge(raw) {
            windowStart = resolved.windowStart
            let new = decodeLines(resolved.clean)
            lines.insert(contentsOf: new, at: 0)
            return new
        }
        // A record wider than `windowBytes` sits right before `windowStart`
        // with no boundary found in this one bounded read. Start traversing
        // it: `windowStart` stays put (still keeps `hasOlder` true) while
        // `pendingOlderEnd` carries this read's own start for the next
        // call to continue from, strictly backward.
        pendingOlderEnd = raw.offset
        return []
    }

    /// Appends a raw JSONL line (no trailing newline) to the backing file and
    /// yields it through the window, exactly as if the file had grown behind
    /// our back. A concurrent external append followed by `append(line:)`
    /// would interleave un-terminated records, so — mirroring the
    /// `poll()`-after-truncation stance — this first drains any pending
    /// external bytes via `poll()` and returns the poll's lines followed by
    /// the appended line, in order.
    public func append(_ line: String) throws -> [String] {
        lock.lock()
        defer { lock.unlock() }

        var polled: [String]
        let sizeBefore = try currentFileSize()
        if sizeBefore > readEnd {
            polled = try pollLocked()
        } else {
            polled = []
        }

        let file = try FileHandle(forWritingTo: URL(fileURLWithPath: path))
        defer { try? file.close() }
        try file.seekToEnd()
        var bytes = Array(line.utf8)
        bytes.append(0x0A)
        try file.write(contentsOf: bytes)
        readEnd += bytes.count
        // readEnd now tracks the appended newline: a later poll can never
        // return these bytes again.
        _ = appendBytes(bytes)
        return polled + [line]
    }

    /// `poll()` without re-locking — for internal callers that already hold
    /// the lock.
    private func pollLocked() throws -> [String] {
        let file = try openFile()
        defer { try? file.close() }

        let size = try fileSize(file)
        if size < readEnd {
            reset()
        }
        guard windowStart != nil else {
            try loadInitial(file: file, size: size)
            return lines
        }
        guard size > readEnd else { return [] }

        let bytes = try readRange(file, from: readEnd, length: nil)
        readEnd += bytes.count
        return appendBytes(bytes)
    }

    /// Reads the initial bounded tail. Call only when `windowStart == nil`.
    /// Callers must hold `lock`.
    private func loadInitial() throws {
        let file = try openFile()
        defer { try? file.close() }
        try loadInitial(file: file, size: try fileSize(file))
    }

    /// Reads the initial bounded tail from an already-open file.
    /// Callers must hold `lock`.
    private func loadInitial(file: FileHandle, size: Int) throws {
        if size == 0 {
            // Nothing to read; the empty file is trivially the whole window.
            windowStart = 0
            readEnd = 0
            return
        }
        if size <= windowBytes {
            // Small enough to load in full.
            let bytes = try readRange(file, from: 0, length: nil)
            windowStart = 0
            readEnd = bytes.count
            _ = appendBytes(bytes)
            return
        }
        let raw = try readRaw(file: file, endOffset: size)
        readEnd = raw.offset + raw.bytes.count
        if let resolved = resolveFromConfirmedEdge(raw) {
            windowStart = resolved.windowStart
            _ = appendBytes(resolved.clean)
        } else {
            // The record reaching EOF is itself at least `windowBytes` wide —
            // its own leading boundary wasn't found in this single bounded
            // read. The oversized trailing record is simply omitted for now:
            // `windowStart` stays a `hasOlder` sentinel and
            // `pendingOlderEnd` marks where the next `loadOlder()` continues
            // from, instead of stalling on or repeating this same span.
            windowStart = size
            pendingOlderEnd = raw.offset
        }
    }


    /// Clears all window/offset state, e.g. after truncation or a replaced
    /// file, so the next load starts fresh.
    private func reset() {
        windowStart = nil
        readEnd = 0
        remainder = []
        remainderYielded = false
        pendingOlderEnd = nil
        lines = []
    }

    /// Reads exactly the `windowBytes`-bounded (or smaller, near offset 0)
    /// span ending at `endOffset` — one single range read, never retried or
    /// grown within one call.
    private func readRaw(file: FileHandle, endOffset: Int) throws -> RawRead {
        let offset = max(0, endOffset - windowBytes)
        let bytes = try readRange(file, from: offset, length: endOffset - offset)
        return RawRead(offset: offset, bytes: bytes)
    }

    /// Resolves `raw` assuming its right edge (`raw.offset + raw.bytes.count`)
    /// is already a confirmed JSONL record boundary — true for every normal
    /// older-page read, and safe for the very first read of a large file too
    /// (a possibly-unterminated final record there is handled by the
    /// remainder logic in `appendBytes`, not here). Discards everything up
    /// to and including the first newline, so `ResolvedChunk.clean` begins at
    /// a genuine record boundary. Returns nil when no newline is found
    /// before the buffer's very last byte — i.e. one record spans the whole
    /// span with no leading boundary discovered yet (a newline *at* the very
    /// last byte is this confirmed edge itself, not new information, so it
    /// doesn't count either).
    private func resolveFromConfirmedEdge(_ raw: RawRead) -> ResolvedChunk? {
        if raw.offset == 0 {
            return ResolvedChunk(clean: raw.bytes, windowStart: 0)
        }
        guard let newline = raw.bytes.firstIndex(of: 0x0A),
              newline != raw.bytes.count - 1
        else { return nil }
        return ResolvedChunk(
            clean: Array(raw.bytes[(newline + 1)...]),
            windowStart: raw.offset + newline + 1
        )
    }


    /// Combines `bytes` with any pending remainder, appends every complete
    /// line to `lines`, and keeps a new trailing partial line (if any) as the
    /// remainder — tentatively yielding it too (dropped and re-delivered once
    /// a later read completes it) so a final unterminated record still shows
    /// immediately rather than waiting for its newline. Returns the lines
    /// newly added to the tail.
    private func appendBytes(_ bytes: [UInt8]) -> [String] {
        guard !bytes.isEmpty else { return [] }
        var input: [UInt8]
        let completesYieldedRemainder = remainderYielded && bytes.first == 0x0A
        if completesYieldedRemainder {
            remainder = []
            remainderYielded = false
            input = Array(bytes[1...])
        } else {
            input = remainder + bytes
            remainder = []
            remainderYielded = false
        }

        var added: [String] = []
        if let lastNewline = input.lastIndex(of: 0x0A) {
            let complete = Array(input[...lastNewline])
            added = decodeLines(complete)
            lines.append(contentsOf: added)
            let tail = Array(input[(lastNewline + 1)...])
            remainder = tail
            if !tail.isEmpty {
                // Tentatively yield the partial tail line immediately; the
                // completing read drops and re-delivers it.
                let tailLine = decodeString(tail)
                lines.append(tailLine)
                added.append(tailLine)
                remainderYielded = true
            }
        } else {
            remainder = input
            if !input.isEmpty {
                let line = decodeString(input)
                lines.append(line)
                added.append(line)
                remainderYielded = true
            }
        }
        return added
    }

    /// Splits newline-terminated bytes into raw lines, dropping the final
    /// empty element that a trailing newline always leaves.
    private func decodeLines(_ bytes: [UInt8]) -> [String] {
        guard !bytes.isEmpty else { return [] }
        let text = decodeString(bytes)
        var result = text.components(separatedBy: "\n")
        if result.last == "" { result.removeLast() }
        return result
    }

    private func decodeString(_ bytes: [UInt8]) -> String {
        // Malformed bytes never throw; unmatched sequences become U+FFFD,
        // matching Drover's utf8.decode(allowMalformed: true).
        String(decoding: bytes, as: UTF8.self)
    }

    // MARK: File I/O

    private func openFile() throws -> FileHandle {
        try FileHandle(forReadingFrom: URL(fileURLWithPath: path))
    }

    private func fileSize(_ file: FileHandle) throws -> Int {
        Int(try file.seekToEnd())
    }

    private func currentFileSize() throws -> Int {
        let file = try openFile()
        defer { try? file.close() }
        return try fileSize(file)
    }

    private func readRange(_ file: FileHandle, from offset: Int, length: Int?) throws -> [UInt8] {
        try file.seek(toOffset: UInt64(offset))
        let data: Data
        if let length {
            data = length > 0 ? (try file.read(upToCount: length) ?? Data()) : Data()
        } else {
            data = try file.readToEnd() ?? Data()
        }
        return Array(data)
    }
}
