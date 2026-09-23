import Foundation
import Observation

// SPDX-License-Identifier: Apache-2.0
//
// The Agents list ordering + grouping views (approved redesign, handoff §B):
// the orders (herdr producer order — the v3 default — recent activity,
// title A–Z, needs-attention, legacy pane order) and six groupings (flat,
// host, session, workspace, tab, state), living in the Agents view menu
// only — never Settings. Pure projection logic here; persistence in
// `AgentListLayoutStore`.

/// Row order within groups. While a search query is active, relevance
/// outranks every one of these (the caller applies the engine's result
/// order instead).
enum AgentListOrder: String, CaseIterable, Identifiable, Sendable {
    case herdr
    case recent
    case title
    case attention
    case pane

    var id: String { rawValue }

    var label: String {
        switch self {
        case .herdr: "Herdr order"
        case .recent: "Recent activity"
        case .title: "Title A–Z"
        case .attention: "Needs attention"
        case .pane: "Pane order"
        }
    }

    var description: String {
        switch self {
        // v3 "Default herdr ordering": the producer's own workspace/tab/
        // pane arrangement — a rename never moves a row, a desktop move
        // does. herdr sessions are independent servers with no global
        // cross-host ordinal, so hosts/sessions stay in the catalog
        // order the user configured. Rows whose producer ordinals are
        // unavailable keep their last-known position at the end, never
        // an invented alphabetical fallback.
        case .herdr:
            "Hosts/sessions in your order; workspaces and tabs in herdr order."
        // Review finding #5: the wire carries no cross-host timestamps —
        // herdr's state_change_seq is comparable only within a Host. The
        // order says so: newest activity first within each machine, hosts
        // in stable blocks. No invented wall-clock ranking.
        case .recent: "Newest activity first within each Host; Hosts in stable blocks."
        case .title: "Alphabetical agent titles."
        case .attention: "Needs you, working, idle, done, then unknown."
        case .pane: "The real snapshot order of panes in the herdr window."
        }
    }
}

/// The grouping axis. Groups are scoped by FULL parent identity: a workspace
/// named "proj" on two Hosts (or two sessions) is two groups, never merged.
enum AgentListGrouping: String, CaseIterable, Identifiable, Sendable {
    case none
    case host
    case session
    case workspace
    case tab
    case state

    var id: String { rawValue }

    var label: String {
        switch self {
        case .none: "None"
        case .host: "Host"
        case .session: "Session"
        case .workspace: "Workspace"
        case .tab: "Tab"
        case .state: "Agent state"
        }
    }

    var description: String {
        switch self {
        case .none: "One compact list across all hosts."
        case .host: "One section per machine."
        case .session: "Sessions scoped to their host."
        case .workspace: "Workspaces scoped to their host and session."
        case .tab: "Tabs scoped to their full workspace path."
        case .state: "Needs you, working, idle, done and unknown."
        }
    }
}

/// One rendered group with the values the header shows. The key carries the
/// FULL parent identity path, so same-name workspace/session/tab values on
/// different parents are different groups, and collapse state survives
/// renames of sibling groups.
struct AgentListSection: Equatable, Identifiable, Sendable {
    struct Key: Hashable, Sendable {
        let grouping: AgentListGrouping
        let identity: [String]
    }

    let key: Key
    /// The group's own title (last identity component).
    let title: String
    /// Full location path for the header's quiet line + VoiceOver.
    let path: [String]
    /// Matching agents in this group, already ordered.
    var agents: [ConsoleAgent]

    var id: String {
        (["g:\(key.grouping.rawValue)"] + key.identity)
            .map { $0.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? "-" }
            .joined(separator: "/")
    }

    /// Matching members only — group counts reflect filtered matches.
    var count: Int { agents.count }

    /// The header's full context path (v2 layout directive): every
    /// identity component of the group's location joined with the
    /// location separator — for the workspace grouping exactly
    /// `host · session · workspace`.
    var contextLine: String {
        path.joined(separator: " · ")
    }
}

/// Pure projection: orders and groups the (already filtered) agent list.
enum AgentListLayout {
    /// State-group ordering: Needs you, Working, Idle, Done, Unknown — the
    /// same urgency ladder the tree's aggregate state uses.
    static func stateRank(_ status: AgentStatus) -> Int {
        switch status {
        case .blocked: 0
        case .working: 1
        case .idle: 2
        case .done: 3
        default: 4
        }
    }

