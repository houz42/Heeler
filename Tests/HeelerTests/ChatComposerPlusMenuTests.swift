import Foundation
import Testing

@testable import Heeler

// SPDX-License-Identifier: Apache-2.0
//
// The v3 + menu / structured-intent contract (design doc "Compact
// composer: one row, one + menu"): the four prefix modes are exposed
// as CHOOSER entry points, a chosen command resolves to a catalog ID
// (never a literal "/" another layer re-guesses), execution goes
// through the SAME routing a typed draft takes, and cancel preserves
// the draft exactly. Composer-state pins (send enablement via the
// shared predicate) live here too — the composer reshape keeps
// ChatDraftComposer.isSendable as the one sendability authority.

// MARK: - Test support (mirrors ChatComposerRouterTests's shape)

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

private func makeDependencies(
    levelDefaults: UserDefaults,
    tags: Recorder<TagFilter>? = nil,
    deliverCommand: (@Sendable (
        _ catalogID: String, _ name: String, _ arguments: [String]
    ) async throws -> Void)? = nil
) -> ComposerRouterStore.Dependencies {
    ComposerRouterStore.Dependencies(
        hostID: UUID(),
        paneID: "wA:p1",
        levelStore: ChatDetailLevelStore(defaults: levelDefaults),
        resolveAgent: { _ in nil },
        deliverMention: { _, _ in },
        bashIO: ComposerBashIO(
            createScratchPane: { _ in "scratch" },
            sendText: { _, _, _ in },
            readPaneText: { _, _ in "" }),
        tagFilter: { tags?.append($0) },
        workspaces: { ["iOS App"] },
        statuses: { ["blocked", "working", "done", "idle"] },
        agents: { ["docs-review", "accessibility"] },
        deliverCommand: deliverCommand)
}
private func freshDefaults() -> UserDefaults {
    let name = "ChatComposerPlusMenuTests.\(UUID().uuidString)"
    return UserDefaults(suiteName: name) ?? .standard
}

// MARK: - The + menu's four prefix modes

@Suite("Composer + menu prefix modes")
struct ChatComposerPlusMenuModeTests {
    /// The design doc's + menu holds EXACTLY the four prefix functions
    /// — Agent command (/), Filter/tag (#), Mention (@), Shell command
    /// (!) — in that order, ahead of the image/file actions.
    @Test func theMenuExposesTheFourPrefixModesInOrder() {
        let modes = ComposerPrefixMode.allCases
        #expect(modes == [.slash, .tag, .mention, .bash])
        #expect(modes.map(\.prefixCharacter) == ["/", "#", "@", "!"])
        #expect(modes.map(\.menuTitle) == [
            "Agent command", "Filter / tag", "Mention", "Shell command",
        ])
    }

    /// Every mode row carries a distinct SF Symbol so the menu rows
    /// read apart at a glance.
    @Test func eachModeCarriesADistinctSymbol() {
        let symbols = ComposerPrefixMode.allCases.map(\.systemImage)
        #expect(Set(symbols).count == symbols.count)
    }
}

// MARK: - Selection resolves to structured intent

@Suite("Composer command selection")
struct ChatComposerCommandSelectionTests {
    /// A chosen agent command is a catalog ID + arguments; its
    /// delivery text is assembled ONCE from the resolved intent —
    /// the same wire form a typed `/name args` would take. (The
    /// TYPED path still delivers this form; a + menu selection
    /// dispatches structurally — see the chooser suite.)
    @Test func deliveryTextMatchesTheTypedWireForm() {
        #expect(
            ComposerCommandSelection(
                catalogID: "omp:compact", name: "compact", arguments: ""
            ).deliveryText == "/compact")
        #expect(
            ComposerCommandSelection(
                catalogID: "omp:compact", name: "compact", arguments: "soft"
            ).deliveryText == "/compact soft")
        #expect(
            ComposerCommandSelection(
                catalogID: "local:level", name: "level", arguments: " 2 "
            ).deliveryText == "/level 2")
    }
}

// MARK: - The store's chooser + selection contract

@Suite("Composer + menu chooser")
struct ChatComposerChooserTests {
    /// Opening a chooser records the mode; cancel clears it without
    /// touching draft, caret, or focus (the design doc: Cancel
    /// returns to exactly the original draft/caret).
    @MainActor
    @Test func chooserOpenAndCancelCycle() {
        let store = ComposerRouterStore(
            dependencies: makeDependencies(levelDefaults: freshDefaults()))
        #expect(store.activeChooser == nil)
        store.openChooser(for: .bash)
        #expect(store.activeChooser == .bash)
        store.cancelChooser()
        #expect(store.activeChooser == nil)
    }

