import Foundation
import Testing

@testable import Heeler

// SPDX-License-Identifier: Apache-2.0
//
// The Composer input-mode router's exhaustive contract (fork plan, Phase
// 2): classify's whole table (each prefix, quoting, the doubled-prefix
// escape, empty drafts, prefix-not-first-char), the suggestion filtering,
// the store's local-command effects on a stub level store, mention
// resolution + delivery, the scratch-shell run protocol, and the
// passthrough identity that keeps Monitor/Attach byte-identical.

// MARK: - Test support

/// Thread-safe capture for closures that cross isolation boundaries.
private final class Recorder<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [Value] = []

    var all: [Value] {
        lock.lock()
        defer { lock.unlock() }
        return items
    }

    func append(_ item: Value) {
        lock.lock()
        defer { lock.unlock() }
        items.append(item)
    }
}

/// A scripted scratch pane for the bash seam. Replies are derived from the
/// wrapped command actually sent, mirroring how a real pane's recent
/// output contains the shell's echo of the wrapped command followed by
/// the command's output and the completion marker.
private final class ScriptedBashPane: @unchecked Sendable {
    enum Mode {
        /// Reply without any completion marker (the run must time out).
        case neverFinishes
        /// Reply with `output`, then the marker with `exitCode`.
        case finishes(output: String, exitCode: Int)
    }

    private let lock = NSLock()
    private let mode: () -> Mode
    let sentText = Recorder<String>()
    private(set) var createdCount = 0

    init(mode: @autoclosure @escaping () -> Mode) {
        self.mode = mode
    }

    /// The completion marker inside the wrapped command the store sent.
    var lastSentinel: String? {
        guard let wrapped = sentText.all.last,
            let prefix = wrapped.range(of: "printf '\\n"),
            let marker = wrapped[prefix.upperBound...].range(of: "__HEELER_BASH_")
        else { return nil }
        let id = wrapped[marker.upperBound...].prefix(8)
        return "__HEELER_BASH_\(id)__"
    }

    func nextRead() -> String {
        lock.lock()
        defer { lock.unlock() }
        guard let wrapped = sentText.all.last else { return "$ " }
        let echo = "$ " + wrapped
        switch mode() {
        case .neverFinishes:
            return echo + "\nstill running\n"
        case .finishes(let output, let exitCode):
            guard let sentinel = lastSentinel else { return echo }
            return echo + "\n" + output + "\n" + sentinel + "\(exitCode)\n$ "
        }
    }

    func createPane() -> String {
        lock.lock()
        defer { lock.unlock() }
        createdCount += 1
        return "scratch-\(createdCount)"
    }
}

private func makeBashIO(
    pane: ScriptedBashPane,
    createError: (any Error)? = nil
) -> ComposerBashIO {
    ComposerBashIO(
        createScratchPane: { _ in
            if let createError { throw createError }
            return pane.createPane()
        },
        sendText: { _, _, text in pane.sentText.append(text) },
        readPaneText: { _, _ in pane.nextRead() })
}

private struct MentionTarget: Equatable {
    let hostID: UUID
    let paneID: String
    let message: String
}

@MainActor
private func makeDependencies(
    hostID: UUID = UUID(),
    paneID: String = "wA:p1",
    levelDefaults: UserDefaults,
    resolve: ((String) -> ComposerResolvedAgent?)? = nil,
    mentions: Recorder<MentionTarget>? = nil,
    deliverError: (any Error)? = nil,
    bashIO: ComposerBashIO = makeBashIO(
        pane: ScriptedBashPane(mode: .finishes(output: "", exitCode: 0))),
    follows: Recorder<String>? = nil,
    tags: Recorder<TagFilter>? = nil,
    levels: Recorder<DetailLevel>? = nil,
    workspaces: [String] = [],
    agents: [String] = [],
    describeError: @escaping @Sendable (any Error) -> String = {
        AgentComposerStore.message(for: $0)
    },
    bashTimeout: Duration = .seconds(10),
    bashPollInterval: Duration = .milliseconds(10)
) -> ComposerRouterStore.Dependencies {
    ComposerRouterStore.Dependencies(
        hostID: hostID,
        paneID: paneID,
        levelStore: ChatDetailLevelStore(defaults: levelDefaults),
        resolveAgent: { name in resolve?(name) },
        deliverMention: { resolved, message in
            if let deliverError { throw deliverError }
            mentions?.append(
                MentionTarget(hostID: resolved.hostID, paneID: resolved.paneID, message: message))
        },
        bashIO: bashIO,
        follow: { follows?.append($0) },
        tagFilter: { tags?.append($0) },
        levelDidChange: { levels?.append($0) },
        workspaces: { workspaces },
        statuses: { ["blocked", "working", "done", "idle"] },
        agents: { agents },
        describeError: describeError,
        bashTimeout: bashTimeout,
        bashPollInterval: bashPollInterval)
}

