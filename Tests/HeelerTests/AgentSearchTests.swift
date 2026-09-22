import Foundation
import Testing

@testable import Heeler

@MainActor
@Suite("Agents fuzzy search")
struct AgentSearchTests {
    // MARK: Fixtures

    private func makeAgent(
        host: String = "devbox",
        session: String = "",
        workspace: String? = "heeler",
        tab: String? = nil,
        tabPosition: Int? = 1,
        tabCount: Int = 1,
        kind: String = "omp",
        name: String? = nil,
        title: String = "Fix the flaky test",
        paneID: String = "p1",
        status: AgentStatus = .working,
        snapshotOrder: Int? = 0,
        stateChangeSeq: Int? = 1
    ) -> ConsoleAgent {
        ConsoleAgent(
            hostID: UUID(), hostName: host,
            agent: Agent(
                terminalID: "term_\(paneID)", kind: kind, title: title, status: status,
                workspaceID: "w_\(paneID)", tabID: "w_\(paneID):t1", paneID: paneID,
                cwd: "/work/\(paneID)", revision: 1, name: name,
                stateChangeSeq: stateChangeSeq),
            workspaceLabel: workspace, repositoryCheckout: nil,
            hostSessionName: session,
            tabLabel: tab, tabPosition: tabPosition, workspaceTabCount: tabCount,
            snapshotOrder: snapshotOrder)
    }

    // MARK: Fuzzy scoring

    @Test func fuzzyScoringMatchesApprovedPreviewLadder() {
        #expect(AgentFuzzyMatcher.score("fix", against: "Fix") == 100)
        #expect(AgentFuzzyMatcher.score("fix", against: "Fix the flaky test") == 90)
        #expect(AgentFuzzyMatcher.score("flaky", against: "Fix the flaky test") == 80)
        // Abbreviation: subsequence.
        #expect(AgentFuzzyMatcher.score("fixft", against: "Fix the flaky test") >= 50)
        // A typo the subsequence test cannot satisfy still matches: the
        // edit-distance band (30).
        #expect(AgentFuzzyMatcher.score("hxeler", against: "heeler") == 30)
        // An in-order deletion scores as an abbreviation, outranking the typo band.
        #expect(AgentFuzzyMatcher.score("heler", against: "heeler") == 66)
        // No match.
        #expect(AgentFuzzyMatcher.score("zzz", against: "Fix the flaky test") == -1)
    }

    @Test func multiTermQueryScoresMeanOfTerms() {
        let prefix = AgentFuzzyMatcher.score("fix", against: "Fix the flaky test")
        let substring = AgentFuzzyMatcher.score("flaky", against: "Fix the flaky test")
        let multi = AgentFuzzyMatcher.score("fix flaky", against: "Fix the flaky test")
        #expect(prefix == 90 && substring == 80)
        #expect(multi == 85)  // Mean of both terms.
        // One term missing: -1 (all terms must match).
        #expect(AgentFuzzyMatcher.score("fix absent", against: "Fix the flaky test") == -1)
    }

    @Test func normalizeFoldsCaseDiacriticsAndWidth() {
        #expect(AgentFuzzyMatcher.normalize("HÉELER") == AgentFuzzyMatcher.normalize("heeler"))
        #expect(AgentFuzzyMatcher.normalize("ｆｉｘ") == "fix")
    }

    @Test func titleSearchMatchesAbbreviationsAndTypos() {
        let agents = [
            makeAgent(title: "Fix the flaky test", paneID: "a"),
            makeAgent(title: "Draft the release notes", paneID: "b"),
        ]
        let engine = AgentSearchEngine(rawQuery: "fixft")
        #expect(engine.matches(over: agents).map(\.agent.paneID) == ["a"])
        // Typo tolerance: "flakx" is one edit from "flaky" and appears only
        // in the first title.
        let typo = AgentSearchEngine(rawQuery: "flakx")
        #expect(typo.matches(over: agents).map(\.agent.paneID) == ["a"])
    }

    // MARK: Relevance ordering

    @Test func relevanceOutranksInputOrderWhileQuerying() {
        let agents = [
            makeAgent(name: "substr-row", title: "About the flaky test", paneID: "substring"),
            makeAgent(name: "flaky", title: "flaky", paneID: "exact"),
        ]
        let engine = AgentSearchEngine(rawQuery: "flaky")
        let matched = engine.matches(over: agents)
        // Exact beats substring regardless of input order.
        #expect(matched.first?.agent.paneID == "exact")
    }

