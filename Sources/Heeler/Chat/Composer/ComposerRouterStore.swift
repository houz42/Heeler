import Foundation
import Observation

// SPDX-License-Identifier: Apache-2.0
//
// The Composer's submit router (fork plan, Phase 2): one @MainActor store
// installed on a chat surface's Composer. It intercepts Send, classifies
// the draft with `ComposerRouter`, and either passes it through to the
// existing Composer delivery unchanged (ADR 0013: one `agent.prompt`, or
// Attach-insert when the Agent is Blocked) or handles it locally:
//
//   .plain          → passthrough — the existing delivery, untouched
//   .slash (omp)    → passthrough — the raw text IS the delivery; the
//                     agent interprets its own commands
//   .slash (local)  → handled — `/level` persists via ChatDetailLevelStore,
//                     `/follow` forwards to a callback
//   .tag            → handled — the structured TagFilter goes to a callback
//   .mention        → handled — resolve agent → (host, pane), deliver there
//                     via `agent.prompt`; cross-host just works because the
//                     delivery closure takes the host
//   .bash           → handled — run in the Host's scratch shell, capture the
//                     output into `bashResults` for the chat to show at L1+
//
// When the router is not installed the Composer's behavior is
// byte-identical: `AgentComposerView` routes through it only when present.

/// Where a resolved `@mention` delivers: the target agent's Host and pane.
/// Resolution from a display name is the wiring owner's job; the router
/// only parses and forwards.
typealias ComposerResolvedAgent = (hostID: UUID, paneID: String)

/// The scratch-shell I/O seam for `!command` runs. The scratch shell is one
/// lazily-created herdr tab per Host, labeled "chat-bash" (ADR 0015's
/// `tab.create` choreography); `createScratchPane` creates it and returns
/// the root pane id. `sendText` writes literal text (command plus newline)
/// and `readPaneText` reads recent output — the pane-level
/// `pane.send_input` / `pane.read` RPCs, ANSI stripped by the provider.
///
/// Wire contract still owed on the Transport side: Heeler's `Transport`
/// protocol currently exposes `pane.read` only through projection-internal
/// calls and has no pane-text input at all. Until `sendPaneInput` lands
/// there, production callers cannot construct this seam; tests construct
/// it over scripted closures.
struct ComposerBashIO: Sendable {
    /// Creates (or names) the Host's labeled scratch pane; returns its pane id.
    let createScratchPane: @Sendable (_ hostID: UUID) async throws -> String
    /// Writes literal text into the pane, as typed.
    let sendText: @Sendable (
        _ hostID: UUID, _ paneID: String, _ text: String
    ) async throws -> Void
    /// Reads the pane's recent output, ANSI stripped.
    let readPaneText: @Sendable (_ hostID: UUID, _ paneID: String) async throws -> String
}

/// One `!command` run, the inline result model the chat shows at L1+.
struct ComposerBashResult: Identifiable, Equatable, Sendable {
    enum State: Equatable, Sendable {
        case running
        case finished(exitCode: Int, output: String)
        case failed(String)
    }

    let id: UUID
    let command: String
    var state: State
}

/// How a routed submit ended for the Composer's delivery path.
enum ComposerSubmitOutcome: Equatable, Sendable {
    /// Deliver through the existing Composer path unchanged (plain text
    /// and omp slash commands).
    case passthrough
    /// The router consumed the draft; the caller clears it.
    case handled
    /// The router rejected the draft (bad arguments, unresolved target).
    /// The caller keeps the draft for editing; `routingError` says why.
    case rejected
}

