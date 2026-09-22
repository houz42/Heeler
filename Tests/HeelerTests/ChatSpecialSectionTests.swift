import Testing
import Foundation

// SPDX-License-Identifier: Apache-2.0

@testable import Heeler

/// Special-section extraction (`ChatSpecialSectionParser` +
/// `ChatFiltering`'s row funnel): `<system-notice>` and `<irc>` blocks
/// are parsed out of transcript text BEFORE the markdown path, render
/// as their own row kind at the tag's source position, and hide
/// entirely at L0 (with the residual prose keeping the tags stripped,
/// never raw tag text).
@Suite("Chat Special Sections")
struct ChatSpecialSectionTests {

    // MARK: - Parser: tag extraction

    @Test func extractsSystemNoticeWithMultiLineBody() {
        let text = """
        Prose before the notice.

        <system-notice>Skill "shell-qa" is now active.
        Commands run through the dev-box QA profile.
        Exit codes are recorded per step.</system-notice>

        Prose after the notice.
        """
        let extraction = ChatSpecialSectionParser.extract(
            from: text, baseID: "M#2")

        #expect(extraction.sections.count == 1)
        let section = extraction.sections[0]
        #expect(section.kind == .systemNotice)
        // The body is verbatim, multi-line preserved.
        #expect(section.body == """
        Skill "shell-qa" is now active.
        Commands run through the dev-box QA profile.
        Exit codes are recorded per step.
        """)
        // The summary is the FIRST non-empty line.
        #expect(section.summary == "Skill \"shell-qa\" is now active.")
        #expect(section.id == "M#2#system-notice#0")
    }

    @Test func extractsIrcMessage() {
        let text = "<irc><Main> The fix looks good — ship it.</irc>"
        let extraction = ChatSpecialSectionParser.extract(
            from: text, baseID: "M#0")

        #expect(extraction.sections.count == 1)
        #expect(extraction.sections[0].kind == .irc)
        #expect(extraction.sections[0].body == "<Main> The fix looks good — ship it.")
        #expect(extraction.sections[0].summary == "<Main> The fix looks good — ship it.")
        #expect(extraction.sections[0].id == "M#0#irc#0")
    }

    @Test func segmentsInterleaveProseAndSectionsInSourceOrder() {
        let text = """
        First prose.
        <irc><Main> hello</irc>
        Middle prose.
        <system-notice>heads up</system-notice>
        Final prose.
        """
        let extraction = ChatSpecialSectionParser.extract(
            from: text, baseID: "M#1")

        #expect(extraction.sections.map(\.kind) == [.irc, .systemNotice])
        // Segment texts carry the residual prose; a segment holds
        // everything up to the NEXT tag (the residual
        // "\nMiddle prose.\n" and the trailing "Final prose."
        // are the two prose segments around the sections).
        #expect(extraction.segments.count == 3)
        #expect(extraction.segments[0].followingSection?.kind == .irc)
        #expect(extraction.segments[1].followingSection?.kind == .systemNotice)
        #expect(extraction.segments[1].text.contains("Middle prose."))
        #expect(extraction.segments.last?.followingSection == nil)
        #expect(extraction.segments.last?.text.contains("Final prose.") == true)
    }

    @Test func multipleSectionsOfOneKindGetDistinctStableIDs() {
        let text = """
        <irc>a</irc>
        <irc>b</irc>
        """
        let extraction = ChatSpecialSectionParser.extract(
            from: text, baseID: "M#3")

        #expect(extraction.sections.map(\.body) == ["a", "b"])
        #expect(extraction.sections.map(\.id) == [
            "M#3#irc#0", "M#3#irc#1",
        ])
        // Re-parsing the same text yields the same ids (level
        // switching never re-keys rows).
        let again = ChatSpecialSectionParser.extract(from: text, baseID: "M#3")
        #expect(again.sections.map(\.id) == extraction.sections.map(\.id))
    }

    @Test func noTagsYieldNoSections() {
        let extraction = ChatSpecialSectionParser.extract(
            from: "Ordinary prose, no tags.", baseID: "M#0")
        #expect(extraction.sections.isEmpty)
        #expect(extraction.segments.count == 1)
        #expect(extraction.segments[0].followingSection == nil)
        #expect(extraction.segments[0].text == "Ordinary prose, no tags.")
    }

    @Test func nestedSameKindOpenerIsBodyData() {
        // The HTML-scanner rule: first close wins; an inner opener is
        // body content, never a second section.
        let text = "<irc>outer <irc>inner</irc> tail</irc> after"
        let extraction = ChatSpecialSectionParser.extract(
            from: text, baseID: "M#0")

        #expect(extraction.sections.count == 1)
        #expect(extraction.sections[0].body == "outer <irc>inner")
        // Only the FIRST close tag is consumed; the stray `</irc>`
        // and tail stay residual prose (an unmatched close tag is
        // inert text — a real transcript never emits one without a
        // body).
        let tail = extraction.segments.last?.text ?? ""
        #expect(tail.contains("after"))
        #expect(!tail.contains("<irc>"))
    }

    @Test func unclosedOpenerExtendsToEndOfText() {
        // A streaming turn must not flash raw tag text: an opener
        // with no close tag yet treats the remainder as its body.
        let text = "Prose.\n<system-notice>partial body, still streaming"
        let extraction = ChatSpecialSectionParser.extract(
            from: text, baseID: "M#0")

        #expect(extraction.sections.count == 1)
        #expect(extraction.sections[0].body == "partial body, still streaming")
        #expect(extraction.sections[0].summary == "partial body, still streaming")
    }


    @Test func emptyBodyStillExtracts() {
        let extraction = ChatSpecialSectionParser.extract(
            from: "before <system-notice></system-notice> after",
            baseID: "M#0")

        #expect(extraction.sections.count == 1)
        #expect(extraction.sections[0].body.isEmpty)
        // The summary falls back to the kind's label — the chip never
        // renders a blank excerpt.
        #expect(extraction.sections[0].summary == "System notice")
    }

    @Test func summaryCollapsesWhitespaceAndSkipsBlankLines() {
        let text = """
        <system-notice>

           Indented   first   line
        with tabs.
        </system-notice>
        """
        let extraction = ChatSpecialSectionParser.extract(
            from: text, baseID: "M#0")
        #expect(extraction.sections[0].summary == "Indented first line")
    }

    @Test func tagsAreCaseInsensitive() {
        let extraction = ChatSpecialSectionParser.extract(
            from: "<IRC>loud</IRC>", baseID: "M#0")
        #expect(extraction.sections.count == 1)
        #expect(extraction.sections[0].kind == .irc)
    }

    // MARK: - Filtering: rows + detail gating

    private func sectionedTurn() -> ChatMessage {
        ChatMessage(role: .assistant, blocks: [
            .text(
                """
                Answer prose before.

                <system-notice>Skill active
                multi-line detail.</system-notice>

                <irc><Main> peer note</irc>

                Closing prose.
                """),
        ])
    }

    @Test func l0HidesSectionsEntirelyAndStripsTagsFromProse() {
        let rows = ChatFiltering.visibleRows(
            messages: [sectionedTurn()], toolResults: [], level: .l0)

        // Zero section rows at L0…
        #expect(rows.filter {
            if case .specialSection = $0 { return true } else { return false }
        }.isEmpty)
        // …and the residual prose renders WITHOUT any raw tag text.
        let prose = rows.compactMap { row -> String? in
            guard case .text(_, _, _, let text) = row else { return nil }
            return text
        }.joined()
        #expect(prose.contains("Answer prose before."))
        #expect(prose.contains("Closing prose."))
        #expect(!prose.contains("<system-notice>"))
        #expect(!prose.contains("</system-notice>"))
        #expect(!prose.contains("<irc>"))
    }

    @Test func l1ShowsSectionsAsTheirOwnRowsAtSourcePosition() {
        let rows = ChatFiltering.visibleRows(
            messages: [sectionedTurn()], toolResults: [], level: .l1)

        let kindAt: (Int) -> String? = { index in
            guard case .specialSection(let section) = rows[index] else {
                return nil
            }
            return section.kind.rawValue
        }
        // Source order: prose → system-notice → irc → closing prose.
        #expect(rows.count == 4)
        #expect(kindAt(1) == "system-notice")
        #expect(kindAt(2) == "irc")
        guard case .text = rows[0], case .text = rows[3] else {
            Issue.record("prose rows must bracket the sections in order")
            return
        }
    }

    @Test func levelSwitchKeepsExistingRowIdsMonotonic() {
        let turn = sectionedTurn()
        func rowsAt(_ level: DetailLevel) -> [ChatRow] {
            ChatFiltering.visibleRows(
                messages: [turn], toolResults: [], level: level)
        }
        let l0 = rowsAt(.l0), l1 = rowsAt(.l1), l2 = rowsAt(.l2), l3 = rowsAt(.l3)

        // Levels nest: every id at L0 survives at L1+ (prose is
        // conversation, visible at every level).
        #expect(Set(l1.map(\.id)).isSuperset(of: Set(l0.map(\.id))))
        // Section ids are identical at every level that shows them
        // (same message, so the same `messageID#blockIndex` base).
        #expect(l1.map(\.id) == l2.map(\.id))
        #expect(l1.map(\.id) == l3.map(\.id))
    }

    @Test func sectionRowsNeverEnterBubbles() {
        // Chrome rows break bubble runs: a section between two prose
        // segments of ONE message yields two bubbles, not one fused.
        let items = ChatFiltering.visibleItems(
            from: ChatFiltering.visibleRows(
                messages: [sectionedTurn()], toolResults: [], level: .l2),
            level: .l2)

        let bubbles = items.filter {
            if case .bubble = $0 { return true } else { return false }
        }
        #expect(bubbles.count == 2)
        let sections = items.filter {
            if case .row(let row) = $0, case .specialSection = row {
                return true
            }
            return false
        }
        #expect(sections.count == 2)
    }
}