    // MARK: Filters: AND across fields, OR within

    @Test func differentFieldsANDTogether() {
        let agents = [
            makeAgent(host: "devbox", workspace: "heeler", paneID: "both"),
            makeAgent(host: "devbox", workspace: "other", paneID: "one"),
            makeAgent(host: "build", workspace: "heeler", paneID: "otherhost"),
        ]
        let engine = AgentSearchEngine(filters: [
            .init(field: .host, value: "devbox"),
            .init(field: .workspace, value: "heeler"),
        ])
        #expect(engine.matches(over: agents).map(\.agent.paneID) == ["both"])
    }

    @Test func multipleValuesOfOneFieldOR() {
        let agents = [
            makeAgent(workspace: "heeler", paneID: "a"),
            makeAgent(workspace: "payments", paneID: "b"),
            makeAgent(workspace: "docs", paneID: "c"),
        ]
        let engine = AgentSearchEngine(filters: [
            .init(field: .workspace, value: "heeler"),
            .init(field: .workspace, value: "payments"),
        ])
        let matched = Set(engine.matches(over: agents).map(\.agent.paneID))
        #expect(matched == ["a", "b"])
    }

    @Test func fieldQueryRestrictsMatchingToThatField() {
        let agents = [
            makeAgent(workspace: "heeler", title: "Unrelated", paneID: "a"),
            makeAgent(workspace: "docs", title: "heeler polish", paneID: "b"),
        ]
        // workspace: heeler must match the workspace field, not a title.
        let engine = AgentSearchEngine(rawQuery: "workspace: heeler")
        #expect(engine.matches(over: agents).map(\.agent.paneID) == ["a"])
    }

    // MARK: Suggestions

    @Test func fieldPrefixQueryYieldsValueSuggestionsWithCounts() throws {
        let agents = [
            makeAgent(workspace: "heeler", paneID: "a"),
            makeAgent(workspace: "heeler", paneID: "b"),
            makeAgent(workspace: "docs", paneID: "c"),
        ]
        let engine = AgentSearchEngine(rawQuery: "workspace: hee")
        let suggestions = engine.suggestions(over: agents)
        let heeler = try #require(suggestions.first { $0.label == "heeler" })
        #expect(heeler.kind == .value && heeler.count == 2)
        #expect(!suggestions.contains { $0.label == "docs" })
    }

    @Test func acceptedValueSuggestionAddsFilterAndClearsQuery() {
        let engine = AgentSearchEngine(rawQuery: "state: work")
        let suggestion = AgentSearchEngine.Suggestion(
            kind: .value, field: .state, value: "Working", label: "Working", score: 90, count: 0)
        let next = suggestion.accepted(in: engine)
        #expect(next.rawQuery.isEmpty)
        #expect(next.filters == [.init(field: .state, value: "Working")])
    }

    @Test func alreadyFilteredValuesDoNotReappear() {
        let agents = [makeAgent(workspace: "heeler", paneID: "a")]
        let engine = AgentSearchEngine(filters: [.init(field: .workspace, value: "heeler")])
        let suggestions = engine.suggestions(over: agents)
        #expect(!suggestions.contains { $0.kind == .value && $0.label == "heeler" })
    }

    // MARK: State labels

    @Test func stateValuesUseHumanWording() {
        #expect(AgentStatus.blocked.searchLabel == "Needs you")
        #expect(AgentStatus(rawValue: "surprise").searchLabel == "Unknown")
        let agents = [makeAgent(paneID: "a", status: .blocked)]
        let engine = AgentSearchEngine(rawQuery: "state: needs")
        #expect(engine.matches(over: agents).map(\.agent.paneID) == ["a"])
    }

    // MARK: Bar store keyboard semantics

