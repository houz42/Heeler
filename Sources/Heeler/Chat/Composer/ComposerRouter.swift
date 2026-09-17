import Foundation

// SPDX-License-Identifier: Apache-2.0
//
// The Composer's input-mode router (fork plan, Phase 2). Pure, table-driven
// parsing in front of the existing Composer delivery (ADR 0013): the
// draft's first character selects a mode — `/` slash command, `#` tag
// filter, `@` agent mention, `!` scratch-shell command — and everything
// else is plain prompt text delivered unchanged. This file only parses;
// `ComposerRouterStore` decides what a parsed command does.
//
// Doubling the prefix character escapes it: "//" delivers literal "/…",
// "##", "@@", "!!" likewise, so none of the mode prefixes can lock the
// user out of prose that starts with one of them.

/// What one submitted draft parsed into.
enum ComposerCommand: Equatable, Sendable {
    /// `/<name>`. The name ends at the first whitespace or `:` — omp's own
    /// `parseSlashCommand` splits there, so `/level 2` and `/level:2` are
    /// the same command. `args` is the remainder, trimmed.
    case slash(name: String, args: String)
    /// `#<query>` — a blended-console tag filter.
    case tag(TagFilter)
    /// `@<agent> <message>` — routed to the named agent's `agent.prompt`.
    case mention(agent: String, message: String)
    /// `!<command>` — run in the Host's scratch shell.
    case bash(command: String)
    /// Everything else (including a bare or escaped prefix character):
    /// delivered by the existing Composer path unchanged.
    case plain(text: String)
}

/// A structured `#` filter. `#status:blocked` names the field; a bare
/// `#blocked` leaves the field nil and lets the consumer match the value
/// against workspaces, statuses, and agents alike.
struct TagFilter: Equatable, Sendable {
    enum Field: String, Sendable {
        case workspace
        case status
        case agent
    }

    /// The explicit `status:` / `workspace:` / `agent:` prefix, when present.
    let field: Field?
    /// The raw value after the prefix, trimmed.
    let value: String
}

/// One row of the Composer's suggestion menu.
struct ComposerSuggestion: Identifiable, Equatable, Sendable {
    enum Kind: Equatable, Sendable {
        /// An omp built-in slash command.
        case slash
        /// A client-local command (handled by `ComposerRouterStore` itself).
        case local
        /// A `#` tag value.
        case tag
        /// An `@` agent name.
        case mention
    }

    let id: String
    let title: String
    let detail: String?
    /// The text that replaces the active token when this row is accepted.
    let insertion: String
    let kind: Kind

    /// The command's usage signature (e.g. `[show|reset [account|active]]`),
    /// shown on the row's second line when the provider carries one.
    var usage: String? = nil
    var prefixCharacter: Character {
        switch kind {
        case .slash, .local: "/"
        case .tag: "#"
        case .mention: "@"
        }
    }
}

/// A client-local slash command: parsed by the router, executed by
/// `ComposerRouterStore` without touching the agent.
struct ComposerLocalCommand: Equatable, Sendable {
    let name: String
    let summary: String
    let usage: String

    /// `/level <0-3>` — set this chat pane's detail level.
    static let level = ComposerLocalCommand(
        name: "level",
        summary: "Set this chat's detail level (0–3)",
        usage: "/level <0-3>")
    /// `/follow <agent>` — follow another agent's output.
    static let follow = ComposerLocalCommand(
        name: "follow",
        summary: "Follow another agent",
        usage: "/follow <agent>")

    static let all = [level, follow]
}

/// The token inside the draft the suggestion menu is currently filtering.
/// Detection is deliberately per-prefix: a `#` filter and an `!` command
/// take the whole rest of the draft, an `@` mention takes the agent name
/// (up to the first whitespace), and a `/` command is a trailing token so
/// prose like "try /compact" can still be completed in place.
enum ComposerSuggestionToken: Equatable, Sendable {
    /// The trailing token including its leading `/`.
    case slash(token: String)
    /// Everything after the draft's leading `#`.
    case tag(query: String)
    /// The agent-name portion after the draft's leading `@`.
    case mention(query: String)

