import Foundation
import Observation

// SPDX-License-Identifier: Apache-2.0
//
// The hierarchical Agents list: Host → session → workspace → tab → Agents.
// Pure tree building lives in `AgentTree`; fold-state persistence in
// `AgentTreeFoldStore`. No SwiftUI/UIKit here, so the logic runs from tests
// and standalone runners against the real sources.

/// One rendered row of the hierarchical Agents list. Group rows fold; an
/// Agent row is the leaf. `depth` drives indentation. Single-child chains
/// collapse, so a row's depth no longer names its level: a merged chain
/// renders at the chain head's depth and its Agents one level deeper, and
/// a tab holding exactly one Agent merges into that Agent's row.
enum AgentTreeRow: Equatable, Identifiable, Sendable {
    case group(
        id: String,
        label: String,
        depth: Int,
        count: Int,
        aggregateState: AgentStatus,
        isFolded: Bool)
    /// `tabLabel` names the single-agent tab this row also represents
    /// (a tab group merged into its Agent's row); nil on a plain leaf.
    case agent(ConsoleAgent, depth: Int, tabLabel: String? = nil)

    var id: String {
        switch self {
        case .group(let id, _, _, _, _, _): id
        case .agent(let agent, _, _):
            "agent:\(agent.hostID.uuidString)/\(agent.agent.paneID)"
        }
    }

    /// The Agent for leaf rows; nil on group rows.
    var agent: ConsoleAgent? {
        if case .agent(let agent, _, _) = self { return agent }
        return nil
    }

    /// The single-agent tab label a leaf row carries after the tab merge.
    var tabLabel: String? {
        if case .agent(_, _, let tabLabel) = self { return tabLabel }
        return nil
    }
}

/// Builds the foldable Host → session → workspace → tab → Agent tree from
/// the Console's already-sorted Agent sequence. Pure: the fold set arrives
/// as a value, and the same inputs always produce the same rows.
enum AgentTree {
    /// Session label when the Host points at herdr's default (unnamed)
    /// session.
    static let defaultSessionLabel = "default"
    /// Label for groups whose snapshot carried no workspace/tab label.
    static let otherLabel = "Other"

    /// Aggregate urgency: Blocked > Working > Idle > Done. A live state
    /// (Blocked or Working) bleeds through to every ancestor group row;
    /// Done outranks nothing because it is asking nobody. Anything this
    /// build cannot interpret never outranks a status it can, matching
    /// the Console sort's unknown bucket.
    static func aggregateRank(_ status: AgentStatus) -> Int {
        switch status {
        case .blocked: 0
        case .working: 1
        case .idle: 2
        case .done: 3
        default: 4
        }
    }

    /// The most urgent status in a subtree; `.unknown` for an empty one.
    static func aggregateState(of agents: [ConsoleAgent]) -> AgentStatus {
        agents.map(\.agent.status).min {
            aggregateRank($0) < aggregateRank($1)
        } ?? .unknown
    }

    /// The Host a group id belongs to; nil for ids this build did not mint.
    /// Only a depth-0 group id ("h/<host>") names a Host — deeper ids
    /// ("h/<host>/s/…", "/w/…", "/t/…") share the prefix, so a bare
    /// prefix read would misresolve every level to the host section.
    /// The merge keeps the chain head's id, so a merged depth-0 row is
    /// still the bare Host id.
    static func hostID(ofGroupID groupID: String) -> Host.ID? {
        guard groupID.hasPrefix("h/") else { return nil }
        let encoded = groupID.dropFirst(2)
        guard !encoded.contains("/") else { return nil }
        guard let decoded = String(encoded)
            .removingPercentEncoding, let id = Host.ID(uuidString: decoded)
        else { return nil }
        return id
    }

