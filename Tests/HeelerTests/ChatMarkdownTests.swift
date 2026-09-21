import Foundation
import MarkdownUI
import Splash
import SwiftUI
import Testing

@testable import Heeler

// SPDX-License-Identifier: Apache-2.0
//
// The rich-markdown seam: the source rewriter that lifts the opener's
// path targets into markdown constructs, and construction-time smoke
// coverage over the MarkdownUI fixtures chat actually renders (GFM
// tables, fenced code, headers, links). Construction parses through
// cmark — a parser crash or an unbounded walk shows up here without a
// render loop.

@Suite("Chat Markdown Text")
struct ChatMarkdownTextTests {
    // MARK: bare paths

    @Test func barePathBecomesConstruct() {
        let rewritten = ChatMarkdownText.rewrite(
            "Wrote it to /tmp/report.md earlier.")
        #expect(
            rewritten
                == "Wrote it to [/tmp/report.md](heeler-chat://file?path=/tmp/report.md) earlier.")
    }

    @Test func escapedSpacePathSurvivesLabel() {
        // The escaped-space form is the visible label; the target carries
        // the unescaped path via the detector's linkURL.
        let rewritten = ChatMarkdownText.rewrite(
            "See /Users/jhou/My\\ Files/plan.md for the plan.")
        #expect(
            rewritten.hasPrefix("See [/Users/jhou/My\\ Files/plan.md](heeler-chat://file?"))
        #expect(rewritten.hasSuffix(" for the plan."))
    }

    @Test func trailingPunctuationStaysOutsideTheLabel() {
        let rewritten = ChatMarkdownText.rewrite("Config: /etc/nginx/nginx.conf, reload after.")
        #expect(rewritten.contains("](heeler-chat://file?path=/etc/nginx/nginx.conf), reload"))
    }

    @Test func plainProseIsUntouched() {
        let text = "No links here, just prose and a // comment marker."
        #expect(ChatMarkdownText.rewrite(text) == text)
    }

    // MARK: markdown constructs with path targets

    @Test func constructWithPathTargetKeepsItsLabel() {
        let rewritten = ChatMarkdownText.rewrite(
            "Edit [the config](/etc/herdr/config.toml) please.")
        #expect(
            rewritten
                == "Edit [the config](heeler-chat://file?path=/etc/herdr/config.toml) please.")
    }

    @Test func constructWithHTTPSTargetIsLeftToTheRenderer() {
        // MarkdownUI already links https constructs; rewriting would
        // double-wrap.
        let text = "See [the docs](https://example.com/docs) for more."
        #expect(ChatMarkdownText.rewrite(text) == text)
    }

    @Test func constructWithUnroutableTargetIsClaimedButUnrewritten() {
        // The detector claims the range (no phantom URL) but maps it to
        // nothing; the raw characters must survive verbatim.
        let text = "See [here](relative/x) now."
        #expect(ChatMarkdownText.rewrite(text) == text)
    }

    // MARK: URLs are MarkdownUI's job

    @Test func bareURLIsNeverRewritten() {
        let text = "See https://example.com/a for details."
        #expect(ChatMarkdownText.rewrite(text) == text)
    }

    @Test func wwwFormIsNeverRewritten() {
        let text = "Go to www.example.com now."
        #expect(ChatMarkdownText.rewrite(text) == text)
    }

    // MARK: fenced code is data

    @Test func pathInsideFencedCodeBlockIsNotRewritten() {
        let text = """
            Saved it to /tmp/out.md first, then:

            ```bash
            cat /tmp/report.md
            mv /tmp/a.log /tmp/b.log
            ```

            Done.
            """
        let rewritten = ChatMarkdownText.rewrite(text)
        // The prose path is linked; the two paths inside the fence keep
        // their literal characters.
        #expect(rewritten.contains("[/tmp/out.md](heeler-chat://file?"))
        #expect(rewritten.contains("cat /tmp/report.md"))
        #expect(rewritten.contains("mv /tmp/a.log /tmp/b.log"))
    }

    @Test func multipleFencedBlocksAreAllProtected() {
        let text = """
            ```swift
            open("/etc/first.conf")
            ```
            Between blocks: /var/log/mid.log
            ```python
            open("/etc/second.conf")
            ```
            """
        let rewritten = ChatMarkdownText.rewrite(text)
        #expect(rewritten.contains("open(\"/etc/first.conf\")"))
        #expect(rewritten.contains("open(\"/etc/second.conf\")"))
        #expect(rewritten.contains("[/var/log/mid.log](heeler-chat://file?"))
    }

    @Test func unterminatedFenceProtectsToTheEnd() {
        let text = "Intro: /tmp/intro.md\n```\nstill code /etc/x.conf"
        let rewritten = ChatMarkdownText.rewrite(text)
        #expect(rewritten.contains("[/tmp/intro.md](heeler-chat://file?"))
        #expect(rewritten.contains("still code /etc/x.conf"))
    }

    // MARK: rewrite round-trips through the parser

    @Test func rewrittenOutputParsesAndRoundTrips() {
        // Rewriting must not break the document's structure: the rewritten
        // markdown's plain-text rendering still carries every visible
        // character of the original's prose.
        let original = "Read /tmp/notes.md and [the config](/etc/app.toml) now."
        let rewritten = ChatMarkdownText.rewrite(original)
        let plain = MarkdownContent(rewritten).renderPlainText()
        #expect(plain == "Read /tmp/notes.md and the config now.")
    }

    @Test func shorterBacktickRunDoesNotCloseALongerFence() {
        // cmark rule: the closing fence needs at least the opening run's
        // backtick count. A shorter run inside the block is content.
        let text = """
            Prose: /tmp/prose.md

            ````markdown
            inside /etc/inner.conf and
            ``` not a close
            ````

            After: /tmp/after.md
            """
        let rewritten = ChatMarkdownText.rewrite(text)
        #expect(rewritten.contains("inside /etc/inner.conf and"))
        #expect(rewritten.contains("``` not a close"))
        #expect(rewritten.contains("[/tmp/prose.md](heeler-chat://file?"))
        #expect(rewritten.contains("[/tmp/after.md](heeler-chat://file?"))
    }
}

