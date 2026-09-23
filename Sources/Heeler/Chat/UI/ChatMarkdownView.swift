@preconcurrency import MarkdownUI
import Splash
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
    static let chat = MarkdownUI.Theme.basic
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
            // exists inside them). Swift blocks get semantic coloring via
            // Splash; any other language (or none) renders plainly.
            ChatCodeBlock(
                content: configuration.content,
                language: configuration.language)
        }
        .table { configuration in
            ChatTableBlock { configuration.label }
        }
        .tableCell { configuration in
            ChatMarkdownTheme.tableCell(
                configuration.row, label: configuration.label)
        }
        .blockquote { configuration in
            // The design's quote: a vertical accent bar, grey text
            // (distinct from the author's prose), soft wash — a real
            // markdown blockquote, never a bare indent.
            configuration.label
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.leading, 12)
                .padding(.trailing, 12)
                .padding(.vertical, 8)
                .background(alignment: .leading) {
                    // 3px accent bar (the prototype's rule).
                    RoundedRectangle(cornerRadius: 1.5)
                        .fill(Color.accentColor)
                        .frame(width: 3)
                }
                .background(Color.primary.opacity(0.035))
                .foregroundStyle(.secondary)
        }

    /// The chat theme with its body text forced to a color (iMessage
    /// user bubbles: white on blue). MarkdownUI resolves the paragraph
    /// text color from the theme's text style, so a container-level
    /// foreground never reaches the glyphs.
    @MainActor
    static func chatColored(_ color: SwiftUI.Color) -> MarkdownUI.Theme {
        chat.text {
            FontSize(15)
            ForegroundColor(color)
        }
    }
}

extension ChatMarkdownTheme {
    /// The table cell weight contract: the header row (row 0) renders
    /// semibold over the theme's filled header background; body rows
    static func tableCellWeight(forRow row: Int) -> SwiftUI.Font.Weight {
        row == 0 ? .semibold : .regular
    }

    /// One table cell: chat body size, padded; the header row carries
    /// `tableCellWeight`'s heavier weight. Cells wrap vertically; in
    /// WIDE mode (a table whose natural width exceeds the chat width,
    /// laid out inside its horizontal scroll) the cell also takes its
    /// natural width — one line per cell, whole columns as the reader
    /// scrolls.
    @MainActor
    static func tableCell(
        _ row: Int, label: MarkdownUI.TableCellConfiguration.Label
    ) -> some View {
        ChatTableCell(row: row, label: label)
    }
}

/// The theme's table cell, split into a view so it can read the
/// wide-table environment flag (a static closure has no view context).
private struct ChatTableCell: View {
    let row: Int
    let label: MarkdownUI.TableCellConfiguration.Label

    @Environment(\.chatWideTableMode) private var wideMode

    var body: some View {
        label
            .fixedSize(horizontal: wideMode, vertical: true)
            .lineSpacing(2)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .font(SwiftUI.Font.subheadline.weight(
                ChatMarkdownTheme.tableCellWeight(forRow: row)))
    }
}

/// One chat code block: horizontal-scrollable, subtle background with a
/// border, and a language badge for the fence's info string. Swift code
/// carries per-token semantic colors (Splash), everything else plain
/// monospace.
struct ChatCodeBlock: View {
    let content: String
    let language: String?

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        if hugMode {
            // HUG-CONTENT (v3 own-message bubbles): a ScrollView's
            // ideal width is its PROPOSAL (it expands to fill
            // whatever it is given), so the always-scrollable block
            // would stretch the bubble even for two lines of code.
            // ViewThatFits picks the COMPACT block (intrinsic width,
            // no scroll) when the code fits the proposal, and falls
            // back to the scrollable block when a line is longer —
            // the code bubble then hugs exactly like the prose cases.
            ViewThatFits(in: .horizontal) {
                blockView(scrollable: false)
                blockView(scrollable: true)
            }
        } else {
            blockView(scrollable: true)
        }
    }

    @Environment(\.chatMarkdownHugMode) private var hugMode

    /// One code block; `scrollable` false lays the lines out at
    /// intrinsic width (hug mode's compact pick), true keeps the
    /// horizontal scroll for long lines.
    @ViewBuilder
    private func blockView(scrollable: Bool) -> some View {
        Group {
            if scrollable {
                ScrollView(.horizontal) { codeLines }
            } else {
                codeLines
                    .fixedSize(horizontal: true, vertical: false)
            }
        }
        .background(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.primary.opacity(0.06))
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .strokeBorder(Color.primary.opacity(0.08)))
        }
        .overlay(alignment: .topTrailing) { badge }
        .padding(.bottom, 8)
    }

    private var codeLines: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let highlighted {
                Text(highlighted)
                    .lineSpacing(2)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text(content)
                    .font(.system(.subheadline, design: .monospaced))
                    .lineSpacing(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.leading, 12)
        .padding(.trailing, 12)
        .padding(.vertical, 8)
    }

    /// Splash-attributed Swift code for the active color scheme, or `nil`
    /// when this block is not Swift.
    private var highlighted: AttributedString? {
        guard
            ChatCodeHighlighter.highlightsSwift(language: language)
        else { return nil }
        return ChatCodeHighlighter.attributed(
            content,
            palette: colorScheme == .dark
                ? ChatCodeHighlighter.dark : ChatCodeHighlighter.light,
            font: SplashFont.chat)
    }

    /// The fence's language tag, shown when present. Not a separate
    /// line — a small corner badge over the block background.
    @ViewBuilder private var badge: some View {
        if let language, !language.isEmpty {
            Text(language)
                .font(.caption2.weight(.medium))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(.fill.tertiary, in: RoundedRectangle(cornerRadius: 5))
                .padding(6)
        }
    }
}

