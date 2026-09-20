import Foundation

// SPDX-License-Identifier: Apache-2.0
//
// The Agents list search engine (approved redesign, handoff §B): fuzzy
// title matching (abbreviations and typos), `field:` context completion
// with fuzzy value matching, and removable filter chips. Pure logic, no
// SwiftUI/UIKit, so the behavior runs from tests and standalone runners
// against the real sources.
//
// Scoring mirrors the user-approved preview's `agent-search.js` exactly:
//   100 exact · 90 prefix · 80 substring · 50+ subsequence · 30 edit distance
// (subsequence = abbreviation; edit distance = typo tolerance).

/// One search field the query and suggestions work over.
enum AgentSearchField: String, CaseIterable, Identifiable, Sendable {
    case host, session, workspace, tab, state

    var id: String { rawValue }

    /// The `field:` prefix the query parser accepts (case-insensitive).
    var queryPrefix: String { "\(rawValue):" }

    var label: String {
        switch self {
        case .host: "Host"
        case .session: "Session"
        case .workspace: "Workspace"
        case .tab: "Tab"
        case .state: "State"
        }
    }
}

/// The parsed query: either free text (fuzzy title matching) or a
/// `field: text` prefix (fuzzy value matching in that one field).
struct AgentSearchQuery: Equatable, Sendable {
    let field: AgentSearchField?
    let text: String

    /// Parses `host:` / `session:` / … prefixes case-insensitively; anything
    /// else is free-text title search.
    init(raw: String) {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let match = AgentSearchField.allCases.first { field in
            let prefix = field.queryPrefix
            return trimmed.count >= prefix.count
                && trimmed.prefix(prefix.count).caseInsensitiveCompare(prefix) == .orderedSame
        }
        field = match
        text = match.map { String(trimmed.dropFirst($0.queryPrefix.count)) } ?? trimmed
    }
}

/// A context filter chip. Different fields AND together; multiple values of
/// one field OR (`AgentSearchEngine.passesFilters`).
struct AgentSearchFilter: Equatable, Identifiable, Hashable, Sendable {
    let field: AgentSearchField
    let value: String

    var id: String { "\(field.rawValue):\(value)" }

    func matches(_ normalizedValue: String) -> Bool {
        AgentFuzzyMatcher.normalize(value) == normalizedValue
    }
}

/// The normalized value one search field holds for an agent. `nil` when the
/// snapshot did not carry the field (the state is unknown to this build, or
/// the tab label is herdr's automatic positional name).
extension ConsoleAgent {
    func searchValue(for field: AgentSearchField) -> String? {
        switch field {
        case .host: return hostName
        case .session:
            let trimmed = hostSessionName.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? AgentTree.defaultSessionLabel : trimmed
        case .workspace:
            let trimmed = workspaceLabel?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return trimmed.isEmpty ? nil : trimmed
        case .tab:
            guard showsTabLabel,
                let label = tabLabel?.trimmingCharacters(in: .whitespacesAndNewlines),
                !label.isEmpty
            else { return nil }
            return label
        case .state: return agent.status.searchLabel
        }
    }
}

extension AgentStatus {
    /// The one label search, suggestions, and the state filter chip use —
    /// human wording, not the wire value. Any status this build cannot
    /// interpret reads as the one Unknown bucket, matching the Console
    /// sort's unknown bucket.
    var searchLabel: String {
        switch self {
        case .blocked: "Needs you"
        case .working: "Working"
        case .idle: "Idle"
        case .done: "Done"
        default: "Unknown"
        }
    }
}

/// The engine: query + filters in, matched agents, suggestions, and the
/// relevance-ordered result out.
struct AgentSearchEngine: Equatable, Sendable {
    private(set) var rawQuery: String
    private(set) var filters: [AgentSearchFilter]

    init(rawQuery: String = "", filters: [AgentSearchFilter] = []) {
        self.rawQuery = rawQuery
        self.filters = filters
    }

    var isConstrained: Bool {
        !AgentSearchQuery(raw: rawQuery).text.isEmpty || !filters.isEmpty
    }

    /// Review finding #5: relevance ordering applies only to a nonempty
    /// TEXT query — chips-only searches keep the view menu's chosen sort.
    var isTextQuery: Bool {
        !AgentSearchQuery(raw: rawQuery).text.isEmpty
    }