/// The live routing + suggestion store for one chat surface's Composer.
@MainActor
@Observable
final class ComposerRouterStore {
    struct Dependencies {
        let hostID: UUID
        let paneID: String
        let levelStore: ChatDetailLevelStore
        /// Display name → target agent. The wiring owner decides matching.
        let resolveAgent: @MainActor (_ name: String) -> ComposerResolvedAgent?
        /// Delivers a mention to the target's `agent.prompt`.
        let deliverMention: @Sendable (
            _ resolved: ComposerResolvedAgent, _ message: String
        ) async throws -> Void
        let bashIO: ComposerBashIO
        /// `/follow <agent>` — the console integration decides what
        /// following means; the router only forwards the name.
        let follow: @MainActor (_ agent: String) -> Void
        /// `#filter` — the blended console's tag consumer.
        let tagFilter: @MainActor (_ filter: TagFilter) -> Void
        /// `/level` feedback so the visible surface can re-read the level.
        let levelDidChange: @MainActor (_ level: DetailLevel) -> Void
        /// The agent's own slash commands, from the provider registry.
        /// Defaults to omp's verified table; the wiring owner passes the
        /// target agent's kind (see `makeChatDependencies`).
        let agentCommands: @MainActor () -> [AgentSlashCommand]
        let workspaces: @MainActor () -> [String]
        let statuses: @MainActor () -> [String]
        let agents: @MainActor () -> [String]
        /// User-facing copy for a delivery/scratch-shell failure.
        let describeError: @Sendable (_ error: any Error) -> String
        let bashTimeout: Duration
        let bashPollInterval: Duration

        init(
            hostID: UUID,
            paneID: String,
            levelStore: ChatDetailLevelStore,
            resolveAgent: @MainActor @escaping (_ name: String) -> ComposerResolvedAgent?,
            deliverMention: @escaping @Sendable (
                _ resolved: ComposerResolvedAgent, _ message: String
            ) async throws -> Void,
            bashIO: ComposerBashIO,
            agentCommands: @escaping @MainActor () -> [AgentSlashCommand] = {
                AgentCommandRegistry.provider(forKind: "omp").slashCommands()
            },
            follow: @escaping @MainActor (_ agent: String) -> Void = { _ in },
            tagFilter: @escaping @MainActor (_ filter: TagFilter) -> Void = { _ in },
            levelDidChange: @escaping @MainActor (_ level: DetailLevel) -> Void = { _ in },
            workspaces: @escaping @MainActor () -> [String] = { [] },
            statuses: @escaping @MainActor () -> [String] = {
                ["blocked", "working", "done", "idle"]
            },
            agents: @escaping @MainActor () -> [String] = { [] },
            describeError: @escaping @Sendable (_ error: any Error) -> String = {
                ($0 as? LocalizedError)?.errorDescription ?? String(describing: $0)
            },
            bashTimeout: Duration = .seconds(10),
            bashPollInterval: Duration = .milliseconds(250)
        ) {
            self.hostID = hostID
            self.paneID = paneID
            self.levelStore = levelStore
            self.resolveAgent = resolveAgent
            self.agentCommands = agentCommands
            self.deliverMention = deliverMention
            self.bashIO = bashIO
            self.follow = follow
            self.tagFilter = tagFilter
            self.levelDidChange = levelDidChange
            self.workspaces = workspaces
            self.statuses = statuses
            self.agents = agents
            self.describeError = describeError
            self.bashTimeout = bashTimeout
            self.bashPollInterval = bashPollInterval
        }
    }

    // MARK: State

    /// `!command` runs, newest last — the inline results the chat shows at
    /// L1+.
    private(set) var bashResults: [ComposerBashResult] = []
    /// The last rejection's user-facing copy; cleared by the next token
    /// change or an explicit dismiss.
    private(set) var routingError: String?
    /// The live suggestion menu, already filtered for the current token.
    private(set) var suggestions: [ComposerSuggestion] = []
    private(set) var selectedSuggestionIndex = 0
    private(set) var isSuggestionsDismissed = false

    // MARK: + menu structured intent (v3)
    //
    // The + menu's command selection resolves to a STRUCTURED intent
    // (the design doc's "selection resolves to typed intent"), not a
    // literal "/" another layer re-guesses. Each prefix mode keeps
    // ONE canonical entry point shared by the + menu and typed text.

    /// The + menu's open prefix-mode chooser, when one is active.
    /// `nil` = no chooser is open. The composer's + menu keeps its
    /// own popover open state (SwiftUI Menu owns that); this records
    /// which MODE's chooser/editor the surface must present after the
    /// menu tap lands — the chooser itself is the chat surface's view.
    private(set) var activeChooser: ComposerPrefixMode?