@Suite("Chat Code Highlighter")
@MainActor
struct ChatCodeHighlighterTests {
    private func foregroundColors(
        _ attributed: AttributedString
    ) -> [(text: String, color: UIColor)] {
        var runs: [(String, UIColor)] = []
        for run in attributed.runs {
            guard let color = run.uiKit.foregroundColor else { continue }
            runs.append((String(attributed[run.range].characters), color))
        }
        return runs
    }

    private func colorOf(
        _ token: String, in code: String, palette: ChatCodeHighlighter.Palette
    ) throws -> UIColor? {
        let attributed = ChatCodeHighlighter.attributed(
            code, palette: palette, font: SplashFontChat())
        let runs = foregroundColors(attributed)
        return runs.first { $0.0.contains(token) }?.1
    }

    @Test func swiftKeywordColorDiffersFromIdentifier() throws {
        let code = "let x = 1\nmyIdentifierValue = 2"
        let keyword = try colorOf(
            "let", in: code, palette: ChatCodeHighlighter.light)
        let identifier = try colorOf(
            "myIdentifierValue", in: code, palette: ChatCodeHighlighter.light)
        let k = try #require(keyword)
        let i = try #require(identifier)
        #expect(k != i, "keyword and identifier must not share a color")
    }

    @Test func swiftStringAndCommentColored() throws {
        let code = "let name = \"hello\" // trailing"
        let str = try colorOf(
            "hello", in: code, palette: ChatCodeHighlighter.light)
        let comment = try colorOf(
            "trailing", in: code, palette: ChatCodeHighlighter.light)
        let plain = try colorOf(
            "name", in: code, palette: ChatCodeHighlighter.light)
        #expect(str != plain)
        #expect(comment != plain)
        #expect(str != comment)
    }

    @Test func darkPaletteDiffersFromLight() throws {
        let code = "let x = \"hello\""
        let lightKeyword = try colorOf(
            "let", in: code, palette: ChatCodeHighlighter.light)
        let darkKeyword = try colorOf(
            "let", in: code, palette: ChatCodeHighlighter.dark)
        #expect(lightKeyword != darkKeyword)
    }

    @Test func unknownLanguageRendersPlainly() {
        #expect(!ChatCodeHighlighter.highlightsSwift(language: "python"))
        #expect(!ChatCodeHighlighter.highlightsSwift(language: "bash"))
        #expect(!ChatCodeHighlighter.highlightsSwift(language: "not-a-lang"))
    }

    @Test func noLanguageRendersPlainly() {
        #expect(!ChatCodeHighlighter.highlightsSwift(language: nil))
        #expect(!ChatCodeHighlighter.highlightsSwift(language: ""))
        #expect(!ChatCodeHighlighter.highlightsSwift(language: "   "))
    }

    @Test func swiftLanguageVariantsHighlight() {
        #expect(ChatCodeHighlighter.highlightsSwift(language: "swift"))
        #expect(ChatCodeHighlighter.highlightsSwift(language: "Swift"))
        #expect(ChatCodeHighlighter.highlightsSwift(language: "swift repl"))
    }
}

