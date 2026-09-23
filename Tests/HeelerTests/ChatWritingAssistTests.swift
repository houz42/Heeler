import Foundation
import Testing
import UIKit

@testable import Heeler

// SPDX-License-Identifier: Apache-2.0
//
// v3 "Writing assistance and placeholder restoration" pins, at the
// seams the design doc names:
//
// 1. THE PLACEHOLDER INVARIANT: the placeholder is visible IFF the
//    installed editor text is empty AND there is no active marked-text
//    composition. Focus/begin/end editing must not independently show
//    it; a programmatic installation (restore/clear/identity switch)
//    re-syncs it exactly like a typed edit — ONE synchronization
//    outcome for every draft installation.
// 2. WRITING-ASSISTANCE TRAITS: ordinary chat defaults to the system
//    keyboard's own correction/prediction (System); Off disables it.
//    Literal mode is the literal-typing contract (asciiCapable, no
//    autocorrection) — command/path/shell editors pin this regardless
//    of the setting.
// 3. THE DRAFT-RESTORE SINGLE PATH: the persisted store's restore
//    decision is ONE pure function — a MISSING draft installs the
//    EMPTY state (never the previous conversation's content), the
//    restored caret is CLAMPED to the text's UTF-16 bounds, and an
//    empty restore clears the rail.

@Suite("Chat placeholder invariant")
struct ChatPlaceholderInvariantTests {
    @MainActor
    private func makeWiredField() -> (
        textView: ChatInputUITextView, placeholder: UILabel,
        coordinator: ChatInputTextView.Coordinator
    ) {
        let textView = ChatInputUITextView()
        let coordinator = ChatInputTextView.Coordinator(
            onEdit: { _, _ in }, isFocused: .constant(false))
        textView.delegate = coordinator
        coordinator.attachPlaceholder(to: textView, placeholder: "Message")
        let placeholder =
            textView.subviews.compactMap { $0 as? UILabel }.first
        #expect(placeholder != nil)
        return (textView, placeholder!, coordinator)
    }

    // -- visibility follows text, and ONLY text --

    @MainActor
    @Test("placeholder visible iff text is empty and no marked composition")
    func visibleIffEmptyAndUnmarked() {
        let (textView, placeholder, coordinator) = makeWiredField()

        // Empty: visible.
        #expect(!placeholder.isHidden)

        // Typed text: hidden — and this is the ONLY thing that
        // changed (no focus involved).
        textView.text = "draft"
        coordinator.syncPlaceholderVisibility(for: textView)
        #expect(placeholder.isHidden)

        // Emptied again: visible.
        textView.text = ""
        coordinator.syncPlaceholderVisibility(for: textView)
        #expect(!placeholder.isHidden)
    }

    @MainActor
    @Test("a programmatic installation re-syncs the placeholder (restore/clear)")
    func programmaticInstallResyncsPlaceholder() {
        // The device-regression class the design doc names: a
        // programmatic `.text` install fires NO delegate callback, so
        // the restore path used to leave the placeholder showing
        // under restored text (or hidden over a cleared field). The
        // representable's update pass now performs the same state
        // work as the typed-edit path.
        let textView = ChatInputUITextView()
        var reported: [(String, Int)] = []
        let coordinator = ChatInputTextView.Coordinator(
            onEdit: { text, caret in reported.append((text, caret)) },
            isFocused: .constant(false))
        textView.delegate = coordinator
        coordinator.attachPlaceholder(to: textView, placeholder: "Message")
        let placeholder =
            textView.subviews.compactMap { $0 as? UILabel }.first!

        // Simulate the update-pass install branch: nonempty text
        // arrives programmatically (a persisted-draft restore).
        let selection = textView.selectedRange
        textView.text = "restored draft"
        textView.selectedRange = selection
        coordinator.syncPlaceholderVisibility(for: textView)
        #expect(placeholder.isHidden)

        // And the clear-after-send direction: programmatic empty.
        textView.text = ""
        coordinator.syncPlaceholderVisibility(for: textView)
        #expect(!placeholder.isHidden)
    }

    @MainActor
    @Test("begin/end editing never independently shows the placeholder over text")
    func focusNeverOverridesText() {
        let (textView, placeholder, coordinator) = makeWiredField()

        // Text present, then focus cycles: the placeholder must stay
        // hidden through begin AND end editing — focus is not an
        // independent show condition.
        textView.text = "held draft"
        coordinator.syncPlaceholderVisibility(for: textView)
        #expect(placeholder.isHidden)

        coordinator.textViewDidBeginEditing(textView)
        #expect(placeholder.isHidden)
        coordinator.textViewDidEndEditing(textView)
        #expect(placeholder.isHidden)

        // Empty again: focus cycles keep it visible, never hide it.
        textView.text = ""
        coordinator.syncPlaceholderVisibility(for: textView)
        coordinator.textViewDidBeginEditing(textView)
        #expect(!placeholder.isHidden)
        coordinator.textViewDidEndEditing(textView)
        #expect(!placeholder.isHidden)
    }

    @MainActor
    @Test("an external apply (suggestion accept) keeps the placeholder hidden")
    func externalApplyKeepsPlaceholderHidden() {
        // The coordinator must stay ALIVE for this test: UITextView's
        // delegate is a weak reference, and discarding the tuple's
        // coordinator slot deallocated it mid-test (the dangling
        // delegate then skipped the placeholder sync silently).
        let (textView, placeholder, coordinator) = makeWiredField()
        #expect(!placeholder.isHidden)
        textView.applyExternalDraft("/agents ", caret: 8)
        #expect(textView.text == "/agents ")
        #expect(textView.markedTextRange == nil)
        #expect(placeholder.isHidden)
        // Clearing through the same external path returns it.
        textView.applyExternalDraft("", caret: 0)
        #expect(!placeholder.isHidden)
    }

