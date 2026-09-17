import Foundation
import Testing

@testable import Heeler

// SPDX-License-Identifier: Apache-2.0

/// The hierarchical Agents list: tree building (grouping, ordering, nil
/// labels, single-agent groups), fold persistence, and aggregate-state
/// urgency.
@Suite("Agent tree")
struct AgentTreeTests {
    private func makeDefaults() throws -> (UserDefaults, cleanup: () -> Void) {
        let suiteName = "hm-agent-tree-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        return (defaults, { defaults.removePersistentDomain(forName: suiteName) })
    }

    private func agent(
        host: Host,
        paneID: String,
        status: AgentStatus,
        session: String = "",
        workspace: String? = nil,
        tab: String? = nil
    ) -> ConsoleAgent {
        ConsoleAgent(
            hostID: host.id,
            hostName: host.displayName,
            agent: Agent(
                terminalID: "term_\(paneID)", kind: "claude", title: "Task",
                status: status, workspaceID: "w", tabID: "t", paneID: paneID,
                cwd: "/work", revision: 1),
            workspaceLabel: workspace,
            repositoryCheckout: nil,
            hostSessionName: session,
            tabLabel: tab)
    }

    private func makeHost(_ name: String) -> Host {
        Host(name: name, address: "example", username: "user")
    }

    private func groupLabels(_ rows: [AgentTreeRow]) -> [String] {
        rows.compactMap {
            if case .group(_, let label, _, _, _, _) = $0 { return label }
            return nil
        }
    }

    private func depths(_ rows: [AgentTreeRow]) -> [Int] {
        rows.map {
            switch $0 {
            case .group(_, _, let depth, _, _, _): depth
            case .agent(_, let depth): depth
            }
        }
    }

    // MARK: Tree building

    @Test func buildsFullHierarchyWithIndentDepths() {
        let hostA = makeHost("alpha")
        let hostB = makeHost("zeta")
        let agents = [
            agent(host: hostA, paneID: "a1", status: .idle, session: "work",
                  workspace: "engine", tab: "1"),
            agent(host: hostB, paneID: "b1", status: .idle, session: "work",
                  workspace: "engine", tab: "1"),
        ]

        let rows = AgentTree.rows(agents: agents, foldedIDs: [])
        #expect(groupLabels(rows) == ["alpha", "work", "engine", "1", "zeta", "work", "engine", "1"])
        #expect(depths(rows) == [0, 1, 2, 3, 4, 0, 1, 2, 3, 4])
    }
    @Test func groupsSortAlphabeticallyWhileLeavesKeepSuppliedOrder() {
        let host = makeHost("box")
        let agents = [
            agent(host: host, paneID: "z", status: .idle, workspace: "beta", tab: "2"),
            agent(host: host, paneID: "y", status: .working, workspace: "beta", tab: "1"),
            agent(host: host, paneID: "x", status: .idle, workspace: "alpha", tab: "1"),
            agent(host: host, paneID: "w", status: .blocked, workspace: "beta", tab: "1"),
        ]

        let rows = AgentTree.rows(agents: agents, foldedIDs: [])
        // Workspaces alpha < beta; beta's tabs 1 < 2. The session row
        // ("default") sits between Host and workspaces.
        #expect(groupLabels(rows) == ["box", "default", "alpha", "1", "beta", "1", "2"])
        // alpha's leaf (x) precedes beta's cluster; within beta's tab 1 the
        // supplied order (y then w) survives — the Console sort owns it —
        // and beta's tab 2 keeps z after them.
        let leaves = rows.compactMap(\.agent).map(\.agent.paneID)
        #expect(leaves == ["x", "y", "w", "z"])
    }

