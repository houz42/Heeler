import Foundation
import UIKit

// SPDX-License-Identifier: Apache-2.0
//
// The per-bubble affordance model: the quick-reaction set the bubble
// overlay offers, the composer draft a Quote produces (plus its caret
// placement), and the Copy affordance's plain-text extraction. Pure data
// so the behaviors are unit-testable without SwiftUI.

/// One quick reaction in the bubble's Tapback pill. Reactions deliver as
/// a short user message through the composer's plain-text path
/// (`deliver`) — the agent's own protocol has no reaction wire type. The
/// message references its target (the emoji plus the block-quoted target
/// text) so an unadorned emoji can never read against the wrong message.
internal enum ChatReaction: String, CaseIterable, Sendable {
    case thumbsUp = "👍"
    case ok = "✅"
    case cross = "❌"

    /// Spoken labels are distinct per button (VoiceOver reads the symbol
    /// poorly on its own).
    var accessibilityLabel: String {
        switch self {
        case .thumbsUp: "Thumbs up"
        case .ok: "OK"
        case .cross: "Cross mark"
        }
    }

    /// The message a reaction delivers: the emoji plus the block-quoted
    /// target text (ChatQuote.draft's format), so the agent sees an
    /// unambiguous "reaction on: <that message>". Blank targets deliver
    /// the bare emoji.
    func message(for target: String) -> String {
        let quote = ChatQuote.draft(for: target)
        return quote.isEmpty ? rawValue : "\(rawValue)\n\(quote)"
    }
}

/// The Quote affordance's model: quoted text → the composer draft it
/// produces, and where the caret lands in it. Pure so the exact contract
/// (the draft string and the caret offset) lives outside the view layer.
internal enum ChatQuote {
    /// The draft for quoting `text`: a markdown block quote followed by
    /// a blank line, so the caret lands on a fresh paragraph the user's
    /// reply types into. Empty for blank text (nothing to quote).
    static func draft(for text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        return trimmed
            .components(separatedBy: "\n")
            .map { "> \($0.trimmingCharacters(in: .whitespaces))" }
            .joined(separator: "\n")
            + "\n\n"
    }

    /// Where the caret lands after the draft is inserted: at its very
    /// end (UTF-16 offset), i.e. on the blank line after the quote — the
    /// fresh paragraph the reply types into.
    static func caretLocation(for draft: String) -> Int {
        draft.utf16.count
    }
}

/// One one-shot caret placement for the composer's text view. The id
/// makes the request one-shot: the text view applies a request it has
/// not seen before and ignores re-renders carrying the same one.
internal struct ChatCaretRequest: Equatable, Sendable {
    let id = UUID()
    let location: Int

    init(location: Int) {
        self.location = location
    }
}

/// The Copy affordance: the bubble's message text onto the pasteboard as
/// plain text — the markdown source stays in the bubble, the clipboard
/// gets what it reads as. One seam so the pasteboard write is testable.
internal enum ChatBubbleCopy {
    /// Strips the inline markdown a chat bubble's text commonly carries
    /// (code spans, bold) down to plain text. Deliberately narrow:
    /// constructs the transcript's prose actually uses, not a full
    /// markdown renderer — fenced blocks keep their fences (data, not
    /// markup, per the chat's own rendering rule).
    static func plainText(from text: String) -> String {
        text
            .replacingOccurrences(of: "`", with: "")
            .replacingOccurrences(of: "**", with: "")
    }

    @MainActor
    static func perform(_ text: String, pasteboard: UIPasteboard = .general) {
        pasteboard.string = plainText(from: text)
    }
}