    // MARK: Matching

    /// AND across fields, OR within a field.
    func passesFilters(_ agent: ConsoleAgent) -> Bool {
        AgentSearchField.allCases.allSatisfy { field in
            let chosen = filters.filter { $0.field == field }
            guard !chosen.isEmpty else { return true }
            guard let value = agent.searchValue(for: field) else { return false }
            let normalized = AgentFuzzyMatcher.normalize(value)
            return chosen.contains { $0.matches(normalized) }
        }
    }

    /// ≥ 0 when the query matches, higher = better; 0 for an empty query.
    /// A `field:` query scores against that field's value only. Free text
    /// fuzzy-matches the row's title identity — the server-reported name
    /// and the terminal titles all identify the row — taking the best
    /// candidate score.
    func score(_ agent: ConsoleAgent) -> Int {
        let query = AgentSearchQuery(raw: rawQuery)
        guard !query.text.isEmpty else { return 0 }
        guard let field = query.field else {
            let candidates = [
                agent.agent.displayName,
                agent.agent.title,
                agent.agent.terminalTitleStripped ?? "",
                agent.agent.paneTitle ?? "",
            ]
            return candidates.compactMap {
                $0.isEmpty ? nil : AgentFuzzyMatcher.score(query.text, against: $0)
            }.max() ?? -1
        }
        guard let value = agent.searchValue(for: field) else { return -1 }
        return AgentFuzzyMatcher.score(query.text, against: value)
    }

    /// Every agent passing filters and matching the query. TEXT queries
    /// order by relevance (score desc, stable by input index); chips-only
    /// searches keep the caller's supplied order (the view menu's chosen
    /// sort owns it — review finding #5).
    func matches(over agents: [ConsoleAgent]) -> [ConsoleAgent] {
        let query = AgentSearchQuery(raw: rawQuery)
        guard query.text.isEmpty else {
            let scored: [(agent: ConsoleAgent, score: Int, index: Int)] =
                agents.enumerated().compactMap { index, agent in
                    guard passesFilters(agent) else { return nil }
                    let score = self.score(agent)
                    guard score >= 0 else { return nil }
                    return (agent, score, index)
                }
            return scored.sorted { lhs, rhs in
                (rhs.score, lhs.index) < (lhs.score, rhs.index)
            }.map(\.agent)
        }
        // Chips only (or nothing): pass the filters through in the order
        // the caller supplies — the chosen sort stays authoritative.
        return agents.filter { passesFilters($0) }
    }

    // MARK: Suggestions

    /// One autocomplete row. `field` rows complete the query prefix; `value`
    /// rows add a filter chip when accepted.
    struct Suggestion: Equatable, Identifiable, Sendable {
        enum Kind: Equatable, Sendable { case field, value }

        let kind: Kind
        let field: AgentSearchField
        /// The value a filter chip carries (value rows only).
        let value: String?
        /// What the row shows.
        let label: String
        let score: Int
        /// How many agents this value would match.
        let count: Int

        var id: String { "\(kind == .field ? "field" : "value"):\(field.rawValue):\(label)" }

        /// Applies acceptance: a field row rewrites the query to the
        /// `field:` prefix; a value row adds the filter chip and clears the
        /// query.
        func accepted(in engine: AgentSearchEngine) -> AgentSearchEngine {
            var next = engine
            switch kind {
            case .field:
                next.rawQuery = field.queryPrefix
            case .value:
                guard let value else { return next }
                let filter = AgentSearchFilter(field: field, value: value)
                next.filters.removeAll { $0.id == filter.id }
                next.filters.append(filter)
                next.rawQuery = ""
            }
            return next
        }
    }

