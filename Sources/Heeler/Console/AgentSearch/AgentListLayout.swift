import Foundation
import Observation

// SPDX-License-Identifier: Apache-2.0
//
// The Agents list ordering + grouping views (approved redesign, handoff §B):
// four orders (recent activity, title A–Z, needs-attention, real pane order)
// and six groupings (flat, host, session, workspace, tab, state), living in
// the Agents view menu only — never Settings. Pure projection logic here;
// persistence in `AgentListLayoutStore`.

/// Row order within groups. While a search query is active, relevance
/// outranks every one of these (the caller applies the engine's result
/// order instead).
enum AgentListOrder: String, CaseIterable, Identifiable, Sendable {
    case recent
    case title
    case attention
    case pane

    var id: String { rawValue }

    var label: String {
        switch self {
        case .recent: "Recent activity"
        case .title: "Title A–Z"
        case .attention: "Needs attention"
        case .pane: "Pane order"
        }
    }

    var description: String {
        switch self {
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

    /// Orders `agents` by the chosen view. Stable on the input order for
    /// every tie.
    static func ordered(_ agents: [ConsoleAgent], by order: AgentListOrder) -> [ConsoleAgent] {
        agents.enumerated().sorted { lhs, rhs in
            switch order {
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

    private(set) var order: AgentListOrder
    private(set) var grouping: AgentListGrouping
    private var collapsedGroupIDs: Set<String>
    @ObservationIgnored private nonisolated(unsafe) let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        order = defaults.string(forKey: Self.orderDefaultsKey)
            .flatMap(AgentListOrder.init(rawValue:)) ?? .recent
        grouping = defaults.string(forKey: Self.groupingDefaultsKey)
            .flatMap(AgentListGrouping.init(rawValue:)) ?? .none
        collapsedGroupIDs = Set(defaults.stringArray(forKey: Self.collapsedGroupsDefaultsKey) ?? [])
    }

    func select(order: AgentListOrder) {
        guard order != self.order else { return }
        self.order = order
        defaults.set(order.rawValue, forKey: Self.orderDefaultsKey)
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
        select(order: .recent)
        select(grouping: .none)
        collapsedGroupIDs.removeAll()
        defaults.removeObject(forKey: Self.collapsedGroupsDefaultsKey)
    }

    private func persistCollapsedGroupIDs() {
        defaults.set(
            collapsedGroupIDs.sorted(), forKey: Self.collapsedGroupsDefaultsKey)
    }
}
