import Foundation

// SPDX-License-Identifier: Apache-2.0
//
// Per-agent-kind slash command discovery for the Composer's suggestion
// menu (fork plan, Phase 3). The menu previously hardcoded omp's built-in
// table inside `ComposerRouter`; this file moves that knowledge behind a
// provider protocol keyed by the agent kind herdr reports, so the menu
// lists what the *target* agent actually understands. Client-local
// commands (`/level`, `/follow`) are router-owned and always shown;
// provider commands come after them.
//
// Probed discovery is a no-op BY DESIGN at protocol 22 / omp 18.2.1:
//   - herdr's `api schema` has no command-listing RPC. The closest
//     surface, `command.invoke`, takes an opaque endpoint-issued
//     `command_id` from the client-shell projection — it consumes
//     commands, it does not enumerate them.
//   - omp session JSONLs (~/.omp/agent/sessions/*/*.jsonl) carry
//     `message` / `custom` / `custom_message` / `session` records only;
//     none embeds command metadata (verified 2026-09-17 across every
//     session on this machine).
// `AgentSlashCommand.Source.probed` therefore exists for the future wire
// that does expose commands; today every provider returns `.builtinTable`
// entries, and kinds without a verified table return none (the menu
// degrades to client-local commands rather than inventing names).

/// One slash command the target agent understands. `summary` and `usage`
/// come from verified agent-side strings — nil rather than invented.
struct AgentSlashCommand: Equatable, Sendable {
    /// Where the command list came from.
    enum Source: Equatable, Sendable {
        /// A client-side table verified against the agent binary's own
        /// command registry.
        case builtinTable
        /// Discovered live from the agent's session or an agent API.
        /// Reserved: no such surface exists at protocol 22 (see the file
        /// header), so no provider marks commands `.probed` yet.
        case probed
    }

    let name: String
    let summary: String?
    let usage: String?
    let source: Source
}

/// Supplies one agent kind's slash commands for the Composer's `/` menu.
protocol AgentCommandProvider: Sendable {
    func slashCommands() -> [AgentSlashCommand]
}

/// The kinds without a verified command table: the menu shows
/// client-local commands only.
private struct EmptyCommandProvider: AgentCommandProvider {
    func slashCommands() -> [AgentSlashCommand] { [] }
}

/// Kind string → provider. Kinds are herdr's open-set agent-program names
/// ("omp", "claude", "codex", ...), matched case-insensitively. Only kinds
/// whose tables are verified against the real agent binary are registered;
/// an unregistered kind deliberately yields no agent commands so the
/// agent answers unknown commands honestly on its own.
enum AgentCommandRegistry {
    private static let providers: [String: any AgentCommandProvider] = [
        "omp": OmpCommandProvider(),
    ]

    /// The provider for one agent kind; unknown kinds never crash and
    /// never fake commands — they get the empty provider.
    static func provider(forKind kind: String) -> any AgentCommandProvider {
        providers[kind.lowercased()] ?? EmptyCommandProvider()
    }
}

/// omp's built-in slash commands, verified against the 18.2.1 binary's
/// embedded command registry (`strings` over the Mach-O): `summary` is
/// each command's `description`, `usage` its `inlineHint` /
/// `acpInputHint` where the registry carries one (nil where it does
/// not — never invented). Suggestions only — delivery is always the raw
/// text through `agent.prompt`, so an omp that lacks a command answers
/// honestly on its own.
struct OmpCommandProvider: AgentCommandProvider {
    func slashCommands() -> [AgentSlashCommand] {
        Self.commands
    }

