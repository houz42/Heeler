import Testing
import UIKit
@testable import Heeler

// SPDX-License-Identifier: Apache-2.0
//
// The draft-composition send contract (review fix 2): every draft
// item rides EXACTLY ONCE, the user's prose survives verbatim (minus
// picker-inserted path strings), and paste-image paths (never in the
// draft) still deliver. Plus the rail's boundary-correct overflow
// arithmetic (review fix 5).

@MainActor
struct ChatDraftComposerTests {

    private func image(_ path: String) -> ChatDraftItem {
        .image(id: "i-\(path)", remotePath: path, previewData: nil)
    }

    @Test func pasteImageAloneIsTheMessage() {
        let text = ChatDraftComposer.messageText(
            items: [image("/remote/pasted.png")], draft: "")
        #expect(text == "/remote/pasted.png")
    }

    @Test func everyAttachmentRidesExactlyOnce() {
        // Two images + one file + prose: all three paths lead, prose
        // last, each path once.
        let text = ChatDraftComposer.messageText(
            items: [
                image("/remote/a.png"),
                .file(id: "f1", name: "notes.md", remotePath: "/remote/notes.md"),
                image("/remote/b.png"),
            ],
            draft: "please review")
        let lines = text.components(separatedBy: "\n")
        #expect(lines.count == 4)
        #expect(lines[0] == "/remote/a.png")
        #expect(lines[1] == "/remote/notes.md")
        #expect(lines[2] == "/remote/b.png")
        #expect(lines[3] == "please review")
    }

    @Test func pickerPathLeavesTheProseExactlyOnce() {
        // The picker inserted the path into the draft; the composition
        // strips it from the prose (it rides as the attachment line).
        let draft = "/remote/pick.png here is my note"
        let text = ChatDraftComposer.messageText(
            items: [image("/remote/pick.png")], draft: draft)
        let lines = text.components(separatedBy: "\n")
        #expect(lines[0] == "/remote/pick.png")
        #expect(lines[1] == "here is my note")
    }

    @Test func quotesDeliverBlockQuotedAndProsePreserved() {
        let text = ChatDraftComposer.messageText(
            items: [.quote(id: "q1", text: "quoted body", author: "Heeler")],
            draft: "my reply")
        let lines = text.components(separatedBy: "\n")
        #expect(lines.first!.contains("quoted body"))
        #expect(lines.last == "my reply")
        #expect(ChatQuote.draft(for: "quoted body") == "> quoted body\n\n")
    }
}

struct ChatDraftTileRailArithmeticTests {

    @Test func twoTilesPlusGapFitsExactly104() {
        // Review fix 5: 2x48 + one 8 gap = 104 fits — the naive
        // floor(104/56)=1 was wrong.
        #expect(ChatDraftTileRail.fits(width: 104) == 2)
    }

    @Test func oneTileShortOfTwoDoesNotFit() {
        #expect(ChatDraftTileRail.fits(width: 103) == 1)
        #expect(ChatDraftTileRail.fits(width: 56) == 1)
        #expect(ChatDraftTileRail.fits(width: 47) == 0)
    }

    @Test func fiveTilesNeedFullRow() {
        // 5 tiles: 5*48 + 4*8 = 272.
        #expect(ChatDraftTileRail.fits(width: 272) == 5)
        #expect(ChatDraftTileRail.fits(width: 271) == 4)
    }
}