/// One chat table: header row with a filled background, zebra striping,
/// and thin row separators.
///
/// WIDTH-ADAPTIVE (v2): a table that fits the chat width wraps its
/// cells exactly as v1 did; a WIDE table (natural column widths exceed
/// the proposed width) instead scrolls horizontally with cells at
/// their natural one-line width — the reader sees whole columns instead
/// of a tall stripe of over-wrapped slivers. The mode rides an
/// environment flag so `ChatMarkdownTheme.tableCell` (MarkdownUI
/// applies it to every cell, no per-cell view hook) can stop wrapping
/// inside the scroll.
///
/// Striping + row separators read better on a phone than column
/// borders: columns are implied by cell spacing, and extra vertical
/// rules would compete with the row separators.
///
/// Row backgrounds and borders are MarkdownUI environment styles applied
/// to the table's own laid-out content; the header's semibold weight
/// lives in the theme's `tableCell` style (row 0). This view only frames.
struct ChatTableBlock<Content: View>: View {
    @ViewBuilder let content: () -> Content

    @State private var naturalWidth: CGFloat?

    var body: some View {
        // The visible table IS the layout: wrapped cells when it fits
        // (v1 behaviour), or one horizontal ScrollView with natural-
        // width cells when the measured natural width exceeds the chat
        // width. The switch needs the CHAT width only — proposed via
        // onGeometryChange on the visible content itself, so the row
        // keeps its intrinsic height (no GeometryReader row body: in a
        // LazyVStack that collapses the row to zero height and rows
        // draw over each other).
        ChatTableAdaptiveTable(content: content, naturalWidth: $naturalWidth)
    }

    private struct ChatTableAdaptiveTable<Inner: View>: View {
        @ViewBuilder let content: () -> Inner
        @Binding var naturalWidth: CGFloat?

        @State private var chatWidth: CGFloat?

        private var isWide: Bool {
            guard let natural = naturalWidth, let chat = chatWidth else {
                return false
            }
            return natural > chat + 1
        }

        var body: some View {
            Group {
                if isWide {
                    ScrollView(.horizontal, showsIndicators: false) {
                        framed
                            .environment(\.chatWideTableMode, true)
                            .fixedSize(horizontal: true, vertical: false)
                    }
                } else {
                    framed
                }
            }
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { _, w in
                if w > 0 { chatWidth = w }
            }
            .background {
                // Hidden measuring pass, present ONLY until it reports:
                // the copy carries MarkdownUI's cell anchor preferences,
                // and a standing duplicate would corrupt the visible
                // table's decoration bounds (TableCellBoundsPreference
                // merges last-writer-wins). Once the natural width
                // lands, the copy leaves the tree entirely.
                if naturalWidth == nil {
                    content()
                        .environment(\.chatWideTableMode, true)
                        .fixedSize(horizontal: true, vertical: false)
                        .hidden()
                        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { _, w in
                            if w > 0 { naturalWidth = w }
                        }
                }
            }
        }

        private var framed: some View {
            content()
                .markdownTableBackgroundStyle(
                    .alternatingRows(
                        Color.primary.opacity(0.045),
                        Color.clear,
                        header: Color.primary.opacity(0.10))
                )
                .markdownTableBorderStyle(
                    TableBorderStyle(
                        .insideHorizontalBorders,
                        color: Color.primary.opacity(0.10),
                        width: 0.5))
                .padding(.bottom, 8)
        }
    }
}