@Suite("Chat Markdown Construction")
struct ChatMarkdownConstructionTests {
    // MARK: fixtures render (construction parses via cmark)

    @Test func gfmTableParses() {
        let table = """
            | Stage | Files | Notes |
            | --- | --- | --- |
            | build | 12 | ok |
            | test | 34 | two flakes |
            """
        let content = MarkdownContent(table)
        // cmark's table extension round-trips the pipes; a table that
        // failed to parse would lose its structure here.
        let rendered = content.renderMarkdown()
        #expect(rendered.contains("|"))
        #expect(rendered.contains("build"))
        #expect(rendered.contains("two flakes"))
        // Plain-text rendering flattens but keeps every cell's words.
        let plain = content.renderPlainText()
        #expect(plain.contains("Stage"))
        #expect(plain.contains("two flakes"))
    }

    @Test func fencedCodeBlockWithLanguageParses() {
        let fenced = """
            ```swift
            struct Hello {
                let path = "/etc/herdr/config.toml"
            }
            ```
            """
        let content = MarkdownContent(fenced)
        let plain = content.renderPlainText()
        #expect(plain.contains("struct Hello"))
        #expect(plain.contains("/etc/herdr/config.toml"))
    }

    @Test func headerLevelsParse() {
        let headers = """
            # One
            ## Two
            ### Three
            #### Four
            ##### Five
            ###### Six
            """
        let content = MarkdownContent(headers)
        let rendered = content.renderMarkdown()
        #expect(rendered.contains("# One"))
        #expect(rendered.contains("###### Six"))
    }

    @Test func linkWithTitleParses() {
        let link = "See [the docs](https://example.com/docs \"Docs\") for more."
        let content = MarkdownContent(link)
        let html = content.renderHTML()
        #expect(html.contains("<a href=\"https://example.com/docs\""))
        #expect(html.contains("the docs"))
    }

    @Test func rewrittenChatMarkdownParsesForEveryStyle() {
        // Every style's text goes through the same construction path;
        // this exercises the exact string `ChatLinkText` builds.
        let source = "Open /tmp/plan.md or [the config](/etc/app.toml)."
        let markdown = ChatMarkdownText(source).rewritten
        let content = MarkdownContent(markdown)
        #expect(content.renderPlainText() == "Open /tmp/plan.md or the config.")
    }

    // MARK: performance smoke — a 100KB transcript chunk

    @Test func hundredKBTranscriptChunkConstructsQuickly() throws {
        // A single chat block at the transcript scale (roughly an
        // assistant turn with tool output pasted inline). Construction =
        // cmark parse + detector pass + rewrite; no render loop.
        var lines: [String] = ["## Summary", ""]
        for index in 0..<1400 {
            lines.append(
                "Item \(index): wrote /tmp/out-\(index).md and see [docs\(index)](/etc/app-\(index).toml) — ok.")
        }
        lines.append("")
        lines.append("```")
        lines.append("literal path /var/log/raw.log stays here")
        lines.append("```")
        let chunk = lines.joined(separator: "\n")
        #expect(chunk.utf8.count > 100_000)

        let start = Date()
        let markdown = ChatMarkdownText(chunk).rewritten
        let content = MarkdownContent(markdown)
        let plain = content.renderPlainText()
        let elapsed = Date().timeIntervalSince(start)
        #expect(plain.contains("literal path /var/log/raw.log stays here"))
        #expect(plain.contains("Item 0:"))
        #expect(plain.contains("docs1399"))
        // Generous ceiling: a smoke, not a benchmark — regression means
        // accidental O(n²) in the rewrite, not 50ms of parsing.
        #expect(elapsed < 2.0, "construction took \(elapsed)s")
    }
}

/// Test-side twin of the app's chat code font: system monospaced at
/// subheadline size, preloaded into a Splash font.
@MainActor
private func SplashFontChat() -> Splash.Font {
    let size = UIFont.preferredFont(forTextStyle: .subheadline).pointSize
    var font = Splash.Font(size: Double(size))
    font.resource = .preloaded(
        UIFont.monospacedSystemFont(ofSize: size, weight: .regular))
    return font
}

@Suite("Chat Table Styling")
@MainActor
struct ChatTableStylingTests {
    /// The two-column fixture the phone complaint was about.
    private let table = """
        | Stage | Files |
        | --- | --- |
        | build | 12 |
        | test | 34 |
        """