    @Test func emptySessionGroupsAsDefault() {
        let host = makeHost("box")
        let agents = [
            agent(host: host, paneID: "a", status: .idle, session: "named"),
            agent(host: host, paneID: "b", status: .idle, session: ""),
            agent(host: host, paneID: "c", status: .idle, session: "  "),
        ]

        let rows = AgentTree.rows(agents: agents, foldedIDs: [])
        // Sessions sort alphabetically; blank names collapse into "default",
        // which sorts before "named". Each session's label-less agents take
        // their own Other workspace/tab rows.
        #expect(groupLabels(rows) == [
            "box", "default", "Other", "Other", "named", "Other", "Other"])
        let defaultCount = rows.first {
            if case .group(_, "default", _, let count, _, _) = $0 { return count == 2 }
            return false
        }
        #expect(defaultCount != nil)
    }

    @Test func nilWorkspaceAndTabLabelsGroupUnderOther() {
        let host = makeHost("box")
        let agents = [
            agent(host: host, paneID: "a", status: .idle, workspace: nil, tab: nil),
            agent(host: host, paneID: "b", status: .idle, workspace: "", tab: ""),
            agent(host: host, paneID: "c", status: .idle, workspace: "real", tab: "1"),
        ]

        let rows = AgentTree.rows(agents: agents, foldedIDs: [])
        #expect(groupLabels(rows) == ["box", "default", "Other", "Other", "real", "1"])
        // Both Other levels fold the two label-less agents at the workspace
        // level (depth 2); the tab-level Other (depth 3) carries them.
        let otherDepths = rows.compactMap { row -> Int? in
            if case .group(_, "Other", let depth, _, _, _) = row { return depth }
            return nil
        }
        #expect(otherDepths == [2, 3])
    }

    @Test func singleAgentGroupsRemainFoldable() {
        let host = makeHost("box")
        let agents = [agent(host: host, paneID: "only", status: .idle)]

        let rows = AgentTree.rows(agents: agents, foldedIDs: [])
        #expect(groupLabels(rows) == ["box", "default", "Other", "Other"])
        // Every group row is present with count 1 — folding never collapses
        // a single-member group away.
        let counts = rows.compactMap { row -> Int? in
            if case .group(_, _, _, let count, _, _) = row { return count }
            return nil
        }
        #expect(counts == [1, 1, 1, 1])
    }

    @Test func emptyHostsStayVisibleAsFoldableStubs() {
        let host = makeHost("empty")
        let rows = AgentTree.rows(
            agents: [], foldedIDs: [],
            emptyHosts: [(host.id, host.displayName)])
        #expect(groupLabels(rows) == ["empty"])
        guard case .group(let id, "empty", 0, 0, let aggregate, false)? = rows.first else {
            Issue.record("expected an expanded depth-0 stub")
            return
        }
        // The stub's id is the minted Host group id, so its fold state is
        // shared with the same Host's populated tree.
        #expect(AgentTree.hostID(ofGroupID: id) == host.id)
        #expect(aggregate == .unknown)
    }

    // MARK: Folding

    @Test func foldingHidesSubtreeButKeepsCountsAndAggregate() {
        let host = makeHost("box")
        let agents = [
            agent(host: host, paneID: "a", status: .blocked, workspace: "engine", tab: "1"),
            agent(host: host, paneID: "b", status: .working, workspace: "engine", tab: "1"),
        ]

        // Unfolded: host, session, workspace, tab, two agents.
        let unfolded = AgentTree.rows(agents: agents, foldedIDs: [])
        #expect(unfolded.count == 6)
        guard case .group(let engineID, "engine", 2, 2, .blocked, false)? =
            unfolded.first(where: { row in
                if case .group(_, "engine", _, _, _, _) = row { return true }
                return false
            })
        else {
            Issue.record("engine workspace group missing")
            return
        }

        // Folded: the workspace row stays with its count and aggregate; the
        // tab row and both leaves disappear.
        let folded = AgentTree.rows(agents: agents, foldedIDs: [engineID])
        #expect(folded.count == 3)
        guard case .group(engineID, "engine", 2, 2, .blocked, true)? =
            folded.first(where: { $0.id == engineID })
        else {
            Issue.record("folded workspace row malformed")
            return
        }
        #expect(!folded.contains { $0.agent?.agent.paneID == "a" })
        #expect(!folded.contains { $0.agent?.agent.paneID == "b" })
    }

    @Test func foldingTheHostHidesEverythingBelowIt() {
        let host = makeHost("box")
        let agents = [
            agent(host: host, paneID: "a", status: .idle),
            agent(host: host, paneID: "b", status: .idle),
        ]
        let unfolded = AgentTree.rows(agents: agents, foldedIDs: [])
        guard case .group(let hostID, "box", 0, 2, _, false)? = unfolded.first else {
            Issue.record("host group missing")
            return
        }
        let folded = AgentTree.rows(agents: agents, foldedIDs: [hostID])
        #expect(folded.count == 1)
        guard case .group(hostID, "box", 0, 2, .idle, true)? = folded.first else {
            Issue.record("folded host row malformed")
            return
        }
    }

    // MARK: Aggregate urgency

    @Test func aggregateUrgencyOrderBlockedWorkingIdleDone() {
        let host = makeHost("box")
        func aggregate(_ statuses: [AgentStatus]) -> AgentStatus {
            AgentTree.aggregateState(
                of: statuses.map { agent(host: host, paneID: $0.rawValue, status: $0) })
        }
        #expect(aggregate([.done, .idle, .working, .blocked]) == .blocked)
        #expect(aggregate([.done, .idle, .working]) == .working)
        #expect(aggregate([.done, .idle]) == .idle)
        #expect(aggregate([.done]) == .done)
        #expect(aggregate([]) == .unknown)
        // An unreadable status never outranks one this build can interpret.
        #expect(aggregate([.unknown, .idle]) == .idle)
    }

    @Test func aggregateBleedsThroughToAncestorGroupRows() {
        let host = makeHost("box")
        let agents = [
            agent(host: host, paneID: "a", status: .idle, workspace: "engine", tab: "1"),
            agent(host: host, paneID: "b", status: .blocked, workspace: "engine", tab: "1"),
        ]
        let rows = AgentTree.rows(agents: agents, foldedIDs: [])
        // The deepest group (tab) and every ancestor carry Blocked.
        let groupAggregates = rows.compactMap { row -> AgentStatus? in
            if case .group(_, _, _, _, let aggregate, _) = row { return aggregate }
            return nil
        }
        #expect(groupAggregates == [.blocked, .blocked, .blocked, .blocked])
    }

    // MARK: Fold persistence

    @MainActor
    @Test func foldDefaultsExpandedAndPersistsAcrossLaunches() throws {
        let (defaults, cleanup) = try makeDefaults()
        defer { cleanup() }

        let store = AgentTreeFoldStore(defaults: defaults)
        #expect(store.foldedIDs.isEmpty)

        let id = "h/abc/s/work"
        store.toggle(id)
        #expect(store.isFolded(id))
        #expect(!store.isFolded("h/other"))

        // A fresh store (next launch) restores the fold.
        let reopened = AgentTreeFoldStore(defaults: defaults)
        #expect(reopened.isFolded(id))
        #expect(!reopened.isFolded("h/other"))

        reopened.toggle(id)
        #expect(!reopened.isFolded(id))
        #expect(AgentTreeFoldStore(defaults: defaults).foldedIDs.isEmpty)
    }
}