/// Whether the chat table theme's cell style renders cells at natural
/// (single-line) width — set inside a wide table's horizontal scroll
/// and its measuring pass, so wrapped-cell and wide-cell metrics agree.
private struct ChatWideTableModeKey: EnvironmentKey {
    static let defaultValue = false
}

/// HUG-CONTENT mode (v3 own-message bubbles): the markdown's BLOCK
/// chrome (code blocks) lays out at intrinsic width instead of
/// stretching to fill the proposal — set by `ChatMarkdownView` when
/// `hugsContent` is true, so a fenced-code own bubble hugs the code
/// exactly like the prose cases hug text. Long code lines still
/// scroll inside the block once the block reaches the caller's
/// capped proposal.
struct ChatMarkdownHugModeKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    var chatWideTableMode: Bool {
        get { self[ChatWideTableModeKey.self] }
        set { self[ChatWideTableModeKey.self] = newValue }
    }
    /// True inside a hug-content markdown render (own-message
    /// bubbles): block chrome sizes to content, not the proposal.
    var chatMarkdownHugMode: Bool {
        get { self[ChatMarkdownHugModeKey.self] }
        set { self[ChatMarkdownHugModeKey.self] = newValue }
    }
}

/// The chat code font as a Splash `Font` — preloaded so Splash doesn't
/// fall back to Menlo: the system monospaced face at subheadline size,
/// matching every other code span in chat. Splash has no
/// `init(preloaded:)`, but `resource` is public, so the preloaded font is
/// assigned onto a default system-font value.
private enum SplashFont {
    @MainActor
    static var chat: Splash.Font {
        let size = UIFont.preferredFont(forTextStyle: .subheadline).pointSize
        var font = Splash.Font(size: Double(size))
        font.resource = .preloaded(
            UIFont.monospacedSystemFont(ofSize: size, weight: .regular))
        return font
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
    /// Overrides the rendered text color when non-nil (iMessage user
    /// bubbles: white on blue). MarkdownUI resolves the paragraph text
    /// color from the theme's text style, so the color rides the theme
    /// (`ChatMarkdownTheme.chatColored`), not a container foreground.
    var textColor: SwiftUI.Color? = nil
    /// HUG-CONTENT sizing (v3 own-message bubbles): when true, the
    /// markdown lays out at its intrinsic width instead of stretching
    /// to fill the proposal — the frame reports the CONTENT's own
    /// width, so an outer bubble's `background` hugs the content
    /// (emoji/one-word bubbles stay small; long prose wraps at the
    /// outer container's max-width proposal). The width cap is
    /// proposed by the CALLER (`ChatBubbleBody`'s `containerPropose`
    /// pass); this view just refuses to fill the space it was given.
    /// Longest-line code blocks stay scrollable at exactly their
    /// content width.
    var hugsContent: Bool = false

    init(
        markdown: String, textColor: SwiftUI.Color? = nil,
        hugsContent: Bool = false
    ) {
        self.markdown = markdown
        self.textColor = textColor
        self.hugsContent = hugsContent
    }

    var body: some View {
        // A single newline renders as a line break WITHIN one paragraph
        // (the v2 contract): cmark calls it a soft break and MarkdownUI
        // would render it as a space, collapsing multi-line agent
        // messages into one blob — the fork's `.lineBreak` soft-break
        // mode fixes the render WITHOUT a source pre-pass. (The v1
        // pre-pass inserted a blank line between every prose line, which
        // also shattered GFM tables into per-row paragraphs and
        // fragmented multi-line blockquotes into one block per line.)
        // Fenced code stays verbatim: soft-break mode never applies
        // inside code blocks, which cmark parses as literal lines.
        // The render pre-pass: IRC log sections fence as code first
        // (their paths must never gain link markup), then detected
        // path targets rewrite as link constructs.
        Markdown(ChatMarkdownText(markdown).rendered)
            .markdownSoftBreakMode(.lineBreak)
            .markdownTheme(
                textColor.map(ChatMarkdownTheme.chatColored)
                    ?? ChatMarkdownTheme.chat)
            // Chat never shows remote images; providers that silently
            // drop them (rather than fetching) keep the pane free of
            // unexpected network loads.
            .markdownImageProvider(NoImageProvider())
            .markdownInlineImageProvider(NoInlineImageProvider())
            // Long-press is native text selection (final interaction
            // spec): the prose/rich-markdown path had NO selection —
            // only the mono/plain paths did. Enabling it on the
            // container selects through MarkdownUI's Texts.
            .textSelection(.enabled)
            // HUG-CONTENT: no fill-frame — the markdown keeps its
            // intrinsic width (never wider than the proposal) and
            // LEADING-aligns inside whatever the caller proposes, so
            // the width the parent sees is the CONTENT's own. The
            // environment flag reaches the theme's BLOCK chrome
            // (code blocks) so they hug too.
            .environment(\.chatMarkdownHugMode, hugsContent)
            .frame(
                maxWidth: hugsContent ? nil : .infinity,
                alignment: .leading)
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

    /// The markdown source with IRC-format sections fenced as code, so
    /// they render as one readable monospace block (channel logs a
    /// paste of an agent transcript carries: `[HH:MM] <nick> msg`,
    /// `*** nick joined/parted`, `Nick: message` lines). Sections must
    /// span whole paragraphs (a blank line bounds them) and EVERY line
    /// must match an IRC pattern — prose that merely contains a time
    /// reference never converts. Pure static — testable without a view.
    var ircFenced: String { ChatMarkdownText.fenceIRCSections(raw) }

    /// The markdown source with detected path targets rewritten as
    /// explicit markdown link constructs. Parsing happens downstream.
    var rewritten: String { ChatMarkdownText.rewrite(raw) }

    /// The full render pre-pass: IRC sections fence FIRST (so their
    /// paths never gain link markup), then path-link rewriting skips
    /// the new fences like any other code block.
    var rendered: String { ChatMarkdownText.rewrite(ircFenced) }

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
    /// BACKTICKS or TILDES opens a fence; the closing fence repeats the
    /// SAME character with at least the opening run's count (cmark never
    /// lets a backtick fence close a tilde fence or vice versa).
    private static func fencedCodeRanges(in text: String) -> [NSRange] {
        let ns = text as NSString
        var ranges: [NSRange] = []
        var searchRange = NSRange(location: 0, length: ns.length)
        while true {
            // Opening fence: after up to three spaces of indentation,
            // three or more backticks or tildes (cmark's fence rule).
            let open = ns.range(
                of: #"(?m)^ {0,3}([`~]{3,})[^\n]*\n"#,
                options: .regularExpression,
                range: searchRange)
            guard open.location != NSNotFound else { break }
            // The closing fence must repeat the SAME fence character
            // at least the opening run's count (cmark rules — a shorter
            // run is content, and the other character never closes).
            let fence = ns.substring(with: open).drop(while: { $0 == " " })
            let fenceChar = fence.first ?? "`"
            let fenceCount = fence.prefix(while: { $0 == fenceChar }).count
            // The closing fence: a line of at least `fenceCount` of
            // the SAME character (optionally spaced) — NSRegularExpression
            // lacks backref quantifiers, so enumerate candidate closers
            // explicitly.
            let afterOpen = NSRange(
                location: open.location + open.length,
                length: searchRange.location + searchRange.length
                    - open.location - open.length)
            let escaped = fenceChar == "`" ? "`" : "~"
            let closePattern = #"(?m)^ {0,3}(\#(escaped){3,})[ \t]*(\n|$)"#
            let closeRegex = try! NSRegularExpression(pattern: closePattern)
            var close = NSRange(location: NSNotFound, length: 0)
            for match in closeRegex.matches(in: text, range: afterOpen) {
                let run = match.range(at: 1)
                if ns.substring(with: run).count >= fenceCount {
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

    /// Fences IRC-format sections as code. A SECTION is a WHOLE
    /// PARAGRAPH — a maximal run of consecutive non-blank lines —
    /// where EVERY line matches one of the IRC log patterns and the
    /// run is at least two lines (a single matching line stays prose —
    /// one `Nick: hi` line is ordinary chat text, not a log). Sections
    /// are classified COMPLETE before any rewriting: a paragraph that
    /// does not qualify passes through UNCHANGED (the review's data-
    /// loss case — a lone `Note: keep this` matched `Nick: ...` and the
    /// flush dropped it). A fence is emitted only over the complete
    /// qualifying paragraph, never over a matching subsequence inside
    /// mixed prose.
    ///
    /// Patterns (line-oriented, prefix-anchored):
    /// - `[HH:MM(:SS)?]`-stamped lines (classic channel log);
    /// - `<nick>`-spoken lines (relay bots, e.g. `<jhou> hello`);
    /// - `***`/`--`/`==` join/part/nick-change markers;
    /// - `Nick: message` (agent-relay format) — a word-ish nick
    ///   followed by `: ` at the line head.
    ///
    /// Already-fenced code (backtick OR tilde fences) is protected
    /// verbatim: any paragraph overlapping a protected range passes
    /// through untouched, so a log pasted inside a fence never
    /// double-fences and prose inside a fence is never reclassified.
    static func fenceIRCSections(_ text: String) -> String {
        let protected = fencedCodeRanges(in: text)
        let lines = text.components(separatedBy: "\n")

        // Line-parallel fence map: which line indices sit inside an
        // existing fence (their content is data, never re-fenced).
        var lineStarts: [Int] = []
        var offset = 0
        for line in lines {
            lineStarts.append(offset)
            offset += line.utf16.count + 1
        }
        func lineRange(_ index: Int) -> NSRange {
            NSRange(
                location: lineStarts[index],
                length: (lines[index] as NSString).length)
        }
        func paragraphOverlapsFence(_ indices: [Int]) -> Bool {
            indices.contains { index in
                protected.contains { overlaps($0, lineRange(index)) }
            }
        }

        // Pass 1: split into paragraphs (maximal non-blank runs). A
        // paragraph is FENCEABLE when it is >= 2 lines, EVERY line
        // matches, and it overlaps no protected fence range.
        struct Paragraph {
            let lineIndices: [Int]
            let fenceable: Bool
        }
        var paragraphs: [Paragraph] = []
        var current: [Int] = []
        func classify() {
            guard !current.isEmpty else { return }
            let qualifies =
                current.count >= 2
                && !paragraphOverlapsFence(current)
                && current.allSatisfy {
                    isIRCLine(lines[$0].trimmingCharacters(in: .whitespaces))
                }
            paragraphs.append(Paragraph(lineIndices: current, fenceable: qualifies))
            current = []
        }
        for (index, line) in lines.enumerated() {
            if line.trimmingCharacters(in: .whitespaces).isEmpty {
                classify()
            } else {
                current.append(index)
            }
        }
        classify()

        // Pass 2: emit. Fenceable paragraphs get one fence around their
        // COMPLETE line run; everything else passes through in order,
        // line for line — blank separators included, no line ever
        // dropped or merged.
        var fencedIndices = Set<Int>()
        for paragraph in paragraphs where paragraph.fenceable {
            paragraph.lineIndices.forEach { fencedIndices.insert($0) }
        }
        var result: [String] = []
        var index = 0
        while index < lines.count {
            if fencedIndices.contains(index) {
                // The paragraph's COMPLETE run, one fence around it.
                guard let paragraph = paragraphs.first(where: {
                    $0.fenceable && $0.lineIndices.contains(index)
                }) else {
                    result.append(lines[index])
                    index += 1
                    continue
                }
                result.append("```irc")
                for i in paragraph.lineIndices {
                    result.append(lines[i])
                }
                result.append("```")
                index = paragraph.lineIndices.last! + 1
            } else {
                result.append(lines[index])
                index += 1
            }
        }
        return result.joined(separator: "\n")
    }

    /// Whether one line carries an IRC-log shape. Prefix-anchored and
    /// deliberately conservative: ordinary prose containing a colon
    /// ("Note: this is prose") also matches `Word: ...` — the
    /// `run.count >= 2` gate above is the other half of that guard.
    private static func isIRCLine(_ line: String) -> Bool {
        // [HH:MM] or [HH:MM:SS] stamped — classic channel log.
        if line.range(
            of: #"^\[\d{1,2}:\d{2}(:\d{2})?\] "#,
            options: .regularExpression) != nil
        { return true }
        // <nick> spoken — relay/bridge format.
        if line.range(
            of: #"^<[A-Za-z0-9_\-\[\]{}|^`]{1,32}> "#,
            options: .regularExpression) != nil
        { return true }
        // *** / -- / == markers: joins, parts, nick changes, topics.
        if line.hasPrefix("*** ") || line.hasPrefix("-- ")
            || line.hasPrefix("== ")
        { return true }
        // Nick: message — a short nick (letters, digits, _ - . [ ]),
        // colon-space, then the line. Markdown list/heading shapes are
        // excluded by the nick character class (no `#`, `-`, `*`, `>`).
        if line.range(
            of: #"^[A-Za-z0-9_\-\.\[\]]{1,32}: "#,
            options: .regularExpression) != nil
        { return true }
        return false
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
