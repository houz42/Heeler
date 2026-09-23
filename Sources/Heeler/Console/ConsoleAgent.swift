import Foundation

/// One row of the Console (#8): an Agent joined with its Host identity and
/// workspace context. The list is flat across Hosts; the workspace is a
/// context tag only, never a grouping level.
struct ConsoleAgent: Identifiable, Sendable, Equatable {
    /// Pane addresses are unique per herdr session, not across Hosts; the
    /// row identity pairs them.
    struct ID: Hashable, Sendable {
        let hostID: Host.ID
        let paneID: String
    }

    let hostID: Host.ID
    let hostName: String
    /// Named herdr session this Host points at; empty means the default
    /// session (and an empty `session` row token).
    let hostSessionName: String
    /// SSH account name, used only for conservative presentation of standard
    /// macOS/Linux home paths as `~`. The actual remote path stays unchanged.
    let hostUsername: String?
    var agent: Agent
    /// Workspace label from the session snapshot; nil when the snapshot did
    /// not carry the workspace.
    let workspaceLabel: String?
    let tabLabel: String?
    let paneLabel: String?
    /// One-based position within the snapshot's workspace tabs. herdr's
    /// automatic label uses position, not TabInfo.number's stable identity.
    let tabPosition: Int?
    /// Tabs in the Agent's workspace, shell-only tabs included. One tab
    /// means herdr's automatic label is the position and names nothing.
    let workspaceTabCount: Int
    /// Collection order from session.snapshot.agents for the `spaces` sort.
    /// The snapshot enumerates workspaces, then tabs, then panes in the
    /// herdr window's order, so this is also the tree's group-order key.
    let snapshotOrder: Int?
    /// The workspace's position in session.snapshot.workspaces — the
    /// PRODUCER's own workspace order (v3 "Default herdr ordering"),
    /// retained across snapshot revisions. A rename never changes it; a
    /// desktop move does (the producer re-enumerates).
    let workspaceOrder: Int?
    /// The tab's position in session.snapshot.tabs — the producer's tab
    /// order within the whole herdr window. Tabs of one workspace are
    /// contiguous in the producer's enumeration, so workspace order then
    /// tab order reproduces the window's workspace→tab arrangement.
    let tabOrder: Int?
    /// Zero-based reading order of the pane across the WHOLE host's
    /// layouts (tab order, then rows top-to-bottom, then left-to-right),
    /// nil when no layout carried the pane. This is the v3 Herdr order's
    /// pane key; within a tab it is exactly the pane-layout traversal.
    let paneOrder: Int?
    /// Snapshot git metadata when the workspace reported any. Presence does
    /// not mean this is removable: the main checkout is reported with
    /// `isLinkedWorktree == false` too.
    let repositoryCheckout: RepositoryCheckout?
    /// Trailing terminal output (`pane.read`, ANSI stripped), fetched after
    /// snapshots and status changes; nil until the first read lands.
    var lastOutputSnippet: String?

    var id: ID { ID(hostID: hostID, paneID: agent.paneID) }

    /// Whether the producer reported enough ordinals for the Herdr
    /// order to place this row exactly: workspace, tab AND pane layout
    /// ordinals all present. False rows sort last in their host block
    /// (missing ordinals keep last-known/arrival order) and surface as
    /// "Order unavailable" — never an invented alphabetical fallback.
    var hasProducerOrder: Bool {
        workspaceOrder != nil && tabOrder != nil && paneOrder != nil
    }

    init(
        hostID: Host.ID,
        hostName: String,
        agent: Agent,
        workspaceLabel: String?,
        repositoryCheckout: RepositoryCheckout?,
        lastOutputSnippet: String? = nil,
        hostUsername: String? = nil,
        hostSessionName: String = "",
        tabLabel: String? = nil,
        tabPosition: Int? = nil,
        workspaceTabCount: Int = 0,
        snapshotOrder: Int? = nil,
        workspaceOrder: Int? = nil,
        tabOrder: Int? = nil,
        paneLabel: String? = nil,
        paneOrder: Int? = nil
    ) {
        self.hostID = hostID
        self.hostName = hostName
        self.hostSessionName = hostSessionName
        self.hostUsername = hostUsername
        self.agent = agent
        self.workspaceLabel = workspaceLabel
        self.tabLabel = tabLabel
        self.paneLabel = paneLabel
        self.tabPosition = tabPosition
        self.workspaceTabCount = workspaceTabCount
        self.snapshotOrder = snapshotOrder
        self.workspaceOrder = workspaceOrder
        self.tabOrder = tabOrder
        self.repositoryCheckout = repositoryCheckout
        self.lastOutputSnippet = lastOutputSnippet
        self.paneOrder = paneOrder
    }