    /// Recency and attention orders key off herdr's own `state_change_seq`
    /// (per-status-change, on the wire) — real activity recency, no
    /// invented clocks. The sequence is comparable only within its Host, so
    /// cross-Host lists keep stable Host blocks and order by sequence
    /// inside them.
    private static func hostBlock(_ agent: ConsoleAgent) -> String {
        agent.hostName
    }

    private static func sequence(_ agent: ConsoleAgent) -> Int {
        agent.agent.stateChangeSeq ?? 0
    }

    /// The row's title for A–Z ordering (re-review finding #1): THE
    /// shared visible-title projection the card renders —
    /// `AgentCardRowTitle` — so the sort key is exactly the text on
    /// screen.
    private static func rowTitle(_ agent: ConsoleAgent) -> String {
        AgentCardRowTitle.title(for: agent)
    }

    private static func snapshotOrder(_ agent: ConsoleAgent) -> Int {
        agent.snapshotOrder ?? Int.max
    }

    // MARK: Herdr order (v3 default)

    /// The v3 default's tiebreak ladder inside one host block, shared by
    /// `ordered(_:by:)` and the host-block comparison below so the two
    /// can never disagree. Producer ordinals first (workspace → tab →
    /// pane, each falling back to "after every placed row"); a row with
    /// a MISSING ordinal sorts after every fully-placed row and keeps
    /// the input (arrival) order among its kind — never a name, status,
    /// or invented fallback key.
    private static func herdrLadder(
        _ lhs: ConsoleAgent, _ rhs: ConsoleAgent
    ) -> Bool {
        // Placed rows always beat unplaced ones: the producer's
        // arrangement for the rows it could place, then the ones it
        // could not ("Order unavailable"), in arrival order.
        if lhs.hasProducerOrder != rhs.hasProducerOrder {
            return lhs.hasProducerOrder
        }
        let lhsWorkspace = lhs.workspaceOrder ?? Int.max
        let rhsWorkspace = rhs.workspaceOrder ?? Int.max
        if lhsWorkspace != rhsWorkspace { return lhsWorkspace < rhsWorkspace }
        let lhsTab = lhs.tabOrder ?? Int.max
        let rhsTab = rhs.tabOrder ?? Int.max
        if lhsTab != rhsTab { return lhsTab < rhsTab }
        let lhsPane = lhs.paneOrder ?? Int.max
        let rhsPane = rhs.paneOrder ?? Int.max
        if lhsPane != rhsPane { return lhsPane < rhsPane }
        return false
    }

    /// Orders `agents` by the chosen view. Stable on the input order for
    /// every tie.
    static func ordered(_ agents: [ConsoleAgent], by order: AgentListOrder) -> [ConsoleAgent] {
        // The v3 herdr order's host/session block ranks: each distinct
        // (host, session) keeps the position of its FIRST appearance in
        // the input — the flatten's catalog order — as its rank. A
        // structural key, never a name/UUID comparison: the sort is not
        // stable in general, so cross-block pairs need a real key.
        struct HerdrBlockKey: Hashable {
            let hostID: Host.ID
            let session: String
        }
        var herdrBlockRanks: [HerdrBlockKey: Int] = [:]
        if order == .herdr {
            for agent in agents {
                let key = HerdrBlockKey(hostID: agent.hostID, session: agent.hostSessionName)
                if herdrBlockRanks[key] == nil { herdrBlockRanks[key] = herdrBlockRanks.count }
            }
        }
        return agents.enumerated().sorted { lhs, rhs in
            switch order {
            case .herdr:
                // The v3 default: host/session blocks in the input
                // (catalog) order, the producer's workspace→tab→pane
                // ordinals inside each block, missing ordinals last in
                // arrival order.
                let lhsBlock = herdrBlockRanks[
                    HerdrBlockKey(hostID: lhs.element.hostID, session: lhs.element.hostSessionName)]!
                let rhsBlock = herdrBlockRanks[
                    HerdrBlockKey(hostID: rhs.element.hostID, session: rhs.element.hostSessionName)]!
                if lhsBlock != rhsBlock { return lhsBlock < rhsBlock }
                let placed = herdrLadder(lhs.element, rhs.element)
                if placed != herdrLadder(rhs.element, lhs.element) {
                    return placed
                }
                return lhs.offset < rhs.offset
            case .title:
                let compared = Self.rowTitle(lhs.element)
                    .localizedCaseInsensitiveCompare(Self.rowTitle(rhs.element))
                if compared != .orderedSame { return compared == .orderedAscending }
                return lhs.offset < rhs.offset
            case .attention:
                let lhsRank = stateRank(lhs.element.agent.status)
                let rhsRank = stateRank(rhs.element.agent.status)
                if lhsRank != rhsRank { return lhsRank < rhsRank }
                if hostBlock(lhs.element) != hostBlock(rhs.element) {
                    return hostBlock(lhs.element) < hostBlock(rhs.element)
                }
                if sequence(lhs.element) != sequence(rhs.element) {
                    return sequence(lhs.element) > sequence(rhs.element)
                }
                return lhs.offset < rhs.offset
            case .recent:
                if hostBlock(lhs.element) != hostBlock(rhs.element) {
                    return hostBlock(lhs.element) < hostBlock(rhs.element)
                }
                if sequence(lhs.element) != sequence(rhs.element) {
                    return sequence(lhs.element) > sequence(rhs.element)
                }
                if snapshotOrder(lhs.element) != snapshotOrder(rhs.element) {
                    return snapshotOrder(lhs.element) < snapshotOrder(rhs.element)
                }
                return lhs.offset < rhs.offset
            case .pane:
                if snapshotOrder(lhs.element) != snapshotOrder(rhs.element) {
                    return snapshotOrder(lhs.element) < snapshotOrder(rhs.element)
                }
                return lhs.offset < rhs.offset
            }
        }.map(\.element)
    }

