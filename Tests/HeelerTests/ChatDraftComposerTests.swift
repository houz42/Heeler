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

    @Test func imageNeverAppearsInProse() {
        // Review round 6, finding 3: an image rides the structured
        // prompt.send images array ONLY — its staged path is NEVER
        // appended as '@path' prose (the '@…jpg leaking as text' bug:
        // the model received the bytes AND a literal path line).
        let text = ChatDraftComposer.messageText(
            items: [image("/remote/pasted.png")], draft: "")
        #expect(text.isEmpty)
    }

    @Test func filesReferenceAsAtImagesDoNot() {
        let text = ChatDraftComposer.messageText(
            items: [
                image("/remote/a.png"),
                .file(id: "f1", name: "notes.md", remotePath: "/remote/notes.md"),
                image("/remote/b.png"),
            ],
            draft: "please review")
        // Prose + ONLY the file reference. The two images are absent
        // (they ride the structured array).
        #expect(text == "please review\n@/remote/notes.md")
    }

    @Test func userTypedPathStringsSurviveVerbatim() {
        // A USER-TYPED path string is prose and survives verbatim —
        // never eaten (images never join the prose, so the only
        // path-like lines are the user's own words and file refs).
        let draft = "look at /remote/pick.png for the details"
        let text = ChatDraftComposer.messageText(
            items: [image("/remote/some-other.png")], draft: draft)
        #expect(text == draft)
    }

    @Test func multipleFilesPlusProseSend() {
        let text = ChatDraftComposer.messageText(
            items: [
                image("/remote/a.png"),
                .file(id: "f1", name: "notes.md", remotePath: "/remote/notes.md"),
            ],
            draft: "review both please")
        #expect(text == "review both please\n@/remote/notes.md")
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

// MARK: - The file-send misclassification fix (device finding 8)

struct ChatDraftCompositionOrderTests {
    private func file(_ path: String) -> ChatDraftItem {
        .file(id: "f-\(path)", name: "notes.md", remotePath: path)
    }

    @Test func proseLeadsAndFileReferencesTrail() {
        let text = ChatDraftComposer.messageText(
            items: [file("/remote/notes.md")], draft: "please review")
        #expect(text == "please review\n@/remote/notes.md")
    }

    @Test func imageReferencesNeverJoinTheProse() {
        // Review round 6, finding 3: images ride the structured
        // prompt.send images array; the composer emits NO image line
        // (files keep their @ grammar — see above).
        let text = ChatDraftComposer.messageText(
            items: [.image(id: "i1", remotePath: "/remote/shot.png", previewData: nil)],
            draft: "see this")
        #expect(text == "see this")
    }
    @Test func attachmentBearingSendsBypassClassification() {
        #expect(ChatDraftComposer.carriesAttachments(
            items: [file("/remote/a.md")]))
        #expect(ChatDraftComposer.carriesAttachments(
            items: [.image(id: "i", remotePath: "/a.png", previewData: nil)]))
        #expect(!ChatDraftComposer.carriesAttachments(
            items: [.quote(id: "q", text: "hi", author: "Heeler")]))
        #expect(!ChatDraftComposer.carriesAttachments(items: []))
    }
}

// MARK: - The sent-attachment render split (device finding 8, render)

struct SentAttachmentTextSplitTests {
    @Test func imageLeadingPathSplitsToTile() {
        let split = SentAttachmentText.split(
            "/remote/shot.png\nlook at this")
        #expect(split?.imageRefs.count == 1)
        #expect(split?.imageRefs.first?.ref == "/remote/shot.png")
        #expect(split?.imageRefs.first?.mimeType.hasPrefix("image/") == true)
        #expect(split?.prose == "look at this")
    }

    @Test func atFileReferenceSplitsToChip() {
        let split = SentAttachmentText.split(
            "here it is\n@/remote/notes.md")
        #expect(split?.imageRefs.count == 1)
        #expect(split?.imageRefs.first?.ref == "/remote/notes.md")
        #expect(split?.imageRefs.first?.mimeType == "file")
        #expect(split?.prose == "here it is")
    }

    @Test func plainProseHasNoSplit() {
        #expect(SentAttachmentText.split("just words") == nil)
        #expect(SentAttachmentText.split("") == nil)
    }

    @Test func midTextPathsStayProse() {
        let split = SentAttachmentText.split("the config at /etc/app.conf changed")
        #expect(split == nil)
    }
}
