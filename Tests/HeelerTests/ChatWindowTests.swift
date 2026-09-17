import Foundation
import Testing

@testable import Heeler

/// Tests for `JsonlTranscriptWindow` against the real 1.7 MB omp session
/// fixture. The hard invariant: paging `loadOlder()` back through the whole
/// window must reconstruct the exact full file content in order —
/// concatenating all delivered lines (with newlines) equals the original
/// bytes. Every yielded line must be complete JSON.
@Suite("Chat window")
struct ChatWindowTests {
    /// The real 1.7 MB live-session fixture (omp 18.2.1), located relative to
    /// this file so the tests run from any working directory.
    private static let fixtureURL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .appendingPathComponent("Fixtures/Transcripts/omp-large-session.jsonl")

    private static func tmpCopy(_ source: URL) throws -> URL {
        let dst = FileManager.default.temporaryDirectory
            .appendingPathComponent("chat-window-\(UUID().uuidString).jsonl")
        try FileManager.default.copyItem(at: source, to: dst)
        return dst
    }

    private static func readAll(_ url: URL) throws -> Data {
        try Data(contentsOf: url)
    }

    /// Reconstructs the full transcript from a window: the initial tail's
    /// lines followed by every `loadOlder()` page's lines, in the order
    /// delivered, joined with newlines (each yielded line was
    /// newline-terminated in the file).
    private static func reconstruct(_ window: JsonlTranscriptWindow) throws -> String {
        var all = window.rawLines
        while window.hasOlder {
            guard let older = try window.loadOlder(), !older.isEmpty else { continue }
            // Prepend older pages to keep file order; the pages themselves
            // come newest-page-first but each page's lines are in file order.
            all.insert(contentsOf: older, at: 0)
        }
        return all.joined(separator: "\n") + "\n"
    }

    // MARK: Full-file reconstruction (hard invariant)

    @Test func tailThenLoadOlderReconstructsEntireRealFixtureInOrder() throws {
        let window = try JsonlTranscriptWindow(path: Self.fixtureURL.path)
        // Default 1 MiB window: smaller than the 1.7 MB fixture, so the
        // initial load is a genuine bounded tail with older history to page.
        #expect(window.hasOlder)
        #expect(window.startOffset! > 0)

        let reconstructed = try Self.reconstruct(window)
        let original = try String(decoding: Self.readAll(Self.fixtureURL), as: UTF8.self)
        #expect(!window.hasOlder)
        #expect(window.startOffset == 0)
        #expect(reconstructed == original)
    }

    @Test func everyYieldedLineIsCompleteParseableJSON() throws {
        let window = try JsonlTranscriptWindow(path: Self.fixtureURL.path)
        var all = window.rawLines
        while window.hasOlder {
            guard let older = try window.loadOlder(), !older.isEmpty else { continue }
            all.insert(contentsOf: older, at: 0)
        }
        #expect(!all.isEmpty)
        for (index, line) in all.enumerated() {
            let object = try #require(try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])
            #expect(object["type"] != nil, "line \(index) has no top-level type field")
        }
    }

    @Test func smallWindowReconstructsEntireRealFixtureToo() throws {
        // A tiny window forces dozens of pages plus multi-page oversized-record
        // traversal on the real fixture — the invariant must still hold.
        let window = try JsonlTranscriptWindow(path: Self.fixtureURL.path, windowBytes: 3_000)
        #expect(window.hasOlder)
        let reconstructed = try Self.reconstruct(window)
        let original = try String(decoding: Self.readAll(Self.fixtureURL), as: UTF8.self)
        #expect(reconstructed == original)
    }

    // MARK: Efficiency — never reads before the window

    @Test func initialTailReadsOnlyWindowBytes() throws {
        let window = try JsonlTranscriptWindow(path: Self.fixtureURL.path)
        #expect(window.startOffset! > 0)
        // The confirmed start must be past the discarded partial record and
        // within one window of EOF.
        let fileEnd = try #require(FileHandle(forReadingFrom: Self.fixtureURL)).seekToEnd()
        #expect(window.startOffset! > Int(fileEnd) - window.windowBytes - 1)
        #expect(window.endOffset == Int(fileEnd))
        // First delivered line sits at/after the confirmed window start.
        let lines = window.rawLines
        #expect(!lines.isEmpty)
        let raw = try Data(contentsOf: Self.fixtureURL)
        let firstLineData = Data(lines[0].utf8)
        #expect(raw.range(of: firstLineData) != nil)
    }

