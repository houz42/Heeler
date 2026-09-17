@preconcurrency import MarkdownUI
import SwiftUI

// SPDX-License-Identifier: Apache-2.0
//
// Rich markdown rendering for chat text, on MarkdownUI (cmark-gfm):
// headings, code spans/blocks, tables, and links replace the old
// inline-only AttributedString path. Link routing is unchanged in shape —
// MarkdownUI renders links as `Text` with `.link` attributes, so the same
// `\.openURL` environment override that `ChatLinkText` used still delivers
// taps to `OpenRouterCore`.
//
// One gap MarkdownUI cannot close by itself: cmark autolinks bare URLs but
// never bare POSIX paths, and markdown-construct path targets
// (`[label](/abs/path)`) are the chat opener's most valuable cases. Those
// are rewritten in the markdown SOURCE before parsing (`ChatMarkdownText`)
// so code spans/blocks stay literal and the detector's prose rules
// (claimed ranges, punctuation trimming) keep applying unchanged.

/// The chat markdown theme: MarkdownUI's `basic` with the chat-specific
/// fixes — body text at subheadline size to match every other chat row,
/// tinted links, chat-tight paragraph spacing, and code (spans and
/// blocks) with a subtle background, which `basic` does not carry.
///
/// Overrides stick to plain SwiftUI modifiers. MarkdownUI's relative
/// helpers (`relativePadding`, `markdownMargin`, `markdownTextStyle`)
/// are main-actor-isolated extension methods whose isolated-conformance
/// results cannot cross into this Swift 6 file warning-free; the `.basic`
/// styles themselves are fine because they were compiled inside
/// MarkdownUI's module.
enum ChatMarkdownTheme {
    @MainActor
    static let chat = Theme.basic
        .text {
            FontSize(15)
        }
        .code {
            FontFamilyVariant(.monospaced)
            FontSize(.em(0.94))
            BackgroundColor(Color.primary.opacity(0.06))
        }
        .link {
            ForegroundColor(Color.accentColor)
        }
        .paragraph { configuration in
            configuration.label
                .fixedSize(horizontal: false, vertical: true)
                .lineSpacing(2)
                .padding(.bottom, 8)
        }
        .codeBlock { configuration in
            // Code blocks render from the raw content (no inline markup
            // exists inside them), styled like the chat's output blocks.
            ScrollView(.horizontal) {
                Text(configuration.content)
                    .font(.system(.subheadline, design: .monospaced))
                    .lineSpacing(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.leading, 12)
                    .padding(.trailing, 12)
                    .padding(.vertical, 8)
            }
            .background(Color.primary.opacity(0.06))
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .padding(.bottom, 8)
        }
}

/// Renders chat text as rich markdown. Link routing is applied by the
/// callers: `ChatLinkText` sets the `\.openURL` override that delivers
/// taps to `OpenRouterCore`; `ChatBlockText`'s prose path renders without
/// one.
///
/// MarkdownUI caveats worth knowing before editing:
/// - No text selection: `Markdown` is a view tree of `Text`s, so the old
///   `.textSelection(.enabled)` on the whole block cannot apply.
/// - Link taps arrive via the `\.openURL` environment, exactly the seam
///   the attributed-string path used.
struct ChatMarkdownView: View {
    let markdown: String