    /// Groups ordered agents into sections. State groups follow the urgency
    /// ladder; every other grouping keeps first-appearance order from the
    /// ordered input (real pane order for pane/recent orders). Identical
    /// names never merge: the key is the full parent identity path.
    static func grouped(
        _ agents: [ConsoleAgent],
        by grouping: AgentListGrouping
    ) -> [AgentListSection] {
        if grouping == .none { return [] }
        if grouping == .state {
            return stateGroups(agents)
        }
        var sections: [AgentListSection] = []
        var indexByKey: [AgentListSection.Key: Int] = [:]
        for agent in agents {
            let (key, title, path) = identity(of: agent, grouping: grouping)
            if let index = indexByKey[key] {
                sections[index].agents.append(agent)
            } else {
                indexByKey[key] = sections.count
                sections.append(AgentListSection(
                    key: key, title: title, path: path, agents: [agent]))
            }
        }
        return sections
    }

    private static func stateGroups(_ agents: [ConsoleAgent]) -> [AgentListSection] {
        var byLabel: [String: [ConsoleAgent]] = [:]
        var labelOrder: [String] = []
        for agent in agents {
            let label = agent.agent.status.searchLabel
            if byLabel[label] == nil { labelOrder.append(label) }
            byLabel[label, default: []].append(agent)
        }
        let ranked = labelOrder.sorted { lhs, rhs in
            let lhsRank = byLabel[lhs]!.first.map { stateRank($0.agent.status) } ?? 4
            let rhsRank = byLabel[rhs]!.first.map { stateRank($0.agent.status) } ?? 4
            return lhsRank < rhsRank
        }
        return ranked.compactMap { label in
            guard let members = byLabel[label], !members.isEmpty else { return nil }
            return AgentListSection(
                key: .init(grouping: .state, identity: [label]),
                title: label, path: [label], agents: members)
        }
    }

    /// The full-identity key, title, and location path for one agent under
    /// a grouping (review finding #8). The KEY is stable IDs — hostID,
    /// session name, workspaceID, tabID — so same-name resources on
    /// different parents can never merge; the PATH carries display labels
    /// for the header.
    private static func identity(
        of agent: ConsoleAgent,
        grouping: AgentListGrouping
    ) -> (key: AgentListSection.Key, title: String, path: [String]) {
        let hostID = agent.hostID.uuidString
        let sessionID = agent.searchValue(for: .session) ?? AgentTree.defaultSessionLabel
        let workspaceID = agent.agent.workspaceID
        let tabID = agent.agent.tabID
        let keyByGrouping: [AgentListGrouping: [String]] = [
            .host: [hostID],
            .session: [hostID, sessionID],
            .workspace: [hostID, sessionID, workspaceID],
            .tab: [hostID, sessionID, workspaceID, tabID],
        ]
        let hostLabel = agent.hostName
        let sessionLabel = sessionID
        let workspaceLabel = agent.searchValue(for: .workspace) ?? AgentTree.otherLabel
        let tabLabel = agent.searchValue(for: .tab) ?? AgentTree.otherLabel
        let pathByGrouping: [AgentListGrouping: [String]] = [
            .host: [hostLabel],
            .session: [hostLabel, sessionLabel],
            .workspace: [hostLabel, sessionLabel, workspaceLabel],
            .tab: [hostLabel, sessionLabel, workspaceLabel, tabLabel],
        ]
        let key = AgentListSection.Key(
            grouping: grouping, identity: keyByGrouping[grouping] ?? [])
        let path = pathByGrouping[grouping] ?? []
        return (key, path.last ?? "", path)
    }
}