    // MARK: poll() after append

    @Test func pollAfterAppendYieldsExactlyTheAppendedBytes() throws {
        let copyURL = try Self.tmpCopy(Self.fixtureURL)
        defer { try? FileManager.default.removeItem(at: copyURL) }

        let window = try JsonlTranscriptWindow(path: copyURL.path)
        var before = window.rawLines

        let appended = #"{"type":"message","message":{"role":"user","content":[{"type":"text","text":"hi again"}]}}"#
        let handle = try FileHandle(forWritingTo: copyURL)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data((appended + "\n").utf8))
        try handle.close()

        let polled = try window.poll()
        #expect(polled == [appended])
        before.append(appended)
        #expect(window.rawLines == before)
        // Polling again yields nothing new.
        #expect(try window.poll() == [])
        // And the full-file invariant still holds.
        let reconstructed = try Self.reconstruct(window)
        let original = try String(decoding: Self.readAll(copyURL), as: UTF8.self)
        #expect(reconstructed == original)
    }

    @Test func appendHelperYieldsTheAppendedLineAndPersistsIt() throws {
        let copyURL = try Self.tmpCopy(Self.fixtureURL)
        defer { try? FileManager.default.removeItem(at: copyURL) }

        let window = try JsonlTranscriptWindow(path: copyURL.path)
        let line = #"{"type":"message","message":{"role":"user","content":[{"type":"text","text":"from the window"}]}}"#
        let yielded = try window.append(line)
        #expect(yielded == [line])

        // The line is really on disk (a fresh window over the same file sees
        // it) and poll() never re-yields it.
        #expect(try window.poll() == [])
        let fresh = try JsonlTranscriptWindow(path: copyURL.path, windowBytes: 16)
        var seen = fresh.rawLines
        while fresh.hasOlder {
            guard let older = try fresh.loadOlder(), !older.isEmpty else { continue }
            seen.insert(contentsOf: older, at: 0)
        }
        #expect(seen.last == line)
    }

    // MARK: Edge cases

    @Test func emptyFileYieldsEmptyWindowWithNoOlder() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("chat-window-empty-\(UUID().uuidString).jsonl")
        FileManager.default.createFile(atPath: url.path, contents: Data())
        defer { try? FileManager.default.removeItem(at: url) }

        let window = try JsonlTranscriptWindow(path: url.path)
        #expect(window.rawLines.isEmpty)
        #expect(!window.hasOlder)
        #expect(try window.loadOlder() == nil)
        #expect(try window.poll() == [])
    }

    @Test func fileSmallerThanWindowLoadsEverything() throws {
        let lines = [
            #"{"type":"title","title":"a"}"#,
            #"{"type":"message","message":{"role":"user"}}"#,
            #"{"type":"message","message":{"role":"assistant"}}"#,
        ]
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("chat-window-small-\(UUID().uuidString).jsonl")
        try lines.joined(separator: "\n").appending("\n").write(to: url, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }

        let window = try JsonlTranscriptWindow(path: url.path)
        #expect(window.rawLines == lines)
        #expect(window.startOffset == 0)
        #expect(!window.hasOlder)
        #expect(try window.loadOlder() == nil)
    }

    @Test func pollDrainsAnExternallyGrownSmallFile() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("chat-window-grow-\(UUID().uuidString).jsonl")
        try #"{"one":1}"#.appending("\n").write(to: url, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }

        let window = try JsonlTranscriptWindow(path: url.path)
        #expect(window.rawLines == [#"{"one":1}"#])

        let handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data([#"{"two":2}"#, #"{"three":3}"#].joined(separator: "\n").appending("\n").utf8))
        try handle.close()

        #expect(try window.poll() == [#"{"two":2}"#, #"{"three":3}"#])
        #expect(window.rawLines == [#"{"one":1}"#, #"{"two":2}"#, #"{"three":3}"#])
        #expect(try window.poll() == [])
    }

    @Test func truncatedFileResetsTheWindow() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("chat-window-trunc-\(UUID().uuidString).jsonl")
        try ([#"{"a":1}"#, #"{"b":2}"#, #"{"c":3}"#].joined(separator: "\n") + "\n")
            .write(to: url, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }

        let window = try JsonlTranscriptWindow(path: url.path)
        #expect(window.rawLines.count == 3)

        try #"{"new":"file"}"#.appending("\n").write(to: url, atomically: true, encoding: .utf8)
        let polled = try window.poll()
        #expect(polled == [#"{"new":"file"}"#])
        #expect(window.rawLines == [#"{"new":"file"}"#])
        #expect(!window.hasOlder)
    }

    @Test func singleRecordWiderThanWindowIsDeliveredWholeNeverTruncated() throws {
        // One record wider than the whole window: the initial tail read
        // cannot find its leading boundary, so it is omitted (sentinel start)
        // and loadOlder walks strictly backward until the record's true
        // start resolves — the record must then be delivered whole.
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("chat-window-wide-\(UUID().uuidString).jsonl")
        let wide = #"{"padding":""# + String(repeating: "x", count: 400) + #""}"#
        let lines = [wide, #"{"after":true}"#]
        try (lines.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }

        let window = try JsonlTranscriptWindow(path: url.path, windowBytes: 128)
        #expect(window.hasOlder)
        #expect(window.rawLines == [#"{"after":true}"#])

        var all = window.rawLines
        while window.hasOlder {
            guard let older = try window.loadOlder(), !older.isEmpty else { continue }
            all.insert(contentsOf: older, at: 0)
        }
        #expect(all == lines)
        #expect(!window.hasOlder)
        #expect(window.startOffset == 0)
    }

    @Test func oversizedRecordMidFilePagesBackwardAcrossIt() throws {
        // A record wider than the window sitting mid-file (not at EOF and not
        // at offset 0): paging backward must cross it via multi-call
        // traversal and still reconstruct byte-exact content.
        let short1 = #"{"i":1}"#
        let short2 = #"{"i":2}"#
        let wide = #"{"wide":""# + String(repeating: "y", count: 500) + #""}"#
        let short3 = #"{"i":3}"#
        let lines = [short1, short2, wide, short3]
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("chat-window-mid-\(UUID().uuidString).jsonl")
        try (lines.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }

        let window = try JsonlTranscriptWindow(path: url.path, windowBytes: 100)
        #expect(window.hasOlder)
        #expect(window.rawLines == [short3])

        var all = window.rawLines
        while window.hasOlder {
            guard let older = try window.loadOlder(), !older.isEmpty else { continue }
            all.insert(contentsOf: older, at: 0)
        }
        #expect(all == lines)
        #expect(window.startOffset == 0)
    }

    @Test func unterminatedFinalRecordIsYieldedTentativelyThenCompleted() throws {
        // The file's last record has no trailing newline: it appears
        // immediately, and once the newline arrives the line is delivered
        // exactly once, complete.
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("chat-window-unterm-\(UUID().uuidString).jsonl")
        try ([#"{"a":1}"#, #"{"b":"no-newline-yet"}"#].joined(separator: "\n"))
            .write(to: url, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }

        let window = try JsonlTranscriptWindow(path: url.path)
        #expect(window.rawLines == [#"{"a":1}"#, #"{"b":"no-newline-yet"}"#])

        let handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("\n".utf8))
        try handle.close()

        #expect(try window.poll() == [])
        #expect(window.rawLines == [#"{"a":1}"#, #"{"b":"no-newline-yet"}"#])
        #expect(try window.poll() == [])
    }

    @Test func utf8MultibyteRecordsAcrossReadBoundariesSurvive() throws {
        // Non-ASCII content forces multi-byte UTF-8 sequences to straddle
        // read boundaries; the reconstruction invariant must still hold.
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("chat-window-utf8-\(UUID().uuidString).jsonl")
        let lines = (0..<40).map { #"{"text":"你好世界 \#($0) 🚀 你好世界 🚀"}"# }
        try (lines.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }

        let window = try JsonlTranscriptWindow(path: url.path, windowBytes: 200)
        #expect(window.hasOlder)
        var all = window.rawLines
        while window.hasOlder {
            guard let older = try window.loadOlder(), !older.isEmpty else { continue }
            all.insert(contentsOf: older, at: 0)
        }
        #expect(all == lines)
        #expect(window.startOffset == 0)
    }
}