@MainActor
private func makeStore(
    _ dependencies: ComposerRouterStore.Dependencies
) -> ComposerRouterStore {
    ComposerRouterStore(dependencies: dependencies)
}

@MainActor
private func freshDefaults() -> UserDefaults {
    let name = "ChatComposerRouterTests.\(UUID().uuidString)"
    return UserDefaults(suiteName: name) ?? .standard
}

// MARK: - classify

@Suite("ComposerRouter.classify")
struct ChatComposerRouterClassifyTests {
    // -- plain --

    @Test func emptyDraftIsPlain() {
        #expect(ComposerRouter.classify("") == .plain(text: ""))
        #expect(ComposerRouter.classify("   ") == .plain(text: "   "))
    }

    @Test func ordinaryTextIsPlain() {
        #expect(ComposerRouter.classify("hello world") == .plain(text: "hello world"))
    }

    @Test func prefixNotFirstCharacterIsPlain() {
        #expect(ComposerRouter.classify("a /level 2") == .plain(text: "a /level 2"))
        #expect(ComposerRouter.classify(" /level 2") == .plain(text: " /level 2"))
        #expect(ComposerRouter.classify("run #tag now") == .plain(text: "run #tag now"))
        #expect(ComposerRouter.classify("see @agent there") == .plain(text: "see @agent there"))
        #expect(ComposerRouter.classify("wow! neat") == .plain(text: "wow! neat"))
    }

    @Test func barePrefixCharacterIsPlain() {
        #expect(ComposerRouter.classify("/") == .plain(text: "/"))
        #expect(ComposerRouter.classify("#") == .plain(text: "#"))
        #expect(ComposerRouter.classify("@") == .plain(text: "@"))
    }

    @Test func bareBangIsAnEmptyBashCommand() {
        // The store rejects it as empty; classifying as .plain would send
        // a literal "!" to the agent.
        #expect(ComposerRouter.classify("!") == .bash(command: ""))
    }

    @Test(arguments: ["//escaped", "##tag", "@@agent", "!!sudo"])
    func doubledPrefixEscapes(_ text: String) {
        let command = ComposerRouter.classify(text)
        guard case .plain(let delivered) = command else {
            Issue.record("\(text) should be plain, got \(command)")
            return
        }
        #expect(delivered == String(text.dropFirst()))
    }

    // -- slash --

    @Test func slashWithoutArgs() {
        #expect(ComposerRouter.classify("/compact") == .slash(name: "compact", args: ""))
    }

