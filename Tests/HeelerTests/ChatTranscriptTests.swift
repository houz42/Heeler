import Foundation
import Testing

@testable import Heeler

/// Parser for omp's JSONL session format (ported from Drover's
/// PiTranscriptParser). Runs against the real 1.7MB session fixture, plus
/// inline lines for the record-spec edge cases: non-message record types are
/// skipped by allowlist, toolCall arguments arrive already decoded, and
/// malformed lines never throw.
@Suite struct ChatTranscriptTests {
    /// The real 1.7MB omp session fixture, located relative to this file so
    /// the test works from any working directory.
    private static func fixtureLines() throws -> [String] {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/Transcripts/omp-large-session.jsonl")
        let raw = try String(contentsOf: url, encoding: .utf8)
        return raw.split(separator: "\n", omittingEmptySubsequences: true)
            .map(String.init)
    }

    @Test func parsesRealSessionFixture() throws {
        let lines = try Self.fixtureLines()
        let (messages, results) = OmpTranscriptParser.parse(lines: lines)

        #expect(!messages.isEmpty)
        #expect(!results.isEmpty)
        // The fixture carries no bashExecution records; toolResults surface
        // in the results array rather than as messages.
        let roles = Set(messages.map(\.role))
        #expect(roles == [.user, .assistant])

        // Census pinned against the fixture's known record counts: 36 user
        // and 222 assistant messages, 203 toolResult records.
        let user = messages.filter { $0.role == .user }.count
        let assistant = messages.filter { $0.role == .assistant }.count
        #expect(user == 36)
        #expect(assistant == 222)
        #expect(results.count == 203)

        // Every message parsed from the real transcript carries a timestamp.
        #expect(messages.allSatisfy { $0.timestamp != nil })
    }

    @Test func toolCallsAndResultsPairOnRealFixture() throws {
        let lines = try Self.fixtureLines()
        let (messages, results) = OmpTranscriptParser.parse(lines: lines)

        var callIds: Set<String> = []
        for message in messages {
            for block in message.blocks {
                if case .toolCall(let call) = block { callIds.insert(call.id) }
            }
        }
        let resultIds = Set(results.map(\.toolCallId))
        #expect(!callIds.isEmpty)
        #expect(!resultIds.isEmpty)
        #expect(!callIds.isDisjoint(with: resultIds))
        // Real session: every tool call has its result and vice versa.
        #expect(callIds == resultIds)
    }

    @Test func skipsNonMessageRecordTypes() {
        // Allowlist, not denylist: every non-message top-level type observed
        // live must be skipped.
        let noise = [
            #"{"type":"title","title":"main"}"#,
            #"{"type":"title_change","title":"changed"}"#,
            #"{"type":"session","id":"abc"}"#,
            #"{"type":"model_change","model":"m"}"#,
            #"{"type":"thinking_level_change","level":"high"}"#,
            #"{"type":"custom","customType":"tool_execution_start"}"#,
            #"{"type":"custom_message","customType":"xdev-mount-notice"}"#,
            #"{invalid json"#,
            "",
            "   ",
        ]
        for line in noise {
            #expect(OmpTranscriptParser.parse(line: line) == nil)
        }
        let (messages, results) = OmpTranscriptParser.parse(lines: noise)
        #expect(messages.isEmpty)
        #expect(results.isEmpty)
    }

    @Test func toolCallArgumentsAreAlreadyDecodedObjects() {
        // omp (unlike Codex) embeds toolCall arguments as a decoded object in
        // the JSONL line; the parser must surface it as-is, never re-decode.
        let line = #"{"type":"message","message":{"role":"assistant","timestamp":1789292098261,"content":[{"type":"thinking","thinking":"planning"},{"type":"toolCall","id":"chatcmpl-tool-9123ab8390114f2f81e8397f80c4cfdf","name":"bash","arguments":{"command":"ls","timeout":30}},{"type":"text","text":"done"}]}}"#

        guard case .message(let message)? = OmpTranscriptParser.parse(line: line) else {
            Issue.record("expected a message record")
            return
        }
        #expect(message.role == .assistant)
        #expect(message.blocks.count == 3)

        guard case .thinking(let thinking) = message.blocks[0] else {
            Issue.record("block 0 should be thinking")
            return
        }
        #expect(thinking == "planning")

        guard case .toolCall(let call) = message.blocks[1] else {
            Issue.record("block 1 should be a toolCall")
            return
        }
        #expect(call.id == "chatcmpl-tool-9123ab8390114f2f81e8397f80c4cfdf")
        #expect(call.name == "bash")
        #expect(call.arguments["command"] == .string("ls"))
        #expect(call.arguments["timeout"] == .number(30))

        guard case .text(let text) = message.blocks[2] else {
            Issue.record("block 2 should be text")
            return
        }
        #expect(text == "done")
    }

    @Test func parsesAndFlattensToolResultRecord() {
        // A tool result is its own top-level message record; content blocks
        // flatten to one text string (image blocks dropped).
        let line = #"{"type":"message","message":{"role":"toolResult","toolCallId":"call_CDXPvNPA1U69hZtEFTn5UoJR|y+sSKRvAXV0DDruBd8sDCuDVacPSg9kbIpsu","toolName":"read","isError":false,"timestamp":1789292100123,"content":[{"type":"text","text":"line 1"},{"type":"image","data":"…"},{"type":"text","text":"line 2"}]}}"#

        guard case .toolResult(let result)? = OmpTranscriptParser.parse(line: line) else {
            Issue.record("expected a toolResult record")
            return
        }
        // The id is an opaque pairing key containing '|'; never parsed.
        #expect(result.id == "call_CDXPvNPA1U69hZtEFTn5UoJR|y+sSKRvAXV0DDruBd8sDCuDVacPSg9kbIpsu")
        #expect(result.toolCallId == result.id)
        #expect(result.toolName == "read")
        #expect(result.isError == false)
        #expect(result.content == "line 1\n\nline 2")
    }

