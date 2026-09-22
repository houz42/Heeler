import Foundation

// SPDX-License-Identifier: Apache-2.0
//
// Special sections of a chat transcript: the harness-injected
// `<system-notice>…</system-notice>` and peer-message `<irc>…</irc>`
// blocks that appear inside an agent's transcript text. They are
// chrome, not conversation — the renderer never shows their raw tag
// text through the markdown path, only a short summary (and, on tap,
// the full body).

/// One special section extracted from a message's text.
internal struct ChatSpecialSection: Sendable, Equatable, Identifiable {
    /// Which tag the section came from.
    enum Kind: String, Sendable, Equatable, CaseIterable {
        case systemNotice = "system-notice"
        case irc = "irc"

        /// The chip's label.
        var label: String {
            switch self {
            case .systemNotice: "System notice"
            case .irc: "IRC message"
            }
        }

        /// The chip's SF Symbol.
        var icon: String {
            switch self {
            case .systemNotice: "exclamationmark.bubble"
            case .irc: "bubble.left.and.bubble.right"
            }
        }
    }

    /// The section's identity: `<baseID>#<kind>#<seq>` where baseID is
    /// the text block's row identity (`messageID#blockIndex`). Unique
    /// within a message even when several sections of one kind ride
    /// one block, and stable across detail-level switches (the filter
    /// never re-keys it).
    let id: String
    let kind: Kind
    /// The tag's full body, verbatim (multi-line, everything between
    /// the opener and close tag; outer blank lines stay).
    let body: String
    /// The chip's one-line excerpt: the body's first non-empty line,
    /// whitespace-normalized. An empty body keeps the kind's label so
    /// the chip never renders a blank excerpt.
    let summary: String
}

/// Extracts `<system-notice>` and `<irc>` blocks out of transcript
/// text BEFORE anything reaches the markdown path, so the tags never
/// render as literal block text. Stateless: safe from any
/// concurrency domain.
///
/// Pairing is the HTML-scanner rule: the EARLIEST opener of either
/// kind wins, its body runs to that kind's NEXT close tag, and the
/// scan resumes after the close tag — a nested same-kind opener
/// inside a body is body data, never a second section. An opener
/// with no close tag extends to the end of the text (a streaming
/// turn must not flash raw tag text; once the close tag arrives the
/// re-parse replaces the section wholesale). An empty body still
/// extracts as a section (a header-only notice is real chrome).
internal enum ChatSpecialSectionParser {
    /// One pass over a text block: the prose/section runs in source
    /// order plus every extracted section.
    struct Extraction: Sendable, Equatable {
        struct Segment: Sendable, Equatable {
            /// Prose that renders through the ordinary markdown path.
            /// Never contains a special-section opener or close tag.
            let text: String
            /// The special section that FOLLOWS this text in source
            /// order, if any (the runs read `text` → section → the
            /// next segment's text …). nil = this prose runs to the
            /// end with no section after it.
            let followingSection: ChatSpecialSection?
        }

        /// The prose/section runs in source order. Prose that is
        /// empty (or whitespace-only — the blank lines tags leave
        /// behind) still holds a place here; the row filter drops
        /// what renders to nothing.
        let segments: [Segment]
        /// Every extracted section, in source order.
        let sections: [ChatSpecialSection]
    }

    /// Extracts every `<system-notice>`/`<irc>` section out of `text`.
    /// `baseID` is the text's row identity (`messageID#blockIndex`);
    /// each section appends `#<kind>#<seq>` so re-parses of the same
    /// message yield the same identities (level switching never
    /// re-keys rows).
    static func extract(from text: String, baseID: String) -> Extraction {
        var segments: [Extraction.Segment] = []
        var sections: [ChatSpecialSection] = []
        var seqByKind: [ChatSpecialSection.Kind: Int] = [:]

        var remainder = Substring(text)
        while let (kind, openRange, closeRange) = nextMatch(in: remainder) {
            let leading = remainder[remainder.startIndex..<openRange.lowerBound]
            let body: Substring
            let after: Substring
            if let closeRange {
                body = remainder[openRange.upperBound..<closeRange.lowerBound]
                after = remainder[closeRange.upperBound...]
            } else {
                // Unclosed opener: the body extends to end-of-text.
                body = remainder[openRange.upperBound...]
                after = remainder[remainder.endIndex...]
            }
            let seq = seqByKind[kind, default: 0]
            seqByKind[kind] = seq + 1
            let section = ChatSpecialSection(
                id: "\(baseID)#\(kind.rawValue)#\(seq)",
                kind: kind,
                body: String(body),
                summary: Self.summary(of: String(body), kind: kind))
            sections.append(section)
            segments.append(Extraction.Segment(
                text: String(leading), followingSection: section))
            remainder = after
        }
        if !remainder.isEmpty {
            segments.append(Extraction.Segment(
                text: String(remainder), followingSection: nil))
        }
        return Extraction(segments: segments, sections: sections)
    }

    // MARK: - Internals

    /// Finds the earliest special-section tag in `text`: its kind,
    /// opener range, and close-tag range (nil = unclosed opener).
    private static func nextMatch(
        in text: Substring
    ) -> (kind: ChatSpecialSection.Kind, open: Range<Substring.Index>, close: Range<Substring.Index>?)? {
        var best: (kind: ChatSpecialSection.Kind, open: Range<Substring.Index>, close: Range<Substring.Index>?)?
        for kind in ChatSpecialSection.Kind.allCases {
            guard let open = text.range(
                of: "<\(kind.rawValue)>", options: .caseInsensitive)
            else { continue }
            if let best, best.open.lowerBound <= open.lowerBound { continue }
            let close = text.range(
                of: "</\(kind.rawValue)>", options: .caseInsensitive,
                range: open.upperBound..<text.endIndex)
            best = (kind, open, close)
        }
        return best
    }

    /// The chip's one-line excerpt: the body's first non-empty line,
    /// whitespace collapsed. An empty body keeps the kind's label.
    private static func summary(of body: String, kind: ChatSpecialSection.Kind) -> String {
        for line in body.split(separator: "\n", omittingEmptySubsequences: true) {
            let collapsed = line.split(whereSeparator: \.isWhitespace)
                .joined(separator: " ")
            if !collapsed.isEmpty { return collapsed }
        }
        return kind.label
    }
}