    @Test func slashWithArgs() {
        #expect(
            ComposerRouter.classify("/level 2")
            == .slash(name: "level", args: "2"))
    }

    @Test func slashArgsAreTrimmed() {
        #expect(
            ComposerRouter.classify("/level   2  ")
            == .slash(name: "level", args: "2"))
    }

    @Test func colonSplitsNameLikeOmp() {
        // omp's parseSlashCommand ends the name at the first whitespace or
        // ':' — `/level:2` and `/level 2` are the same command.
        #expect(
            ComposerRouter.classify("/level:2")
            == .slash(name: "level", args: "2"))
        #expect(
            ComposerRouter.classify("/skill:web fix")
            == .slash(name: "skill", args: "web fix"))
    }

    // -- tag --

    @Test func bareTagQuery() {
        #expect(
            ComposerRouter.classify("#blocked")
            == .tag(TagFilter(field: nil, value: "blocked")))
    }

    @Test func qualifiedTagFields() {
        #expect(
            ComposerRouter.classify("#status:blocked")
            == .tag(TagFilter(field: .status, value: "blocked")))
        #expect(
            ComposerRouter.classify("#Workspace:myrepo ")
            == .tag(TagFilter(field: .workspace, value: "myrepo")))
        #expect(
            ComposerRouter.classify("#AGENT:john")
            == .tag(TagFilter(field: .agent, value: "john")))
    }

    @Test func unknownFieldPrefixStaysTheWholeValue() {
        #expect(
            ComposerRouter.classify("#my:weird")
            == .tag(TagFilter(field: nil, value: "my:weird")))
    }

    // -- mention --

    @Test func mentionWithMessage() {
        #expect(
            ComposerRouter.classify("@agent do the thing")
            == .mention(agent: "agent", message: "do the thing"))
    }

    @Test func mentionWithoutMessage() {
        #expect(
            ComposerRouter.classify("@agent")
            == .mention(agent: "agent", message: ""))
    }

    @Test func mentionNameEndsAtWhitespace() {
        #expect(
            ComposerRouter.classify("@agent-2.ok   fix it")
            == .mention(agent: "agent-2.ok", message: "fix it"))
    }

    // -- bash --

    @Test func bashCommand() {
        #expect(
            ComposerRouter.classify("!ls -la /tmp")
            == .bash(command: "ls -la /tmp"))
    }

    @Test func bashCommandIsTrimmed() {
        #expect(
            ComposerRouter.classify("!  git status ")
            == .bash(command: "git status"))
    }

    @Test func bashKeepsInternalQuoting() {
        #expect(
            ComposerRouter.classify("!echo 'a b'")
            == .bash(command: "echo 'a b'"))
    }
}

// MARK: - activeToken (suggestion detection)

@Suite("ComposerRouter.activeToken")
struct ChatComposerRouterTokenTests {
    @Test func slashIsTrailingToken() {
        #expect(ComposerRouter.activeToken(draft: "/") == .slash(token: "/"))
        #expect(ComposerRouter.activeToken(draft: "/le") == .slash(token: "/le"))
        #expect(ComposerRouter.activeToken(draft: "try /comp") == .slash(token: "/comp"))
    }

    @Test func slashTokenEndsAtWhitespace() {
        #expect(ComposerRouter.activeToken(draft: "/level 2") == nil)
    }

    @Test func tagTakesTheWholeRest() {
        #expect(ComposerRouter.activeToken(draft: "#") == .tag(query: ""))
        #expect(ComposerRouter.activeToken(draft: "#blo") == .tag(query: "blo"))
        #expect(ComposerRouter.activeToken(draft: "#status:blo") == .tag(query: "status:blo"))
    }

    @Test func tagClosesOnceAValueIsChosen() {
        #expect(ComposerRouter.activeToken(draft: "#blocked ") == nil)
    }

    @Test func mentionTakesTheNameOnly() {
        #expect(ComposerRouter.activeToken(draft: "@") == .mention(query: ""))
        #expect(ComposerRouter.activeToken(draft: "@jo") == .mention(query: "jo"))
    }

    @Test func mentionClosesOnceAMessageStarts() {
        #expect(ComposerRouter.activeToken(draft: "@john fix") == nil)
    }

    @Test func bashNeverOpensSuggestions() {
        #expect(ComposerRouter.activeToken(draft: "!") == nil)
        #expect(ComposerRouter.activeToken(draft: "!git st") == nil)
    }

    @Test func proseAndEscapesNeverOpenSuggestions() {
        #expect(ComposerRouter.activeToken(draft: "hello") == nil)
        #expect(ComposerRouter.activeToken(draft: "//x") == nil)
        #expect(ComposerRouter.activeToken(draft: "fix something") == nil)
    }

    @Test func slashReplacementSwapsTheTrailingToken() {
        let token = ComposerRouter.activeToken(draft: "try /le")!
        #expect(token.replacingDraft("try /le", with: "/level ") == "try /level ")
    }

    @Test func mentionReplacementKeepsASeparatingSpace() {
        let token = ComposerRouter.activeToken(draft: "@jo")!
        #expect(token.replacingDraft("@jo", with: "john") == "@john ")
    }