    var body: some View {
        Markdown(markdown)
            .markdownTheme(ChatMarkdownTheme.chat)
            // Chat never shows remote images; providers that silently
            // drop them (rather than fetching) keep the pane free of
            // unexpected network loads.
            .markdownImageProvider(NoImageProvider())
            .markdownInlineImageProvider(NoInlineImageProvider())
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Chat text as markdown source, with `ChatLinkDetector`'s targets
/// rewritten into explicit link constructs before parsing. What
/// MarkdownUI already links on its own — markdown constructs with
/// http(s) targets, bare URLs via cmark's autolink extension — is left
/// untouched; everything else (bare POSIX paths, markdown constructs with
/// path targets) becomes `[label](url)` first.
struct ChatMarkdownText: Hashable {
    let raw: String

    init(_ raw: String) {
        self.raw = raw
    }

    /// The markdown source with detected path targets rewritten as
    /// explicit markdown link constructs. Parsing happens downstream.
    var rewritten: String { ChatMarkdownText.rewrite(raw) }

    /// The pure seam: raw markdown in, markdown with explicit link
    /// constructs out. Static so tests drive it without a view.
    ///
    /// A detected range is skipped when it already sits inside a fenced
    /// code block (code is data — a path in tool output must not gain
    /// markup) or inside a markdown construct the parser already renders
    /// as a link with the same destination.
    static func rewrite(_ text: String) -> String {
        guard !text.isEmpty else { return text }
        let links = ChatLinkDetector.detect(in: text)
        guard !links.isEmpty else { return text }

        let protected = fencedCodeRanges(in: text)
        let ns = text as NSString
        var result = ""
        var cursor = 0
        for link in links {
            // Skip targets MarkdownUI renders as links unaided: markdown
            // constructs with http(s) targets, and bare http(s)/www URLs
            // that cmark's autolink extension links.
            guard case .path = link.target else { continue }

            let range = link.range
            guard range.location >= cursor else { continue }
            // Fenced code blocks render literally; injecting a construct
            // there would corrupt the displayed code.
            guard !protected.contains(where: { overlaps($0, range) })
            else { continue }
            result += ns.substring(with: NSRange(
                location: cursor, length: range.location - cursor))
            // A claimed markdown construct rewrites to a construct with
            // the SAME label and the routed target; a bare path rewrites
            // to a construct whose label is the visible span. Either way
            // the span's visible text is preserved exactly.
            let span = ns.substring(with: range)
            let label = constructLabel(of: span) ?? span
            result += "[\(label)](\(link.target.linkURL.absoluteString))"
            cursor = range.location + range.length
        }
        result += ns.substring(from: cursor)
        return result
    }

    /// The content ranges of fenced code blocks (the text between the
    /// opening and closing fence lines). Fence-line matching is line-
    /// oriented, mirroring cmark: a line whose (after up to three spaces
    /// of indentation) first non-space characters are three or more
    /// backticks opens a fence; the closing fence repeats them.
    private static func fencedCodeRanges(in text: String) -> [NSRange] {
        let ns = text as NSString
        var ranges: [NSRange] = []
        var searchRange = NSRange(location: 0, length: ns.length)
        while true {
            // Opening fence: after up to three spaces of indentation,
            // three or more backticks (cmark's fence rule).
            let open = ns.range(
                of: #"(?m)^ {0,3}(`{3,})[^\n]*\n"#,
                options: .regularExpression,
                range: searchRange)
            guard open.location != NSNotFound else { break }
            // The closing fence must repeat at least the opening run's
            // backtick count (cmark rule — a shorter run is content).
            let fence = ns.substring(with: open).drop(while: { $0 == " " })
            let ticks = fence.prefix(while: { $0 == "`" }).count
            // The closing fence: a line of at least `ticks` backticks
            // (optionally spaced) — NSRegularExpression lacks backref
            // quantifiers, so enumerate candidate closers explicitly.
            let afterOpen = NSRange(
                location: open.location + open.length,
                length: searchRange.location + searchRange.length
                    - open.location - open.length)
            let closePattern = #"(?m)^ {0,3}(`{3,})[ \t]*(\n|$)"#
            let closeRegex = try! NSRegularExpression(pattern: closePattern)
            var close = NSRange(location: NSNotFound, length: 0)
            for match in closeRegex.matches(in: text, range: afterOpen) {
                let run = match.range(at: 1)
                if ns.substring(with: run).count >= ticks {
                    close = match.range
                    break
                }
            }
            guard close.location != NSNotFound else {
                // Unterminated fence: cmark extends the code block to
                // the end of the document, so protection does too.
                ranges.append(NSRange(
                    location: open.location + open.length,
                    length: searchRange.location + searchRange.length
                        - open.location - open.length))
                break
            }
            ranges.append(NSRange(
                location: open.location + open.length,
                length: close.location - open.location - open.length))
            searchRange = NSRange(
                location: close.location + close.length,
                length: searchRange.location + searchRange.length
                    - close.location - close.length)
        }
        return ranges
    }

    /// The label of a `[label](target)` construct, when the span IS one
    /// (the detector claims markdown constructs whole). `nil` for bare
    /// spans. Matches the detector's own construct regex so the two can
    /// never drift apart.
    private static func constructLabel(of span: String) -> String? {
        let constructRegex = try! NSRegularExpression(
            pattern: #"\[([^\[\]\r\n]+)\]\(\s*((?:[^()\s]|\\.)+)\s*\)"#)
        let ns = span as NSString
        guard
            let match = constructRegex.matches(
                in: span, range: NSRange(location: 0, length: ns.length)).first,
            match.range.location == 0, match.range.length == ns.length
        else { return nil }
        return ns.substring(with: match.range(at: 1))
    }
}


/// Whether two ranges share at least one unit position.
private func overlaps(_ a: NSRange, _ b: NSRange) -> Bool {
    a.location < b.location + b.length
        && b.location < a.location + a.length
}
/// Never loads: chat shows no images.
private struct NoImageProvider: ImageProvider {
    func makeImage(url: URL?) -> some View {
        Color.clear.frame(width: 0, height: 0)
    }
}

/// Never loads: inline images in chat text render as nothing.
private struct NoInlineImageProvider: InlineImageProvider {
    func image(with url: URL, label: String) async throws -> Image {
        throw URLError(.unsupportedURL)
    }
}
