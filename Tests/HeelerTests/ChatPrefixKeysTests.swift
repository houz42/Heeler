import Foundation
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
}
