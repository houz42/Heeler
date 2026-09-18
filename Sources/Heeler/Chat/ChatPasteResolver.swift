import Foundation
import UIKit
import UniformTypeIdentifiers

// SPDX-License-Identifier: Apache-2.0
//
// The chat input's paste → attachment resolver: what the system
// pasteboard holds, and which of the pinned paste rules applies.
//
// The rules (pinned in ChatAttachmentDraftStoreTests):
//   1. Image only  → attach: upload via the Composer staging pipeline;
//      no text lands in the draft.
//   2. Text only   → the stock UIKit paste; nothing here changes it.
//   3. Text + image both present → text wins: typed/copied text is the
//      primary payload, and a stray image representation beside it
//      (apps that copy both) must not hijack the paste.

/// Reads the pasteboard once, synchronously where possible: an image
/// paste attaches, a text paste stays literal, both-present prefers
/// text. The item-provider route is kept for the payloads that need an
/// async load (data not materialized on the pasteboard yet).
enum ChatPasteResolver {
    /// The pasteboard's payload, resolved to the intent the paste path
    /// acts on. Reading `UIPasteboard.general` twice is avoided: the
    /// first access can show the paste-notification banner, and both
    /// reads here see the same snapshot.
    @MainActor
    static func resolve(pasteboard: ChatPasteboardSnapshotProviding = UIPasteboard.general)
        -> ChatPasteIntent
    {
        let hasImage = pasteboard.hasImages
        guard hasImage else {
            // No image: the stock paste handles text (and everything
            // else) untouched; nothing to attach.
            return .plainPaste
        }
        let text = pasteboard.stringForPaste
        guard text?.isEmpty ?? true else {
            // Both present: text wins, and the text paste must run
            // through UIKit's stock path (its payload is the string).
            return ChatPasteIntent(attachesImage: false, text: text, imageData: nil)
        }
        // Image only: pull the image data now; a nil/empty read means
        // the provider could not produce it, so the paste is a no-op
        // rather than a wrong text insert.
        guard let data = imageData(from: pasteboard), !data.isEmpty else {
            return .plainPaste
        }
        return ChatPasteIntent(attachesImage: true, text: nil, imageData: data)
    }

    /// Decodes the pasteboard's image into raw image bytes, preferring
    /// the representation the pasteboard already holds (PNG/JPEG data
    /// need no re-encode); falls back to `UIPasteboard.image`'s re-encode
    /// for synthesized or indirect representations.
    @MainActor
    static func imageData(from pasteboard: ChatPasteboardSnapshotProviding) -> Data? {
        if let data = pasteboard.imageDataRepresentation {
            return data
        }
        guard let image = pasteboard.imageRepresentation else { return nil }
        return image.pngData()
    }
}

/// The pasteboard surface the resolver reads: `UIPasteboard`'s
/// reading APIs narrowed to the ones the rules need, so tests can drive
/// the pinned precedence with scripted snapshots instead of the
/// process-wide system pasteboard.
@MainActor
protocol ChatPasteboardSnapshotProviding {
    /// `UIPasteboard.hasImages` — the pasteboard claims an image
    /// representation without materializing it.
    var hasImages: Bool { get }
    /// The string the stock text paste would insert; nil when the
    /// pasteboard holds no string representation.
    var stringForPaste: String? { get }
    /// Raw image bytes already on the pasteboard (PNG/JPEG), if any.
    var imageDataRepresentation: Data? { get }
    /// The decoded image, when only indirect representations exist.
    var imageRepresentation: UIImage? { get }
}

extension UIPasteboard: ChatPasteboardSnapshotProviding {
    var hasImages: Bool { UIPasteboard.general.hasImages }
    var stringForPaste: String? {
        UIPasteboard.general.string
    }
    var imageDataRepresentation: Data? {
        UIPasteboard.general.data(forPasteboardType: UTType.png.identifier)
            ?? UIPasteboard.general.data(forPasteboardType: UTType.jpeg.identifier)
    }
    var imageRepresentation: UIImage? {
        UIPasteboard.general.image
    }
}