    /// The command catalog is the SAME table the typed `/` menu
    /// filters: agent commands first (catalog IDs `omp:<name>`),
    /// client-local last (`local:<name>`) — a + menu selection is a
    /// resolved catalog identity.
    @MainActor
    @Test func catalogCarriesResolvedIDsAgentsFirstLocalsLast() {
        let store = ComposerRouterStore(
            dependencies: makeDependencies(levelDefaults: freshDefaults()))
        let catalog = store.commandCatalog()
        let ompNames = OmpCommandProvider().slashCommands().map(\.name)
        #expect(catalog.prefix(ompNames.count).map(\.id)
            == ompNames.map { "omp:\($0)" })
        #expect(catalog.suffix(ComposerLocalCommand.all.count).map(\.id)
            == ComposerLocalCommand.all.map { "local:\($0.name)" })
    }

    /// Executing a resolved selection routes through the SAME path a
    /// typed draft takes: a client-local /level with arguments
    /// persists the level and reports `.handled`; the chooser clears.
    @MainActor
    @Test func runCommandSelectionRoutesLikeTypedText() async {
        let defaults = freshDefaults()
        let store = ComposerRouterStore(
            dependencies: makeDependencies(levelDefaults: defaults))
        store.openChooser(for: .slash)
        let outcome = await store.runCommandSelection(
            ComposerCommandSelection(
                catalogID: "local:level", name: "level", arguments: "2"))
        #expect(outcome == .handled)
        #expect(store.activeChooser == nil)
        #expect(
            ChatDetailLevelStore(defaults: defaults)
                .level(paneID: "wA:p1") == .l2)
    }

    /// A rejected selection (bad arguments) keeps the chooser OPEN and
    /// carries the user-facing reason — never a silent no-op.
    @MainActor
    @Test func rejectedSelectionKeepsChooserOpenWithError() async {
        let store = ComposerRouterStore(
            dependencies: makeDependencies(levelDefaults: freshDefaults()))
        store.openChooser(for: .slash)
        let outcome = await store.runCommandSelection(
            ComposerCommandSelection(
                catalogID: "local:level", name: "level", arguments: "nine"))
        #expect(outcome == .rejected)
        #expect(store.activeChooser == .slash)
        #expect(store.routingError?.contains("Usage") == true)
    }

    /// An AGENT command selection dispatches STRUCTURALLY through the
    /// deliverCommand seam (the command.invoke contract): the catalog
    /// ID and arguments go out as an opaque invocation — never as
    /// slash text re-parsed by a passthrough (review round 1's
    /// blocker: the old path "succeeded" while nothing invoked the
    /// command).
    @MainActor
    @Test func agentCommandSelectionDispatchesThroughTheSeam() async {
        let invocations = Recorder<(id: String, name: String, args: [String])>()
        let store = ComposerRouterStore(
            dependencies: makeDependencies(
                levelDefaults: freshDefaults(),
                deliverCommand: { id, name, args in
                    invocations.append((id, name, args))
                }))
        store.openChooser(for: .slash)
        let outcome = await store.runCommandSelection(
            ComposerCommandSelection(
                catalogID: "omp:compact", name: "compact",
                arguments: "soft --keep-recent"))
        #expect(outcome == .handled)
        #expect(store.activeChooser == nil)
        #expect(invocations.all.count == 1)
        #expect(invocations.all[0].id == "omp:compact")
        #expect(invocations.all[0].name == "compact")
        // Whitespace-separated arguments arrive as an array.
        #expect(invocations.all[0].args == ["soft", "--keep-recent"])
    }

    /// No command lane (nil seam — no broker chat / capability
    /// closed): an agent-command selection REJECTS honestly with a
    /// reason. It must never fall back to delivering slash text as a
    /// prompt (the silent-no-delivery bug).
    @MainActor
    @Test func agentCommandSelectionWithoutSeamRejectsHonestly() async {
        let store = ComposerRouterStore(
            dependencies: makeDependencies(levelDefaults: freshDefaults()))
        store.openChooser(for: .slash)
        let outcome = await store.runCommandSelection(
            ComposerCommandSelection(
                catalogID: "omp:compact", name: "compact", arguments: ""))
        #expect(outcome == .rejected)
        #expect(store.activeChooser == .slash)
        #expect(store.routingError?.contains("cannot run commands") == true)
    }

    /// A seam delivery failure surfaces the reason and keeps the
    /// chooser open.
    @MainActor
    @Test func seamFailureKeepsChooserOpenWithError() async {
        struct Boom: LocalizedError {
            var errorDescription: String? { "The agent refused the command." }
        }
        let store = ComposerRouterStore(
            dependencies: makeDependencies(
                levelDefaults: freshDefaults(),
                deliverCommand: { _, _, _ in throw Boom() }))
        store.openChooser(for: .slash)
        let outcome = await store.runCommandSelection(
            ComposerCommandSelection(
                catalogID: "omp:compact", name: "compact", arguments: ""))
        #expect(outcome == .rejected)
        #expect(store.routingError == "The agent refused the command.")
    }

    /// A mention selection resolves + delivers like a typed mention;
    /// an unresolved name rejects with the chooser still open.
    @MainActor
    @Test func mentionSelectionDeliversOrRejectsLikeTypedText() async {
        let store = ComposerRouterStore(
            dependencies: makeDependencies(levelDefaults: freshDefaults()))
        store.openChooser(for: .mention)
        let rejected = await store.runMentionSelection(
            ComposerMentionSelection(agentName: "ghost", message: "hi"))
        #expect(rejected == .rejected)
        #expect(store.activeChooser == .mention)

        let delivered = await store.runMentionSelection(
            ComposerMentionSelection(agentName: "ghost", message: "hi"))
        #expect(delivered == .rejected)
    }

    /// A shell selection routes to the scratch shell (never the agent
    /// prompt): an empty command is rejected with guidance, the
    /// chooser stays open; a real one is handled and clears it.
    @MainActor
    @Test func shellSelectionRoutesToTheScratchShell() async {
        let store = ComposerRouterStore(
            dependencies: makeDependencies(levelDefaults: freshDefaults()))
        store.openChooser(for: .bash)
        let rejected = await store.runShellSelection(
            ComposerShellSelection(command: ""))
        #expect(rejected == .rejected)
        #expect(store.activeChooser == .bash)
        #expect(store.routingError != nil)

        let handled = await store.runShellSelection(
            ComposerShellSelection(command: "ls"))
        #expect(handled == .handled)
        #expect(store.activeChooser == nil)
    }

    /// The tag chooser's catalog runs over the SAME live data the
    /// typed `#` menu filters, and a chosen tag applies the SAME
    /// structured TagFilter the typed path builds — client-side,
    /// never agent-bound.
    @MainActor
    @Test func tagCatalogAndApplyShareTheTypedParse() {
        let tags = Recorder<TagFilter>()
        let store = ComposerRouterStore(
            dependencies: makeDependencies(
                levelDefaults: freshDefaults(), tags: tags))
        let catalog = store.tagCatalog()
        #expect(catalog.contains { $0.insertion == "#status:blocked " })
        #expect(catalog.contains { $0.insertion == "#iOS App " })

        store.applyTagSuggestion(
            ComposerSuggestion(
                id: "tag:#status:blocked ", title: "blocked",
                detail: "status", insertion: "#status:blocked ",
                kind: .tag))
        #expect(tags.all == [TagFilter(field: .status, value: "blocked")])
    }

    /// The agent roster for the Mention chooser is the SAME list the
    /// typed `@` menu suggests.
    @MainActor
    @Test func agentRosterMirrorsTheTypedSuggestions() {
        let store = ComposerRouterStore(
            dependencies: makeDependencies(levelDefaults: freshDefaults()))
        #expect(store.agentRoster() == ["docs-review", "accessibility"])
    }
}