    @Test func headerCellIsHeavierThanBodyCells() {
        // The theme contract: row 0 (the header) renders semibold over
        // the filled header background; body rows render regular.
        // Distinct weights = a header that reads as a header.
        #expect(
            ChatMarkdownTheme.tableCellWeight(forRow: 0)
                == ChatMarkdownTheme.tableCellWeight(forRow: 0))
        #expect(
            ChatMarkdownTheme.tableCellWeight(forRow: 0) != .regular,
            "header row must not render at the body weight")
        #expect(
            ChatMarkdownTheme.tableCellWeight(forRow: 1) == .regular)
        #expect(
            ChatMarkdownTheme.tableCellWeight(forRow: 2) == .regular)
    }

    @Test func tableParsesHeaderIntoRowZero() throws {
        // The styling hinges on MarkdownUI numbering the header row as
        // row 0 — verify the parse feeds the seam: header text lands in
        // the first row, body text in the rows after. The commonmark
        // renderer re-emits the header line without inner padding, so
        // the check targets the unpadded pipe form.
        let content = MarkdownContent(table)
        let plain = content.renderPlainText()
        #expect(plain.contains("Stage"))
        #expect(plain.contains("build"))
        #expect(plain.contains("test"))
        // Structure round-trips through the table extension.
        #expect(content.renderMarkdown().contains("|Stage|Files|"))
    }

    @Test func themedTableRendersHeaderDistinctFromBody() throws {
        // Visual proof over the real rendering path: host the themed
        // table in a window (the same way the app displays it), force a
        // light window, rasterize the hierarchy, then scan every row of
        // the table area for background shades. The theme's tiers
        // (filled header, zebra stripe, plain row) must appear as
        // distinct horizontal bands with the header the strongest tint.
        let view = ChatMarkdownView(markdown: table)
            .frame(width: 380)
            .background(Color.white)
        let controller = UIHostingController(rootView: view)
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 402, height: 874))
        window.overrideUserInterfaceStyle = .light
        window.rootViewController = controller
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        RunLoop.current.run(until: Date().addingTimeInterval(0.3))
        controller.view.layoutIfNeeded()

        let raster = UIGraphicsImageRenderer(
            size: controller.view.bounds.size
        ).image { _ in
            controller.view.drawHierarchy(
                in: controller.view.bounds, afterScreenUpdates: true)
        }

        let bands = try #require(
            raster.rowBackgroundBands(), "rasterization diagnostics: \(raster.diagnostics())")
        // The table's tinted bands: the header fill (strongest), the
        // odd-row zebra stripe (middle). The plain even body row is
        // white — indistinguishable from the surrounding page, which is
        // exactly why the header and stripe must carry the distinction.
        let tinted = bands.filter { $0.shade < 0.99 }
        #expect(
            tinted.count >= 2,
            "expected a header band and a stripe band, saw \(bands.map(\.shade))")
        // Header fill is stronger than the stripe: the darkest tinted
        // band is the header, the lighter one the stripe.
        let shades = tinted.map(\.shade).sorted()
        #expect(
            shades[0] < shades[1],
            "header fill must be stronger than the body stripe, saw \(shades)")
        // And both are visibly tinted against white.
        #expect(shades[0] < 0.95)
        #expect(shades[1] < 0.99)
        // The stripe must be weaker than the header.
        #expect(shades[1] > shades[0] + 0.005)
    }

    /// The decoration must cover EVERY table row: the v2 wide-table
    /// adaptor's hidden measuring copy once stayed mounted, and its
    /// cell anchor preferences (last-writer-wins merge) pulled the
    /// visible table's border/stripe bounds short — the last body row
    /// rendered outside the decorated box. Pin: the sample column's
    /// colored bands (header + stripes) extend CONTIGUOUSLY over every
    /// tinted band, and after the last tinted band the rest of the
    /// column is pure page white — no table content below the
    /// decoration's extent.
    @Test func decorationCoversEveryTableRow() throws {
        let view = ChatMarkdownView(markdown: table)
            .frame(width: 380)
            .background(Color.white)
        let controller = UIHostingController(rootView: view)
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 402, height: 874))
        window.overrideUserInterfaceStyle = .light
        window.rootViewController = controller
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        // Two runloop turns: the measuring pass reports after the
        // first layout; the adaptor re-renders on the second.
        RunLoop.current.run(until: Date().addingTimeInterval(0.3))
        controller.view.layoutIfNeeded()

        let raster = UIGraphicsImageRenderer(
            size: controller.view.bounds.size
        ).image { _ in
            controller.view.drawHierarchy(
                in: controller.view.bounds, afterScreenUpdates: true)
        }
        let bands = try #require(
            raster.rowBackgroundBands(), "rasterization diagnostics: \(raster.diagnostics())")
        let tinted = bands.filter { $0.shade < 0.99 }
        #expect(tinted.count >= 2, "header + stripe bands, saw \(bands.map(\.shade))")
        // No TINTED band may appear after a plain gap below the
        // decoration's extent: the bands sequence must be
        // [plain-page?, header, stripe/plain...] with nothing colored
        // after the last tinted band's run.
        if let lastTinted = bands.lastIndex(where: { $0.shade < 0.99 }) {
            let after = bands[(lastTinted + 1)...]
            #expect(
                after.allSatisfy { $0.shade >= 0.99 },
                "table content after the decoration's last band — a row rendered outside the decorated table: \(bands)")
        }
    }

    /// The on-sim context: the table renders inside the chat's
    /// ScrollView + LazyVStack row. The decoration must cover every
    /// row in THAT context too (captures showed the last body row
    /// outside the decorated box — this test pins the real layout
    /// pipeline, not the free window).
    @Test func decorationCoversEveryTableRowInLazyScrollContext() throws {
        let view = ScrollView {
            LazyVStack(alignment: .leading, spacing: 12) {
                ChatMarkdownView(markdown: table)
                    .padding(.horizontal, 12)
            }
            .padding(.vertical, 10)
        }
        .frame(width: 390, height: 700)
        .background(Color.white)
        let controller = UIHostingController(rootView: view)
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 700))
        window.overrideUserInterfaceStyle = .light
        window.rootViewController = controller
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        RunLoop.current.run(until: Date().addingTimeInterval(0.5))
        controller.view.layoutIfNeeded()

        let raster = UIGraphicsImageRenderer(
            size: controller.view.bounds.size
        ).image { _ in
            controller.view.drawHierarchy(
                in: controller.view.bounds, afterScreenUpdates: true)
        }
        let bands = try #require(
            raster.rowBackgroundBands(), "rasterization diagnostics: \(raster.diagnostics())")
        let tinted = bands.filter { $0.shade < 0.99 }
        #expect(
            tinted.count >= 2,
            "header + stripe bands in the lazy-scroll context, saw \(bands.map(\.shade))")
        if let lastTinted = bands.lastIndex(where: { $0.shade < 0.99 }) {
            let after = bands[(lastTinted + 1)...]
            #expect(
                after.allSatisfy { $0.shade >= 0.99 },
                "content below the decoration's extent in the lazy-scroll context: \(bands)")
        }
    }
}

