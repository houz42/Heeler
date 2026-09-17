import Foundation
import Testing

@testable import Heeler

// SPDX-License-Identifier: Apache-2.0
//
// ChatScreen scroll paging (Phase 5): the trigger's contract — one
// loadOlder fire per gesture window — plus the store's older-page merge,
// which must PREPEND (older history renders above what is already shown).

// MARK: - The gate: one fire per gesture window

@Suite("Chat scroll paging gate")
struct ChatScrollPagingTests {
    @Test func arrivingAtTheTopWithOlderHistoryFiresOnce() {
        var gate = ChatPagingGate()
        let gateResult1 = gate.update(sentinelVisible: true, hasOlder: true, isLoadingOlder: false)
        #expect(gateResult1)
        // Holding at the top re-reports the same inputs on every layout
        // pass; the latch holds.
        let gateResult2 = gate.update(sentinelVisible: true, hasOlder: true, isLoadingOlder: false)
        #expect(!gateResult2)
        let gateResult3 = gate.update(sentinelVisible: true, hasOlder: true, isLoadingOlder: false)
        #expect(!gateResult3)
    }

    @Test func noOlderHistoryOrAnInFlightLoadNeverFires() {
        var gate = ChatPagingGate()
        let gateResult4 = gate.update(sentinelVisible: true, hasOlder: false, isLoadingOlder: false)
        #expect(!gateResult4)
        let gateResult5 = gate.update(sentinelVisible: true, hasOlder: true, isLoadingOlder: true)
        #expect(!gateResult5)
        // Older becomes available only once the user is still at the top.
        let gateResult6 = gate.update(sentinelVisible: true, hasOlder: true, isLoadingOlder: false)
        #expect(gateResult6)
    }

    @Test func leavingTheTopReArmsForTheNextPage() {
        var gate = ChatPagingGate()
        let gateResult7 = gate.update(sentinelVisible: true, hasOlder: true, isLoadingOlder: false)
        #expect(gateResult7)
        // The load lands (busy falls) while the user still holds at the
        // top: still latched — one page per gesture window.
        let gateResult8 = gate.update(sentinelVisible: true, hasOlder: true, isLoadingOlder: true)
        #expect(!gateResult8)
        let gateResult9 = gate.update(sentinelVisible: true, hasOlder: true, isLoadingOlder: false)
        #expect(!gateResult9)
        // Scrolling away ends the gesture window; coming back is a new one.
        let gateResult10 = gate.update(sentinelVisible: false, hasOlder: true, isLoadingOlder: false)
        #expect(!gateResult10)
        let gateResult11 = gate.update(sentinelVisible: true, hasOlder: true, isLoadingOlder: false)
        #expect(gateResult11)
        let gateResult12 = gate.update(sentinelVisible: true, hasOlder: true, isLoadingOlder: false)
        #expect(!gateResult12)
    }

    @Test func exhaustedHistoryCannotRelatch() {
        var gate = ChatPagingGate()
        let gateResult13 = gate.update(sentinelVisible: true, hasOlder: true, isLoadingOlder: false)
        #expect(gateResult13)
        let gateResult14 = gate.update(sentinelVisible: false, hasOlder: false, isLoadingOlder: false)
        #expect(!gateResult14)
        // The window now reaches byte 0: arriving at the top again must not
        // fire, and later hasOlder edges stay inert until history exists.
        let gateResult15 = gate.update(sentinelVisible: true, hasOlder: false, isLoadingOlder: false)
        #expect(!gateResult15)
    }

    @Test func triggerFiresTheStubStoreExactlyOncePerGestureWindow() async {
        // The view-level sequence end-to-end against a counting stub: the
        // gate's fire is the view's loadOlder call.
        final class CountingStore: @unchecked Sendable {
            let lock = NSLock()
            private var calls = 0
            var callCount: Int {
                lock.lock(); defer { lock.unlock() }
                return calls
            }
            func loadOlder() {
                lock.lock(); defer { lock.unlock() }
                calls += 1
            }
        }
        let stub = CountingStore()
        var gate = ChatPagingGate()
        var hasOlder = true
        var isLoadingOlder = false

        // One gesture window: arrive at the top (one fire), hold (none),
        // load in flight (none), load done (none), leave (none), return
        // (one fire for the next page).
        func step(sentinelVisible: Bool) {
            if gate.update(
                sentinelVisible: sentinelVisible, hasOlder: hasOlder,
                isLoadingOlder: isLoadingOlder)
            {
                stub.loadOlder()
            }
        }
        step(sentinelVisible: true)
        isLoadingOlder = true
        step(sentinelVisible: true)
        isLoadingOlder = false
        step(sentinelVisible: true)
        step(sentinelVisible: false)
        step(sentinelVisible: true)
        #expect(stub.callCount == 2)

        // Exhausting history: no further fire across any number of returns.
        hasOlder = false
        step(sentinelVisible: false)
        step(sentinelVisible: true)
        #expect(stub.callCount == 2)
    }
}

// MARK: - Older-page merge prepends

@MainActor
@Suite("Chat older-page merge")
struct ChatOlderPageMergeTests {
    private func userLine(_ text: String) -> String {
        #"{"type":"message","message":{"role":"user","content":[{"type":"text","text":"\#(text)"}]}}"#
    }

    @Test func olderLinesLandBeforeTheExistingRows() {
        let existing = ChatContent(messages: [
            ChatMessage(
                id: UUID(uuidString: "AAAAAAAA-0000-0000-0000-000000000002")!,
                role: .user, blocks: [.text("second")], timestamp: nil),
        ])
        let merged = ChatStore.mergeOlderLines(
            [userLine("first")], into: existing)
        #expect(merged.messages.map { msg -> String? in
            if case .text(let text)? = msg.blocks.first { return text } else { return nil }
        } == ["first", "second"])
    }

    @Test func mergeOlderLinesNeverTouchesToolResultsOrder() {
        let existing = ChatContent(toolResults: [
            ToolResult(toolCallId: "keep", toolName: "read", isError: false, content: "kept"),
        ])
        let merged = ChatStore.mergeOlderLines(
            [#"{"type":"message","message":{"role":"toolResult","toolCallId":"old","toolName":"read","content":[{"type":"text","text":"older"}]}}"#],
            into: existing)
        // The older result prepends; pairing by id is the filtering layer's
        // job, order here is all this seam owns.
        #expect(merged.toolResults.map(\.toolCallId) == ["old", "keep"])
    }
}