    @Test func toolResultWithoutCallIdIsSkipped() {
        let line = #"{"type":"message","message":{"role":"toolResult","toolName":"read","content":[]}}"#
        #expect(OmpTranscriptParser.parse(line: line) == nil)
    }

    @Test func malformedLinesAreToleratedMidStream() {
        // A live transcript can contain a truncated write; the rest of the
        // stream must still load.
        let good = #"{"type":"message","message":{"role":"user","content":[{"type":"text","text":"hello"}]}}"#
        let (messages, results) = OmpTranscriptParser.parse(
            lines: "{truncated", good, #"{"type":"message""#, good)
        #expect(messages.count == 2)
        #expect(results.isEmpty)
        guard case .text(let text)? = messages.first?.blocks.first else {
            Issue.record("expected a text block")
            return
        }
        #expect(text == "hello")
    }

    @Test func userMessageTimestampDecodesFromEpochMilliseconds() {
        let line = #"{"type":"message","message":{"role":"user","timestamp":1789292098261,"content":[{"type":"text","text":"hi"}]}}"#
        guard case .message(let message)? = OmpTranscriptParser.parse(line: line) else {
            Issue.record("expected a message record")
            return
        }
        #expect(message.timestamp == Date(timeIntervalSince1970: 1_789_292_098.261))
    }

    @Test func bashExecutionRecordYieldsBashExecutionMessage() {
        // The TUI's `!command` shell escape carries command/output instead
        // of a content array.
        let line = #"{"type":"message","message":{"role":"bashExecution","command":"git status","output":"clean"}}"#
        guard case .message(let message)? = OmpTranscriptParser.parse(line: line) else {
            Issue.record("expected a message record")
            return
        }
        #expect(message.role == .bashExecution)
        #expect(message.blocks == [.text("git status")])
    }

    @Test func whitespaceOnlyAndEmptyContentYieldNoMessage() {
        let blankText = #"{"type":"message","message":{"role":"user","content":[{"type":"text","text":"   "}]}}"#
        let noContent = #"{"type":"message","message":{"role":"assistant","content":[]}}"#
        #expect(OmpTranscriptParser.parse(line: blankText) == nil)
        #expect(OmpTranscriptParser.parse(line: noContent) == nil)
    }

    @Test func unknownRoleIsSkipped() {
        let line = #"{"type":"message","message":{"role":"newInAPiUpdate","content":[{"type":"text","text":"x"}]}}"#
        #expect(OmpTranscriptParser.parse(line: line) == nil)
    }

    /// The todo/task call+result records extracted verbatim from real omp
    /// sessions (Fixtures/Transcripts/omp-agent-management.jsonl): both are
    /// ordinary toolCall + toolResult records — evidence that no parser
    /// change is needed for visibility control.
    @Test func parsesRealTodoAndTaskRecords() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/Transcripts/omp-agent-management.jsonl")
        let raw = try String(contentsOf: url, encoding: .utf8)
        let lines = raw.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
        let (messages, results) = OmpTranscriptParser.parse(lines: lines)

        // One assistant turn carrying a `todo` call, one carrying a `task`
        // call.
        let calls = messages.flatMap(\.blocks).compactMap { block -> ToolCall? in
            guard case .toolCall(let call) = block else { return nil }
            return call
        }
        let names = calls.map(\.name).sorted()
        #expect(names == ["task", "todo", "todo"])
        // The real `todo` op is init/done — decoded as ordinary arguments.
        let ops = calls.filter { $0.name == "todo" }.compactMap {
            $0.arguments["op"]?.stringValue
        }
        #expect(ops == ["done", "done"])
        // Real opaque ids survive verbatim (never parsed).
        #expect(Set(calls.map(\.id)) == [
            "todo:0#5024a45c7c24404db0179f21b19ca365",
            "todo:1#d83d081d95474b46b85f12133ff68d2a",
            "chatcmpl-tool-26a54d122aa141b8868476c33250ab67",
        ])

        // Three paired toolResult records: two todo checklists and one
        // subagent-spawn report.
        #expect(results.count == 3)
        let resultNames = Set(results.map(\.toolName))
        #expect(resultNames == ["task", "todo"])
        // The todo result body IS the rendered checklist.
        let checklist = results.first { $0.toolName == "todo" }
        #expect(checklist?.content.hasPrefix("Remaining items") == true)
        #expect(checklist?.content.contains("[X] Parser slice (Chat/Transcript)") == true)
        // The task result reports spawned agents.
        let spawn = results.first { $0.toolName == "task" }
        #expect(spawn?.content.hasPrefix("Spawned 4 background agents using scout.") == true)
    }

    @Test func toolExecutionStartCustomRecordIsSkipped() {
        // Verbatim `custom` record from a real session: `tool_execution_start`
        // fires for EVERY tool (not just subagent spawns), so it stays noise.
        let line = #"{"type":"custom","customType":"tool_execution_start","data":{"toolCallId":"read_0_598377ff","toolName":"read","startedAt":"2026-09-17T14:29:53.291Z","args":{"path":"/Users/jhou/src"},"intent":"Listing current directory"},"id":"fb7b2429","parentId":"16ecd14c","timestamp":"2026-09-17T14:29:53.291Z"}"#
        #expect(OmpTranscriptParser.parse(line: line) == nil)
    }
}