    static let commands: [AgentSlashCommand] = [
        .init(
            name: "agents",
            summary: "Open the agents hub (per-agent model, prewalk, and advisor)",
            usage: nil, source: .builtinTable),
        .init(
            name: "btw",
            summary: "Ask a side question, or browse this session's BTW history",
            usage: "[question]", source: .builtinTable),
        .init(
            name: "cleanse",
            summary: "Detect and fix project diagnostics with weighted parallel subagents",
            usage: "[request] [--all]", source: .builtinTable),
        .init(
            name: "clear",
            summary: "Clear the conversation context in place, keeping the session",
            usage: nil, source: .builtinTable),
        .init(
            name: "collab",
            summary: "Share this session live via a relay",
            usage: "[start|view|list|stop|status] [relayUrl]", source: .builtinTable),
        .init(
            name: "compact",
            summary: "Manually compact the session context",
            usage: "[soft|remote|snapcompact] [focus]", source: .builtinTable),
        .init(
            name: "context",
            summary: "Show estimated context usage breakdown",
            usage: nil, source: .builtinTable),
        .init(
            name: "copy",
            summary: "Pick text or code from the conversation to copy",
            usage: nil, source: .builtinTable),
        .init(
            name: "debug",
            summary: "Open debug tools selector",
            usage: nil, source: .builtinTable),
        .init(
            name: "delete",
            summary: "Delete the current session and start a new one",
            usage: nil, source: .builtinTable),
        .init(
            name: "elide",
            summary: "Strip tool results + large blocks (default)",
            usage: nil, source: .builtinTable),
        .init(
            name: "exit",
            summary: "Exit the application",
            usage: nil, source: .builtinTable),
        .init(
            name: "fork",
            summary: "Create a new fork from a previous message",
            usage: nil, source: .builtinTable),
        .init(
            name: "fresh",
            summary: "Reset provider stream state without changing the local transcript",
            usage: nil, source: .builtinTable),
        .init(
            name: "goal",
            summary: "Toggle goal mode (persistent autonomous objective for this session)",
            usage: "[objective]", source: .builtinTable),
        .init(
            name: "handoff",
            summary: "Hand off session context to a new session",
            usage: "[focus instructions]", source: .builtinTable),
        .init(
            name: "help",
            summary: "Show help message",
            usage: nil, source: .builtinTable),
        .init(
            name: "hub",
            summary: "Open the live Agent Hub",
            usage: nil, source: .builtinTable),
        .init(
            name: "images",
            summary: "Strip image blocks",
            usage: nil, source: .builtinTable),
        .init(
            name: "info",
            summary: "Show session info and stats",
            usage: nil, source: .builtinTable),
        .init(
            name: "jobs",
            summary: "Show async background jobs status",
            usage: nil, source: .builtinTable),
        .init(
            name: "memory",
            summary: "Inspect and operate memory maintenance",
            usage: "<subcommand>", source: .builtinTable),
        .init(
            name: "new",
            summary: "Start a new session",
            usage: nil, source: .builtinTable),
        .init(
            name: "omfg",
            summary: "Forge a TTSR rule from a complaint to stop a recurring behavior",
            usage: "<complaint>", source: .builtinTable),
        .init(
            name: "pin",
            summary: "Pin or unpin a session at the top of the resume list",
            usage: "[session id]", source: .builtinTable),
        .init(
            name: "queue",
            summary: "Queue a message for after the agent yields",
            usage: "<message>", source: .builtinTable),
        .init(
            name: "rename",
            summary: "Rename the current session (omit title to generate)",
            usage: "[title]", source: .builtinTable),
        .init(
            name: "retry",
            summary: "Retry the last failed agent turn",
            usage: nil, source: .builtinTable),
        .init(
            name: "session",
            summary: "Session management commands",
            usage: "[info|delete|pin [account]]", source: .builtinTable),
        .init(
            name: "share",
            summary: "Share session via an encrypted link (share server or secret gist)",
            usage: nil, source: .builtinTable),
        .init(
            name: "shake",
            summary: "Drop heavy content from context (tool results, large blocks)",
            usage: "[elide|images|thinking]", source: .builtinTable),
        .init(
            name: "tan",
            summary: "Run a full background agent on tangential work",
            usage: "<work>", source: .builtinTable),
        .init(
            name: "thinking",
            summary: "Drop all thinking blocks",
            usage: nil, source: .builtinTable),
        .init(
            name: "todo",
            summary: "View or modify the agent's todo list",
            usage: "<subcommand>", source: .builtinTable),
        .init(
            name: "tree",
            summary: "Navigate session tree (switch branches)",
            usage: nil, source: .builtinTable),
        .init(
            name: "usage",
            summary: "Show provider usage and limits",
            usage: "[show|reset [account|active]]", source: .builtinTable),
    ]
}