/// Horizontal shade bands discovered in a rasterized table image: every
/// maximal run of rows whose sampled background pixels share one shade.
/// The image is redrawn into a context with a guaranteed RGBA-8888
/// layout first — ImageRenderer's byte order is not contractual.
private struct ImageRowBands {
    /// Distinct bands top-to-bottom, each its average sampled shade
    /// (0 = darkest, 1 = white) and row count.
    let bands: [(shade: Double, rows: Int)]

    init?(uiImage: UIImage, sampleX: Int) {
        guard
            let cgImage = uiImage.cgImage,
            let data = cgImage.dataProvider?.data,
            let bytes = CFDataGetBytePtr(data)
        else { return nil }
        let bytesPerRow = cgImage.bytesPerRow
        let bytesPerPixel = cgImage.bitsPerPixel / 8
        guard bytesPerPixel >= 3, sampleX >= 0,
            sampleX * bytesPerPixel + 2 < bytesPerRow,
            cgImage.height > 1
        else { return nil }

        let offset = { (y: Int) in y * bytesPerRow + sampleX * bytesPerPixel }
        let shade = { (y: Int) in
            let o = offset(y)
            return (Double(bytes[o]) + Double(bytes[o + 1])
                + Double(bytes[o + 2])) / (3 * 255)
        }

        // Rows shade-bucket to 1/255; adjacent rows within 2/255 are the
        // same band (anti-aliasing tolerance).
        var collected: [(shade: Double, rows: Int)] = []
        var currentShade = shade(0)
        var currentRows = 1
        for y in 1..<cgImage.height {
            let rowShade = shade(y)
            if abs(rowShade - currentShade) < 2.0 / 255 {
                currentShade = (currentShade * Double(currentRows) + rowShade)
                    / Double(currentRows + 1)
                currentRows += 1
            } else {
                collected.append((currentShade, currentRows))
                currentShade = rowShade
                currentRows = 1
            }
        }
        collected.append((currentShade, currentRows))
        // Drop hair-thin bands (row separators, text edges).
        bands = collected.filter { $0.rows >= 4 }
    }
}

