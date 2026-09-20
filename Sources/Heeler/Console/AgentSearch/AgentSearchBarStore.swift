import Foundation
import Observation

// SPDX-License-Identifier: Apache-2.0
//
// The search bar's state (approved redesign, handoff §B): the query, the
// filter chips, and the suggestion highlight. Pure keyboard semantics:
// Enter/Tab accept, arrows move, Esc dismisses — none of them ever
// submit a message. Query and filters live here (owned by ConsoleView as
// @State), so they survive navigation by construction.

@MainActor
@Observable
final class AgentSearchBarStore {
    private(set) var engine: AgentSearchEngine
    /// -1 = none highlighted.
    private(set) var highlightIndex: Int = -1
    private(set) var showsSuggestions: Bool = false

    init(engine: AgentSearchEngine = AgentSearchEngine()) {
        self.engine = engine
    }

    var isConstrained: Bool { engine.isConstrained }

    // MARK: Query

    /// Typing updates the query and reopens suggestions; the highlight
    /// resets so the top row is the first Enter.
    func updateQuery(_ raw: String) {
        engine = engine.settingQuery(raw)
        highlightIndex = -1
        showsSuggestions = true
    }

    func clearQuery() {
        updateQuery("")
    }

    func clearAll() {
        engine = engine.cleared()
        highlightIndex = -1
    }

    // MARK: Suggestions

    var suggestionsHelp: String {
        AgentSearchQuery(raw: engine.rawQuery).field != nil
            ? "Choose a value to add a filter"
            : "Fuzzy titles · filter by context"
    }

    func visibleSuggestionCount(over agents: [ConsoleAgent]) -> Int {
        engine.suggestions(over: agents).count
    }

    func moveHighlight(_ delta: Int, over agents: [ConsoleAgent]) {
        showsSuggestions = true
        let count = visibleSuggestionCount(over: agents)
        guard count > 0 else { return }
        if highlightIndex < 0 {
            highlightIndex = delta > 0 ? 0 : count - 1
            return
        }
        highlightIndex = (highlightIndex + delta + count) % count
    }

    func dismissSuggestions() {
        showsSuggestions = false
        highlightIndex = -1
    }

    /// Enter/Tab: accepts the highlighted suggestion (top row when none).
    /// Accepting a value row adds the filter chip and clears the query;
    /// a field row rewrites the query to the `field:` prefix.
    func acceptHighlighted(over agents: [ConsoleAgent]) {
        let suggestions = engine.suggestions(over: agents)
        guard !suggestions.isEmpty else { return }
        let index = highlightIndex >= 0 && highlightIndex < suggestions.count
            ? highlightIndex : 0
        accept(suggestions[index])
    }

    /// Tap or keyboard accept.
    func accept(_ suggestion: AgentSearchEngine.Suggestion) {
        engine = suggestion.accepted(in: engine)
        highlightIndex = -1
        showsSuggestions = false
    }

    // MARK: Filters

    func removeFilter(_ filter: AgentSearchFilter) {
        engine = engine.removingFilter(filter)
    }
}
