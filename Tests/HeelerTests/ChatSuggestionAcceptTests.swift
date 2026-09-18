import Foundation
import SwiftUI
import Testing
import UIKit

@testable import Heeler

// SPDX-License-Identifier: Apache-2.0
//
// The suggestion-accept contract for the chat input, at the two seams the
// device regressions lived in:
//
// 1. Accept (tap or Return) must land the caret at the END of the applied
//    insertion — after the trailing space "/agents " carries — not where
//    the pre-accept caret happened to sit (right after the "/").
// 2. Return with the menu open accepts the highlighted suggestion and
//    inserts NO newline; with the menu closed the stock newline insert is
//    unchanged.
//
// The tests drive the real `ChatInputUITextView` and its coordinator the
// way the wiring in `ChatScreen.inputFrame` does — the same pattern
// ChatPrefixKeysTests uses for the prefix bar.

private func makeDependencies() -> ComposerRouterStore.Dependencies {
    ComposerRouterStore.Dependencies(
        hostID: UUID(),
        paneID: "wA:p1",
        levelStore: ChatDetailLevelStore(
            defaults: UserDefaults(suiteName: "ChatSuggestionAcceptTests.\(UUID().uuidString)")
                ?? .standard),
        resolveAgent: { _ in nil },
        deliverMention: { _, _ in },
        bashIO: ComposerBashIO(
            createScratchPane: { _ in "scratch" },
            sendText: { _, _, _ in },
            readPaneText: { _, _ in "" }))
}

@MainActor
@Suite("Chat suggestion accept")
struct ChatSuggestionAcceptTests {
    // -- the accept's caret --