    @Test func tagReplacementReplacesTheWholeDraft() {
        let token = ComposerRouter.activeToken(draft: "#blo")!
        #expect(token.replacingDraft("#blo", with: "#status:blocked ") == "#status:blocked ")
    }
}

// MARK: - suggestion filtering

@Suite("ComposerRouter.suggestions")
struct ChatComposerRouterSuggestionTests {
    /// The omp table, as the store injects it for an omp-kind agent.
    private let ompCommands = OmpCommandProvider().slashCommands()

    @Test func slashListsLocalsFirst() {
        let suggestions = ComposerRouter.slashSuggestions(
            matching: "", agentCommands: ompCommands)
        #expect(!suggestions.isEmpty)
        #expect(suggestions.first?.title == ComposerLocalCommand.level.name)
        #expect(
            suggestions.prefix(2).map(\.title)
            == ComposerLocalCommand.all.map(\.name))
    }

    @Test func slashMatchesPrefixCaseInsensitively() {
        let suggestions = ComposerRouter.slashSuggestions(
            matching: "LE", agentCommands: ompCommands)
        #expect(suggestions.map(\.title) == [ComposerLocalCommand.level.name])
        let omp = ComposerRouter.slashSuggestions(
            matching: "COMP", agentCommands: ompCommands)
        #expect(omp.map(\.title) == ["compact"])
    }

    @Test func slashSuggestsOmpBuiltinsWithInsertion() {
        let suggestions = ComposerRouter.slashSuggestions(
            matching: "compact", agentCommands: ompCommands)
        #expect(suggestions == [
            ComposerSuggestion(
                id: "omp:compact", title: "compact",
                detail: "Manually compact the session context",
                insertion: "/compact ", kind: .slash,
                usage: "[soft|remote|snapcompact] [focus]")
        ])
    }

    /// An empty `/` query is the command palette: every agent command,
    /// then the client-local ones, uncapped — the menu scrolls.
    @Test func slashEmptyQueryListsEverythingAgentFirst() {
        let suggestions = ComposerRouter.slashSuggestions(
            matching: "", agentCommands: ompCommands)
        #expect(suggestions.count
            == ompCommands.count + ComposerLocalCommand.all.count)
        #expect(suggestions.prefix(ompCommands.count).allSatisfy {
            $0.kind == .slash
        })
        #expect(suggestions.suffix(ComposerLocalCommand.all.count).allSatisfy {
            $0.kind == .local
        })
    }

    @Test func tagStatusesCarryTheirField() {
        let suggestions = ComposerRouter.tagSuggestions(
            field: nil, matching: "",
            workspaces: ["heeler"], statuses: ["blocked"], agents: [])
        let status = suggestions.first { $0.title == "blocked" }
        #expect(status?.insertion == "#status:blocked ")
        let workspace = suggestions.first { $0.title == "heeler" }
        #expect(workspace?.insertion == "#heeler ")
    }

    @Test func explicitFieldFiltersToThatField() {
        let suggestions = ComposerRouter.tagSuggestions(
            field: .status, matching: "",
            workspaces: ["heeler"], statuses: ["blocked"], agents: ["john"])
        #expect(suggestions.map(\.title) == ["blocked"])
    }

    @Test func tagMatchesByPrefix() {
        let suggestions = ComposerRouter.tagSuggestions(
            field: nil, matching: "blo",
            workspaces: ["heeler"], statuses: ["blocked", "working"], agents: [])
        #expect(suggestions.map(\.title) == ["blocked"])
    }

    @Test func mentionMatchesByPrefix() {
        let suggestions = ComposerRouter.mentionSuggestions(
            matching: "jo", agents: ["john", "jane", "josephine"])
        #expect(suggestions.map(\.title) == ["john", "josephine"])
        #expect(suggestions.first?.insertion == "john")
    }
}

// MARK: - store routing

@MainActor
@Suite("ComposerRouterStore submit")
struct ChatComposerRouterStoreTests {
    @Test func plainTextPassesThroughUntouched() async {
        let store = makeStore(makeDependencies(levelDefaults: freshDefaults()))
        let outcome = await store.submit("hello world")
        #expect(outcome == .passthrough)
        #expect(store.bashResults.isEmpty)
        #expect(store.routingError == nil)
    }