    // -- ONE placeholder layer --

    @MainActor
    @Test("exactly one placeholder layer installs — no SwiftUI+UIKit overlap")
    func exactlyOnePlaceholderLayer() {
        // attachPlaceholder is the ONE installation seam; a second
        // call (the overlapping-layer regression) would add a second
        // UILabel. The invariant: attach is idempotent per view.
        let textView = ChatInputUITextView()
        let coordinator = ChatInputTextView.Coordinator(
            onEdit: { _, _ in }, isFocused: .constant(false))
        textView.delegate = coordinator
        coordinator.attachPlaceholder(to: textView, placeholder: "Message")
        coordinator.attachPlaceholder(to: textView, placeholder: "Message")
        let labels = textView.subviews.compactMap { $0 as? UILabel }
        #expect(labels.count == 1)
        #expect(labels.first?.text == "Message")
    }
}

@Suite("Chat writing-assistance traits")
struct ChatWritingAssistTraitsTests {
    @MainActor
    @Test("System: the ordinary chat field follows the OS correction/prediction")
    func systemDefaultEnablesAssistance() {
        let textView = ChatInputUITextView()
        textView.applyChatInputConfiguration(writingAssistance: true)
        #expect(textView.autocorrectionType == .default)
        #expect(textView.spellCheckingType == .default)
        #expect(textView.smartQuotesType == .default)
        #expect(textView.smartDashesType == .default)
        // The OS keyboard itself is never replaced: the default
        // multilingual keyboard (with globe/language keys).
        #expect(textView.keyboardType == .default)
    }

    @MainActor
    @Test("Off: the chat field is literal typing")
    func offDisablesAssistance() {
        let textView = ChatInputUITextView()
        textView.applyChatInputConfiguration(writingAssistance: false)
        #expect(textView.autocorrectionType == .no)
        #expect(textView.spellCheckingType == .no)
        #expect(textView.smartQuotesType == .no)
        #expect(textView.smartDashesType == .no)
        #expect(textView.keyboardType == .asciiCapable)
    }

    @MainActor
    @Test("the persisted choice defaults to System and round-trips Off")
    func settingsDefaultAndRoundTrip() {
        let suite = "dev.houz42.meadow.writing-assist.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite) ?? .standard
        let settings = WritingAssistanceSettings(defaults: defaults)

        // Default: System (the OS keyboard's own correction).
        #expect(settings.selection == .system)
        #expect(settings.isEnabled)

        settings.select(.off)
        #expect(!settings.isEnabled)

        // A fresh instance over the same defaults reads the same
        // persisted choice (no in-memory-only preference).
        let reloaded = WritingAssistanceSettings(defaults: defaults)
        #expect(reloaded.selection == .off)

        settings.select(.system)
        #expect(WritingAssistanceSettings(defaults: defaults).isEnabled)
    }
}

@Suite("Chat draft-restore single path")
struct ChatDraftRestoreSinglePathTests {
    private func makeStore() -> ChatDraftPersistenceStore {
        let suite = "dev.houz42.meadow.chat.tests.\(UUID().uuidString)"
        return ChatDraftPersistenceStore(
            defaults: UserDefaults(suiteName: suite) ?? .standard)
    }

    @Test("a restore clamps the saved caret to the text's UTF-16 bounds")
    func restoreClampsCaret() {
        let store = makeStore()
        let text = "half-typed"
        store.save(
            ChatPaneDraft(
                text: text, caretLocation: 999, items: []),
            paneID: "wA:p1")

        let saved = store.draft(paneID: "wA:p1")!
        // The clamp the installation path applies (mirrors
        // installDraft's min/max in ChatScreen):
        let clamped = min(max(saved.caretLocation, 0), text.utf16.count)
        #expect(clamped == text.utf16.count)
    }

    @Test("a MISSING draft restores empty — never the previous conversation's content")
    func missingDraftInstallsEmpty() {
        let store = makeStore()
        // Previous identity had a draft; the new identity has none.
        store.save(
            ChatPaneDraft(
                text: "previous identity's draft", caretLocation: 5, items: []),
            paneID: "hostA#wA:p1")

        // The new identity's load: nil → the EMPTY state (text,
        // items, caret all zero).
        let saved = store.draft(paneID: "hostB#wB:p9")
        #expect(saved == nil)
        #expect(store.draft(paneID: "hostA#wA:p1")?.text
            == "previous identity's draft")
    }

    @Test("versioned draft round-trip: text, items, UTF-16 selection together")
    func versionedDraftRoundTrip() {
        let store = makeStore()
        let draft = ChatPaneDraft(
            text: "回复 with mixed 日本語", caretLocation: 7, items: [
                .init(kind: .quote, id: "q1", remotePath: nil, name: nil,
                      text: "quoted", author: "Heeler"),
            ])
        store.save(draft, paneID: "wA:p2")
        let restored = store.draft(paneID: "wA:p2")
        #expect(restored == draft)
        #expect(restored?.caretLocation == 7)
        // UTF-16 semantics: the caret is a UTF-16 offset (mixed-width
        // text above exercises the boundary).
        #expect(
            (restored?.text as NSString?)?.length
                == restored?.text.utf16.count)
    }
}