    /// The mode a + menu selection entered, so the surface can
    /// dismiss it on cancel (Cancel returns to exactly the original
    /// draft/caret/keyboard — the design doc's contract).
    func openChooser(for mode: ComposerPrefixMode) {
        activeChooser = mode
    }

    /// Cancels the active chooser: no draft, caret, or focus change.
    func cancelChooser() {
        activeChooser = nil
    }

    /// The command catalog the + menu's Agent-command chooser lists:
    /// the agent's own commands (provider + dynamic store) first,
    /// then the client-local ones — the SAME table the typed `/`
    /// suggestion menu filters. Each row carries its catalog ID, so a
    /// selection is a resolved identity, never a text guess.
    func commandCatalog() -> [ComposerSuggestion] {
        var matches: [ComposerSuggestion] = []
        for command in dependencies.agentCommands() {
            matches.append(
                ComposerSuggestion(
                    id: "omp:" + command.name,
                    title: command.name,
                    detail: command.summary,
                    insertion: "/\(command.name) ",
                    kind: .slash,
                    usage: command.usage))
        }
        for command in ComposerLocalCommand.all {
            matches.append(
                ComposerSuggestion(
                    id: "local:" + command.name,
                    title: command.name,
                    detail: command.summary,
                    insertion: "/\(command.name) ",
                    kind: .local,
                    usage: command.usage))
        }
        return matches
    }

    /// The + menu's Filter/tag chooser list, over the SAME live
    /// workspace/status/agent data the typed `#` menu filters.
    func tagCatalog() -> [ComposerSuggestion] {
        ComposerRouter.tagSuggestions(
            field: nil, matching: "",
            workspaces: dependencies.workspaces(),
            statuses: dependencies.statuses(),
            agents: dependencies.agents())
    }

    /// The console's agent roster for the Mention chooser — the SAME
    /// names the typed `@` menu suggests.
    func agentRoster() -> [String] {
        dependencies.agents()
    }

    /// Applies one chosen tag suggestion as the structured
    /// ``TagFilter`` (client-side; never transmitted to an agent).
    /// The suggestion's insertion is the canonical `#…` text — the
    /// SAME parse the typed path uses, so the two cannot drift.
    func applyTagSuggestion(_ suggestion: ComposerSuggestion) {
        // The insertion is the canonical `#… ` text the typed path
        // would apply; strip the prefix and the trailing separator,
        // then run the SAME tagFilter parse the typed path uses.
        var query = suggestion.insertion
        if query.hasPrefix("#") { query.removeFirst() }
        while query.hasSuffix(" ") { query.removeLast() }
        let filter = ComposerRouter.tagFilter(for: query)
        guard !filter.value.isEmpty else { return }
        dependencies.tagFilter(filter)
    }

    /// Executes one + menu/chooser selection end-to-end (v3's
    /// selection-resolves-to-intent rule). The caller built the
    /// selection from a catalog ID; this runs it through the SAME
    /// routing a typed draft would take — never a parallel path,
    /// never re-parsing text. `.handled` clears the chooser;
    /// `.rejected` keeps it open with `routingError` explaining.
    func runCommandSelection(
        _ selection: ComposerCommandSelection
    ) async -> ComposerSubmitOutcome {
        let outcome = await submit(selection.deliveryText)
        if outcome != .rejected { activeChooser = nil }
        return outcome
    }

    /// Executes one + menu/chooser mention selection (structured
    /// target + message): resolution + delivery, same as a typed
    /// `@agent message` submit.
    func runMentionSelection(
        _ selection: ComposerMentionSelection
    ) async -> ComposerSubmitOutcome {
        let outcome = await routeMention(
            agent: selection.agentName, message: selection.message)
        if outcome != .rejected { activeChooser = nil }
        return outcome
    }

    /// Executes one + menu/chooser shell selection: the command goes
    /// to the Host's companion scratch terminal (never the agent
    /// prompt), same as a typed `!command` submit.
    func runShellSelection(
        _ selection: ComposerShellSelection
    ) async -> ComposerSubmitOutcome {
        let outcome = await startBash(selection.command)
        if outcome != .rejected { activeChooser = nil }
        return outcome
    }

