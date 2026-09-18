import Foundation
import Testing

@testable import Heeler

// SPDX-License-Identifier: Apache-2.0
//
// Pure-helper tests for the SFTP transcript transport slice
// (`TranscriptFetch`): absolute-path validation and chunk-offset math.
// The network paths (openSFTP + readFileChunk in HeelerSSHTransport) are
// compile-only here — they need a live Host.

@Suite("Chat transport SFTP helpers")
struct ChatTransportSFTPTests {

    // MARK: - Path validation

    @Test func acceptsAbsolutePOSIXPaths() {
        #expect(TranscriptFetch.validatedTranscriptPath(
            "/home/jhou/.omp/sessions/2026/session.jsonl") != nil)
        #expect(TranscriptFetch.validatedTranscriptPath("/") != nil)
        // Spaces are fine: SFTP is not a shell.
        #expect(TranscriptFetch.validatedTranscriptPath(
            "/tmp/my transcripts/a b.jsonl") != nil)
        // Unicode is fine too: only NUL/quote/backslash/control are refused.
        #expect(TranscriptFetch.validatedTranscriptPath(
            "/tmp/中文-会议记录.jsonl") != nil)
    }

    @Test func rejectsRelativeAndEmptyPaths() {
        #expect(TranscriptFetch.validatedTranscriptPath("") == nil)
        #expect(TranscriptFetch.validatedTranscriptPath("session.jsonl") == nil)
        #expect(TranscriptFetch.validatedTranscriptPath(
            "relative/path/session.jsonl") == nil)
        #expect(TranscriptFetch.validatedTranscriptPath("~/.omp/session.jsonl") == nil)
        #expect(TranscriptFetch.validatedTranscriptPath("./session.jsonl") == nil)
    }

    @Test func rejectsUnquotableCharacters() {
        // NUL, single quote, backslash, and control characters never reach a
        // channel open.
        #expect(TranscriptFetch.validatedTranscriptPath("/tmp/a\u{0}b.jsonl") == nil)
        #expect(TranscriptFetch.validatedTranscriptPath("/tmp/a'b.jsonl") == nil)
        #expect(TranscriptFetch.validatedTranscriptPath("/tmp/a\\b.jsonl") == nil)
        #expect(TranscriptFetch.validatedTranscriptPath("/tmp/a\u{01}b.jsonl") == nil)
        #expect(TranscriptFetch.validatedTranscriptPath("/tmp/a\u{7F}b.jsonl") == nil)
    }

    // MARK: - Chunk length clamping

    @Test func clampsChunkLengths() {
        #expect(TranscriptFetch.clampedChunkLength(0) == 0)
        #expect(TranscriptFetch.clampedChunkLength(-5) == 0)
        #expect(TranscriptFetch.clampedChunkLength(1) == 1)
        #expect(TranscriptFetch.clampedChunkLength(64 * 1_024) == 64 * 1_024)
        // Above the cap: clamped, never an unbounded single read.
        #expect(TranscriptFetch.clampedChunkLength(Int.max) == 64 * 1_024)
    }

    // MARK: - Whole-file chunk plans

    @Test func emptyAndMissingFilesProduceNoChunks() {
        #expect(TranscriptFetch.chunkPlan(fileSize: nil).isEmpty)
        #expect(TranscriptFetch.chunkPlan(fileSize: 0).isEmpty)
    }

    @Test func smallFileIsOneChunk() {
        let plan = TranscriptFetch.chunkPlan(fileSize: 100)
        #expect(plan.count == 1)
        #expect(plan.first?.offset == 0)
        #expect(plan.first?.length == 100)
    }

    @Test func exactChunkMultipleHasNoTrailingEmptyChunk() {
        let chunk = UInt64(64 * 1_024)
        let plan = TranscriptFetch.chunkPlan(fileSize: chunk * 2)
        #expect(plan.count == 2)
        #expect(plan[0] == (offset: 0, length: 64 * 1_024))
        #expect(plan[1] == (offset: chunk, length: 64 * 1_024))
    }

    @Test func planCoversFileExactlyInOrder() {
        // A size that is not a chunk multiple, exercising the remainder.
        let size = UInt64(64 * 1_024) * 3 + 17
        let plan = TranscriptFetch.chunkPlan(fileSize: size)
        #expect(plan.count == 4)
        var covered: UInt64 = 0
        var previousEnd: UInt64 = 0
        for step in plan {
            #expect(step.offset == previousEnd) // ascending, contiguous
            #expect(step.length > 0)
            #expect(step.length <= TranscriptFetch.maximumChunkBytes)
            previousEnd = step.offset + UInt64(step.length)
            covered &+= UInt64(step.length)
        }
        #expect(covered == size)
        #expect(previousEnd == size)
    }

    // MARK: - Arbitrary-range chunk plans (loadOlder paging)

    @Test func rangePlanRejectsNonPositiveInputs() {
        #expect(TranscriptFetch.chunkPlan(
            rangeStart: 0, rangeLength: 0).isEmpty)
        #expect(TranscriptFetch.chunkPlan(
            rangeStart: 10, rangeLength: 0).isEmpty)
    }

    @Test func rangePlanSplitsContiguously() {
        let start = UInt64(150 * 1_024)
        let plan = TranscriptFetch.chunkPlan(
            rangeStart: start,
            rangeLength: UInt64(64 * 1_024) + 100)
        #expect(plan.count == 2)
        #expect(plan[0].offset == start)
        #expect(plan[0].length == 64 * 1_024)
        #expect(plan[1].offset == start + UInt64(64 * 1_024))
        #expect(plan[1].length == 100)
    }

    // MARK: - Append-poll growth math

    @Test func appendedRangeIsNilWhenNoGrowth() {
        #expect(TranscriptFetch.appendedRange(knownBytes: 100, reportedSize: 100) == nil)
        #expect(TranscriptFetch.appendedRange(knownBytes: 100, reportedSize: 50) == nil)
    }

    @Test func appendedRangeStartsAtKnownBytes() {
        let growth = TranscriptFetch.appendedRange(
            knownBytes: 1_000, reportedSize: 1_250)
        #expect(growth?.offset == 1_000)
        #expect(growth?.length == 250)
    }

    @Test func appendedRangeCoversLargeGrowth() {
        // A poll after a long quiet period reads the whole growth in one
        // bounded tail read; the transport clamps per-request length.
        let growth = TranscriptFetch.appendedRange(
            knownBytes: 0, reportedSize: UInt64(5 * 1_024 * 1_024))
        #expect(growth?.offset == 0)
        #expect(growth?.length == 5 * 1_024 * 1_024)
    }
}
