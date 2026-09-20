import Foundation
import SwiftUI
import Testing

@testable import Heeler

@MainActor
@Suite("Agents list layout views")
struct AgentListLayoutTests {
    /// Deterministic UUID per host name (uuid5-style: fixed name UUIDs
    /// are not in Foundation; a memoized dict works for the test).
    private static var hostIDs: [String: UUID] = [:]
    @MainActor
    private static func hostID(named name: String) -> UUID {
        if let existing = hostIDs[name] { return existing }
        let id = UUID()
        hostIDs[name] = id
        return id
    }

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
            // One stable Host identity per host NAME: agents on the same
            // machine share the hostID, exactly as the wire reports.
            hostID: Self.hostID(named: host), hostName: host,
            agent: Agent(
                terminalID: "term_\(paneID)", kind: kind, title: title, status: status,
                workspaceID: "w-\(host)-\(workspace ?? "x")",
                tabID: "w-\(host)-\(workspace ?? "x"):t1", paneID: paneID,
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

    @Test func sameNameDifferentIDWorkspacesNeverMerge() {
        // Review finding #8: group identity is the stable IDs (hostID,
        // session, workspaceID), not display names — two same-LABEL
        // workspaces with different workspaceIDs are two groups even on
        // the same host.
        let host = Host.fixture(name: "alpha")
        let a = ConsoleAgent(
            hostID: host.id, hostName: "alpha",
            agent: Agent(terminalID: "t1", kind: "omp", title: "A", status: .idle,
                workspaceID: "w-1", tabID: "w-1:t", paneID: "p1", cwd: "/", revision: 1),
            workspaceLabel: "proj", repositoryCheckout: nil,
            snapshotOrder: 0)
        let b = ConsoleAgent(
            hostID: host.id, hostName: "alpha",
            agent: Agent(terminalID: "t2", kind: "omp", title: "B", status: .idle,
                workspaceID: "w-2", tabID: "w-2:t", paneID: "p2", cwd: "/", revision: 1),
            workspaceLabel: "proj", repositoryCheckout: nil,
            snapshotOrder: 1)
        let sections = AgentListLayout.grouped([a, b], by: .workspace)
        #expect(sections.count == 2)
        #expect(sections.map(\.agents.count) == [1, 1])
    }

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
    }

    @Test func unrecognizedKindGetsNeutralFallbackAndRawName() {
        let unknown = AgentKindBadgeModel(kind: "some-new-runtime")
        #expect(!unknown.isRecognized)
        #expect(unknown.glyph == nil)
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

    @Test func coreRuntimesRenderTheApprovedPrototypeGlyphs() {
        // The user-approved prototype marks, ported 1:1: omp → π,
        // codex → angle brackets, claude → sunburst.
        #expect(AgentKindBadgeModel(kind: "omp").glyph == .pi)
        #expect(AgentKindBadgeModel(kind: "pi").glyph == .pi)
        #expect(AgentKindBadgeModel(kind: "codex").glyph == .brackets)
        #expect(AgentKindBadgeModel(kind: "claude").glyph == .sunburst)
        // Review finding #7: the approved marks scope to the runtimes the
        // design drew them for — opencode/copilot get distinct neutral
        // symbols, not the core glyphs.
        #expect(AgentKindBadgeModel(kind: "opencode").glyph == nil)
        #expect(AgentKindBadgeModel(kind: "copilot").glyph == nil)
        #expect(AgentKindBadgeModel(kind: "opencode").systemImage != AgentKindBadgeModel(kind: "omp").systemImage)
        // Long-tail kinds keep the symbol set, no glyph.
        #expect(AgentKindBadgeModel(kind: "gemini").glyph == nil)
        #expect(AgentKindBadgeModel(kind: "gemini").systemImage == "sparkles")
    }

    @Test func approvedGlyphGeometryMatchesThePrototype() {
        // The π mark: bar + left leg + curved right leg, in 24×24 space.
        let pi = AgentKindGlyphShape(glyph: .pi).path(
            in: CGRect(x: 0, y: 0, width: 24, height: 24))
        // Path.Element.line carries only its end point (the start is the
        // subpath's current point); collect the drawing sequence in order.
        var sequence: [Path.Element] = []
        pi.forEach { sequence.append($0) }
        // The π: move(5,7) → line(19,7) [the bar], move(9,7) → line(9,17)
        // [the left leg] — the prototype's exact geometry.
        #expect(sequence.count >= 4)
        if case .move(to: let first) = sequence[0] {
            #expect(first == CGPoint(x: 5, y: 7))
        } else {
            Issue.record("π must begin its bar at (5,7)")
        }
        if case .line(to: let bar) = sequence[1] {
            #expect(bar == CGPoint(x: 19, y: 7))
        } else {
            Issue.record("π's bar must end at (19,7)")
        }
        if case .move(to: let legStart) = sequence[2] {
            #expect(legStart == CGPoint(x: 9, y: 7))
        } else {
            Issue.record("π's left leg must start at (9,7)")
        }
        if case .line(to: let leg) = sequence[3] {
            #expect(leg == CGPoint(x: 9, y: 17))
        } else {
            Issue.record("π's left leg must end at (9,17)")
        }
    }

    @Test func distinctKindsGetDistinctPresentation() {
        let presents = ["omp", "claude", "codex", "gemini", "cursor", "devin", "cline", "kimi", "droid", "grok"]
            .map { kind in
                let model = AgentKindBadgeModel(kind: kind)
                return "\(model.glyph.map(String.init(describing:)) ?? model.systemImage)"
            }
        #expect(Set(presents).count > 3)
    }
}