    /// Applies an accepted suggestion's `insertion` to `draft`. Pure
    /// replacement math: each case knows where its token lives.
    func replacingDraft(_ draft: String, with insertion: String) -> String {
        switch self {
        case .slash(let token):
            guard draft.hasSuffix(token) else { return draft }
            return String(draft.dropLast(token.count)) + insertion
        case .tag:
            // A tag replaces the whole draft; the menu's insertions carry
            // their own trailing space.
            return insertion
        case .mention(let query):
            guard draft.hasPrefix("@" + query) else { return draft }
            let remainder = String(draft.dropFirst(1 + query.count))
            // The name was still being typed, so nothing follows except
            // possibly nothing at all — add the separating space here.
            return "@" + insertion + (remainder.isEmpty ? " " : remainder)
        }
    }
}

/// Keys the suggestion menu consumes before the text editor sees them.
enum ComposerSuggestionKey: Equatable, Sendable {
    case up
    case down
    case enter
    case escape
}

/// Pure parsing and suggestion filtering. No state, no I/O.
enum ComposerRouter {
    /// The mode prefixes, in display order.
    static let prefixes: [Character] = ["/", "#", "@", "!"]

    /// The most rows the suggestion menu ever shows.
    static let maximumSuggestions = 8

    /// Classifies a whole submitted draft. Only a first-character prefix
    /// routes — a prefix anywhere else is prose. A bare prefix character
    /// (`/` alone) is prose too, matching omp's own parse, which rejects
    /// an empty command name. A doubled leading prefix is the escape and
    /// delivers the text minus one prefix character.
    static func classify(_ text: String) -> ComposerCommand {
        guard let first = text.first, prefixes.contains(first) else {
            return .plain(text: text)
        }
        if text.count >= 2, text[text.index(after: text.startIndex)] == first {
            return .plain(text: String(text.dropFirst()))
        }
        let rest = String(text.dropFirst())
        switch first {
        case "/":
            guard !rest.isEmpty else { return .plain(text: text) }
            guard let separator = rest.firstIndex(where: { $0.isWhitespace || $0 == ":" })
            else { return .slash(name: rest, args: "") }
            let name = String(rest[..<separator])
            let args = String(rest[rest.index(after: separator)...])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return .slash(name: name, args: args)
        case "#":
            guard !rest.isEmpty else { return .plain(text: text) }
            return .tag(tagFilter(for: rest))
        case "@":
            guard !rest.isEmpty else { return .plain(text: text) }
            guard let separator = rest.firstIndex(where: \.isWhitespace)
            else { return .mention(agent: rest, message: "") }
            let agent = String(rest[..<separator])
            let message = String(rest[rest.index(after: separator)...])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return .mention(agent: agent, message: message)
        case "!":
            // A bare "!" is an empty bash command — route it so the store
            // can reject it with guidance instead of sending "!" as prose.
            return .bash(command: rest.trimmingCharacters(in: .whitespacesAndNewlines))
        default:
            return .plain(text: text)
        }
    }

    /// Splits a `#` query into field and value. `status:` / `workspace:` /
    /// `agent:` (case-insensitive) name the field; anything else is the
    /// whole value, colon included.
    static func tagFilter(for query: String) -> TagFilter {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let separator = trimmed.firstIndex(of: ":")
        else { return TagFilter(field: nil, value: trimmed) }
        let fieldText = String(trimmed[..<separator]).lowercased()
        guard let field = TagFilter.Field(rawValue: fieldText)
        else { return TagFilter(field: nil, value: trimmed) }
        let value = String(trimmed[trimmed.index(after: separator)...])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return TagFilter(field: field, value: value)
    }