    @Test func emptyDraftPassesThrough() async {
        let store = makeStore(makeDependencies(levelDefaults: freshDefaults()))
        #expect(await store.submit("") == .passthrough)
    }

    @Test func ompSlashCommandsPassThroughAsPromptText() async {
        let store = makeStore(makeDependencies(levelDefaults: freshDefaults()))
        #expect(await store.submit("/compact") == .passthrough)
        #expect(await store.submit("/unknown-command now") == .passthrough)
        #expect(store.routingError == nil)
    }

    @Test func levelCommandPersistsThroughTheLevelStore() async {
        let defaults = freshDefaults()
        let levels = Recorder<DetailLevel>()
        let store = makeStore(
            makeDependencies(levelDefaults: defaults, levels: levels))
        #expect(await store.submit("/level 2") == .handled)
        #expect(
            ChatDetailLevelStore(defaults: defaults).level(paneID: "wA:p1")
            == .l2)
        #expect(levels.all == [.l2])
    }

    @Test func levelCommandAcceptsColonForm() async {
        let defaults = freshDefaults()
        let store = makeStore(makeDependencies(levelDefaults: defaults))
        #expect(await store.submit("/level:3") == .handled)
        #expect(
            ChatDetailLevelStore(defaults: defaults).level(paneID: "wA:p1")
            == .l3)
    }

    @Test func levelCommandRejectsOutOfRange() async {
        let store = makeStore(makeDependencies(levelDefaults: freshDefaults()))
        #expect(await store.submit("/level 9") == .rejected)
        #expect(await store.submit("/level") == .rejected)
        #expect(await store.submit("/level two") == .rejected)
        #expect(store.routingError == "Usage: /level <0-3>")
    }

    @Test func followCommandForwardsTheName() async {
        let follows = Recorder<String>()
        let store = makeStore(
            makeDependencies(levelDefaults: freshDefaults(), follows: follows))
        #expect(await store.submit("/follow john") == .handled)
        #expect(follows.all == ["john"])
    }

    @Test func followCommandRequiresAnAgent() async {
        let store = makeStore(makeDependencies(levelDefaults: freshDefaults()))
        #expect(await store.submit("/follow") == .rejected)
        #expect(store.routingError == "Usage: /follow <agent>")
    }

    @Test func tagCommandForwardsTheStructuredFilter() async {
        let tags = Recorder<TagFilter>()
        let store = makeStore(
            makeDependencies(levelDefaults: freshDefaults(), tags: tags))
        #expect(await store.submit("#status:blocked") == .handled)
        #expect(tags.all == [TagFilter(field: .status, value: "blocked")])
        #expect(await store.submit("#myrepo") == .handled)
        #expect(tags.all.last == TagFilter(field: nil, value: "myrepo"))
    }

    @Test func mentionDeliversToTheResolvedTarget() async {
        let target = (hostID: UUID(), paneID: "wB:p2")
        let mentions = Recorder<MentionTarget>()
        let store = makeStore(
            makeDependencies(
                levelDefaults: freshDefaults(),
                resolve: { name in name == "john" ? target : nil },
                mentions: mentions))
        #expect(await store.submit("@john fix the build") == .handled)
        #expect(
            mentions.all
            == [MentionTarget(hostID: target.hostID, paneID: target.paneID, message: "fix the build")])
    }

    @Test func mentionWithoutMessageIsRejected() async {
        let store = makeStore(
            makeDependencies(
                levelDefaults: freshDefaults(),
                resolve: { _ in (hostID: UUID(), paneID: "wB:p2") }))
        #expect(await store.submit("@john") == .rejected)
        #expect(store.routingError == "Add a message after the agent name.")
    }

    @Test func unresolvedMentionIsRejected() async {
        let store = makeStore(
            makeDependencies(levelDefaults: freshDefaults(), resolve: { _ in nil }))
        #expect(await store.submit("@nobody hi") == .rejected)
        #expect(store.routingError == "No agent named “nobody”.")
    }

    @Test func failedMentionDeliverySurfacesTheError() async {
        let store = makeStore(
            makeDependencies(
                levelDefaults: freshDefaults(),
                resolve: { _ in (hostID: UUID(), paneID: "wB:p2") },
                deliverError: TransportError.timedOut))
        #expect(await store.submit("@john hi") == .rejected)
        #expect(store.routingError == AgentComposerStore.message(for: TransportError.timedOut))
    }
}

