import Foundation
import MarkdownUI
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