    var repoName: String? { repositoryCheckout?.repoName }

    /// Protocol 20 has no custom-name bit. A manual name equal to the
    /// automatic position cannot be distinguished from an automatic name.
    var showsTabLabel: Bool {
        guard let tabLabel, !tabLabel.isEmpty else { return false }
        if workspaceTabCount > 1 { return true }
        guard let tabPosition else { return true }
        return tabLabel != String(tabPosition)
    }

    var checkoutPath: String? { repositoryCheckout?.checkoutPath }

    /// Console badge and destructive-action eligibility come only from the
    /// latest session snapshot's explicit linkage bit.
    var isLinkedWorktree: Bool { repositoryCheckout?.isLinkedWorktree == true }

    var workspaceContext: String? {
        switch (workspaceLabel, repoName) {
        case (nil, nil): nil
        case (let label?, nil): label
        case (nil, let repo?): repo
        case (let label?, let repo?): label == repo ? label : "\(label) · \(repo)"
        }
    }

    /// The directory the skills probe treats as the agent's project root:
    /// the worktree checkout when the workspace has one, else the agent's
    /// launch cwd. Deliberately not the live foreground cwd — agents load
    /// project skills from where they started.
    var skillsProjectRoot: String? {
        if let checkoutPath, !checkoutPath.isEmpty { return checkoutPath }
        return agent.cwd.isEmpty ? nil : agent.cwd
    }

    /// Client-side Agents search (#292): a trimmed, case-insensitive
    /// substring match over the working directory and the title/visible
    /// text. An empty query matches every agent.
    func matchesAgentSearch(_ query: String) -> Bool {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return true }
        let candidates: [String?] = [
            agent.cwd,
            workspaceLabel,
            tabLabel,
            paneLabel,
            agent.title,
            agent.paneTitle,
            agent.displayName,
            agent.terminalTitle,
            agent.terminalTitleStripped,
        ]
        return candidates.contains {
            guard let field = $0, !field.isEmpty else { return false }
            return field.range(of: needle, options: .caseInsensitive) != nil
        }
    }

    /// The launch directory as a Console row should print it. The snapshot
    /// carries the expanded remote path but not `$HOME`, so only the
    /// account's conventional macOS/Linux homes are shortened to `~`; every
    /// other path stays exactly as the Agent reported it.
    var displayCwd: String {
        guard let hostUsername, !hostUsername.isEmpty else { return agent.cwd }
        let homes =
            hostUsername == "root"
            ? ["/root"]
            : ["/Users/\(hostUsername)", "/home/\(hostUsername)"]
        guard let home = homes.first(where: { agent.cwd == $0 || agent.cwd.hasPrefix("\($0)/") })
        else { return agent.cwd }
        return agent.cwd == home ? "~" : "~\(agent.cwd.dropFirst(home.count))"
    }
}

/// The snapshot's exact git checkout identity for one workspace. Workspace
/// ids are reusable slots, so destructive actions match this tuple too.
struct RepositoryCheckout: Sendable, Equatable, Hashable {
    let repoKey: String
    let repoName: String
    let repoRoot: String
    let checkoutPath: String
    let isLinkedWorktree: Bool

    init(
        repoKey: String,
        repoName: String,
        repoRoot: String,
        checkoutPath: String,
        isLinkedWorktree: Bool
    ) {
        self.repoKey = repoKey
        self.repoName = repoName
        self.repoRoot = repoRoot
        self.checkoutPath = checkoutPath
        self.isLinkedWorktree = isLinkedWorktree
    }

