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

    /// The Cancel control's full reset (user directive): query AND chips
    /// cleared, suggestions dismissed — the caller resigns focus so the
    /// keyboard follows.
    func cancelSearch() {
        engine = engine.cleared()
        highlightIndex = -1
        showsSuggestions = false
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

    /// Reopens the suggestion list (the magnifier's other half).
    func reopenSuggestions() {
        showsSuggestions = true
        highlightIndex = -1
    }

    /// Enter/Tab: accepts the VISIBLE HIGHLIGHTED suggestion only (review
    /// finding #6). With suggestions dismissed (Esc) or nothing
    /// highlighted, Enter does NOTHING — no phantom first-row accept.
    /// Accepting a value row adds the filter chip and clears the query;
    /// a field row rewrites the query to the `field:` prefix AND OPENS
    /// the field's value completions (the prefix is a half-typed state,
    /// not a finished one).
    func acceptHighlighted(over agents: [ConsoleAgent]) {
        guard showsSuggestions else { return }
        let suggestions = engine.suggestions(over: agents)
        guard highlightIndex >= 0, highlightIndex < suggestions.count else {
            return
        }
        accept(suggestions[highlightIndex])
    }

    /// Tap or keyboard accept. Field rows keep the suggestion list OPEN
    /// (value completions follow the prefix); value rows close it.
    func accept(_ suggestion: AgentSearchEngine.Suggestion) {
        let wasField = suggestion.kind == .field
        engine = suggestion.accepted(in: engine)
        if wasField {
            highlightIndex = -1
            showsSuggestions = true
        } else {
            highlightIndex = -1
            showsSuggestions = false
        }
    }

    // MARK: Filters

    func removeFilter(_ filter: AgentSearchFilter) {
        engine = engine.removingFilter(filter)
    }

    /// The quick-state chips (user device finding): single-state quick
    /// filter, replacing any other state value; the "All" chip clears
    /// every state filter. Rides the same filter model as typed chips.
    func setQuickStateFilter(_ value: String) {
        engine = engine.settingQuickState(value)
    }

    func removeAllStateFilters() {
        for filter in engine.filters where filter.field == .state {
            engine = engine.removingFilter(filter)
        }
    }
}