    /// The suggestion-menu token for the current draft, when there is one.
    /// `!` never opens the menu: shell commands are free-form text.
    static func activeToken(draft: String) -> ComposerSuggestionToken? {
        // A "/" command token is a trailing token anywhere in the draft,
        // like the Skills trigger: prose can still be completed in place.
        // The escape rule comes first: "//…" never opens the menu.
        let trailingToken: Substring =
            if let boundary = draft.lastIndex(where: \.isWhitespace) {
                draft[draft.index(after: boundary)...]
            } else {
                draft[...]
            }
        if trailingToken.first == "/" {
            let escaped =
                trailingToken.count >= 2
                && trailingToken[trailingToken.index(after: trailingToken.startIndex)] == "/"
            return escaped ? nil : .slash(token: String(trailingToken))
        }
        // The `#` / `@` filters are draft-leading only, and the doubled
        // prefix is prose while typing too.
        guard let first = draft.first,
            first == "#" || first == "@",
            draft.count == 1 || draft[draft.index(after: draft.startIndex)] != first
        else { return nil }
        let rest = String(draft.dropFirst())
        guard !rest.isEmpty else {
            return first == "#" ? .tag(query: "") : .mention(query: "")
        }
        // The value/name is being typed; once a space follows it, it is
        // chosen and the menu gets out of the way.
        guard !rest.contains(where: \.isWhitespace) else { return nil }
        return first == "#" ? .tag(query: rest) : .mention(query: rest)
    }

    /// `/` suggestions: client-local commands first (they outrank the
    /// agent's own), then the agent's commands from its provider, matched
    /// by name prefix only — a command is completed by its name, and
    /// matching its description would drown two-letter queries in
    /// unrelated rows. An empty query lists them all, capped.
    static func slashSuggestions(
        matching query: String,
        agentCommands: [AgentSlashCommand]
    ) -> [ComposerSuggestion] {
        let needle = query.lowercased()
        var matches: [ComposerSuggestion] = []
        for command in ComposerLocalCommand.all
        where needle.isEmpty || command.name.hasPrefix(needle) {
            matches.append(
                ComposerSuggestion(
                    id: "local:" + command.name,
                    title: command.name,
                    detail: command.summary,
                    insertion: "/\(command.name) ",
                    kind: .local,
                    usage: command.usage))
        }
        for command in agentCommands
        where needle.isEmpty || command.name.hasPrefix(needle) {
            matches.append(
                ComposerSuggestion(
                    id: "omp:" + command.name,
                    title: command.name,
                    detail: command.summary,
                    insertion: "/\(command.name) ",
                    kind: .slash,
                    usage: command.usage))
        }
        return Array(matches.prefix(maximumSuggestions))
    }

    /// `#` suggestions: statuses and agents always carry their field prefix
    /// (picking `blocked` produces the structured `#status:blocked`), bare
    /// workspaces stay bare. An explicit field filters to that field only.
    static func tagSuggestions(
        field: TagFilter.Field?,
        matching query: String,
        workspaces: [String],
        statuses: [String],
        agents: [String]
    ) -> [ComposerSuggestion] {
        let needle = query.lowercased()
        var matches: [ComposerSuggestion] = []
        func consider(_ value: String, _ field: TagFilter.Field?) {
            guard !value.isEmpty,
                needle.isEmpty || value.lowercased().hasPrefix(needle)
            else { return }
            let insertion = field.map { "#\($0.rawValue):\(value) " } ?? "#\(value) "
            matches.append(
                ComposerSuggestion(
                    id: "tag:" + insertion,
                    title: value,
                    detail: field?.rawValue,
                    insertion: insertion,
                    kind: .tag))
        }
        switch field {
        case .status?:
            statuses.forEach { consider($0, .status) }
        case .workspace?:
            workspaces.forEach { consider($0, .workspace) }
        case .agent?:
            agents.forEach { consider($0, .agent) }
        case nil:
            statuses.forEach { consider($0, .status) }
            workspaces.forEach { consider($0, nil) }
            agents.forEach { consider($0, .agent) }
        }
        return Array(matches.prefix(maximumSuggestions))
    }

    /// `@` suggestions: agent names from the injected provider, prefix match.
    static func mentionSuggestions(
        matching query: String,
        agents: [String]
    ) -> [ComposerSuggestion] {
        let needle = query.lowercased()
        return Array(
            agents
                .filter { !$0.isEmpty && (needle.isEmpty || $0.lowercased().hasPrefix(needle)) }
                .map { name in
                    ComposerSuggestion(
                        id: "mention:" + name,
                        title: name,
                        detail: nil,
                        insertion: name,
                        kind: .mention)
                }
                .prefix(maximumSuggestions))
    }

}