// MARK: - Send enablement keeps the shared predicate

@Suite("Composer send enablement")
struct ChatComposerSendEnablementTests {
    /// The v3 reshape keeps ONE sendability authority: nonempty text
    /// OR any held item (image, file, quote) sends; an image-only
    /// draft sends (structured images carry the content); only
    /// genuinely-empty is refused. The Send button and the submit
    /// guard both consult this.
    @Test func sendabilityFollowsTheSharedPredicate() {
        #expect(!ChatDraftComposer.isSendable(text: "", items: []))
        #expect(!ChatDraftComposer.isSendable(text: "   \n  ", items: []))
        #expect(ChatDraftComposer.isSendable(text: "hello", items: []))
        #expect(ChatDraftComposer.isSendable(text: "", items: [
            .image(id: "i1", remotePath: "img.png", previewData: nil),
        ]))
        #expect(ChatDraftComposer.isSendable(text: "", items: [
            .file(id: "f1", name: "notes.txt", remotePath: "notes.txt"),
        ]))
        #expect(ChatDraftComposer.isSendable(text: "", items: [
            .quote(id: "q1", text: "quoted", author: "Meadow"),
        ]))
        // An attachment-bearing message is a PROMPT by definition —
        // prefix classification is bypassed entirely.
        #expect(ChatDraftComposer.carriesAttachments(items: [
            .file(id: "f1", name: "a.sh", remotePath: "a.sh"),
        ]))
        #expect(!ChatDraftComposer.carriesAttachments(items: [
            .quote(id: "q1", text: "quoted", author: "Meadow"),
        ]))
    }

    /// The composed message preserves the MATCHED send contract
    /// byte-for-byte: quotes lead block-quoted (their draft carries
    /// the trailing blank paragraph), prose verbatim, files as
    /// @-references, images NEVER in the prose (they ride the
    /// structured array).
    @Test func composedMessageKeepsTheSendContract() {
        let items: [ChatDraftItem] = [
            .quote(id: "q1", text: "earlier line", author: "Meadow"),
            .image(id: "i1", remotePath: "shot.png", previewData: nil),
            .file(id: "f1", name: "spec.md", remotePath: "/tmp/spec.md"),
        ]
        let text = ChatDraftComposer.messageText(
            items: items, draft: "  look at this  ")
        #expect(text == """
            > earlier line


            look at this
            @/tmp/spec.md
            """)
    }
}