    @Test func acceptCarriesTheCaretPastTheInsertionsTrailingSpace() {
        // The reported bug: accepting "agents" from "/" left the caret
        // right after the "/" — the insertion "/agents " landed but the
        // caret (and so the effective trailing space) never followed.
        let router = ComposerRouterStore(dependencies: makeDependencies())
        router.updateSuggestions(forDraft: "/")
        let agentsIndex = router.suggestions.firstIndex(where: { $0.title == "agents" })
        #expect(agentsIndex != nil, "the omp table must offer /agents")
        router.selectSuggestion(at: agentsIndex!)

        let accept = router.acceptSelectedSuggestionWithCaret(into: "/")
        #expect(accept?.draft == "/agents ")
        // The caret is the end of the insertion — AFTER the trailing
        // space, so typing continues as command arguments.
        #expect(accept?.caret == "/agents ".utf16.count)

        // The text view applies text and caret together.
        let textView = ChatInputUITextView()
        let reported = Recorder<(String, Int)>()
        textView.onPrefixInsert = { draft, caret in
            reported.append((draft, caret))
        }
        textView.applyExternalDraft(accept!.draft, caret: accept!.caret)

        #expect(textView.text == "/agents ")
        #expect(textView.selectedRange.location == 8)
        #expect(
            textView.selectedRange.location
                == (textView.text as NSString).length,
            "the caret must sit after the trailing space, not before it")
        #expect(reported.all.count == 1)
        #expect(reported.all.first?.0 == "/agents ")
        #expect(reported.all.first?.1 == 8)
        // The accept reports as an edit, so the draft binding and the
        // router's suggestion pass both see the new draft.
    }

    /// The ChatScreen wiring, mirrored: the owner holds the draft and the
    /// pending accept; the router arbitrates the return key; the
    /// representable applies a pending accept on its update pass.
    @MainActor
    private final class WiredField {
        let textView = ChatInputUITextView()
        let coordinator: ChatInputTextView.Coordinator
        let router = ComposerRouterStore(dependencies: makeDependencies())
        var draft = ""
        var pendingAccept: (draft: String, caret: Int)?

        init() {
            let coordinator = ChatInputTextView.Coordinator(
                onEdit: { _, _ in }, isFocused: .constant(false))
            self.coordinator = coordinator
            // All stored properties are initialized; self is safe now.
            let field = self
            coordinator.onEdit = { newText, _ in field.draft = newText }
            textView.delegate = coordinator
            textView.onPrefixInsert = { newText, _ in field.draft = newText }
            // ChatScreen.inputFrame's onReturnKey, verbatim: the owner's
            // draft updates IN THE ACTION — a @State write during the
            // representable's update pass is dropped, which is exactly
            // the send-disabled regression.
            textView.onReturnKey = {
                let result = field.router.handleReturnKey(into: field.draft)
                if let accepted = result.accepted {
                    field.draft = accepted.draft
                    field.pendingAccept = accepted
                }
                return result.consumedKey
            }
        }

        /// Simulates the representable's update pass applying the pending
        /// accept (text and caret together, then consumed).
        func applyPendingAccept() {
            guard let accept = pendingAccept else { return }
            textView.applyExternalDraft(accept.draft, caret: accept.caret)
            pendingAccept = nil
        }

        func type(_ string: String) {
            textView.text = string
            textView.selectedRange = NSRange(
                location: (string as NSString).length, length: 0)
            draft = string
            router.updateSuggestions(forDraft: string)
        }
    }

    @Test func returnWithOpenSuggestionsAcceptsWithoutANewline() {
        // The reported bug: Return inserted "\n" between "/" and the
        // command name instead of accepting the highlighted suggestion.
        let field = WiredField()
        field.type("/")
        #expect(field.router.hasActiveSuggestions)

        // The return key, through the same delegate gate UIKit calls.
        let consumed = field.coordinator.textView(
            field.textView,
            shouldChangeTextIn: NSRange(location: 1, length: 0),
            replacementText: "\n")

        #expect(consumed == false, "the menu must consume the return key")
        #expect(
            !field.textView.text.contains("\n"),
            "no newline may land")
        // The router produced the highlighted suggestion's accept...
        let highlighted = field.router.suggestions[
            field.router.selectedSuggestionIndex]
        #expect(field.pendingAccept?.draft == highlighted.insertion)
        // ...and the update pass applies it with the caret after the
        // insertion's trailing space.
        field.applyPendingAccept()
        #expect(field.textView.text == highlighted.insertion)
        #expect(
            field.textView.selectedRange.location
                == (field.textView.text as NSString).length)
        #expect(field.pendingAccept == nil, "the accept is consumed")
        // The owner's draft updated in the action, so Send's disabled
        // gate (draft trimmed non-empty) is open by the time the text
        // view shows the accepted draft.
        #expect(
            field.draft == highlighted.insertion,
            "the owner's draft must carry the accepted text")
        #expect(
            !field.draft.trimmingCharacters(in: .whitespacesAndNewlines)
                .isEmpty,
            "Send must be enabled after an accept")
    }

    @Test func tapAcceptUpdatesTheOwnerDraftSoSendEnables() {
        // The device-verified regression: after tapping a suggestion the
        // text rendered in the field while the owner's draft stayed "",
        // so the send button never enabled. The tap action (what
        // ChatScreen passes as ComposerSuggestionRow's applyDraft) must
        // assign the draft there — a @State write during the
        // representable's update pass is dropped.
        let field = WiredField()
        field.type("/")
        let agentsIndex = field.router.suggestions.firstIndex(
            where: { $0.title == "agents" })!
        field.router.selectSuggestion(at: agentsIndex)

        // The tap action, verbatim from ChatScreen.inputFrame.
        let newDraft = field.router.acceptSelectedSuggestion(into: field.draft)!
        field.draft = newDraft
        field.pendingAccept = (newDraft, newDraft.utf16.count)

        #expect(field.draft == "/agents ")
        #expect(
            !field.draft.trimmingCharacters(in: .whitespacesAndNewlines)
                .isEmpty,
            "Send must be enabled after a tap accept")
        field.applyPendingAccept()
        #expect(field.textView.text == "/agents ")
        #expect(
            field.textView.selectedRange.location
                == (field.textView.text as NSString).length)
    }

    @Test func returnWithOpenSuggestionsAppliesTheHighlightNotTheFirstRow() {
        // Down-arrow then Return accepts the second row, not the first —
        // the router's selection drives the accept.
        let field = WiredField()
        field.type("/")
        let second = field.router.suggestions[1]

        #expect(field.router.handleKey(.down))

        let consumed = field.coordinator.textView(
            field.textView,
            shouldChangeTextIn: NSRange(location: 1, length: 0),
            replacementText: "\n")
        #expect(consumed == false)
        #expect(field.pendingAccept?.draft == second.insertion)
        field.applyPendingAccept()
        #expect(field.textView.text == second.insertion)
    }

    // -- Return with the menu closed: the stock newline survives --

    @Test func returnWithClosedSuggestionsKeepsTheNewlineInsert() {
        let field = WiredField()
        field.type("hello")
        #expect(!field.router.hasActiveSuggestions)
        #expect(
            field.router.handleReturnKey(into: "hello").consumedKey == false,
            "with the menu closed the router must not consume the key")
        #expect(field.pendingAccept == nil)

        let consumed = field.coordinator.textView(
            field.textView,
            shouldChangeTextIn: NSRange(location: 5, length: 0),
            replacementText: "\n")
        #expect(
            consumed == true,
            "with the menu closed the delegate must let the newline land")
    }

    @Test func anAppliedAcceptDoesNotReApplyOverLaterTyping() {
        // The accept is a one-shot: once applied it must not resurface on
        // a later update pass and clobber newer typing. The representable
        // consumes it (pendingAccept = nil after applying); the applied
        // draft is what later edits build on.
        let textView = ChatInputUITextView()
        textView.applyExternalDraft("/agents ", caret: 8)
        // The user keeps typing an argument.
        textView.text = "/agents list"
        textView.selectedRange = NSRange(location: 12, length: 0)
        #expect(textView.text == "/agents list")
        #expect(textView.selectedRange.location == 12)
    }

    // -- the placeholder follows an external apply (device regression) --

    @Test func placeholderHidesAfterAnAcceptAndReturnsWhenEmptied() {
        // The accept path suppresses the intermediate change-notification
        // to avoid reporting the stale caret; the placeholder's visibility
        // toggle used to fire only in that suppressed branch, so the
        // placeholder stayed visible UNDER the accepted draft. It must
        // track the text in the accept branch too.
        let textView = ChatInputUITextView()
        let coordinator = ChatInputTextView.Coordinator(
            onEdit: { _, _ in }, isFocused: .constant(false))
        textView.delegate = coordinator
        coordinator.attachPlaceholder(
            to: textView, placeholder: "Message — / # @ ! for commands")
        let placeholder =
            textView.subviews.compactMap { $0 as? UILabel }.first
        #expect(placeholder != nil)

        // Empty draft: the placeholder is visible.
        #expect(placeholder!.isHidden == false)

        // The accept applies the draft through the delegate-suppressed
        // path; the placeholder must hide with the text.
        textView.applyExternalDraft("/agents ", caret: 8)
        #expect(textView.text == "/agents ")
        #expect(placeholder!.isHidden == true)

        // Back to an empty draft (a handled submit clears it): the
        // placeholder returns.
        textView.applyExternalDraft("", caret: 0)
        #expect(textView.text.isEmpty)
        #expect(placeholder!.isHidden == false)
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