    @Test func typingResetsHighlightAndArrowsNavigateAndEnterAccepts() {
        let agents = [makeAgent(workspace: "heeler", paneID: "a"), makeAgent(workspace: "docs", paneID: "b")]
        let bar = AgentSearchBarStore()
        bar.updateQuery("h")
        // No highlight: first down arrow highlights the top row.
        bar.moveHighlight(1, over: agents)
        #expect(bar.highlightIndex == 0)
        bar.moveHighlight(1, over: agents)
        #expect(bar.highlightIndex == 1)
        // Wrap.
        bar.moveHighlight(1, over: agents)
        #expect(bar.highlightIndex == 0)
        // Up from none goes to the last row.
        bar.dismissSuggestions()
        bar.moveHighlight(-1, over: agents)
        #expect(bar.highlightIndex == 1)
        // Enter accepts the highlighted suggestion: a value row adds a filter.
        bar.acceptHighlighted(over: agents)
        #expect(bar.engine.filters == [.init(field: .workspace, value: "heeler")])
        #expect(bar.engine.rawQuery.isEmpty)
    }

    @Test func enterWithoutHighlightOrWithDismissedSuggestionsAcceptsNothing() {
        // Review finding #6: no phantom accepts — Enter with suggestions
        // dismissed (Esc), or with no highlight, changes NOTHING.
        let agents = [makeAgent(workspace: "heeler", paneID: "a")]
        let bar = AgentSearchBarStore()
        bar.updateQuery("h")
        bar.dismissSuggestions()
        bar.acceptHighlighted(over: agents)
        #expect(bar.engine.filters.isEmpty)
        #expect(bar.engine.rawQuery == "h")
        // Visible suggestions but nothing highlighted: Enter still does
        // nothing (the user must see and choose).
        bar.moveHighlight(1, over: agents)
        bar.dismissSuggestions()
        bar.acceptHighlighted(over: agents)
        #expect(bar.engine.filters.isEmpty)
    }

    @Test func fieldRowAcceptanceOpensValueCompletions() {
        // Review finding #6: accepting a `field:` prefix is a half-typed
        // state — the suggestion list stays OPEN showing the field's
        // values.
        let agents = [makeAgent(host: "devbox", paneID: "a")]
        let bar = AgentSearchBarStore()
        bar.updateQuery("hos")
        bar.moveHighlight(1, over: agents)
        let fieldRow = bar.engine.suggestions(over: agents)
            .first { $0.kind == .field }!
        bar.accept(fieldRow)
        #expect(bar.engine.rawQuery == "host:")
        #expect(bar.showsSuggestions, "value completions must open after the prefix")
        #expect(!bar.engine.suggestions(over: agents).isEmpty)
    }

    @Test func chipsOnlyQueriesKeepTheSuppliedSortOrder() {
        // Review finding #5: chips-only searches never apply relevance —
        // the caller's (chosen-sort) order passes through untouched.
        let agents = [
            makeAgent(workspace: "heeler", title: "Zulu", paneID: "z"),
            makeAgent(workspace: "heeler", title: "Alpha", paneID: "a"),
            makeAgent(workspace: "docs", title: "Mike", paneID: "m"),
        ]
        let engine = AgentSearchEngine(filters: [.init(field: .workspace, value: "heeler")])
        let matched = engine.matches(over: agents)
        #expect(matched.map { (row: ConsoleAgent) in row.agent.paneID } == ["z", "a"], "supplied order preserved")
        #expect(engine.isConstrained && !engine.isTextQuery)
    }

    @Test func textQueriesStillRankByRelevance() {
        let agents = [
            makeAgent(title: "About heeler work", paneID: "substring"),
            makeAgent(name: "heeler", title: "Unrelated", paneID: "exact"),
        ]
        let engine = AgentSearchEngine(rawQuery: "heeler")
        #expect(engine.isTextQuery)
        #expect(engine.matches(over: agents).first?.agent.paneID == "exact")
    }

    @Test func queryAndFiltersSurviveStoreRoundTrips() {
        // The state is a plain value store owned by @State: navigation cannot
        // reset it. The engine round-trips through every mutation.
        var engine = AgentSearchEngine(rawQuery: "fix")
        engine = engine
            .accepting(.init(kind: .value, field: .state, value: "Working", label: "Working", score: 1, count: 1))
        engine = engine.removingFilter(.init(field: .state, value: "Working"))
        #expect(engine.filters.isEmpty && engine.rawQuery.isEmpty)
        #expect(!engine.isConstrained)
    }
}

extension AgentSearchEngine {
    /// Test seam for applying a suggestion directly.
    func accepting(_ suggestion: Suggestion) -> AgentSearchEngine {
        suggestion.accepted(in: self)
    }
}