// MARK: - store suggestions + keyboard

@MainActor
@Suite("ComposerRouterStore suggestions")
struct ChatComposerRouterSuggestionStoreTests {
    @Test func slashDraftOpensTheMenu() {
        let store = makeStore(makeDependencies(levelDefaults: freshDefaults()))
        store.updateSuggestions(forDraft: "/")
        #expect(store.hasActiveSuggestions)
        #expect(store.suggestions.contains { $0.title == "level" })
    }

    @Test func typingFiltersTheMenu() {
        let store = makeStore(makeDependencies(levelDefaults: freshDefaults()))
        store.updateSuggestions(forDraft: "/le")
        #expect(store.suggestions.map(\.title) == ["level"])
    }

    @Test func proseDraftHasNoMenu() {
        let store = makeStore(makeDependencies(levelDefaults: freshDefaults()))
        store.updateSuggestions(forDraft: "hello there")
        #expect(!store.hasActiveSuggestions)
    }

    @Test func agentsComeFromTheProvider() {
        let store = makeStore(
            makeDependencies(levelDefaults: freshDefaults(), agents: ["john", "jane"]))
        store.updateSuggestions(forDraft: "@ja")
        #expect(store.suggestions.map(\.title) == ["jane"])
    }

    @Test func arrowKeysCycleAndEscapeDismisses() {
        let store = makeStore(makeDependencies(levelDefaults: freshDefaults()))
        store.updateSuggestions(forDraft: "/")
        let count = store.suggestions.count
        #expect(count > 2)
        #expect(store.handleKey(.down))
        #expect(store.selectedSuggestionIndex == 1)
        #expect(store.handleKey(.up))
        #expect(store.selectedSuggestionIndex == 0)
        // Up from the first wraps to the last.
        #expect(store.handleKey(.up))
        #expect(store.selectedSuggestionIndex == count - 1)
        #expect(store.handleKey(.escape))
        #expect(!store.hasActiveSuggestions)
        #expect(!store.handleKey(.down))
    }

    @Test func retypingTheTokenRearmsADismissedMenu() {
        let store = makeStore(makeDependencies(levelDefaults: freshDefaults()))
        store.updateSuggestions(forDraft: "/")
        store.handleKey(.escape)
        #expect(!store.hasActiveSuggestions)
        store.updateSuggestions(forDraft: "/le")
        #expect(store.hasActiveSuggestions)
    }

    @Test func acceptedSuggestionRewritesTheDraft() {
        let store = makeStore(makeDependencies(
            levelDefaults: freshDefaults(), agents: ["john"]))
        store.updateSuggestions(forDraft: "/le")
        #expect(store.acceptSelectedSuggestion(into: "/le") == "/level ")
        store.updateSuggestions(forDraft: "@jo")
        #expect(store.acceptSelectedSuggestion(into: "@jo") == "@john ")
    }

    @Test func keysWithoutAMenuDoNotConsume() {
        let store = makeStore(makeDependencies(levelDefaults: freshDefaults()))
        #expect(!store.handleKey(.up))
        #expect(!store.handleKey(.down))
        #expect(!store.handleKey(.escape))
        #expect(!store.handleKey(.enter))
    }

    @Test func tokenChangeClearsAStaleRejection() async {
        let store = makeStore(makeDependencies(levelDefaults: freshDefaults()))
        let rejected = await store.submit("/level 9")
        #expect(rejected == .rejected)
        #expect(store.routingError != nil)
        store.updateSuggestions(forDraft: "/le")
        #expect(store.routingError == nil)
    }
}

// MARK: - bash