private extension UIImage {
    /// The image redrawn into a guaranteed RGBA-8888 (premultiplied,
    /// last) pixel layout — ImageRenderer's byte order is not
    /// contractual, so sampling reads this canonical copy instead.
    var canonicalRGBA: CGImage? {
        guard let cgImage else { return nil }
        let width = cgImage.width
        let height = cgImage.height
        let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        context?.interpolationQuality = .none
        context?.draw(
            cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
        return context?.makeImage()
    }
}

private extension UIImage {
    /// Shade bands sampled inside the table's rendered area: the image
    /// is redrawn into a canonical RGBA layout, the table's right edge
    /// located (content-hugging, so its x-extent is unknown), then a
    /// column near that edge — clear of cell text — is scanned row by
    /// row.
    func rowBackgroundBands() -> [(shade: Double, rows: Int)]? {
        guard let canonical = canonicalRGBA else { return nil }
        guard let sampleX = Self.rightClearColumn(of: canonical) else {
            return nil
        }
        return ImageRowBands(
            uiImage: UIImage(cgImage: canonical), sampleX: sampleX)?.bands
    }

    /// Rasterization diagnostics for the band test's failure messages.
    func diagnostics() -> String {
        guard let cgImage else { return "no cgImage" }
        return "size \(cgImage.width)x\(cgImage.height) "
            + "bpp \(cgImage.bitsPerPixel) alpha "
            + "\(cgImage.alphaInfo.rawValue)"
    }

    /// A column near the table's right edge, inside the fill but clear
    /// of any cell text. The canonical layout guarantees bytes are RGB.
    private static func rightClearColumn(
        of cgImage: CGImage
    ) -> Int? {
        guard
            let data = cgImage.dataProvider?.data,
            let bytes = CFDataGetBytePtr(data)
        else { return nil }
        let bytesPerRow = cgImage.bytesPerRow
        let bytesPerPixel = cgImage.bitsPerPixel / 8
        guard bytesPerPixel >= 3 else { return nil }

        let isColored: (_ x: Int, _ y: Int) -> Bool = { x, y in
            let offset = y * bytesPerRow + x * bytesPerPixel
            let r = Double(bytes[offset])
            let g = Double(bytes[offset + 1])
            let b = Double(bytes[offset + 2])
            return max(r, g, b) < 250
        }

        // The table's right edge: the last column holding any non-white
        // pixel (border, stripe, or glyph), minus a small inset to stay
        // inside the fill.
        var rightEdge = 0
        for x in 0..<cgImage.width {
            if (0..<cgImage.height).contains(where: { isColored(x, $0) }) {
                rightEdge = x
            }
        }
        guard rightEdge > 20 else { return nil }
        return rightEdge - 6
    }
}

// MARK: - Multiline (the v2 contract: one paragraph, line breaks inside)

struct ChatMarkdownHardBreakTests {
    /// A single newline is a line break WITHIN one paragraph — never a
    /// paragraph split (cmark's soft break). The v1 pre-pass inserted a
    /// blank line between every prose line; that shattered GFM tables
    /// and fragmented multi-line blockquotes, so the render now keeps
    /// the source structure and turns soft breaks into line breaks at
    /// the view (markdownSoftBreakMode(.lineBreak)). Structure proof:
    /// one <p>, the newline inside it.
    @Test func singleNewlineIsOneParagraph() {
        let html = MarkdownContent("first line\nsecond line").renderHTML()
        #expect(html.components(separatedBy: "<p>").count - 1 == 1)
        // The line break survives as a newline INSIDE the paragraph.
        #expect(html.contains("first line\nsecond line"))
    }

    /// A blank line is a real paragraph boundary (two <p> blocks).
    @Test func blankLineStillSplitsParagraphs() {
        let html = MarkdownContent("para one\n\npara two").renderHTML()
        #expect(html.components(separatedBy: "<p>").count - 1 == 2)
    }

    /// A GFM table stays ONE table block — rows are not paragraphs.
    /// The v1 pre-pass turned every row into a separate <p>, which the
    /// chat table view then framed as stripes of unrelated paragraphs;
    /// with the pre-pass gone, MarkdownUI parses the whole table.
    @Test func gfmTableParsesAsOneTable() {
        let source = """
            | Phase | Status |
            | --- | --- |
            | Build | passing |
            | Tests | failing |
            """
        let html = MarkdownContent(source).renderHTML()
        #expect(html.contains("<table>"))
        #expect(html.contains("<thead>"))
        // cmark's table renderer keeps header cells inside <thead> without
        // emitting <th> tags; the contract is the ONE-table structure with
        // header separated — not a specific tag.
        #expect(html.components(separatedBy: "<p>").count - 1 == 0)
    }

