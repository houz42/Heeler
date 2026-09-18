import Foundation
import Observation
import SwiftUI
import UIKit

// SPDX-License-Identifier: Apache-2.0
//
// The chat input's attachment flow, modeled on the terminal Composer's
// `ComposerStagingStore` pipeline (ADR 0005) but owning its own draft
// seam: the chat input's draft lives in ChatScreen's SwiftUI state and
// the router classifies it, so a plain-path insert must run through
// `applyEditorDraft` (caret-faithful) and the pending-image flow holds a
// thumbnail the user can remove before Send, rather than a bare path
// string appearing in the text.
//
// Two producers feed the same upload: the + button's pickers and an
// image paste (UIPasteboard image detection in the text view's paste
// path). The paste rule is pinned in ChatAttachmentDraftStoreTests: an
// image on the pasteboard attaches instead of inserting text; text
// pastes stay literal; when the pasteboard holds BOTH, text wins —
// typed/copied text is the primary payload and a stray image beside it
// (an app copying both representations) must not hijack the paste.

/// What the paste path should do with a pasteboard payload. Derived from
/// the item providers' registered type identifiers, per the pinned rule.
struct ChatPasteIntent: Equatable, Sendable {
    let attachesImage: Bool
    /// The literal string a text paste must insert; non-nil when the
    /// paste is a text paste (including the both-present case, where
    /// text wins and the image is ignored).
    let text: String?
    /// The image data the attach path uploads; non-nil only when the
    /// pasteboard carries an image and NO text.
    let imageData: Data?

    static let plainPaste: ChatPasteIntent = ChatPasteIntent(
        attachesImage: false, text: nil, imageData: nil)

    static func intent(
        text: String?, hasImage: Bool, imageData: () async -> Data?
    ) async -> ChatPasteIntent {
        // Both present → text wins; the paste inserts text unchanged.
        if let text, !text.isEmpty {
            return ChatPasteIntent(attachesImage: false, text: text, imageData: nil)
        }
        guard hasImage, let data = await imageData() else { return .plainPaste }
        return ChatPasteIntent(attachesImage: true, text: nil, imageData: data)
    }

    static func intent(text: String?, hasImage: Bool, imageData: Data?) -> ChatPasteIntent {
        if let text, !text.isEmpty {
            return ChatPasteIntent(attachesImage: false, text: text, imageData: nil)
        }
        guard hasImage, let imageData, !imageData.isEmpty else { return .plainPaste }
        return ChatPasteIntent(attachesImage: true, text: nil, imageData: imageData)
    }
}

/// The chat input's draft seam: caret-faithful draft updates for the
/// staging store's path inserts, plus the pending-image thumbnail the
/// seamless paste flow shows before Send. Plain text flows around this
/// seam (typed edits belong to the text view); only the staging store
/// and the screen's own bookkeeping mutate through it.
@MainActor
@Observable
final class ChatAttachmentDraftStore: ComposerDraftOperations {
    /// The image waiting to attach to the next sent message (paste
    /// flow): the paste uploaded it to the Host, and Send delivers it by
    /// prepending the remote path to the message text — the same path
    /// reference the terminal Composer inserts into its draft.
    private(set) var pendingImage: PendingImageAttachment?
    /// The upload's last failure detail, for the frame's error row.
    private(set) var uploadFailureMessage: String?

    struct PendingImageAttachment: Equatable {
        let remotePath: String
    }

    /// The screen's current draft, mirrored here so the staging store's
    /// insert can land at the caret the text view reports. ChatScreen
    /// owns the SwiftUI binding; every text-view edit routes through
    /// ``applyEditorDraft(_:selection:)`` to keep this mirror exact.
    private(set) var draft: String
    /// UTF-16 caret/selection, the same coordinate system the text
    /// view reports.
    private(set) var draftSelection = NSRange(location: 0, length: 0)

    init(draft: String = "", selection: NSRange = NSRange(location: 0, length: 0)) {
        self.draft = draft
        self.draftSelection = selection
    }

    /// Text-view edits: caret-faithful, the same contract the terminal
    /// Composer's `applyEditorDraft` has. A no-op when the text and
    /// selection already match.
    func applyEditorDraft(_ text: String, selection: NSRange) {
        let clamped = Self.clamped(selection, to: text)
        guard draft != text || draftSelection != clamped else { return }
        draft = text
        draftSelection = clamped
    }

    /// The staging store's completed-attachment path: inserts the remote
    /// path at the caret. The screen re-sinks the new draft into the
    /// text view through its own `draft` binding; the caret follows the
    /// insertion, matching the terminal Composer's `insertIntoDraft`.
    func insertIntoDraft(_ text: String) {
        let range = Self.clamped(draftSelection, to: draft)
        draft = (draft as NSString).replacingCharacters(in: range, with: text)
        draftSelection = NSRange(
            location: range.location + (text as NSString).length, length: 0)
    }

    func replaceDraft(with text: String) {
        draft = text
        draftSelection = NSRange(location: (text as NSString).length, length: 0)
    }

    /// Holds a successfully uploaded image for the Send flow. The
    /// staging store's own insertIntoDraft already placed the path in
    /// the draft for the plain (file, picker-image) flow; the paste flow
    /// calls this instead and removes the path from the draft — the
    /// thumbnail is the visible attachment, and Send prepends the path
    /// to the delivered text.
    func holdPendingImage(path: String) {
        pendingImage = PendingImageAttachment(remotePath: path)
    }
    /// The x on the thumbnail chip, or the teardown after Send.
    func clearPendingImage() {
        pendingImage = nil
    }

    func recordUploadFailure(_ message: String) {
        uploadFailureMessage = message
    }

    func clearUploadFailure() {
        uploadFailureMessage = nil
    }

    /// Builds the message text Send delivers: the pending image's remote
    /// path prepended to the draft text, matching the reference
    /// convention the agent already reads — the path reference rides
    /// ahead of any message prose.
    func messageText(forDraft text: String) -> String {
        guard let pendingImage else { return text }
        return "\(pendingImage.remotePath) \(text)"
    }

    private static func clamped(_ range: NSRange, to text: String) -> NSRange {
        let length = (text as NSString).length
        guard range.location != NSNotFound else {
            return NSRange(location: length, length: 0)
        }
        let location = min(max(range.location, 0), length)
        let remaining = length - location
        let clampedLength = min(max(range.length, 0), remaining)
        return NSRange(location: location, length: clampedLength)
    }
}

/// The chat input's attachment bundle: the staging pipeline the +
/// button and paste share, plus the draft seam its path inserts land
/// in. One instance per chat surface; nil keeps the frame exactly as
/// before (previews, unwired hosts).
@MainActor
struct ChatAttachments {
    let staging: ComposerStagingStore
    let draftStore: ChatAttachmentDraftStore
}

/// One pending image attachment, previewed as a thumbnail chip above
/// the chat input's text field with an x to remove. The chip is the
/// visible half of the paste-to-attach flow; the remote path it stands
/// for rides ahead of the message text at Send.
struct ChatAttachmentThumbnail: View {
    let imageSource: Data

    var body: some View {
        Group {
            if let image = UIImage(data: imageSource) {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                Image(systemName: "photo")
                    .font(.title3)
            }
        }
        .frame(width: 56, height: 56)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(.secondary.opacity(0.3), lineWidth: 0.5)
        }
        .accessibilityLabel("Pending image attachment")
    }
}
