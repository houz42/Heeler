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
            defaults: UserDefaults(suiteName: "ChatPrefixKeysTests.\(UUID().uuidString)")
                ?? .standard),
        resolveAgent: { _ in nil },
        deliverMention: { _, _ in },
        bashIO: ComposerBashIO(
            createScratchPane: { _ in "scratch" },
            sendText: { _, _, _ in },
            readPaneText: { _, _ in "" }))
}

@Suite("Chat prefix keys")
struct ChatPrefixKeysTests {
    // -- insert at the cursor --

    @Test func insertInAnEmptyDraftPlacesTheCharacterAndCursor() {
        let result = chatDraftByInserting("/", into: "", selection: 0)
        #expect(result.draft == "/")
        #expect(result.selection == 1)
    }

    @Test func insertAtTheTailAppendsAndAdvances() {
        let result = chatDraftByInserting("#", into: "note", selection: 4)
        #expect(result.draft == "note#")
        #expect(result.selection == 5)
    }

    @Test func insertBetweenCharactersSplitsAtTheCursor() {
        let result = chatDraftByInserting("@", into: "hi john", selection: 3)
        #expect(result.draft == "hi @john")
        #expect(result.selection == 4)
    }

    @Test func insertAtTheHeadOfADraft() {
        let result = chatDraftByInserting("!", into: "ls", selection: 0)
        #expect(result.draft == "!ls")
        #expect(result.selection == 1)
    }

    @Test func insertClampsAStaleSelectionPastTheEnd() {
        // A programmatic draft rewrite (suggestion accept, rejected-draft
        // restore) can leave a selection beyond the new text; UITextView
        // clamps selectedRange, so the helper must too.
        let result = chatDraftByInserting("#", into: "ab", selection: 9)
        #expect(result.draft == "ab#")
        #expect(result.selection == 3)
    }

    @Test func insertClampsANegativeSelection() {
        let result = chatDraftByInserting("/", into: "ab", selection: -2)
        #expect(result.draft == "/ab")
        #expect(result.selection == 1)
    }

    @Test func insertIntoADraftWhoseTextIsNotPureAsciiStillAnchors() {
        // UTF-16 offsets are what UITextView reports; emoji count as 2,
        // so the offset math must ride utf16, not Character counts.
        let result = chatDraftByInserting("@", into: "👋 there", selection: 2)
        #expect(result.draft == "👋@ there")
        #expect(result.selection == 3)
    }

    // -- the suggestion retrigger --

    @MainActor
    @Test func insertedSlashDraftOpensTheSuggestionMenu() {
        // The bar's end-to-end reason: the insert feeds
        // `updateSuggestions`, which must react to the resulting draft
        // exactly as if typed.
        let router = ComposerRouterStore(dependencies: makeDependencies())
        let insert = chatDraftByInserting("/", into: "", selection: 0)
        router.updateSuggestions(forDraft: insert.draft)
        #expect(router.hasActiveSuggestions)
        #expect(router.suggestions.contains { $0.title == "level" })
    }

    @MainActor
    @Test func insertInProseDoesNotNagWithSuggestions() {
        // Inserting mid-prose (cursor in the middle of a non-token draft)
        // must not open the menu: the router classifies by the active
        // token, and prose has none.
        let router = ComposerRouterStore(dependencies: makeDependencies())
        let insert = chatDraftByInserting("@", into: "hi john", selection: 3)
        router.updateSuggestions(forDraft: insert.draft)
        #expect(!router.hasActiveSuggestions)
    }

    // -- accessory bar layout (device regression: keyboard clipped it) --

    @MainActor
    @Test func theBarDeclaresExactlyOneKeyRowOfHeight() {
        // The keyboard docks the accessory at the height its constraints
        // declare. A hosted SwiftUI bar's intrinsic sizing under-reported
        // here and the keys were clipped behind the keyboard's top edge.
        let bar = ChatPrefixKeyBarView()
        bar.layoutIfNeeded()
        #expect(bar.systemLayoutSizeFitting(
            UIView.layoutFittingCompressedSize).height == 44)
    }

    @MainActor
    @Test func theBarIsTheTextViewsInputAccessorySoItDocksWithTheKeyboard() {
        let textView = ChatInputUITextView()
        #expect(textView.inputAccessoryView === textView.prefixBar)
        #expect(textView.prefixBar.onInsert != nil)
    }

    @MainActor
    @Test func theBarTapsInsertAtTheCursorThroughTheTextSystem() {
        let textView = ChatInputUITextView()
        let inserted = Recorder<String>()
        textView.onPrefixInsert = { newText, _ in inserted.append(newText) }

        // Drive the bar's action directly, the way a touch does.
        textView.text = "hi john"
        textView.selectedRange = NSRange(location: 3, length: 0)
        textView.insertPrefix(.mention)

        #expect(textView.text == "hi @john")
        #expect(textView.selectedRange.location == 4)
        #expect(inserted.all == ["hi @john"])
    }

    @MainActor
    @Test func theBarsInsertIsWiredAtInitSoADockTapAlwaysWorks() {
        // The bar's button action is installed in the text view's init,
        // before any SwiftUI layout pass — a keyboard that docks early
        // can never observe an unwired bar.
        let textView = ChatInputUITextView()
        #expect(textView.prefixBar.onInsert != nil)
    }

    // -- field sizing (device regression: frame ballooned) --

    @MainActor
    @Test func theFieldHugsOneLineInsteadOfBallooning() {
        // The clamp contract: one short line claims the 36 pt floor (the
        // same floor the Composer's editor uses), never the whole
        // safe-area inset a scroll-enabled text view would otherwise
        // stretch to.
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
        // Collapsed = the one-line floor regardless of content: never
        // grows to a second line; content beyond it scrolls in place.
        // The draft text itself is untouched (never cleared on blur).
        #expect(size.height == 36)
        #expect(size.height < lineHeight * 2)
        #expect(textView.isScrollEnabled)
        #expect(textView.text == longLine)
    }
}

/// Thread-safe capture for closures that cross isolation boundaries.
private final class Recorder<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [Value] = []

    var all: [Value] {
        lock.lock()
        defer { lock.unlock() }
        return items
    }

    func append(_ item: Value) {
        lock.lock()
        defer { lock.unlock() }
        items.append(item)
    }
}