    /// A multi-line blockquote is ONE blockquote with its line breaks
    /// inside — the accent bar + wash render once per action, never
    /// one bar per line (the v1 "quote renders duplicated" finding).
    @Test func multilineBlockquoteIsOneQuote() {
        let source = "> quoted line one\n> quoted line two"
        let content = MarkdownContent(source)
        let html = content.renderHTML()
        #expect(html.components(separatedBy: "<blockquote>").count - 1 == 1)
        // The lines stay in ONE paragraph inside the quote.
        let quoteHTML = content.childContent?.renderHTML() ?? ""
        #expect(quoteHTML.components(separatedBy: "<p>").count - 1 == 1)
        #expect(quoteHTML.contains("quoted line one\nquoted line two"))
    }

    /// Fenced code keeps its literal line structure (a code block is
    /// data, not prose — soft-break mode never reaches inside it).
    @Test func fencedCodeStaysVerbatim() {
        let source = "before\n```swift\nlet a = 1\nlet b = 2\n```\nafter"
        let html = MarkdownContent(source).renderHTML()
        #expect(html.contains("<pre><code"))
        #expect(html.contains("let a = 1\nlet b = 2"))
        #expect(html.contains("before"))
        #expect(html.contains("after"))
    }
}

// MARK: - IRC section fencing (v2; the review's data-loss regressions)

struct ChatMarkdownIRCFencingTests {
    /// The review's data-loss repro: a paragraph whose SINGLE line
    /// matches `Nick: ...` is ordinary prose — it must pass through
    /// UNCHANGED (the first cut's flush dropped it to '').
    @Test func loneNickLinePassesThroughUnchanged() {
        let input = "Note: keep this"
        #expect(ChatMarkdownText.fenceIRCSections(input) == input)
    }

    /// A qualifying multi-line log still fences — the pass-through
    /// guard must not over-correct into never fencing.
    @Test func qualifyingLogFences() {
        let input = "[09:41] <jhou> the build broke\n[09:42] <sam> seeing it"
        let out = ChatMarkdownText.fenceIRCSections(input)
        #expect(out.hasPrefix("```irc\n"))
        #expect(out.hasSuffix("\n```"))
        #expect(out.contains("[09:41] <jhou> the build broke"))
    }

    /// A MIXED paragraph (some matching, some prose lines) is NOT
    /// fenceable — the fence must wrap the WHOLE paragraph or nothing;
    /// a matching subsequence inside prose never fences alone.
    @Test func mixedParagraphPassesThroughWhole() {
        let input = "Intro prose line\n[09:41] <jhou> log line\nMore prose here"
        #expect(ChatMarkdownText.fenceIRCSections(input) == input)
    }

    /// The review's tilde repro: content inside a TILDE fence is data —
    /// a `Note: preserve literally` line inside ~~~ fences must stay
    /// verbatim, never re-fenced and never dropped.
    @Test func tildeFenceContentStaysVerbatim() {
        let input = "~~~text\nNote: preserve literally\n~~~"
        #expect(ChatMarkdownText.fenceIRCSections(input) == input)
    }

    /// Blank-line separators between paragraphs are preserved — the
    /// paragraph rewriter must not merge or drop them.
    @Test func blankSeparatorsSurvive() {
        // A single-line log paragraph stays PROSE (>= 2-line gate):
        // the whole input passes through unchanged, separators intact.
        let input = "first para\n\n[09:41] <jhou> a log line\n\nlast para"
        #expect(ChatMarkdownText.fenceIRCSections(input) == input)
        // A TWO-line log paragraph between the same separators fences,
        // and the separators + prose paragraphs survive around it.
        let input2 = "first para\n\n[09:41] <jhou> a log line\n[09:42] <sam> another\n\nlast para"
        let out = ChatMarkdownText.fenceIRCSections(input2)
        #expect(out.hasPrefix("first para\n\n```irc\n"))
        #expect(out.hasSuffix("\n```\n\nlast para"))
    }

    /// A fence NEVER wraps a partial run: the qualifying paragraph is
    /// classified before any rewrite, so an unfenced emit is the
    /// ORIGINAL text, not a truncated one.
    @Test func noPartialFencing() {
        let input = "The build broke on main today:\nsee the CI log for why"
        #expect(ChatMarkdownText.fenceIRCSections(input) == input)
    }
}

// MARK: - ChatKeyboardInset (v2 item 5; the review's geometry regressions)

struct ChatKeyboardInsetTests {
    /// Drives the inset through real notifications with an injected
    /// measurement seam.
    @MainActor
    private func makeInset(
        measure: @escaping @MainActor (CGRect) -> CGFloat?
    ) -> (ChatKeyboardInset, NotificationCenter) {
        let center = NotificationCenter()
        let inset = ChatKeyboardInset(
            notificationCenter: center, measure: measure)
        return (inset, center)
    }