    var hasActiveSuggestions: Bool {
        !suggestions.isEmpty && !isSuggestionsDismissed
    }

    /// One lazily-created scratch pane per Host, surviving runs.
    @ObservationIgnored private var scratchPaneIDs: [UUID: String] = [:]
    @ObservationIgnored private var isBashRunning = false
    @ObservationIgnored private var lastToken: ComposerSuggestionToken?

    private let dependencies: Dependencies

    init(dependencies: Dependencies) {
        self.dependencies = dependencies
    }

    // MARK: Submit routing

    /// Routes one submitted draft. `.passthrough` tells the Composer to
    /// deliver exactly as it always did; the other outcomes replace that
    /// delivery.
    func submit(_ text: String) async -> ComposerSubmitOutcome {
        switch ComposerRouter.classify(text) {
        case .plain:
            return .passthrough
        case .slash(let name, let args):
            return await routeSlash(name: name, args: args)
        case .tag(let filter):
            guard !filter.value.isEmpty else { return .passthrough }
            dependencies.tagFilter(filter)
            return .handled
        case .mention(let agent, let message):
            return await routeMention(agent: agent, message: message)
        case .bash(let command):
            return await startBash(command)
        }
    }

    private func routeSlash(name: String, args: String) async -> ComposerSubmitOutcome {
        switch name {
        case "level":
            guard let raw = Int(args), let level = DetailLevel(rawValue: raw)
            else {
                routingError = "Usage: \(ComposerLocalCommand.level.usage)"
                return .rejected
            }
            dependencies.levelStore.setLevel(level, paneID: dependencies.paneID)
            dependencies.levelDidChange(level)
            return .handled
        case "follow":
            guard !args.isEmpty else {
                routingError = "Usage: \(ComposerLocalCommand.follow.usage)"
                return .rejected
            }
            dependencies.follow(args)
            return .handled
        default:
            // An omp command: the raw text is the delivery, so the existing
            // Composer path carries it verbatim.
            return .passthrough
        }
    }

    private func routeMention(
        agent: String, message: String
    ) async -> ComposerSubmitOutcome {
        guard let resolved = dependencies.resolveAgent(agent) else {
            routingError = "No agent named “\(agent)”."
            return .rejected
        }
        guard !message.isEmpty else {
            routingError = "Add a message after the agent name."
            return .rejected
        }
        do {
            try await dependencies.deliverMention(resolved, message)
            return .handled
        } catch {
            routingError = dependencies.describeError(error)
            return .rejected
        }
    }

    // MARK: Bash

    private func startBash(_ command: String) async -> ComposerSubmitOutcome {
        guard !command.isEmpty else {
            routingError = "Type a shell command after !."
            return .rejected
        }
        guard !isBashRunning else {
            routingError = "A shell command is already running."
            return .rejected
        }
        let result = ComposerBashResult(
            id: UUID(), command: command, state: .running)
        bashResults.append(result)
        isBashRunning = true

        let io = dependencies.bashIO
        let hostID = dependencies.hostID
        let paneID: String
        do {
            paneID = try await ensureScratchPane(hostID: hostID, io: io)
        } catch {
            return failBash(result.id, error: error)
        }
        let sentinel = Self.makeSentinel()
        do {
            try await io.sendText(hostID, paneID, Self.wrappedCommand(command, sentinel: sentinel))
        } catch {
            // The cached pane may have been closed on the desktop; drop it
            // so the next attempt recreates it.
            scratchPaneIDs[hostID] = nil
            return failBash(result.id, error: error)
        }
        let timeout = dependencies.bashTimeout
        let pollInterval = dependencies.bashPollInterval
        let describeError = dependencies.describeError
        Task { [weak self] in
            let state = await Self.pollBashOutput(
                io: io,
                hostID: hostID,
                paneID: paneID,
                command: command,
                sentinel: sentinel,
                timeout: timeout,
                pollInterval: pollInterval,
                describeError: describeError)
            self?.finishBash(result.id, state: state)
        }
        return .handled
    }