    /// The rows to render. Hosts sort alphabetically by label (stable —
    /// the unique group id breaks label ties), the same policy as the
    /// grouped mode's sections. Below each Host, groups follow the herdr
    /// window's pane order — the snapshot enumerates workspaces, tabs,
    /// and panes the way the user arranged them — and leaves within a
    /// tab follow the pane's reading position. A folded group hides its
    /// whole subtree while its row keeps the subtree's count and
    /// aggregate state.
    ///
    /// `emptyHosts` keeps catalog Hosts with no Agents visible as foldable
    /// depth-0 group rows (the tree's counterpart of the grouped mode's
    /// empty sections), sorted in with the populated Hosts.
    static func rows(
        agents: [ConsoleAgent],
        foldedIDs: Set<String>,
        emptyHosts: [(id: Host.ID, label: String)] = []
    ) -> [AgentTreeRow] {
        var rows: [AgentTreeRow] = []
        guard !agents.isEmpty || !emptyHosts.isEmpty else { return rows }

        var hostClusters = clusters(agents, key: hostKey, label: { $0.hostName })
        for host in emptyHosts where !agents.contains(where: { $0.hostID == host.id }) {
            hostClusters.append((key: host.id.uuidString, label: host.label, agents: []))
        }

        for host in hostClusters.sorted(by: { ($0.label, $0.key) < ($1.label, $1.key) }) {
            emitGroup(
                id: "h/" + encode(host.key),
                label: host.label, members: host.agents,
                depth: 0, level: 0,
                foldedIDs: foldedIDs, rows: &rows)
        }
        return rows
    }

    /// Emits one group row and recurses into its children. A group whose
    /// whole subtree is one single-child chain (one session with one
    /// workspace with one tab) collapses into one "a · b · c" row at the
    /// chain head's depth. The merged row keeps the chain head's id, so
    /// its fold survives the chain later gaining a sibling (the row
    /// un-merges but keeps its id), and a depth-0 head still names its
    /// Host for the section header.
    ///
    /// A chain that bottoms out in exactly one visible leaf merges the
    /// other way, at ANY level — not just tabs: the chain stops there and
    /// the Agent's row absorbs every remaining group row (keeping each
    /// label that adds information). A single-agent workspace under a
    /// multi-workspace host and a single-agent tab under a multi-tab
    /// workspace collapse by the same rule, so the same shape renders
    /// identically on every Host. A foldable group over a single visible
    /// leaf would render two rows where one says everything; folding is
    /// meaningless there — the merged row renders no chevron, and a stale
    /// fold id for the absorbed group re-engages only once it holds two
    /// visible leaves again.
    ///
    /// Two label-only drops keep merged rows readable: a label this
    /// build synthesized (`Other` for a missing workspace/tab label)
    /// names nothing the row below doesn't, and herdr's automatic tab
    /// label (the position) is plumbing the Agent card already hides
    /// (`ConsoleAgent.showsTabLabel`).
    private static func emitGroup(
        id: String,
        label: String,
        members: [ConsoleAgent],
        depth: Int,
        level: Int,  // 0 = host, 1 = session, 2 = workspace, 3 = tab
        foldedIDs: Set<String>,
        rows: inout [AgentTreeRow]
    ) {
        var label = label, members = members, level = level
        // Children of a level-L group are clustered by keys[L]; level 3
        // (tab) has agents directly, no further grouping.
        let keys: [(ConsoleAgent) -> String] = [sessionKey, workspaceKey, tabKey]
        let markers = ["s", "w", "t"]

        while level < 3 {
            let children = clusters(members, key: keys[level], label: keys[level])
            guard children.count == 1, let only = children.first else { break }
            // A single-Agent tab is absorbed by its Agent's row below,
            // never by this group's label.
            if level == 2, only.agents.count == 1 { break }
            if showsMergedComponent(only, level: level) {
                label += " · " + only.label
            }
            members = only.agents
            level += 1
        }

        appendGroup(id, label, depth, members, foldedIDs, &rows)
        guard !foldedIDs.contains(id) else { return }

        if level >= 3 {
            for entry in members.enumerated().sorted(by: { lhs, rhs in
                (leafIndex(lhs.element), lhs.offset)
                    < (leafIndex(rhs.element), rhs.offset)
            }) {
                rows.append(.agent(entry.element, depth: depth + 1))
            }
            return
        }
        var children = clusters(members, key: keys[level], label: keys[level])
        // Sessions are separate herdr servers, not panes in one window —
        // they keep the tree's alphabetical group order. Workspaces and
        // tabs are layout inside one window and keep pane order.
        if level == 0 {
            children.sort { ($0.label, $0.key) < ($1.label, $1.key) }
        }
        for child in children {
            // A workspace or tab cluster whose whole subtree is one
            // visible leaf merges into that Agent's row — at any grouping
            // level below the session, so the same shape collapses the
            // same way on every Host. A foldable group over a single
            // leaf would render two rows where one says everything;
            // folding is meaningless there — the merged row renders no
            // chevron, and a stale fold id for the absorbed group
            // re-engages only once it holds two visible leaves again.
            if level >= 1, let absorbed = absorbSingleLeafChain(child, level: level) {
                rows.append(absorbed(depth + 1))
                continue
            }
            emitGroup(
                id: id + "/" + markers[level] + "/" + encode(child.key),
                label: child.label, members: child.agents,
                depth: depth + 1, level: level + 1,
                foldedIDs: foldedIDs, rows: &rows)
        }
    }

