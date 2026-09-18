import Foundation
import Testing

@testable import Heeler

// SPDX-License-Identifier: Apache-2.0

/// The hierarchical Agents list: collapsed-chain tree building (grouping,
/// ordering, single-child merges, label drops), fold persistence, and
/// aggregate-state urgency.
@MainActor
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
        tab: String? = nil,
        workspaceTabCount: Int = 0,
        tabPosition: Int? = nil,
        kind: String = "claude",
        name: String? = nil,
        snapshotOrder: Int? = nil,
        paneOrder: Int? = nil
    ) -> ConsoleAgent {
        ConsoleAgent(
            hostID: host.id,
            hostName: host.displayName,
            agent: Agent(
                terminalID: "term_\(paneID)", kind: kind, title: "Task",
                status: status, workspaceID: "w", tabID: "t", paneID: paneID,
                cwd: "/work", revision: 1, name: name),
            workspaceLabel: workspace,
            repositoryCheckout: nil,
            hostSessionName: session,
            tabLabel: tab,
            tabPosition: tabPosition,
            workspaceTabCount: workspaceTabCount,
            snapshotOrder: snapshotOrder,
            paneOrder: paneOrder)
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
            case .agent(_, let depth, _): depth
            }
        }
    }

    // MARK: Collapsed-chain tree building

    /// One Host with one session, one workspace, and multiple single-Agent
    /// tabs: the host → session → workspace chain collapses into a single
    /// depth-0 merged row, and each tab merges into its Agent's row.
    @Test func singleChainToWorkspaceMergesAndSingleAgentTabsMergeIntoAgentRows() {
        let host = makeHost("Mac")
        let agents = [
            agent(host: host, paneID: "p1", status: .idle, session: "",
                  workspace: "herdr", tab: "Herdr",
                  workspaceTabCount: 3, tabPosition: 1),
            agent(host: host, paneID: "p2", status: .working, session: "",
                  workspace: "herdr", tab: "bridge",
                  workspaceTabCount: 3, tabPosition: 2),
            agent(host: host, paneID: "p3", status: .blocked, session: "",
                  workspace: "herdr", tab: "kitty",
                  workspaceTabCount: 3, tabPosition: 3),
        ]

        let rows = AgentTree.rows(agents: agents, foldedIDs: [])
        // "Mac · default · herdr" merged row (depth 0), then each tab's
        // single Agent as its own row (depth 1) carrying the tab label —
        // no tab group rows remain.
        #expect(groupLabels(rows) == ["Mac · default · herdr"])
        #expect(depths(rows) == [0, 1, 1, 1])
        let leaves = rows.compactMap { row -> (paneID: String, tabLabel: String)? in
            guard let agent = row.agent else { return nil }
            return (agent.agent.paneID, row.tabLabel ?? "")
        }
        #expect(leaves.map(\.paneID) == ["p1", "p2", "p3"])
        #expect(leaves.map(\.tabLabel) == ["Herdr", "bridge", "kitty"])
    }

    /// A tab holding multiple Agents keeps its foldable group row; only
    /// single-Agent tabs merge into their Agent's row.
    @Test func multiAgentTabStaysAFoldableGroupRow() {
        let host = makeHost("Mac")
        let agents = [
            agent(host: host, paneID: "p1", status: .idle, session: "",
                  workspace: "herdr", tab: "bridge",
                  workspaceTabCount: 2, tabPosition: 1),
            agent(host: host, paneID: "p2", status: .blocked, session: "",
                  workspace: "herdr", tab: "bridge",
                  workspaceTabCount: 2, tabPosition: 1),
            agent(host: host, paneID: "p3", status: .working, session: "",
                  workspace: "herdr", tab: "kitty",
                  workspaceTabCount: 2, tabPosition: 2),
        ]

        let rows = AgentTree.rows(agents: agents, foldedIDs: [])
        // "bridge" holds two Agents, so it stays a group row; "kitty"
        // holds one and merges into its Agent's row.
        #expect(groupLabels(rows) == ["Mac · default · herdr", "bridge"])
        #expect(depths(rows) == [0, 1, 2, 2, 1])
        let leaves = rows.compactMap { row -> (paneID: String, tabLabel: String)? in
            guard let agent = row.agent else { return nil }
            return (agent.agent.paneID, row.tabLabel ?? "")
        }
        #expect(leaves.map(\.paneID) == ["p1", "p2", "p3"])
        // The multi-Agent tab's leaves carry no tab label (the group row
        // shows it); kitty's merged leaf carries its label.
        #expect(leaves.map(\.tabLabel) == ["", "", "kitty"])

        // Folding "bridge" hides its two leaves and nothing else.
        guard case .group(let bridgeID, "bridge", _, _, _, _)? = rows.last(
            where: { row in
                if case .group(_, "bridge", _, _, _, _) = row { return true }
                return false
            })
        else {
            Issue.record("bridge group row missing")
            return
        }
        let folded = AgentTree.rows(agents: agents, foldedIDs: [bridgeID])
        #expect(folded.compactMap(\.agent).map(\.agent.paneID) == ["p3"])
    }

    /// The full chain — one session, one workspace, one single-Agent tab —
    /// collapses into a merged group row plus the Agent's own row (which
    /// absorbs the tab row), keeping the chain head's id (the bare Host
    /// id), so the fold survives the chain later gaining a sibling and
    /// the view's host lookup still resolves.
    @Test func fullSingleChainCollapsesToOneMergedRow() {
        let host = makeHost("box")
        let agent = agent(
            host: host, paneID: "only", status: .idle,
            workspace: "engine", tab: "1")
        let rows = AgentTree.rows(agents: [agent], foldedIDs: [])
        #expect(groupLabels(rows) == ["box · default · engine"])
        // The leaf absorbed the tab row and carries its label.
        #expect(rows.compactMap { row -> String? in
            guard row.agent != nil else { return nil }
            return row.tabLabel ?? ""
        } == ["1"])

        guard case .group(let id, _, 0, 1, .idle, false)? = rows.first else {
            Issue.record("merged chain row missing")
            return
        }
        // The head id is the bare Host id — the same id the empty-host
        // stub mints — so the fold is shared across every shape.
        let stub = AgentTree.rows(
            agents: [], foldedIDs: [], emptyHosts: [(host.id, "box")])
        #expect(id == stub.first?.id)
        #expect(AgentTree.hostID(ofGroupID: id) == host.id)
    }

    /// A level with multiple children is never swallowed by the merge,
    /// and a workspace whose whole subtree is one Agent now absorbs into
    /// that Agent's row — the same rule the tab level always had, so the
    /// one-Agent-workspace shape renders identically on every Host.
    @Test func multiChildLevelsBlockTheMerge() {
        let host = makeHost("box")
        let agents = [
            agent(host: host, paneID: "a", status: .idle, workspace: "alpha", tab: "1",
                  workspaceTabCount: 1, tabPosition: 1),
            agent(host: host, paneID: "b", status: .idle, workspace: "beta", tab: "1",
                  workspaceTabCount: 1, tabPosition: 1),
        ]
        let rows = AgentTree.rows(agents: agents, foldedIDs: [])
        // The host row merges only with "default" (single session); the
        // two workspaces stop the chain. Each workspace holds exactly
        // one Agent, so each absorbs into its Agent's depth-1 row —
        // no workspace group rows remain.
        #expect(groupLabels(rows) == ["box · default"])
        #expect(depths(rows) == [0, 1, 1])
        // The automatic tab label (position) still rides nothing:
        // both leaves carry no tab label.
        #expect(rows.compactMap(\.tabLabel).isEmpty)
    }

    /// Two sessions under one Host also stop the merge at the Host row.
    @Test func multipleSessionsStopTheMergeAtHost() {
        let host = makeHost("box")
        let agents = [
            agent(host: host, paneID: "a", status: .idle, session: "work",
                  workspace: "engine", tab: "1"),
            agent(host: host, paneID: "b", status: .idle, session: "labs",
                  workspace: "engine", tab: "1"),
        ]
        let rows = AgentTree.rows(agents: agents, foldedIDs: [])
        // Each session's single workspace merges into the session row;
        // the single-Agent tab absorbs into the Agent's row.
        #expect(groupLabels(rows) == ["box", "labs · engine", "work · engine"])
        #expect(depths(rows) == [0, 1, 2, 1, 2])
    }

    /// herdr's automatic tab label (the position, not a user name) is
    /// plumbing the Agent card already hides, so it neither joins a
    /// merged group label nor rides the Agent row. A named tab rides the
    /// Agent's row when the layout does not already render it.
    @Test func automaticTabLabelDropsFromMergedRows() {
        let host = makeHost("box")
        let autoTab = agent(
            host: host, paneID: "a", status: .idle,
            workspace: "engine", tab: "1",
            workspaceTabCount: 1, tabPosition: 1)
        let namedTab = agent(
            host: host, paneID: "b", status: .idle,
            workspace: "engine", tab: "bridge",
            workspaceTabCount: 1, tabPosition: 1)

        let autoRows = AgentTree.rows(agents: [autoTab], foldedIDs: [])
        #expect(groupLabels(autoRows) == ["box · default · engine"])
        #expect(autoRows.compactMap { row -> String? in
            guard row.agent != nil else { return nil }
            return row.tabLabel ?? ""
        } == [""])

        let namedRows = AgentTree.rows(agents: [namedTab], foldedIDs: [])
        #expect(groupLabels(namedRows) == ["box · default · engine"])
        #expect(namedRows.compactMap { row -> String? in
            guard row.agent != nil else { return nil }
            return row.tabLabel ?? ""
        } == ["bridge"])
    }

    /// A label this build synthesized (`Other`) names nothing the row
    /// below doesn't, so it drops from merged labels: two label-less
    /// Agents under the default session collapse to one "box · default"
    /// row with both Agents directly beneath it.
    @Test func otherPlaceholderDropsFromMergedLabels() {
        let host = makeHost("box")
        let agents = [
            agent(host: host, paneID: "a", status: .idle, workspace: nil, tab: nil),
            agent(host: host, paneID: "b", status: .idle, workspace: nil, tab: nil),
        ]
        let rows = AgentTree.rows(agents: agents, foldedIDs: [])
        #expect(groupLabels(rows) == ["box · default"])
        #expect(depths(rows) == [0, 1, 1])
        #expect(rows.compactMap { row -> String? in
            guard row.agent != nil else { return nil }
            return row.tabLabel ?? ""
        } == ["", ""])
    }

    /// Sessions sort alphabetically; the default session's label stays in
    /// merged rows when it must distinguish real sessions.
    @Test func defaultSessionLabelSurvivesWhenDistinguishing() {
        let host = makeHost("box")
        let agents = [
            agent(host: host, paneID: "a", status: .idle, session: "named",
                  workspace: "engine", tab: "1"),
            agent(host: host, paneID: "b", status: .idle, session: "",
                  workspace: "engine", tab: "1"),
        ]
        let rows = AgentTree.rows(agents: agents, foldedIDs: [])
        // Two sessions stop the merge at the Host row; each session then
        // merges its single workspace, and the single-Agent tab absorbs
        // into the Agent's row. "default" < "named" orders the sessions.
        #expect(groupLabels(rows) == [
            "box", "default · engine", "named · engine"])
        #expect(depths(rows) == [0, 1, 2, 1, 2])
    }

    /// Below a Host, groups and leaves keep the herdr window's pane
    /// order — the snapshot enumerates workspaces, tabs, and panes the
    /// way the user arranged them — not alphabetical label order. The
    /// user reads the herdr panes left-to-right as canonical; the tree
    /// follows it. Agents without snapshot order (legacy/test shapes)
    /// keep the supplied sequence.
    @Test func groupsKeepTheHerdWindowPaneOrderNotAlphabetical() {
        let host = makeHost("box")
        let agents = [
            agent(host: host, paneID: "z", status: .idle, workspace: "beta", tab: "2",
                  snapshotOrder: 3),
            agent(host: host, paneID: "y", status: .working, workspace: "beta", tab: "1",
                  snapshotOrder: 1),
            agent(host: host, paneID: "x", status: .idle, workspace: "alpha", tab: "1",
                  snapshotOrder: 2),
            agent(host: host, paneID: "w", status: .blocked, workspace: "beta", tab: "1",
                  snapshotOrder: 0),
        ]

        let rows = AgentTree.rows(agents: agents, foldedIDs: [])
        // The host row merges with "default" only; the workspaces keep
        // window order (beta first — w's pane came first in the snapshot)
        // instead of alphabetical (alpha < beta). beta's tab "1" holds
        // two Agents and keeps its group row; beta's single-Agent tab
        // "2" and alpha's single-Agent workspace absorb into their
        // Agent's rows.
        #expect(groupLabels(rows) == ["box · default", "beta", "1"])
        // Merged depth-0 row; beta (depth 1); beta's tab "1" group row
        // (depth 2) with its leaves (depth 3) in pane order — w's pane
        // preceded y's, so w leads; beta's tab "2" leaf replaces its tab
        // row at depth 2; alpha's absorbed leaf replaces its workspace
        // row at depth 1.
        #expect(depths(rows) == [0, 1, 2, 3, 3, 2, 1])
        let leaves: [(paneID: String, tabLabel: String?)] = rows.compactMap { row in
            guard let agent = row.agent else { return nil }
            return (paneID: agent.agent.paneID, tabLabel: row.tabLabel)
        }
        #expect(leaves.map(\.paneID) == ["w", "y", "z", "x"])
        // The single-Agent tab's leaf carries its tab label ("2"); the
        // absorbed alpha workspace's leaf carries its named tab ("1").
        // beta's two-Agent tab names itself in its group row.
        #expect(leaves.map(\.tabLabel) == [nil, nil, "2", "1"])
    }

    /// Leaves within one tab follow the pane's reading position — rows
    /// top-to-bottom, then left-to-right — exactly the way the herdr
    /// window lays its panes out. The snapshot's collection order follows
    /// pane CREATION order, which diverges once the user splits: p7
    /// (created first, bottom-left) must render after p1 (created later,
    /// top-left). This pins the bug where the tree showed agents in
    /// snapshot/creation order instead of window order.
    @Test func leavesFollowPaneGeometryNotSnapshotOrderWithinATab() {
        let host = makeHost("devbox")
        let agents = [
            agent(host: host, paneID: "wA:p7", status: .done, workspace: "SS",
                  tab: "Dynamic States", workspaceTabCount: 2, tabPosition: 1,
                  snapshotOrder: 0, paneOrder: 1),
            agent(host: host, paneID: "wA:p1", status: .idle, workspace: "SS",
                  tab: "Dynamic States", workspaceTabCount: 2, tabPosition: 1,
                  snapshotOrder: 1, paneOrder: 0),
        ]

        let rows = AgentTree.rows(agents: agents, foldedIDs: [])
        // Both agents share the session, workspace, and tab, so the tree
        // is the merged host row plus the tab's two leaves — and p1 (the
        // top-left pane) precedes p7 (bottom-left) despite p7 coming
        // first in the snapshot's agent collection.
        #expect(groupLabels(rows) == ["devbox · default · SS · Dynamic States"])
        #expect(
            rows.compactMap(\.agent).map(\.agent.paneID) == ["wA:p1", "wA:p7"])
    }

    /// The real devbox shape (captured from `herdr api snapshot` on
    /// jhou-pc): one default session, four workspaces — "SS" and
    /// "Review" holding multiple one-agent tabs, "Omarchy" and "Inbox"
    /// holding exactly one agent each. The single-agent workspaces
    /// rendered as separate group rows over one leaf (the reported
    /// "chain collapse not engaging on the devbox host"), while the Mac
    /// host — whose workspaces all hold multiple tabs — collapsed fine.
    /// The absorption of a single-visible-leaf chain must apply at any
    /// grouping level, so identical shapes collapse identically
    /// regardless of host.
    @Test func devboxSingleAgentWorkspacesCollapseLikeSingleAgentTabs() {
        let host = makeHost("jhou-pc")
        let agents = [
            // wA "SS": five one-agent tabs; two suffice to prove the
            // multi-tab workspace keeps its group row and its tabs
            // absorb into their Agent rows in window order.
            agent(host: host, paneID: "wA:p7", status: .done, workspace: "SS",
                  tab: "Dynamic States", workspaceTabCount: 5, tabPosition: 1,
                  snapshotOrder: 0),
            agent(host: host, paneID: "wA:pM", status: .idle, workspace: "SS",
                  tab: "Eval error", workspaceTabCount: 5, tabPosition: 2,
                  snapshotOrder: 1),
            // wD "Omarchy": exactly one agent — the no-collapse shape.
            agent(host: host, paneID: "wD:pA", status: .idle, workspace: "Omarchy",
                  tab: "Omaice", workspaceTabCount: 1, tabPosition: 1,
                  snapshotOrder: 7),
            // wE "Inbox": exactly one agent — same shape again.
            agent(host: host, paneID: "wE:p1", status: .idle, workspace: "Inbox",
                  tab: "Inbox", workspaceTabCount: 1, tabPosition: 1,
                  snapshotOrder: 8),
        ]
        let rows = AgentTree.rows(agents: agents, foldedIDs: [])
        // Depth-0 merged host row ("default" session), then the three
        // workspaces in window order: SS keeps its group row (multiple
        // tabs), while Omarchy and Inbox — one visible leaf each —
        // absorb into their Agent's rows at workspace depth, exactly
        // like a one-agent tab always has. No group row may stand over
        // a single leaf.
        #expect(groupLabels(rows) == ["jhou-pc · default", "SS"])
        #expect(depths(rows) == [0, 1, 2, 2, 1, 1])
        // SS's two one-agent tabs absorb into their Agent rows (depth
        // 2) in window order; Omarchy's and Inbox's absorbed leaves sit
        // at workspace depth (1), replacing the group rows that used to
        // stand over them.
        let leaves: [(paneID: String, tabLabel: String?)] = rows.compactMap { row in
            guard let agent = row.agent else { return nil }
            return (paneID: agent.agent.paneID, tabLabel: row.tabLabel)
        }
        #expect(leaves.map(\.paneID) == ["wA:p7", "wA:pM", "wD:pA", "wE:p1"])
        // The absorbed workspace leaves keep their named tab labels —
        // "Omaice" and "Inbox" still ride the rows.
        #expect(leaves.map(\.tabLabel) == [
            "Dynamic States", "Eval error", "Omaice", "Inbox"])
        // No group row stands over a single leaf.
        for row in rows {
            if case .group(_, _, _, let count, _, _) = row {
                #expect(count >= 2)
            }
        }
    }

    /// Empty hosts render as foldable depth-0 stubs; the stub keeps the
    /// minted Host id, so its fold state is shared with the same Host's
    /// populated tree.
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
        #expect(AgentTree.hostID(ofGroupID: id) == host.id)
        #expect(aggregate == .unknown)
    }

    // MARK: Folding

    /// Folding a merged row hides its whole subtree while keeping its
    /// count and aggregate state.
    @Test func foldingAMergedRowHidesItsSubtree() {
        let host = makeHost("Mac")
        let agents = [
            agent(host: host, paneID: "p1", status: .blocked, session: "",
                  workspace: "herdr", tab: "Herdr",
                  workspaceTabCount: 2, tabPosition: 1),
            agent(host: host, paneID: "p2", status: .working, session: "",
                  workspace: "herdr", tab: "bridge",
                  workspaceTabCount: 2, tabPosition: 2),
        ]

        let unfolded = AgentTree.rows(agents: agents, foldedIDs: [])
        // The merged host row plus each single-Agent tab's Agent row.
        #expect(groupLabels(unfolded) == ["Mac · default · herdr"])
        #expect(depths(unfolded) == [0, 1, 1])
        guard case .group(let mergedID, _, _, 2, _, false)? = unfolded.first else {
            Issue.record("merged chain row missing")
            return
        }

        // Folding the merged row leaves exactly one row: the merged row
        // itself, with its subtree count and aggregate intact.
        let folded = AgentTree.rows(agents: agents, foldedIDs: [mergedID])
        #expect(folded.count == 1)
        guard case .group(mergedID, "Mac · default · herdr", 0, 2, .blocked, true)? =
            folded.first
        else {
            Issue.record("folded merged row malformed")
            return
        }
        #expect(!folded.contains { $0.agent != nil })
    }

    /// Folding a deeper group in an expanded chain hides only that
    /// subtree; siblings stay visible and the merged row keeps the whole
    /// subtree's aggregate.
    @Test func foldingADeepGroupHidesOnlyItsSubtree() {
        let host = makeHost("Mac")
        let agents = [
            agent(host: host, paneID: "p1", status: .blocked, session: "",
                  workspace: "herdr", tab: "bridge",
                  workspaceTabCount: 2, tabPosition: 1),
            agent(host: host, paneID: "p2", status: .working, session: "",
                  workspace: "herdr", tab: "bridge",
                  workspaceTabCount: 2, tabPosition: 1),
            agent(host: host, paneID: "p3", status: .idle, session: "",
                  workspace: "herdr", tab: "kitty",
                  workspaceTabCount: 2, tabPosition: 2),
        ]
        let unfolded = AgentTree.rows(agents: agents, foldedIDs: [])
        // Unfolded: merged host row, the two-Agent tab's group row, its
        // two leaves, and the single-Agent tab's merged Agent row.
        #expect(unfolded.count == 5)
        let tabRow = unfolded.first { row in
            if case .group(_, "bridge", 1, _, _, _) = row { return true }
            return false
        }
        guard case .group(let id, "bridge", 1, 2, .blocked, false)? = tabRow else {
            Issue.record("tab group row missing")
            return
        }

        let folded = AgentTree.rows(agents: agents, foldedIDs: [id])
        // The merged row, the folded tab row, and kitty's merged Agent
        // row stay; only bridge's two leaves disappear.
        #expect(folded.count == 3)
        #expect(!folded.contains { $0.agent?.agent.paneID == "p1" })
        #expect(!folded.contains { $0.agent?.agent.paneID == "p2" })
        #expect(folded.contains { $0.agent?.agent.paneID == "p3" })
        guard case .group(_, "Mac · default · herdr", 0, 3, .blocked, false)? =
            folded.first
        else {
            Issue.record("merged row should stay expanded with the whole aggregate")
            return
        }
    }

    /// The merged row's fold id is the chain head's id, so a fold made
    /// while the chain was fully merged still hides the depth-0 row after
    /// the chain gains a sibling tab and un-merges.
    @Test func mergedRowFoldSurvivesChainGainingASibling() {
        let host = makeHost("Mac")
        let single = [
            agent(host: host, paneID: "p1", status: .idle, session: "",
                  workspace: "herdr", tab: "Herdr",
                  workspaceTabCount: 1, tabPosition: 1),
        ]
        guard case .group(let headID, _, 0, _, _, _)? =
            AgentTree.rows(agents: single, foldedIDs: []).first
        else {
            Issue.record("merged chain row missing")
            return
        }
        #expect(AgentTree.hostID(ofGroupID: headID) == host.id)

        // A second tab appears: the chain now stops at the workspace
        // level, but the depth-0 row keeps the same id — the fold hides
        // it either way.
        let expanded = [
            agent(host: host, paneID: "p1", status: .idle, session: "",
                  workspace: "herdr", tab: "Herdr",
                  workspaceTabCount: 2, tabPosition: 1),
            agent(host: host, paneID: "p2", status: .idle, session: "",
                  workspace: "herdr", tab: "bridge",
                  workspaceTabCount: 2, tabPosition: 2),
        ]
        let rows = AgentTree.rows(agents: expanded, foldedIDs: [headID])
        guard case .group(headID, "Mac · default · herdr", 0, 2, .idle, true)? =
            rows.first
        else {
            Issue.record("depth-0 row should keep the chain head id and fold")
            return
        }
        #expect(rows.count == 1)
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

    /// The most urgent live status bleeds through to the merged chain row
    /// and every deeper group; a single-Agent tab's merged Agent row has
    /// no group row of its own, so only the true group rows carry the
    /// aggregate.
    @Test func aggregateBleedsThroughToMergedRowAndGroups() {
        let host = makeHost("Mac")
        let agents = [
            agent(host: host, paneID: "p1", status: .idle, session: "",
                  workspace: "herdr", tab: "bridge",
                  workspaceTabCount: 2, tabPosition: 1),
            agent(host: host, paneID: "p2", status: .blocked, session: "",
                  workspace: "herdr", tab: "bridge",
                  workspaceTabCount: 2, tabPosition: 1),
            agent(host: host, paneID: "p3", status: .working, session: "",
                  workspace: "herdr", tab: "kitty",
                  workspaceTabCount: 2, tabPosition: 2),
        ]
        let rows = AgentTree.rows(agents: agents, foldedIDs: [])
        // The merged depth-0 row and the multi-Agent tab's group row are
        // the only group rows; both carry Blocked, the subtree's most
        // urgent state.
        let groupAggregates = rows.compactMap { row -> AgentStatus? in
            if case .group(_, _, _, _, let aggregate, _) = row { return aggregate }
            return nil
        }
        #expect(groupAggregates == [.blocked, .blocked])
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