@MainActor
@Suite("ComposerRouterStore bash")
struct ChatComposerRouterBashTests {
    @Test func runCapturesExitCodeAndOutput() async {
        let pane = ScriptedBashPane(mode: .finishes(output: "hi", exitCode: 0))
        let store = makeStore(
            makeDependencies(
                levelDefaults: freshDefaults(),
                bashIO: makeBashIO(pane: pane),
                bashPollInterval: .milliseconds(5)))
        #expect(await store.submit("!echo hi") == .handled)
        // The wrapped command carries the completion marker and Enter.
        let sent = pane.sentText.all
        #expect(sent.count == 1)
        #expect(sent[0].hasPrefix("echo hi ; printf '\\n__HEELER_BASH_"))
        #expect(sent[0].hasSuffix("' \"$?\"\n"))
        #expect(store.bashResults.count == 1)
        #expect(store.bashResults[0].command == "echo hi")
        #expect(store.bashResults[0].state == .running)

        // The poll is a background task; wait for the sentinel to land.
        await waitUntil(timeout: .seconds(2)) {
            if case .finished = store.bashResults[0].state { return true }
            return false
        }
        guard case .finished(let exitCode, let output) = store.bashResults[0].state
        else {
            Issue.record("expected finished, got \(store.bashResults[0].state)")
            return
        }
        #expect(exitCode == 0)
        #expect(output == "hi")
    }

    @Test func nonzeroExitCodeIsReported() async {
        let pane = ScriptedBashPane(mode: .finishes(output: "", exitCode: 3))
        let store = makeStore(
            makeDependencies(
                levelDefaults: freshDefaults(),
                bashIO: makeBashIO(pane: pane),
                bashPollInterval: .milliseconds(5)))
        #expect(await store.submit("!exit 3") == .handled)
        await waitUntil(timeout: .seconds(2)) {
            if case .finished = store.bashResults[0].state { return true }
            return false
        }
        guard case .finished(let exitCode, _) = store.bashResults[0].state
        else {
            Issue.record("expected finished, got \(store.bashResults[0].state)")
            return
        }
        #expect(exitCode == 3)
    }

    @Test func paneIsCreatedLazilyAndReused() async {
        let pane = ScriptedBashPane(mode: .finishes(output: "", exitCode: 0))
        let store = makeStore(
            makeDependencies(
                levelDefaults: freshDefaults(),
                bashIO: makeBashIO(pane: pane),
                bashPollInterval: .milliseconds(5)))
        _ = await store.submit("!true")
        #expect(pane.createdCount == 1)
        await waitUntil(timeout: .seconds(2)) {
            if case .finished = store.bashResults[0].state { return true }
            return false
        }
        _ = await store.submit("!true")
        // The same pane serves the second run.
        #expect(pane.createdCount == 1)
        // Let the second run settle so the store is not left running.
        await waitUntil(timeout: .seconds(2)) {
            if case .finished = store.bashResults[1].state { return true }
            return false
        }
    }

    @Test func timeoutFailsTheRun() async {
        let pane = ScriptedBashPane(mode: .neverFinishes)
        let store = makeStore(
            makeDependencies(
                levelDefaults: freshDefaults(),
                bashIO: makeBashIO(pane: pane),
                bashTimeout: .milliseconds(40),
                bashPollInterval: .milliseconds(5)))
        #expect(await store.submit("!sleep 1000") == .handled)
        await waitUntil(timeout: .seconds(2)) {
            if case .failed = store.bashResults[0].state { return true }
            return false
        }
        guard case .failed(let message) = store.bashResults[0].state
        else { return }
        #expect(message == "The command did not finish before the timeout.")
    }

    @Test func emptyAndConcurrentBashAreRejected() async {
        let pane = ScriptedBashPane(mode: .neverFinishes)
        let store = makeStore(
            makeDependencies(
                levelDefaults: freshDefaults(),
                bashIO: makeBashIO(pane: pane),
                bashTimeout: .seconds(5)))
        #expect(await store.submit("!") == .rejected)
        #expect(await store.submit("!sleep 10") == .handled)
        #expect(await store.submit("!echo hi") == .rejected)
        #expect(store.routingError == "A shell command is already running.")
        #expect(store.bashResults.count == 1)
    }
}

// MARK: - helpers

/// Polls `condition` until it holds or the timeout elapses.
@MainActor
private func waitUntil(
    timeout: Duration,
    condition: @MainActor () -> Bool
) async {
    let deadline = ContinuousClock().now + timeout
    while !condition() {
        guard ContinuousClock().now < deadline else {
            Issue.record("timed out waiting for the condition")
            return
        }
        try? await Task.sleep(for: .milliseconds(5))
    }
}
