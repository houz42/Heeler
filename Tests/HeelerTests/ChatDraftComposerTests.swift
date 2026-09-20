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

    @Test func userTypedPathStringsSurviveVerbatim() {
        // Attachment paths never live in the prose (removed at
        // tile-creation time), so a USER-TYPED path string is prose
        // and survives verbatim — never eaten by the composition.
        let draft = "look at /remote/pick.png for the details"
        let text = ChatDraftComposer.messageText(
            items: [image("/remote/some-other.png")], draft: draft)
        let lines = text.components(separatedBy: "\n")
        #expect(lines[0] == "/remote/some-other.png")
        #expect(lines[1] == "look at /remote/pick.png for the details")
    }

    @Test func multipleFilesPlusProseSend() {
        // The real send shape: two attachments + prose — all items
        // once, prose last, exactly once.
        let text = ChatDraftComposer.messageText(
            items: [
                image("/remote/a.png"),
                .file(id: "f1", name: "notes.md", remotePath: "/remote/notes.md"),
            ],
            draft: "review both please")
        #expect(text == "/remote/a.png\n/remote/notes.md\nreview both please")
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

struct OmpParserImageBlockTests {
    @Test func demoImageLineParsesWithImagesAndText() {
        let line = #"{"type":"message","id":"demo-images","timestamp":1789292118000,"message":{"role":"assistant","content":[{"type":"image","mimeType":"image/png","ref":"/home/demo/.local/share/omp/shot-1.png","byteLength":90},{"type":"image","mimeType":"image/png","ref":"/home/demo/.local/share/omp/shot-2.png","byteLength":90},{"type":"text","text":"Six verification captures from the run."}],"timestamp":1789292118000}}"#
        guard case .message(let message)? = OmpTranscriptParser.parse(line: line) else {
            Issue.record("demo-images line did not parse")
            return
        }
        var images = 0
        var texts = 0
        for block in message.blocks {
            if case .image = block { images += 1 }
            if case .text = block { texts += 1 }
        }
        #expect(images == 2)
        #expect(texts == 1)
    }
}