    private func ensureScratchPane(hostID: UUID, io: ComposerBashIO) async throws -> String {
        if let cached = scratchPaneIDs[hostID] { return cached }
        let paneID = try await io.createScratchPane(hostID)
        scratchPaneIDs[hostID] = paneID
        return paneID
    }

    private func failBash(_ id: UUID, error: any Error) -> ComposerSubmitOutcome {
        isBashRunning = false
        let message = dependencies.describeError(error)
        if let index = bashResults.firstIndex(where: { $0.id == id }) {
            bashResults[index].state = .failed(message)
        }
        routingError = message
        return .rejected
    }

    private func finishBash(_ id: UUID, state: ComposerBashResult.State) {
        isBashRunning = false
        guard let index = bashResults.firstIndex(where: { $0.id == id }) else { return }
        bashResults[index].state = state
    }

    // MARK: Suggestions

    /// Re-derives the suggestion menu for the current draft. The Composer
    /// calls this on every draft change; the token changing also re-arms a
    /// dismissed menu and clears a stale rejection.
    func updateSuggestions(forDraft draft: String) {
        let token = ComposerRouter.activeToken(draft: draft)
        if token != lastToken {
            lastToken = token
            selectedSuggestionIndex = 0
            isSuggestionsDismissed = false
            routingError = nil
        }
        guard let token else {
            suggestions = []
            return
        }
        suggestions = filteredSuggestions(for: token)
    }

    private func filteredSuggestions(
        for token: ComposerSuggestionToken
    ) -> [ComposerSuggestion] {
        switch token {
        case .slash(let tokenText):
            return ComposerRouter.slashSuggestions(
                matching: String(tokenText.dropFirst()),
                agentCommands: dependencies.agentCommands())
        case .tag(let query):
            let filter = ComposerRouter.tagFilter(for: query)
            return ComposerRouter.tagSuggestions(
                field: filter.field,
                matching: filter.value,
                workspaces: dependencies.workspaces(),
                statuses: dependencies.statuses(),
                agents: dependencies.agents())
        case .mention(let query):
            return ComposerRouter.mentionSuggestions(
                matching: query, agents: dependencies.agents())
        }
    }

    // MARK: Suggestion interaction

    /// Consumes a key press before the text editor sees it. Returns false
    /// when the menu is not showing, so the editor's behavior is unchanged.
    @discardableResult
    func handleKey(_ key: ComposerSuggestionKey) -> Bool {
        guard hasActiveSuggestions else { return false }
        switch key {
        case .up:
            moveSelection(-1)
            return true
        case .down:
            moveSelection(1)
            return true
        case .escape:
            isSuggestionsDismissed = true
            return true
        case .enter:
            // The caller applies the returned draft; the next
            // `updateSuggestions` pass recomputes the menu.
            return true
        }
    }

    func moveSelection(_ delta: Int) {
        guard !suggestions.isEmpty else { return }
        let count = suggestions.count
        selectedSuggestionIndex =
            ((selectedSuggestionIndex + delta) % count + count) % count
    }

    func selectSuggestion(at index: Int) {
        guard suggestions.indices.contains(index) else { return }
        selectedSuggestionIndex = index
    }

    /// The draft with the selected suggestion applied, or nil when there is
    /// nothing to accept or the draft no longer holds the active token.
    func acceptSelectedSuggestion(into draft: String) -> String? {
        guard hasActiveSuggestions,
            suggestions.indices.contains(selectedSuggestionIndex),
            let token = ComposerRouter.activeToken(draft: draft)
        else { return nil }
        return token.replacingDraft(
            draft, with: suggestions[selectedSuggestionIndex].insertion)
    }

    /// The accepted draft plus the caret the accept leaves: the end of the
    /// applied insertion (UTF-16 offset). Every token case lands the
    /// insertion at the applied draft's tail — slash tokens are trailing,
    /// a tag replaces the whole draft, and a mention's remainder is empty
    /// while the menu is open — so the insertion end is the draft's end.
    func acceptSelectedSuggestionWithCaret(
        into draft: String
    ) -> (draft: String, caret: Int)? {
        guard let accepted = acceptSelectedSuggestion(into: draft)
        else { return nil }
        return (accepted, accepted.utf16.count)
    }