    init(_ info: WorkspaceWorktreeInfo) {
        self.init(
            repoKey: info.repoKey,
            repoName: info.repoName,
            repoRoot: info.repoRoot,
            checkoutPath: info.checkoutPath,
            isLinkedWorktree: info.isLinkedWorktree)
    }
}

/// A workspace known for a Host from its latest session snapshot, offered as
/// a target in the new-agent flow (#12). Identity is herdr's opaque
/// `workspace_id`; the label is what the picker shows.
struct ConsoleWorkspace: Identifiable, Hashable, Sendable {
    let id: String
    let label: String
}

extension AgentStatus {
    /// Console sort bucket: Blocked > Done > Working > Idle. The order tracks
    /// how much of the user's attention each status is asking for — Blocked
    /// has stopped and is waiting on an answer, Done has a result to read,
    /// Working needs nothing, Idle least of all. Unknown and any status this
    /// build does not recognize (herdr's API has no stability guarantee)
    /// share the bottom bucket — a status we cannot interpret is not
    /// actionable, so it must not outrank one we can.
    var consoleSortBucket: Int {
        switch self {
        case .blocked: 0
        case .done: 1
        case .working: 2
        case .idle: 3
        default: 4
        }
    }
}

extension [ConsoleAgent] {
    /// Pins always lead by recency. Snapshot policy controls each Host's
    /// remaining Agents; absent snapshots retain the legacy priority order.
    /// Space order uses stable Host blocks even in the flat presentation.
    /// (The v3 herdr-ordered VIEW projection lives in `AgentListLayout`;
    /// this remains the raw store order for the legacy surfaces — the
    /// terminal switcher rail, Live Activities — and the pin-led
    /// relevance-tie input the search engine sees.)
    func consoleSorted(
        sortByHost: [Host.ID: AgentPanelSort] = [:],
        pinRank: (ConsoleAgent) -> Int? = { _ in nil }
    ) -> [ConsoleAgent] {
        // Space order is meaningful only within a Host. If any Host uses it,
        // compare Host identities before local policy; selecting a comparator
        // from just one operand would violate transitivity across mixed Hosts.
        let usesSpaceOrder = contains { sortByHost[$0.hostID] == .spaces }
        return sorted { lhs, rhs in
            let lhsRank = pinRank(lhs)
            let rhsRank = pinRank(rhs)
            switch (lhsRank, rhsRank) {
            case (let lhsRank?, let rhsRank?):
                if lhsRank != rhsRank { return lhsRank < rhsRank }
            case (_?, nil):
                return true
            case (nil, _?):
                return false
            case (nil, nil):
                break
            }
            if usesSpaceOrder && lhs.hostID != rhs.hostID {
                if lhs.hostName != rhs.hostName { return lhs.hostName < rhs.hostName }
                return lhs.hostID.uuidString < rhs.hostID.uuidString
            }
            let policy = sortByHost[lhs.hostID] ?? .priority
            if !usesSpaceOrder || policy == .priority {
                let lhsBucket = lhs.agent.status.consoleSortBucket
                let rhsBucket = rhs.agent.status.consoleSortBucket
                if lhsBucket != rhsBucket { return lhsBucket < rhsBucket }
            }
            if lhs.hostName != rhs.hostName { return lhs.hostName < rhs.hostName }
            if lhs.hostID != rhs.hostID {
                return lhs.hostID.uuidString < rhs.hostID.uuidString
            }
            if sortByHost[lhs.hostID] != nil {
                // State sequences are comparable only within their Host.
                if policy == .priority {
                    let lhsSequence = lhs.agent.stateChangeSeq ?? 0
                    let rhsSequence = rhs.agent.stateChangeSeq ?? 0
                    if lhsSequence != rhsSequence { return lhsSequence > rhsSequence }
                }
                let lhsOrder = lhs.snapshotOrder ?? Int.max
                let rhsOrder = rhs.snapshotOrder ?? Int.max
                if lhsOrder != rhsOrder { return lhsOrder < rhsOrder }
            }
            let lhsWorkspace = lhs.workspaceLabel ?? ""
            let rhsWorkspace = rhs.workspaceLabel ?? ""
            if lhsWorkspace != rhsWorkspace { return lhsWorkspace < rhsWorkspace }
            return lhs.agent.paneID < rhs.agent.paneID
        }
    }
}
