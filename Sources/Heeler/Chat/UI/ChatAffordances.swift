import Foundation

// SPDX-License-Identifier: Apache-2.0
//
// The per-bubble affordance model: the quick-reaction set the bubble
// overlay offers, and the composer draft a Quote produces. Pure data so
// the behaviors are unit-testable without SwiftUI.

/// One quick reaction in the bubble overlay. Reactions deliver as a short
/// user message through the composer's plain-text path (`deliver`) — the
/// agent's own protocol has no reaction wire type, and an emoji alone is
/// an unambiguous acknowledgment a text model reads natively.
internal enum ChatReaction: String, CaseIterable, Sendable {
    case thumbsUp = "👍"
    case ok = "✅"
    case celebrate = "🎉"

    /// Spoken labels are distinct per button (VoiceOver reads the symbol
    /// poorly on its own).
    var accessibilityLabel: String {
        switch self {
        case .thumbsUp: "Thumbs up"
        case .ok: "OK"
        case .celebrate: "Celebrate"
        }
    }
}

/// The Quote affordance's model: quoted text → the composer draft it
/// produces. Pure so the exact draft (the contract the test pins) lives
/// outside the view layer.
internal enum ChatQuote {
    /// The draft for quoting `text`: a markdown block quote followed by
    /// a blank line, so the cursor lands on a fresh paragraph the user's
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
}
