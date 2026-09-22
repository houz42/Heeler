import CryptoKit
import Foundation

// SPDX-License-Identifier: Apache-2.0
//
// Resolved-ask history persistence: the transcript blocks an agent's
// chat renders survive the chat store's whole lifecycle (AgentDetailView
// owns the store in @State — leaving the detail DESTROYS it; reopening
// builds a NEW store). The archive is a JSON file per broker session
// (keyed by socket path + pane session file — the store's own
// identity), loaded when the store is built and written on every
// resolution record. App-support, not UserDefaults: it is
// conversation-derived data, not user preference.

/// Codable carrier: the archive file's root.
struct AgentChatResolutionArchive: Codable, Sendable, Equatable {
    /// The pane session file the resolutions belong to (part of the
    /// archive's key; written back verbatim for auditability).
    var sessionFile: String
    /// The broker socket the resolutions arrived over (part of the
    /// archive's key; written back verbatim for auditability).
    var socketPath: String
    /// First-record order; one entry per requestId (the store's
    /// recordResolution dedup rule persists too).
    var resolutions: [AgentChatInteractionResolution]
}

/// Load/append/replace against the per-session archive file. All
/// operations are synchronous file I/O on small JSON (bounded by the
/// number of asks in a session's history); the store calls them on the
/// main actor where it already touches resolution state.
enum AgentChatResolutionArchiveStore: Sendable {
    /// The archive key → file path. One archive per broker session.
    static func archiveURL(
        socketPath: String, sessionFile: String
    ) -> URL? {
        let socket = socketPath.trimmingCharacters(in: .whitespaces)
        let session = sessionFile.trimmingCharacters(in: .whitespaces)
        guard !socket.isEmpty, !session.isEmpty else { return nil }
        let dir = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        ).first?
            .appendingPathComponent("HeelerAskHistory", isDirectory: true)
        guard let dir else { return nil }
        try? FileManager.default.createDirectory(
            at: dir, withIntermediateDirectories: true)
        // Opaque stable key from the two identity strings: SHA-256 of
        // their UTF8 (64 hex chars — a raw hex of the bytes would
        // exceed APFS's 255-byte filename cap on long real paths and
        // silently fail the write). Never used for display.
        let key = SHA256.hash(data: Data((socket + "\u{0}" + session).utf8))
            .map { String(format: "%02x", $0) }
            .joined()
        return dir.appendingPathComponent("\(key).json")
    }

    /// The persisted resolutions for this broker session (empty when
    /// no archive exists yet). A corrupt or undecodable file reads as
    /// empty — history that cannot render honestly starts fresh rather
    /// than crashing the chat surface.
    static func load(
        socketPath: String, sessionFile: String
    ) -> [AgentChatInteractionResolution] {
        guard let url = archiveURL(
            socketPath: socketPath, sessionFile: sessionFile),
            let data = try? Data(contentsOf: url),
            let archive = try? JSONDecoder().decode(
                AgentChatResolutionArchive.self, from: data)
        else { return [] }
        return archive.resolutions
    }

    /// Persists the full resolution list (the store's current
    /// first-record state after its dedup/replace). One write per
    /// resolution change; a write failure is silent (the in-memory
    /// history still renders — persistence is best-effort, the next
    /// successful write re-syncs).
    static func save(
        socketPath: String, sessionFile: String,
        resolutions: [AgentChatInteractionResolution]
    ) {
        guard let url = archiveURL(
            socketPath: socketPath, sessionFile: sessionFile)
        else { return }
        let archive = AgentChatResolutionArchive(
            sessionFile: sessionFile,
            socketPath: socketPath,
            resolutions: resolutions)
        guard let data = try? JSONEncoder().encode(archive) else { return }
        try? data.write(to: url, options: .atomic)
    }
}
