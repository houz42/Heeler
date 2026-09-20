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
        case .recent: "Most recent activity first."
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

/// One rendered group with the values the header shows. `id` is the full
/// parent identity path, so collapse state and identity survive renames of
/// sibling groups.
struct AgentListSection: Equatable, Identifiable, Sendable {
    struct Key: Hashable, Sendable {
        let grouping: AgentListGrouping
        let identity: [String]

        func expanded(with value: String) -> Key {
            Key(grouping: grouping, identity: identity + [value])
        }
    }

    let key: Key
    /// The group's own title (last identity component).
    let title: String
    /// Full location path for the header's quiet line + VoiceOver.
    let path: [String]
    /// Matching agents in this group, already ordered.
    let agents: [ConsoleAgent]

    var id: String {
        key.identity.map { $0.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? "∅" }
            .joined(separator: "/")
    }

    var count: Int { agents.count }

    /// `host · session · workspace · tab` for the group header's quiet line.
    var parentLine: String {
        path.dropLast().joined(separator: " · ")
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

    /// The recency key: the last status-change time the Console observed for
    /// the pane (status deltas are exactly what herdr reports as activity);
    /// nil agents sort by pane order. Descending, recent first.
    private static func recency(
        _ agent: ConsoleAgent, times: [String: Date]
    ) -> (hasTime: Bool, time: Date, snapshotOrder: Int) {
        let id = agent.agent.paneID
        if let time = times[id] {
            return (true, time, agent.snapshotOrder ?? Int.max)
        }
        return (false, .distantPast, agent.snapshotOrder ?? Int.max)
    }

    /// Orders `agents` by the chosen view. `nil` stays the caller's order
    /// (search relevance) — search outranks the sort while querying.
    static func ordered(
        _ agents: [ConsoleAgent],
        by order: AgentListOrder,
        recencyTimes: [String: Date] = [:]
    ) -> [ConsoleAgent] {
        agents.enumerated().sorted { lhs, rhs in
            switch order {
            case .title:
                (lhs.element.agent.displayName.localizedCaseInsensitiveCompare(
                    rhs.element.agent.displayName), lhs.offset)
                    < (rhs.element.agent.displayName.localizedCaseInsensitiveCompare(
                        lhs.element.agent.displayName), rhs.offset)
            case .attention:
                let lhsRank = stateRank(lhs.element.agent.status)
                let rhsRank = stateRank(rhs.element.agent.status)
                if lhsRank != rhsRank { return lhsRank < rhsRank }
                let lhsRecent = recency(lhs.element, times: recencyTimes)
                let rhsRecent = recency(rhs.element, times: recencyTimes)
                if lhsRecent.time != rhsRecent.time { return lhsRecent.time > rhsRecent.time }
                return lhs.offset < rhs.offset
            case .recent:
                let lhsRecent = recency(lhs.element, times: recencyTimes)
                let rhsRecent = recency(rhs.element, times: recencyTimes)
                if lhsRecent.time != rhsRecent.time { return lhsRecent.time > rhsRecent.time }
                if lhsRecent.snapshotOrder != rhsRecent.snapshotOrder {
                    return lhsRecent.snapshotOrder < rhsRecent.snapshotOrder
                }
                return lhs.offset < rhs.offset
            case .pane:
                let lhsOrder = lhs.element.snapshotOrder ?? Int.max
                let rhsOrder = rhs.element.snapshotOrder ?? Int.max
                if lhsOrder != rhsOrder { return lhsOrder < rhsOrder }
                return lhs.offset < rhs.offset
            }
        }.map(\.element)
    }

    /// Groups ordered agents into sections. Group order: state groups by
    /// urgency; everything else by first-appearance in the ordered input
    /// (real pane order for pane/recent orders, alphabetical within for
    /// title order). Identical names never merge: the key is the full
    /// parent identity path.
    static func grouped(
        _ agents: [ConsoleAgent],
        by grouping: AgentListGrouping
    ) -> [AgentListSection] {
        switch grouping {
        case .none:
            return []
        case .state:
            return AgentStatus.searchOrder.compactMap { status in
                let members = agents.filter { $0.agent.status.searchLabel == status.searchLabel }
                    .sorted { $0.agent.paneID < $1.agent.paneID }
                guard !members.isEmpty else { return nil }
                return AgentListSection(
                    key: .init(grouping: .state, identity: [status.searchLabel]),
                    title: status.searchLabel,
                    path: [status.searchLabel],
                    agents: members)
            }
        default:
            var sections: [AgentListSection] = []
            var byKey: [AgentListSection.Key: Int] = [:]
            for agent in agents {
                let (key, title, path) = identity(of: agent, grouping: grouping)
                if let index = byKey[key] {
                    sections[index].agents.append(agent)
                } else {
                    byKey[key] = sections.count
                    sections.append(AgentListSection(
                        key: key, title: title, path: path, agents: [agent]))
                }
            }
            return sections
        }
    }

    /// The full-identity key, title, and location path for one agent under
    /// a grouping. Same-name workspace/session/tab values on different
    /// parents produce different keys.
    private static func identity(
        of agent: ConsoleAgent,
        grouping: AgentListGrouping
    ) -> (key: AgentListSection.Key, title: String, path: [String]) {
        let host = agent.hostName
        let session = agent.searchValue(for: .session) ?? AgentTree.defaultSessionLabel
        let workspace = agent.searchValue(for: .workspace) ?? AgentTree.otherLabel
        let tab = agent.searchValue(for: .tab) ?? AgentTree.otherLabel
        let pathByGrouping: [AgentListGrouping: [String]] = [
            .host: [host],
            .session: [host, session],
            .workspace: [host, session, workspace],
            .tab: [host, session, workspace, tab],
            .state: [],
            .none: [],
        ]
        let path = pathByGrouping[grouping] ?? []
        return (AgentListSection.Key(grouping: grouping, identity: path), path.last ?? "", path)
    }
}

extension AgentStatus {
    /// The state-group presentation order.
    static let searchOrder: [AgentStatus] = [.blocked, .working, .idle, .done, .unknown]
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