/// Persists the Agents view menu choices (ordering + grouping). These live
/// in the Agents view menu only, never Settings.
@MainActor
@Observable
final class AgentListLayoutStore {
    private static let orderDefaultsKey = "agent-list-layout.order"
    private static let groupingDefaultsKey = "agent-list-layout.grouping"
    private static let collapsedGroupsDefaultsKey = "agent-list-layout.collapsed-groups"
    /// The v3 migration marker: absent until the user makes their FIRST
    /// explicit order choice. Fresh installs AND pre-v3 defaults (which
    /// never wrote this key) both land on the new herdr default; a
    /// deliberately chosen order — including a pre-v3 choice — sets the
    /// marker and is preserved forever after.
    private static let orderChoiceMarkerKey = "agent-list-layout.order-chosen"

    private(set) var order: AgentListOrder
    private(set) var grouping: AgentListGrouping
    private var collapsedGroupIDs: Set<String>
    @ObservationIgnored private nonisolated(unsafe) let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let storedOrder = defaults.string(forKey: Self.orderDefaultsKey)
            .flatMap(AgentListOrder.init(rawValue:))
        if defaults.bool(forKey: Self.orderChoiceMarkerKey) {
            // Deliberately chosen: preserved, even if it predates v3.
            order = storedOrder ?? .herdr
        } else if let storedOrder, storedOrder != .recent {
            // A pre-v3 deliberate choice (the old default wrote
            // nothing; only a real picker tap stored "recent"): the
            // marker migrates it forward and the choice is preserved.
            order = storedOrder
            defaults.set(true, forKey: Self.orderChoiceMarkerKey)
        } else {
            // Fresh install or untouched old default: migrate to the
            // v3 herdr default.
            order = .herdr
        }
        grouping = defaults.string(forKey: Self.groupingDefaultsKey)
            .flatMap(AgentListGrouping.init(rawValue:)) ?? .none
        collapsedGroupIDs = Set(defaults.stringArray(forKey: Self.collapsedGroupsDefaultsKey) ?? [])
    }

    func select(order: AgentListOrder) {
        guard order != self.order else { return }
        self.order = order
        defaults.set(order.rawValue, forKey: Self.orderDefaultsKey)
        defaults.set(true, forKey: Self.orderChoiceMarkerKey)
    }

    func select(grouping: AgentListGrouping) {
        guard grouping != self.grouping else { return }
        self.grouping = grouping
        defaults.set(grouping.rawValue, forKey: Self.groupingDefaultsKey)
    }

    func isCollapsed(_ groupID: String) -> Bool {
        collapsedGroupIDs.contains(groupID)
    }

    func setCollapsed(_ collapsed: Bool, for groupID: String) {
        let changed: Bool
        if collapsed {
            changed = collapsedGroupIDs.insert(groupID).inserted
        } else {
            changed = collapsedGroupIDs.remove(groupID) != nil
        }
        guard changed else { return }
        persistCollapsedGroupIDs()
    }

    func toggleCollapsed(_ groupID: String) {
        setCollapsed(!isCollapsed(groupID), for: groupID)
    }

    func reset() {
        // Reset returns the list to the fresh-install v3 state — herdr
        // order, no grouping — WITHOUT clearing the choice marker: a
        // user who reset away from a chosen sort and then picks another
        // one is still making explicit choices.
        select(order: .herdr)
        select(grouping: .none)
        collapsedGroupIDs.removeAll()
        defaults.removeObject(forKey: Self.collapsedGroupsDefaultsKey)
    }

    private func persistCollapsedGroupIDs() {
        defaults.set(
            collapsedGroupIDs.sorted(), forKey: Self.collapsedGroupsDefaultsKey)
    }
}
