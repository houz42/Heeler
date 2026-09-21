import Foundation
import Testing

@testable import Heeler

// SPDX-License-Identifier: Apache-2.0
//
// Item 18: a half-typed message survives leaving and returning to a
// chat — per-pane draft persistence, load/save/clear, with the
// restored caret and the removable-item rail's Codable form.

@Suite("Chat draft persistence")
struct ChatDraftPersistenceTests {
    private func makeStore() -> ChatDraftPersistenceStore {
        let suite = "dev.houz42.heeler.chat.tests.\(UUID().uuidString)"
        return ChatDraftPersistenceStore(
            defaults: UserDefaults(suiteName: suite) ?? .standard)
    }

    @Test("a saved draft round-trips per pane, isolated across panes")
    func roundTripPerPane() {
        let store = makeStore()
        let draft = ChatPaneDraft(
            text: "half-typed reply", caretLocation: 9, items: [
                .init(kind: .image, id: "img-1", remotePath: "/tmp/x.png", name: nil, text: nil, author: nil),
                .init(kind: .file, id: "f-1", remotePath: "/tmp/doc.md", name: "doc.md", text: nil, author: nil),
                .init(kind: .quote, id: "q-1", remotePath: nil, name: nil, text: "quoted words", author: "Heeler"),
            ])
        store.save(draft, paneID: "w1:p4")
        let other = ChatPaneDraft(text: "other pane", caretLocation: 0, items: [])
        store.save(other, paneID: "w1:p5")

        let restored = store.draft(paneID: "w1:p4")
        #expect(restored == draft)
        #expect(store.draft(paneID: "w1:p5") == other)
        #expect(store.draft(paneID: "never-seen") == nil)
    }

    @Test("an empty draft save clears the entry — a cleared composer stays cleared")
    func emptySaveClears() {
        let store = makeStore()
        store.save(
            ChatPaneDraft(text: "draft", caretLocation: 0, items: []),
            paneID: "w1:p4")
        #expect(store.draft(paneID: "w1:p4")?.text == "draft")
        store.save(
            ChatPaneDraft(text: "   ", caretLocation: 0, items: []),
            paneID: "w1:p4")
        #expect(store.draft(paneID: "w1:p4") == nil)
    }

    @Test("clear removes the entry (successful send starts clean)")
    func clearAfterSend() {
        let store = makeStore()
        store.save(
            ChatPaneDraft(text: "sent message", caretLocation: 0, items: []),
            paneID: "w1:p4")
        store.clear(paneID: "w1:p4")
        #expect(store.draft(paneID: "w1:p4") == nil)
    }

    @Test("whitespace-only text with no items counts as empty")
    func isEmptySemantics() {
        let blank = ChatPaneDraft(text: " \n ", caretLocation: 0, items: [])
        #expect(blank.isEmpty)
        let itemsOnly = ChatPaneDraft(
            text: "", caretLocation: 0,
            items: [.init(kind: .image, id: "i", remotePath: "/x.png", name: nil, text: nil, author: nil)])
        #expect(!itemsOnly.isEmpty)
    }

    @Test("pane ids percent-encode into distinct keys (no forging or collisions)")
    func keyIsolation() {
        #expect(
            ChatDraftPersistenceStore.key(paneID: "w1:p4")
                != ChatDraftPersistenceStore.key(paneID: "w1:p5"))
        #expect(
            ChatDraftPersistenceStore.key(paneID: "weird/pane id")
                == ChatDraftPersistenceStore.key(paneID: "weird/pane id"))
        #expect(!ChatDraftPersistenceStore.key(paneID: "x").contains(" "))
    }
}