    /// The ordered suggestion list for the current query: `field:` prefix
    /// completions (field-name matches only, +10), then direct value
    /// suggestions across every field with per-value match counts. Already
    /// chosen values never reappear; the list stays bounded
    /// (`AgentFuzzyMatcher.maximumSuggestions`).
    func suggestions(over agents: [ConsoleAgent]) -> [Suggestion] {
        let query = AgentSearchQuery(raw: rawQuery)
        var list: [Suggestion] = []
        for field in AgentSearchField.allCases {
            if query.field != nil, query.field != field { continue }
            if query.field == nil, !query.text.isEmpty {
                let fieldScore = AgentFuzzyMatcher.score(query.text, against: field.rawValue)
                if fieldScore >= 0 {
                    list.append(.init(
                        kind: .field, field: field, value: nil,
                        label: field.queryPrefix, score: fieldScore + 10, count: 0))
                }
            }
            var seenValues = Set<String>()
            for agent in agents {
                guard let value = agent.searchValue(for: field),
                    passesFilters(agent)
                else { continue }
                let normalized = AgentFuzzyMatcher.normalize(value)
                guard seenValues.insert(normalized).inserted else { continue }
                guard !filters.contains(where: { $0.field == field && $0.matches(normalized) })
                else { continue }
                let score = AgentFuzzyMatcher.score(query.text, against: value)
                guard score >= 0 else { continue }
                let count = agents
                    .filter {
                        $0.searchValue(for: field).map { AgentFuzzyMatcher.normalize($0) } == normalized
                    }
                    .count { passesFilters($0) }
                list.append(.init(
                    kind: .value, field: field, value: value, label: value,
                    score: score, count: count))
            }
        }
        list.sort { lhs, rhs in
            (rhs.score, rhs.count, lhs.field.rawValue, lhs.label)
                < (lhs.score, lhs.count, rhs.field.rawValue, rhs.label)
        }
        return Array(list.prefix(AgentFuzzyMatcher.maximumSuggestions))
    }

    // MARK: Mutations

    func settingQuery(_ raw: String) -> AgentSearchEngine {
        var next = self
        next.rawQuery = raw
        return next
    }

    func removingFilter(_ filter: AgentSearchFilter) -> AgentSearchEngine {
        var next = self
        next.filters.removeAll { $0.id == filter.id }
        return next
    }

    func cleared() -> AgentSearchEngine {
        AgentSearchEngine()
    }
}

/// Fuzzy matching, scored exactly like the approved preview:
/// exact 100 · prefix 90 · substring 80 · multi-term mean · subsequence
/// 50+length ratio · typo (edit distance ≤1, or ≤2 for queries ≥6) 30 ·
/// no match −1. Normalization: lowercase + NFKD fold + combining-mark strip.
enum AgentFuzzyMatcher {
    static let maximumSuggestions = 12

    static func normalize(_ text: String) -> String {
        let folded = text
            .folding(options: [.diacriticInsensitive, .widthInsensitive, .caseInsensitive],
                      locale: nil)
        return folded
            .precomposedStringWithCompatibilityMapping
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func score(_ query: String, against text: String) -> Int {
        let q = normalize(query)
        let t = normalize(text)
        guard !q.isEmpty else { return 0 }
        if q == t { return 100 }
        if t.hasPrefix(q) { return 90 }
        if t.contains(q) { return 80 }
        let terms = q.split(separator: " ", omittingEmptySubsequences: true)
        if terms.count > 1 {
            let scores = terms.map { score(String($0), against: text) }
            return scores.allSatisfy { $0 >= 0 } ? scores.reduce(0, +) / scores.count : -1
        }
        if isSubsequence(q, in: t) {
            return 50 + 20 * q.count / max(t.count, 1)
        }
        if q.count >= 3, t.split(whereSeparator: { " -_".contains($0) }).contains(where: { word in
            editDistance(q, String(word)) <= (q.count >= 6 ? 2 : 1)
        }) {
            return 30
        }
        return -1
    }

    /// In-order subsequence: "fixft" matches "Fix the flaky test".
    private static func isSubsequence(_ needle: String, in haystack: String) -> Bool {
        var at = haystack.startIndex
        for char in needle {
            while at < haystack.endIndex, haystack[at] != char {
                at = haystack.index(after: at)
            }
            guard at < haystack.endIndex else { return false }
            at = haystack.index(after: at)
        }
        return true
    }

    /// Classic two-row edit distance.
    static func editDistance(_ lhs: String, _ rhs: String) -> Int {
        var previous = Array(0...rhs.count)
        for lhsChar in lhs {
            var next = [previous[0] + 1]
            for (index, rhsChar) in rhs.enumerated() {
                let substitution = previous[index] + (lhsChar == rhsChar ? 0 : 1)
                next.append(min(next[index] + 1, previous[index + 1] + 1, substitution))
            }
            previous = next
        }
        return previous[rhs.count]
    }
}