    /// Return-key arbitration for the text fields: with the menu open the
    /// key accepts the highlighted suggestion instead of inserting a
    /// newline. `consumedKey` tells the editor to keep the newline out;
    /// the accept may still be nil when the draft no longer holds the
    /// token — the key is consumed regardless so a stale menu cannot
    /// leak a newline (parity with the Composer's newline handler).
    func handleReturnKey(into draft: String) -> (
        accepted: (draft: String, caret: Int)?, consumedKey: Bool
    ) {
        guard handleKey(.enter), hasActiveSuggestions
        else { return (nil, false) }
        return (acceptSelectedSuggestionWithCaret(into: draft), true)
    }

    func clearRoutingError() {
        routingError = nil
    }

    // MARK: Scratch-shell protocol

    /// A unique single-quoted-safe sentinel for one run's completion marker.
    nonisolated static func makeSentinel() -> String {
        "__HEELER_BASH_\(UUID().uuidString.prefix(8))__"
    }

    /// The command as typed into the shell: run it, then print the sentinel
    /// line carrying the exit status. Appending (instead of a `{ … }` group)
    /// keeps user commands that contain unbalanced quotes or braces working;
    /// a command that kills the shell simply hits the timeout honestly.
    nonisolated static func wrappedCommand(
        _ command: String, sentinel: String
    ) -> String {
        command + " ; printf '\\n\(sentinel)%s\\n' \"$?\"\n"
    }

    /// Polls the pane until the sentinel lands or the timeout elapses.
    nonisolated private static func pollBashOutput(
        io: ComposerBashIO,
        hostID: UUID,
        paneID: String,
        command: String,
        sentinel: String,
        timeout: Duration,
        pollInterval: Duration,
        describeError: @Sendable (_ error: any Error) -> String
    ) async -> ComposerBashResult.State {
        let deadline = ContinuousClock().now + timeout
        while true {
            let text: String
            do {
                text = try await io.readPaneText(hostID, paneID)
            } catch {
                return .failed(describeError(error))
            }
            if let parsed = parseBashOutput(
                command: command, sentinel: sentinel, from: text)
            {
                return .finished(exitCode: parsed.exitCode, output: parsed.output)
            }
            guard ContinuousClock().now < deadline else {
                return .failed("The command did not finish before the timeout.")
            }
            do {
                try await Task.sleep(for: pollInterval)
            } catch {
                return .failed("The command run was cancelled.")
            }
        }
    }

    /// Extracts the exit status and the command's output from the pane text.
    /// The pane echoes the wrapped command first, so everything up to and
    /// including that echoed line is dropped; the sentinel's printf runs
    /// immediately after the command, so what precedes the sentinel is the
    /// output. Heuristics, documented as such: a shell prompt the pane
    /// printed before the echo survives into the output.
    nonisolated static func parseBashOutput(
        command: String, sentinel: String, from text: String
    ) -> (exitCode: Int, output: String)? {
        // The pane echoes the wrapped command, which itself contains the
        // sentinel — the completion marker is the LAST occurrence,
        // followed by the status digits.
        guard let range = text.range(of: sentinel, options: .backwards)
        else { return nil }
        let statusRun = text[range.upperBound...].prefix(while: \.isNumber)
        guard let exitCode = Int(statusRun) else { return nil }
        let output = cleanedOutput(String(text[..<range.lowerBound]), command: command)
        return (exitCode, output)
    }

