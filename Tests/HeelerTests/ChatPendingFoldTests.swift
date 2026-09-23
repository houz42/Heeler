import Foundation
import Testing

@testable import Heeler

// SPDX-License-Identifier: Apache-2.0
//
// The compact-foldable pending region's PURE model (design amendment):
// collapsed by default (view state — pinned by construction, not test),
// the summary counts, the three-preview cap, the attention
// classification, and the region's mount condition. The fold never
// mutates delivery state — the model only DERIVES from entries.

@MainActor
@Suite("Chat pending region compact fold model")
struct ChatPendingFoldTests {
    private func entry(
        _ text: String, status: AgentChatOutboxEntry.Status = .accepted,
        images: [AgentChatOutgoingImage] = [], isHidden: Bool = false
    ) -> ChatPendingEntry {
        ChatPendingEntry(
            text: text, images: images, ordinal: 0, status: status,
            failureMessage: nil, isHidden: isHidden)
    }

    // MARK: Mount condition (0 entries = absence)

    @Test("zero entries: the region never mounts (absence, not an empty frame)")
    func zeroEntriesAbsent() {
        #expect(!ChatPendingFoldModel.isPresent(entries: []))
        #expect(ChatPendingFoldModel.summaryCount(from: []) == 0)
        #expect(ChatPendingFoldModel.overflowCount(from: []) == 0)
    }

    @Test("only hidden entries: the region still mounts (the recovery row)")
    func hiddenOnlyStillMounts() {
        let entries = [
            entry("one", status: .rejected, isHidden: true),
            entry("two", status: .rejected, isHidden: true),
        ]
        #expect(ChatPendingFoldModel.isPresent(entries: entries))
        #expect(ChatPendingFoldModel.summaryCount(from: entries) == 0)
    }

    // MARK: 1 and 3 entries: previews and no overflow

    @Test("one entry: summary Pending 1, one preview, no overflow")
    func oneEntry() {
        let entries = [entry("hello")]
        #expect(ChatPendingFoldModel.summaryCount(from: entries) == 1)
        #expect(ChatPendingFoldModel.previews(from: entries).count == 1)
        #expect(ChatPendingFoldModel.overflowCount(from: entries) == 0)
    }

    @Test("three entries: exactly three previews, no overflow")
    func threeEntries() {
        let entries = (1...3).map { entry("m\($0)") }
        #expect(ChatPendingFoldModel.summaryCount(from: entries) == 3)
        #expect(ChatPendingFoldModel.previews(from: entries).count == 3)
        #expect(ChatPendingFoldModel.overflowCount(from: entries) == 0)
    }

    // MARK: 20 entries: the cap and the sheet's ownership

    @Test("twenty entries: three previews, seventeen overflow — never the whole stack inline")
    func twentyEntries() {
        let entries = (1...20).map { entry("m\($0)") }
        #expect(ChatPendingFoldModel.summaryCount(from: entries) == 20)
        let previews = ChatPendingFoldModel.previews(from: entries)
        #expect(previews.count == 3)
        #expect(previews.map(\.text) == ["m1", "m2", "m3"])  // submission order
        #expect(ChatPendingFoldModel.overflowCount(from: entries) == 17)
    }

    // MARK: Attention classification

    @Test("attention = rejected + outcome-unknown only (queued/accepted/committed never)")
    func attentionClassification() {
        let entries = [
            entry("queued", status: .locallyQueued),
            entry("accepted", status: .accepted),
            entry("rejected", status: .rejected),
            entry("unknown", status: .outcomeUnknown),
            entry("committed", status: .committed),
        ]
        #expect(ChatPendingFoldModel.attentionCount(from: entries) == 2)
    }

    @Test("hidden entries never count toward attention or the summary")
    func hiddenExcluded() {
        let entries = [
            entry("visible rejected", status: .rejected),
            entry("hidden rejected", status: .rejected, isHidden: true),
        ]
        #expect(ChatPendingFoldModel.attentionCount(from: entries) == 1)
        #expect(ChatPendingFoldModel.summaryCount(from: entries) == 1)
        #expect(ChatPendingFoldModel.previews(from: entries).map(\.text)
            == ["visible rejected"])
    }

    // MARK: Image-only previews

    @Test("an image-only entry previews by attachment count, never empty")
    func imageOnlyPreviewText() {
        let one = entry("", images: [
            AgentChatOutgoingImage(data: Data([1]), mimeType: "image/png"),
        ])
        let three = entry("", images: [
            AgentChatOutgoingImage(data: Data([1]), mimeType: "image/png"),
            AgentChatOutgoingImage(data: Data([2]), mimeType: "image/png"),
            AgentChatOutgoingImage(data: Data([3]), mimeType: "image/png"),
        ])
        #expect(ChatPendingFoldModel.previewText(for: one) == "Image")
        #expect(ChatPendingFoldModel.previewText(for: three) == "3 images")
        #expect(ChatPendingFoldModel.previewText(for: entry("prose"))
            == "prose")
    }

    // MARK: The fold mutates nothing

    @Test("every derivation is pure — the same entries read the same after any fold query")
    func foldNeverMutates() {
        var entries = (1...4).map { entry("m\($0)", status: .rejected) }
        entries.append(entry("m5", status: .rejected, isHidden: true))
        let before = entries
        // Derive everything (the fold's full read surface).
        _ = ChatPendingFoldModel.isPresent(entries: entries)
        _ = ChatPendingFoldModel.summaryCount(from: entries)
        _ = ChatPendingFoldModel.attentionCount(from: entries)
        _ = ChatPendingFoldModel.previews(from: entries)
        _ = ChatPendingFoldModel.overflowCount(from: entries)
        _ = entries.map { ChatPendingFoldModel.previewText(for: $0) }
        #expect(entries == before)  // statuses, keys, content untouched
    }
}