    /// A cluster whose whole subtree bottoms out in exactly one visible
    /// leaf renders as that Agent's row, at any grouping level below the
    /// session — a one-Agent workspace under a multi-workspace Host and a
    /// one-Agent tab under a multi-tab workspace collapse by the same
    /// rule, so the same shape renders identically on every Host. The
    /// Agent row keeps the tab label when it adds information, exactly
    /// as the tab-level merge always has. nil means the cluster holds
    /// multiple leaves and keeps its foldable group row. Sessions (level
    /// 0) never absorb: the session name is identity the chain merge
    /// already carries into its label.
    private static func absorbSingleLeafChain(
        _ cluster: (key: String, label: String, agents: [ConsoleAgent]),
        level: Int
    ) -> ((Int) -> AgentTreeRow)? {
        guard cluster.agents.count == 1, let only = cluster.agents.first else {
            return nil
        }
        // A one-Agent workspace: the leaf may sit under a one-Agent tab
        // whose label then rides the row (the tab renders no row of its
        // own either).
        if level == 1 {
            let tabs = clusters(cluster.agents, key: tabKey, label: tabKey)
            guard tabs.count == 1, let tab = tabs.first, tab.agents.count == 1,
                only.showsTabLabel
            else { return { depth in .agent(only, depth: depth) } }
            return { depth in .agent(only, depth: depth, tabLabel: tab.label) }
        }
        // level == 2: a one-Agent tab, the merge the tree always had.
        return { depth in
            .agent(
                only, depth: depth,
                tabLabel: only.showsTabLabel ? cluster.label : nil)
        }
    }

    /// Whether a single-child cluster's label joins the merged row's label.
    /// `Other` is this build's placeholder for a label the snapshot did
    /// not carry, and an automatic tab label (herdr names unnamed tabs by
    /// position) is not a name the user chose — neither earns a " · "
    /// component. Everything else does, including herdr's "default"
    /// session label, which distinguishes real sessions.
    private static func showsMergedComponent(
        _ cluster: (key: String, label: String, agents: [ConsoleAgent]),
        level: Int
    ) -> Bool {
        if cluster.label == otherLabel { return false }
        if level == 2, !cluster.agents.contains(where: \.showsTabLabel) {
            return false
        }
        return true
    }

    /// One clustering level: agents keyed by `key`, labeled from the
    /// cluster's first element (every member shares the key by
    /// construction). Within a Host, clusters keep the herdr window's
    /// order — the snapshot enumerates workspaces, tabs, and panes the
    /// way the user arranged them — via the first member's snapshot
    /// collection position, with the supplied sequence as the stable
    /// fallback (tests and legacy shapes with no snapshot order).
    private static func clusters(
        _ agents: [ConsoleAgent],
        key: (ConsoleAgent) -> String,
        label: (ConsoleAgent) -> String
    ) -> [(key: String, label: String, agents: [ConsoleAgent])] {
        var firstIndex: [String: Int] = [:]
        for (index, agent) in agents.enumerated() {
            if firstIndex[key(agent)] == nil {
                firstIndex[key(agent)] = index
            }
        }
        return Dictionary(grouping: agents, by: key)
            .map { grouped -> (key: String, label: String, agents: [ConsoleAgent]) in
                let first = grouped.value.first
                return (
                    key: grouped.key,
                    label: first.map(label) ?? grouped.key,
                    agents: grouped.value
                )
            }
            .sorted { lhs, rhs in
                let lhsOrder = clusterIndex(lhs.agents)
                let rhsOrder = clusterIndex(rhs.agents)
                if lhsOrder != rhsOrder { return lhsOrder < rhsOrder }
                // Same (possibly missing) snapshot position: keep the
                // supplied sequence.
                return (firstIndex[lhs.key] ?? Int.max) < (firstIndex[rhs.key] ?? Int.max)
            }
    }

