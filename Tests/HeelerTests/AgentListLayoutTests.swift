import Foundation
import Testing

@testable import Heeler

@MainActor
@Suite("Agents list layout views")
struct AgentListLayoutTests {
    private func makeAgent(
        host: String = "devbox",
        session: String = "",
        workspace: String? = "heeler",
        tab: String? = nil,
        kind: String = "omp",
        title: String = "Task",
        name: String? = nil,
        paneID: String,
        status: AgentStatus = .idle,
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
            tabLabel: tab, tabPosition: 1, workspaceTabCount: 1,
            snapshotOrder: snapshotOrder)
    }

    // MARK: Ordering

    @Test func paneOrderUsesRealSnapshotOrderNotInputOrder() {
        let agents = [
            makeAgent(paneID: "late", snapshotOrder: 3),
            makeAgent(paneID: "early", snapshotOrder: 0),
            makeAgent(paneID: "mid", snapshotOrder: 2),
        ]
        let ordered = AgentListLayout.ordered(agents, by: .pane)
        #expect(ordered.map { (row: ConsoleAgent) in row.agent.paneID } == ["early", "mid", "late"])
    }

    @Test func recentOrderKeysOffWireStateChangeSeq() {
        let agents = [
            makeAgent(paneID: "stale", stateChangeSeq: 1),
            makeAgent(paneID: "fresh", stateChangeSeq: 9),
            makeAgent(paneID: "middle", stateChangeSeq: 4),
        ]
        let ordered = AgentListLayout.ordered(agents, by: .recent)
        #expect(ordered.map(\.agent.paneID) == ["fresh", "middle", "stale"])
    }

    @Test func attentionOrderIsNeedsYouThenWorkingThenIdleThenDone() {
        let agents = [
            makeAgent(paneID: "done", status: .done),
            makeAgent(paneID: "needs", status: .blocked),
            makeAgent(paneID: "idle", status: .idle),
            makeAgent(paneID: "working", status: .working),
        ]
        let ordered = AgentListLayout.ordered(agents, by: .attention)
        #expect(ordered.map(\.agent.paneID) == ["needs", "working", "idle", "done"])
    }

    @Test func titleOrderIsAlphabeticalStable() {
        let agents = [
            makeAgent(title: "beta", paneID: "b"),
            makeAgent(title: "Alpha", paneID: "a"),
            makeAgent(title: "beta", paneID: "c"),
        ]
        let ordered = AgentListLayout.ordered(agents, by: .title)
        #expect(ordered.map(\.agent.paneID) == ["a", "b", "c"])
    }

    // MARK: Grouping

    @Test func sameNameWorkspacesOnDifferentHostsNeverMerge() {
        let agents = [
            makeAgent(host: "alpha", workspace: "proj", paneID: "a1"),
            makeAgent(host: "beta", workspace: "proj", paneID: "b1"),
            makeAgent(host: "alpha", workspace: "proj", paneID: "a2"),
        ]
        let sections = AgentListLayout.grouped(agents, by: .workspace)
        #expect(sections.count == 2)
        #expect(sections[0].agents.map(\.agent.paneID) == ["a1", "a2"])
        #expect(sections[1].agents.map(\.agent.paneID) == ["b1"])
        #expect(sections.map(\.title) == ["proj", "proj"])
    }

    @Test func sameNameSessionsOnDifferentHostsStayScoped() {
        let agents = [
            makeAgent(host: "alpha", session: "main", paneID: "a1"),
            makeAgent(host: "beta", session: "main", paneID: "b1"),
        ]
        let sections = AgentListLayout.grouped(agents, by: .session)
        #expect(sections.count == 2)
    }

    @Test func stateGroupingUsesUrgencyLadder() {
        let agents = [
            makeAgent(paneID: "done", status: .done),
            makeAgent(paneID: "needs", status: .blocked),
            makeAgent(paneID: "working", status: .working),
        ]
        let sections = AgentListLayout.grouped(agents, by: .state)
        #expect(sections.map { (section: AgentListSection) in section.title } == ["Needs you", "Working", "Done"])
        #expect(sections.map { (section: AgentListSection) in section.count } == [1, 1, 1])
    }

    @Test func groupCountsReflectOnlyTheirMatchingMembers() {
        let agents = [
            makeAgent(host: "alpha", paneID: "a1"),
            makeAgent(host: "alpha", paneID: "a2"),
            makeAgent(host: "beta", paneID: "b1"),
        ]
        let sections = AgentListLayout.grouped(agents, by: .host)
        let alpha = sections.first { $0.title == "alpha" }
        #expect(alpha?.count == 2)
        #expect(sections.reduce(0, { $0 + $1.count }) == 3)
    }

    @Test func flatGroupingProducesNoSections() {
        let agents = [makeAgent(paneID: "a")]
        #expect(AgentListLayout.grouped(agents, by: .none).isEmpty)
    }

    // MARK: Persistence

    @Test func storePersistsChoicesAndCollapsedGroups() throws {
        let suite = "agent-list-layout-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = AgentListLayoutStore(defaults: defaults)
        #expect(store.order == .recent && store.grouping == .none)
        store.select(order: .title)
        store.select(grouping: .host)
        store.toggleCollapsed("g:host/alpha")
        let rehydrated = AgentListLayoutStore(defaults: defaults)
        #expect(rehydrated.order == .title)
        #expect(rehydrated.grouping == .host)
        #expect(rehydrated.isCollapsed("g:host/alpha"))
        rehydrated.reset()
        #expect(rehydrated.order == .recent && rehydrated.grouping == .none)
        #expect(!rehydrated.isCollapsed("g:host/alpha"))
    }
}

@Suite("Agent kind badge")
struct AgentKindBadgeTests {
    @Test func kindComesFromSnapshotFieldWithHumanNames() {
        let claude = AgentKindBadgeModel(kind: "claude")
        #expect(claude.accessibilityLabel == "Claude Code")
        #expect(claude.isRecognized)
        let omp = AgentKindBadgeModel(kind: "omp")
        #expect(omp.accessibilityLabel == "OMP")
        #expect(omp.systemImage == "infinity")
    }

    @Test func unrecognizedKindGetsNeutralFallbackAndRawName() {
        let unknown = AgentKindBadgeModel(kind: "some-new-runtime")
        #expect(!unknown.isRecognized)
        #expect(unknown.systemImage == AgentKindBadgeModel.fallbackSystemImage)
        // The raw runtime kind stays the label — never a guessed value.
        #expect(unknown.accessibilityLabel == "some-new-runtime")
    }

    @Test func kindResolutionNeverInfersFromTitle() {
        // A codex-titled agent whose runtime kind is omp badges as omp.
        let agent = ConsoleAgent(
            hostID: UUID(), hostName: "devbox",
            agent: Agent(
                terminalID: "t", kind: "omp", title: "Run codex workflow", status: .idle,
                workspaceID: "w", tabID: "w:t", paneID: "p", cwd: "/w", revision: 1),
            workspaceLabel: nil, repositoryCheckout: nil)
        let badge = AgentKindBadgeModel(agent: agent)
        #expect(badge.accessibilityLabel == "OMP")
    }

    @Test func distinctKindsGetDistinctSymbols() {
        let symbols = Set(
            ["omp", "claude", "codex", "gemini", "cursor", "devin", "cline", "kimi", "droid", "grok"]
                .map { AgentKindBadgeModel(kind: $0).systemImage })
        #expect(symbols.count > 1)
    }
}