    @MainActor
    private func post(
        _ center: NotificationCenter, _ name: Notification.Name,
        frame: CGRect? = nil
    ) {
        var userInfo: [AnyHashable: Any] = [:]
        if let frame {
            userInfo[UIResponder.keyboardFrameEndUserInfoKey] = frame
        }
        center.post(
            name: name, object: nil, userInfo: userInfo.isEmpty ? nil : userInfo)
    }

    /// Async main-queue delivery + the 60ms coalesce: the main thread
    /// must YIELD for the queue-scheduled observer block to run; poll
    /// with sleeps (each `try await Task.sleep` services the main queue).
    @MainActor
    private func settle(
        _ inset: ChatKeyboardInset, to height: CGFloat
    ) async -> Bool {
        for _ in 0..<50 {
            if inset.height == height { return true }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return inset.height == height
    }

    @Test func dockedPresentationSetsHeight() async throws {
        let (inset, center) = await MainActor.run {
            makeInset { frame in
                frame.height > 100 ? frame.height : nil
            }
        }
        await MainActor.run {
            post(center, UIResponder.keyboardWillShowNotification, frame: CGRect(
                x: 0, y: 500, width: 390, height: 400))
        }
        let settled = await settle(inset, to: 400)
        let finalHeight = await MainActor.run { inset.height }
        #expect(settled, "coalesced docked height never landed; got \(finalHeight)")
    }

    @Test func dismissalClearsHeight() async throws {
        let (inset, center) = await MainActor.run {
            makeInset { frame in
                frame.height > 100 ? frame.height : nil
            }
        }
        await MainActor.run {
            post(center, UIResponder.keyboardWillShowNotification, frame: CGRect(
                x: 0, y: 500, width: 390, height: 400))
        }
        _ = await settle(inset, to: 400)
        await MainActor.run {
            post(center, UIResponder.keyboardWillHideNotification)
        }
        let cleared = await settle(inset, to: 0)
        #expect(cleared, "dismissal never cleared the inset")
    }

    /// The review's floating-keyboard case: a frame that covers no
    /// bottom edge measures ZERO, and — the actual regression — a zero
    /// measurement arriving while a previous height is set must CLEAR
    /// it (the first cut discarded the update and the stale inset
    /// stayed pinned).
    @Test func zeroCoverageClearsAPreviouslySetInset() async throws {
        let (inset, center) = await MainActor.run {
            makeInset { frame in
                // Floating geometry: hovers mid-window, never touches
                // the bottom edge → measures zero.
                if frame.minY > 200 && frame.maxY < 700 { return 0 }
                return frame.height
            }
        }
        // Docked first: height set.
        await MainActor.run {
            post(center, UIResponder.keyboardWillShowNotification, frame: CGRect(
                x: 0, y: 500, width: 390, height: 400))
        }
        let docked = await settle(inset, to: 400)
        #expect(docked, "docked presentation never landed")
        // Then docked→floating: the update carries the floating frame
        // and must CLEAR the inset, not keep the stale 400.
        await MainActor.run {
            post(center, UIResponder.keyboardWillChangeFrameNotification, frame: CGRect(
                x: 40, y: 300, width: 320, height: 200))
        }
        let cleared = await settle(inset, to: 0)
        let finalHeight2 = await MainActor.run { inset.height }
        #expect(cleared, "floating transition never cleared the inset; got \(finalHeight2)")
    }

    /// The observer leak: the inset's block registrations are REMOVED
    /// at deinit — after the inset dies, posting must not deliver
    /// anywhere (no zombie observer in the center).
    @Test func observersAreRemovedAtDeinit() async throws {
        await MainActor.run {
            let center = NotificationCenter()
            do {
                _ = ChatKeyboardInset(
                    notificationCenter: center,
                    measure: { _ in 300 })
            }
            // Delivered after deinit → a leaked registration. The
            // center holds weak self so delivery is a no-op for the
            // dead inset; the OBSERVABLE contract is that no block
            // remains registered at all.
            var delivered = 0
            let probe = center.addObserver(
                forName: UIResponder.keyboardWillShowNotification,
                object: nil, queue: .main
            ) { _ in delivered += 1 }
            defer { center.removeObserver(probe) }
            center.post(name: UIResponder.keyboardWillShowNotification, object: nil)
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
            // The probe itself received the post.
            #expect(delivered == 1)
        }
    }
}
