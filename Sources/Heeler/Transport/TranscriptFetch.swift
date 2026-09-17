import Foundation

// SPDX-License-Identifier: Apache-2.0
//
// Pure path-validation and chunk-offset math for the chat layer's SFTP
// transcript reads (ADR-0011: one channel per op, closed in the caller).
// Everything here is network-free and unit-testable; the transport side
// (openSFTP + readFileChunk) lives in HeelerSSHTransport.

/// Transcript file reads over SFTP: absolute-path validation (Drover's rule —
/// a transcript path must be absolute POSIX, leading "/") plus the byte-range
/// math the windowing layer uses for bounded tails, `loadOlder` paging, and
/// append-poll deltas.
enum TranscriptFetch: Sendable {
    /// The maximum single-chunk read length: one SFTP round trip per call,
    /// sized to the driver's internal 64 KiB read granularity so a full
    /// chunk is one driver loop iteration.
    static let maximumChunkBytes = 64 * 1_024

    /// The path when it is a usable transcript location: absolute POSIX
    /// (leading "/") and free of NUL, quote, backslash, and control
    /// characters (`RemoteShellPath`'s quotable subset). Nil otherwise.
    /// Relative paths are rejected before any channel opens.
    static func validatedTranscriptPath(_ path: String) -> String? {
        RemoteShellPath.quotedAbsolute(path) != nil ? path : nil
    }

    /// Clamps a requested read length into a valid single-chunk length.
    /// Non-positive lengths become 0 (the transport reads nothing); lengths
    /// above the chunk cap are clamped to the cap so no request can pin an
    /// unbounded buffer. The caller loops for more.
    static func clampedChunkLength(_ length: Int) -> Int {
        min(max(length, 0), maximumChunkBytes)
    }

    /// Splits a whole-file read of `size` bytes into chunk descriptors:
    /// (offset, length) pairs, at most `maximumChunkBytes` each, in file
    /// order, together covering exactly `[0, size)`. A non-positive or
    /// missing size yields no descriptors (nothing to read).
    static func chunkPlan(
        fileSize: UInt64?, chunkBytes: Int = maximumChunkBytes
    ) -> [(offset: UInt64, length: Int)] {
        guard let fileSize else { return [] }
        return chunkPlan(rangeStart: 0, rangeLength: fileSize, chunkBytes: chunkBytes)
    }

    /// Splits the byte range `[rangeStart, rangeStart + rangeLength)` into
    /// chunk descriptors of at most `chunkBytes` each, in ascending offset
    /// order. A non-positive range yields no descriptors.
    static func chunkPlan(
        rangeStart: UInt64,
        rangeLength: UInt64,
        chunkBytes: Int = maximumChunkBytes
    ) -> [(offset: UInt64, length: Int)] {
        guard rangeLength > 0, chunkBytes > 0 else { return [] }
        let chunk = UInt64(clamping: chunkBytes)
        var plan: [(offset: UInt64, length: Int)] = []
        var offset = rangeStart
        var remaining = rangeLength
        while remaining > 0 {
            let take = UInt64(min(remaining, chunk))
            plan.append((offset: offset, length: Int(take)))
            offset &+= take
            remaining -= take
        }
        return plan
    }

    /// The next append-poll read after a consumer holding `knownBytes`
    /// observes a file of `reportedSize`: nil when nothing new arrived,
    /// otherwise the offset (always `knownBytes`) and the byte count to
    /// request — the full growth in one bounded tail read.
    static func appendedRange(
        knownBytes: UInt64, reportedSize: UInt64
    ) -> (offset: UInt64, length: Int)? {
        guard reportedSize > knownBytes else { return nil }
        let growth = reportedSize - knownBytes
        return (offset: knownBytes, length: Int(clamping: growth))
    }
}
