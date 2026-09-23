import Foundation

#if DEBUG

/// TEMP channel-continuity audit (rides the smoke suite; revert with
/// the harness). One JSON line per channel event — JSONEncoder-built
/// (never hand-rolled), every line carrying the run ID, the channel
/// INSTANCE id (a fresh UUID per AgentChatChannel — reconnects are
/// distinguishable), subsecond UTC + a monotonic per-process sequence,
/// and a structured detail. The harness appends a distinct
/// harness.teardown marker so teardown-era lines cannot be mistaken
/// for mid-hold events.
///
/// Gated by the harness's HEELER_A1_RUN_ID; production never logs
/// (the release stub below is a no-op).
enum AgentChatChannelEvidence {
    static let runID = ProcessInfo.processInfo.environment["HEELER_A1_RUN_ID"]

    private struct Line: Codable {
        var seq: Int
        var run: String
        var channel: String
        var event: String
        var t: String
        var detail: String
    }

    private static let lock = NSLock()
    // The lock guards every access — the annotations satisfy the
    // concurrency checker while the mutation stays lock-scoped.
    private nonisolated(unsafe) static var nextSeq = 0
    private nonisolated(unsafe) static let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    private static func fileURL() -> URL? {
        guard let runID else { return nil }
        let dir = URL(fileURLWithPath: "/tmp/heeler-proof-signals/a1-continuity")
        try? FileManager.default.createDirectory(
            at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("\(runID).jsonl")
    }

    static func record(
        channel: String, event: String, detail: String = ""
    ) {
        guard let url = fileURL() else { return }
        lock.lock()
        nextSeq += 1
        let line = Line(
            seq: nextSeq,
            run: runID ?? "",
            channel: channel,
            event: event,
            t: iso.string(from: Date()),
            detail: detail)
        lock.unlock()
        guard let data = try? JSONEncoder().encode(line) else { return }
        var toAppend = data
        toAppend.append(0x0A)
        lock.lock()
        defer { lock.unlock() }
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(
                atPath: url.path, contents: toAppend)
        } else if let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: toAppend)
        }
    }

    /// One harness-boundary marker (no channel).
    static func harnessEvent(_ event: String, detail: String = "") {
        record(channel: "harness", event: event, detail: detail)
    }
}

#else

enum AgentChatChannelEvidence {
    /// Release stub: evidence logging is harness-only. Same shape as the
    /// debug variant's `record` so ungated call sites compile in every
    /// configuration (the release stub was missing it — the v2 tip's
    /// Release build did not compile).
    static func record(
        channel: String, event: String, detail: String = ""
    ) {}
    static func harnessEvent(_ event: String, detail: String = "") {}
}

#endif
