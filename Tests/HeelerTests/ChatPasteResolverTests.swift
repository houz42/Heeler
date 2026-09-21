import Testing
import UIKit
@testable import Heeler

// SPDX-License-Identifier: Apache-2.0
//
// The paste-resolution contract — and the device-crash regression pin.
// The phone crash report: stack overflow at 130k recursion levels of
// UIPasteboard.hasImages.getter — the conformance used to re-dispatch
// `UIPasteboard.general.hasImages` from an extension member ON
// UIPasteboard (general returns the same singleton → self-recursion).
// The fix removed the custom member (the SYSTEM hasImages witnesses the
// protocol) and re-pointed the shims at self's real instance API.
//
// These tests call the REAL members through the protocol: any residual
// self-recursion overflows the stack HERE, in the test — that is the
// regression proof.

@MainActor
struct ChatPasteResolverTests {

    // MARK: - The behavior contract (stub provider)

    private struct StubPasteboard: ChatPasteboardSnapshotProviding {
        var hasImages: Bool
        var stringForPaste: String?
        var imageDataRepresentation: Data?
        var imageRepresentation: UIImage?
    }

    @Test func textOnlyPasteStaysLiteral() {
        // Text-only: plainPaste — the stock UIKit paste handles the
        // text; the resolver does not intercept, so it carries NO
        // text payload (attachesImage false is the whole verdict).
        let intent = ChatPasteResolver.resolve(
            pasteboard: StubPasteboard(
                hasImages: false, stringForPaste: "hello",
                imageDataRepresentation: nil, imageRepresentation: nil))
        #expect(!intent.attachesImage)
        #expect(intent.text == nil)
    }

    @Test func bothPresentTextWins() {
        let intent = ChatPasteResolver.resolve(
            pasteboard: StubPasteboard(
                hasImages: true, stringForPaste: "words beside the image",
                imageDataRepresentation: Data([1, 2]),
                imageRepresentation: nil))
        #expect(!intent.attachesImage)
        #expect(intent.text == "words beside the image")
        #expect(intent.imageData == nil)
    }

    @Test func imageOnlyAttaches() {
        let intent = ChatPasteResolver.resolve(
            pasteboard: StubPasteboard(
                hasImages: true, stringForPaste: nil,
                imageDataRepresentation: Data([9, 9, 9]),
                imageRepresentation: nil))
        #expect(intent.attachesImage)
        #expect(intent.imageData == Data([9, 9, 9]))
    }

    // MARK: - The recursion regression pin (REAL pasteboard)

    @Test func realPasteboardMembersTerminate() {
        // The device crash was infinite recursion through the
        // conformance's members. Calling the REAL members to completion
        // proves termination: the stack-overflow recursion would die
        // right here (the extension fix removed the self-dispatching
        // members; the system hasImages + self-instance shims cannot
        // recurse).
        let board = UIPasteboard.general
        // Clear so the state is deterministic for the read sequence.
        board.string = "resolver-recursion-pin"
        let viaProtocol: ChatPasteboardSnapshotProviding = board
        _ = viaProtocol.hasImages
        _ = viaProtocol.stringForPaste
        _ = viaProtocol.imageDataRepresentation
        _ = viaProtocol.imageRepresentation
        let intent = ChatPasteResolver.resolve(pasteboard: viaProtocol)
        // The members TERMINATED — the recursion pin is that this code
        // reaches the assertions at all (any residual self-recursion
        // through the conformance overflows the stack right here).
        #expect(!intent.attachesImage)
        board.string = ""
    }
}
