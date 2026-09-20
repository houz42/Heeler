import Foundation

#if DEBUG

/// TEMP channel-continuity evidence (rides the smoke suite; revert with
/// the harness): every open/close/request event appends one
/// timestamped, run-identified JSON line to an ISOLATED per-run file,
/// so a hold run can be independently audited after the fact — an
/// independent read can separate mid-hold events from teardown.
///
/// The run ID comes from the harness (HEELER_A1_RUN_ID) — one file per
/// invocation, no mixing between runs. Dead without the env var
/// (production never logs).
enum AgentChatChannelEvidence {
    static let runID = ProcessInfo.processInfo.environment["HEELER_A1_RUN_ID"]

    private static let queue = DispatchQueue(label: "chat.channel.evidence")

    private static var fileURL: URL? {
        guard let runID else { return nil }
        let dir = URL(fileURLWithPath: "/tmp/heeler-proof-signals/a1-continuity")
        try? FileManager.default.createDirectory(
            at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("\(runID).jsonl")
    }

    /// One event line: run, event, timestamp, detail.
    static func record(_ event: String, _ detail: String = "") {
        guard let url = fileURL else { return }
        let stamp = ISO8601DateFormatter().string(from: Date())
        let line = "{\"run\":\"\(runID ?? "")\",\"event\":\"\(event)\",\"t\":\"\(stamp)\",\"detail\":\"\(detail)\"}\n"
        queue.sync {
            let data = line.data(using: .utf8) ?? Data()
            if !FileManager.default.fileExists(atPath: url.path) {
                FileManager.default.createFile(atPath: url.path, contents: data)
            } else if let handle = try? FileHandle(forWritingTo: url) {
                defer { try? handle.close() }
                _ = try? handle.seekToEnd()
                try? handle.write(contentsOf: data)
            }
        }
    }

    static func connect() { record("channel.connect") }
    /// The params preview lets an auditor match prompt.send events to
    /// the broker-side record by text, not just timing.
    static func request(_ method: String, params: String? = nil) {
        record("channel.request", params.map { "\(method) | \(String($0.prefix(80)))" } ?? method)
    }
    static func close(reason: String) { record("channel.close", reason) }
}

#else

enum AgentChatChannelEvidence {
    static func connect() {}
    static func request(_ method: String, params: String? = nil) {}
    static func close(reason: String) {}
}

#endif