    /// The window position a group occupies: the earliest snapshot
    /// collection order among its members. The snapshot enumerates
    /// workspaces, tabs, and panes in window order, so the first pane of
    /// a group in window order is the group's reading position.
    private static func clusterIndex(_ agents: [ConsoleAgent]) -> Int {
        agents.map { $0.snapshotOrder ?? Int.max }.min() ?? Int.max
    }

    /// The reading position of a leaf within its tab: pane geometry first
    /// (rows top-to-bottom, then left-to-right), falling back to the
    /// snapshot's collection order when no layout carried the pane.
    private static func leafIndex(_ agent: ConsoleAgent) -> Int {
        agent.paneOrder ?? agent.snapshotOrder ?? Int.max
    }

    /// Cluster keys. A missing (nil or blank) workspace/tab label collapses
    /// to one `Other` group at the level that lacked it, never a scattered
    /// set of empty names.
    private static func hostKey(_ agent: ConsoleAgent) -> String {
        agent.hostID.uuidString
    }

    private static func sessionKey(_ agent: ConsoleAgent) -> String {
        let trimmed = agent.hostSessionName.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? defaultSessionLabel : trimmed
    }

    private static func workspaceKey(_ agent: ConsoleAgent) -> String {
        labeled(agent.workspaceLabel)
    }

    private static func tabKey(_ agent: ConsoleAgent) -> String {
        labeled(agent.tabLabel)
    }

    private static func labeled(_ label: String?) -> String {
        let trimmed = label?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? otherLabel : trimmed
    }

    /// Percent-encode one id component so a label cannot forge a separator
    /// or collide with another level's id.
    private static func encode(_ component: String) -> String {
        component.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? otherLabel
    }

    private static func appendGroup(
        _ id: String,
        _ label: String,
        _ depth: Int,
        _ subtree: [ConsoleAgent],
        _ foldedIDs: Set<String>,
        _ rows: inout [AgentTreeRow]
    ) {
        rows.append(.group(
            id: id,
            label: label,
            depth: depth,
            count: subtree.count,
            aggregateState: aggregateState(of: subtree),
            isFolded: foldedIDs.contains(id)))
    }
}

/// Fold state for the hierarchical Agents list, persisted per group
/// identity in the dedicated `dev.houz42.meadow.tree` UserDefaults suite.
/// Unknown groups default to expanded; folded ids are deliberately
/// retained when their group disappears so a later return restores the
/// choice (the same policy as the grouped mode's collapsed Hosts).
@MainActor
@Observable
final class AgentTreeFoldStore {
    static let suiteName = "dev.houz42.meadow.tree"
    private static let foldedGroupsKey = "tree.folded-groups"

    private(set) var foldedIDs: Set<String>
    // UserDefaults is documented thread-safe; Sendable modulo that promise.
    @ObservationIgnored private nonisolated(unsafe) let defaults: UserDefaults

    init(defaults: UserDefaults = AgentTreeFoldStore.sharedDefaults()) {
        self.defaults = defaults
        foldedIDs = Set(defaults.stringArray(forKey: Self.foldedGroupsKey) ?? [])
    }

    func isFolded(_ groupID: String) -> Bool {
        foldedIDs.contains(groupID)
    }

    func setFolded(_ folded: Bool, for groupID: String) {
        let changed: Bool
        if folded {
            changed = foldedIDs.insert(groupID).inserted
        } else {
            changed = foldedIDs.remove(groupID) != nil
        }
        guard changed else { return }
        defaults.set(foldedIDs.sorted(), forKey: Self.foldedGroupsKey)
    }

    func toggle(_ groupID: String) {
        setFolded(!isFolded(groupID), for: groupID)
    }

    /// The suite-backed defaults for the default initializer; `.standard`
    /// if the suite cannot be created (fold state is cosmetic).
    private static func sharedDefaults() -> UserDefaults {
        UserDefaults(suiteName: suiteName) ?? .standard
    }
}