    /// Drops the echoed command line, leading and trailing blanks, and
    /// bounds the output for inline display.
    nonisolated static func cleanedOutput(
        _ output: String, command: String
    ) -> String {
        var lines = output.split(
            separator: "\n", omittingEmptySubsequences: false
        ).map(String.init)
        let firstWord =
            command.split(whereSeparator: \.isWhitespace).first.map(String.init) ?? ""
        if !firstWord.isEmpty,
            let echo = lines.firstIndex(where: { $0.contains(firstWord) })
        {
            lines.removeSubrange(...echo)
        }
        while lines.last?.trimmingCharacters(in: .whitespaces).isEmpty == true {
            lines.removeLast()
        }
        while lines.first?.trimmingCharacters(in: .whitespaces).isEmpty == true {
            lines.removeFirst()
        }
        var text = lines.joined(separator: "\n")
        if text.count > maximumInlineOutputCharacters {
            text = String(text.suffix(maximumInlineOutputCharacters))
        }
        return text
    }

    /// Inline bash output is bounded; the full pane keeps the rest.
    nonisolated static let maximumInlineOutputCharacters = 20_000
}

extension ComposerRouterStore {
    /// The chat-surface wiring over a ConsoleStore. Mention delivery and
    /// agent-name resolution reuse the Console's existing Host-scoped RPCs,
    /// so `@mention` works across Hosts. `bashIO` still needs the pane-I/O
    /// seam (see ``ComposerBashIO``); the level store is the chat's shared
    /// persistence, keyed by the pane.
    @MainActor
    static func makeChatDependencies(
        console: ConsoleStore,
        agent: ConsoleAgent,
        bashIO: ComposerBashIO,
        agentKind: String = "omp",
        commandFileIO: AgentCommandFileIO? = nil
    ) -> Dependencies {
        let hostID = agent.hostID
        let paneID = agent.agent.paneID
        let commandProvider = AgentCommandRegistry.provider(forKind: agentKind)
        let dynamicStore = AgentDynamicCommandStore.shared
        // The chat surface's opening refresh of the Host's file-borne
        // commands (skills + project command files). The menu reads the
        // cache synchronously, so it shows the static table first and
        // the discovered commands appear as soon as the refresh lands.
        if let commandFileIO {
            let kind = agentKind
            let cwd = agent.agent.cwd
            Task { @MainActor in
                await dynamicStore.refresh(
                    hostID: hostID,
                    paneID: paneID,
                    kind: kind,
                    cwd: cwd,
                    io: commandFileIO)
            }
        }
        return Dependencies(
            hostID: hostID,
            paneID: paneID,
            levelStore: .shared,
            resolveAgent: { name in
                Self.resolveAgent(name, in: console.agents)
            },
            deliverMention: { resolved, message in
                _ = try await console.promptAgent(
                    AgentPromptParams(target: resolved.paneID, text: message),
                    on: resolved.hostID)
            },
            bashIO: bashIO,
            agentCommands: {
                commandProvider.slashCommands()
                    + dynamicStore.cachedCommands(hostID: hostID, paneID: paneID)
            },
            workspaces: {
                var seen = Set<String>()
                return console.agents
                    .filter { $0.hostID == hostID }
                    .compactMap(\.workspaceLabel)
                    .filter { seen.insert($0).inserted }
            },
            agents: { console.agents.compactMap(Self.suggestionName) },
            describeError: { AgentComposerStore.message(for: $0) })
    }

    /// Display-name resolution over the Console's flat agent list: an
    /// exact (case-insensitive) match wins, then a unique prefix match;
    /// anything ambiguous stays unresolved so the user sees the rejection.
    @MainActor
    static func resolveAgent(
        _ name: String, in agents: [ConsoleAgent]
    ) -> ComposerResolvedAgent? {
        let needle = name.lowercased()
        if let exact = agents.first(where: {
            Self.suggestionName($0)?.lowercased() == needle
        }) {
            return (exact.hostID, exact.agent.paneID)
        }
        let prefixed = agents.filter {
            Self.suggestionName($0)?.lowercased().hasPrefix(needle) == true
        }
        guard prefixed.count == 1 else { return nil }
        return (prefixed[0].hostID, prefixed[0].agent.paneID)
    }

    /// The name a `@mention` addresses an agent by, and the name the
    /// suggestion menu lists: the pane's own label first, then the
    /// agent's display name, then the tab label.
    @MainActor
    static func suggestionName(_ agent: ConsoleAgent) -> String? {
        agent.paneLabel ?? agent.agent.name ?? agent.tabLabel
    }
}
