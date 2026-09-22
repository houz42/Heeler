import Foundation
import SwiftUI
import UIKit
import Testing

@testable import Heeler

// SPDX-License-Identifier: Apache-2.0
//
// The prefix-key insert contract: the pure helper the accessory bar's
// keys share. Insert at the cursor — middle, head, tail, empty draft —
// cursor advancing past the inserted character so the router's
// suggestion pass targets the new token, clamping stale selections the
// way UITextView clamps selectedRange. The suggestion retrigger itself is
// the store's existing contract (ChatComposerRouterTests covers
// `updateSuggestions`); here only the draft the bar feeds it.
//
// The layout sections cover the two device regressions: the bar docked as
// an inputAccessoryView must report exactly one key-row height (a hosted
// SwiftUI bar under-reports and the keyboard clipped it), and the text
// view must hug measured text instead of ballooning to the safe-area cap.

private func makeDependencies() -> ComposerRouterStore.Dependencies {
    ComposerRouterStore.Dependencies(
        hostID: UUID(),
        paneID: "wA:p1",
        levelStore: ChatDetailLevelStore(
            defaults: UserDefaults(suiteName: "ChatInputFieldSizingTests.\(UUID().uuidString)")
                ?? .standard),
        resolveAgent: { _ in nil },
        deliverMention: { _, _ in },
        bashIO: ComposerBashIO(
            createScratchPane: { _ in "scratch" },
            sendText: { _, _, _ in },
            readPaneText: { _, _ in "" }))
}

@Suite("Chat prefix keys")
struct ChatInputFieldSizingTests {
    // The prefix-key bar and its insert path are REMOVED (v2 user
    // decision: a Messages-clean composer; the / # @ ! command modes
    // still work from TYPED text — the router's own tests pin them).
    // What remains of this file: the text-view SIZE contract.

    @MainActor
    @Test func theFieldHugsOneLineInsteadOfBallooning() {
        // The clamp contract: one short line claims the 36 pt floor in
        // the WORKING (uncollapsed) frame; the v2 compact-resting change
        // tightened only the COLLAPSED floor (28, the row's control
        // height). Never the whole safe-area inset a scroll-enabled text
        // view would otherwise stretch to.
        let textView = ChatInputUITextView()
        textView.applyChatInputConfiguration()
        textView.text = "one short line"
        let size = ChatInputTextView.measuredSize(for: textView, width: 300)
        let lineHeight = textView.font?.lineHeight ?? 20
        #expect(size.height == 36)
        #expect(size.height < lineHeight * 5)
        #expect(!textView.isScrollEnabled)
    }

    @MainActor
    @Test func theFieldGrowsToTheThreeLineCapThenScrolls() {
        // Conversation redesign: focused-with-text grows bounded at
        // three lines; past the cap the field scrolls.
        let textView = ChatInputUITextView()
        textView.applyChatInputConfiguration()
        let longLine = String(repeating: "word ", count: 40)
        textView.text = longLine
        let size = ChatInputTextView.measuredSize(for: textView, width: 300)
        let lineHeight = textView.font?.lineHeight ?? 20
        #expect(size.height == lineHeight * 3)
        #expect(textView.isScrollEnabled)
    }

    @MainActor
    @Test func theCollapsedFieldClaimsOneLineRegardlessOfContent() {
        // Collapsed (empty draft or unfocused): a long draft still
        // claims exactly one line — the content scrolls in place; the
        // draft text itself is untouched (never cleared on blur).
        let textView = ChatInputUITextView()
        textView.applyChatInputConfiguration()
        let longLine = String(repeating: "word ", count: 40)
        textView.text = longLine
        let size = ChatInputTextView.measuredSize(
            for: textView, width: 300, collapsed: true)
        let lineHeight = textView.font?.lineHeight ?? 20
        // Collapsed = the one-line floor regardless of content (28 pt,
        // the compact resting row's control height): never grows to a
        // second line; content beyond it scrolls in place. The draft
        // text itself is untouched (never cleared on blur).
        #expect(size.height == 28)
        #expect(size.height < lineHeight * 2)
        #expect(textView.isScrollEnabled)
        #expect(textView.text == longLine)
    }
}
