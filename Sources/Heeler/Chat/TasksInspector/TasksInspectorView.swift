import SwiftUI

// SPDX-License-Identifier: Apache-2.0
//
// The v3 work inspector VIEW (design doc: 'Tasks and subagents').
// READ-ONLY observation: a Tasks tab over the hierarchical
// checklist and the subagent identity rows. Visual language per the
// doc: task rows ≥44pt with 12pt bounded indentation per nesting
// level; subagent rows ≥52pt with a 26pt rounded state icon and two
// text lines; state shown by the LEFT icon ONLY (no redundant
// text-state column) with accessible labels naming the state; task
// marks are read-only, not editable checkboxes; parent disclosure
// and task detail are separate actions.
//
// Entry: `WorkInspectorSheet` presents the tabbed surface; the
// header-menu slice's Tasks/Subagents rows open it (entrypoint kept
// minimal so it lands when that menu merges). The demo route
// `--demo-tasks-inspector` presents the same sheet full-screen with
// a fixture transcript for the capture proof.

// MARK: - The tab model

/// Which inspector tab is showing. Both surfaces (hierarchical
/// checklist rows, subagent identity rows) are READ-ONLY.
enum WorkInspectorTab: String, CaseIterable, Identifiable {
    case tasks
    case subagents

    var id: String { rawValue }

    var title: String {
        switch self {
        case .tasks: "Tasks"
        case .subagents: "Subagents"
        }
    }

    var icon: String {
        switch self {
        case .tasks: "checklist"
        case .subagents: "person.2"
        }
    }
}

/// Collapsed-group state, keyed by STABLE task ID (design: "retain
/// expansion by stable task ID"). Survives content edits.
@MainActor
@Observable
final class WorkInspectorExpansion {
    /// Group IDs whose children are hidden. Absent = expanded —
    /// fresh groups start OPEN (the checklist reads at a glance);
    /// the user opts into collapsing.
    private(set) var collapsedGroupIDs: Set<String> = []

    func isCollapsed(_ groupID: String) -> Bool {
        collapsedGroupIDs.contains(groupID)
    }

    func toggle(_ groupID: String) {
        if !collapsedGroupIDs.insert(groupID).inserted {
            collapsedGroupIDs.remove(groupID)
        }
    }

    /// Rows whose group no longer exists never linger.
    func prune(validGroupIDs: Set<String>) {
        collapsedGroupIDs.formIntersection(validGroupIDs)
    }
}

// MARK: - The visible list model

/// One VISIBLE row — the depth-first walk of the hierarchy honoring
/// collapsed groups. Direct children of a collapsed group are
/// hidden; DESCENDANTS require explicit expansion (a collapsed
/// group hides its whole subtree, an expanded one shows it all the
/// way down — there is no implicit deep expansion).
struct WorkVisibleTaskRow: Identifiable, Sendable, Equatable {
    let task: WorkTask
    /// 0 = a top-level row; +1 per ancestor generation. BOUNDED
    /// (design): deeper ancestry stays available in the detail.
    let depth: Int
    var id: String { task.id }
}

/// The depth-first producer-order walk. Groups always render;
/// their children render only while the group is expanded — and a
/// collapsed group hides its entire subtree (cycle-guarded).
enum WorkVisibleRows {
    static func walk(
        _ tasks: [WorkTask], collapsedGroupIDs: Set<String>
    ) -> [WorkVisibleTaskRow] {
        let byParent = Dictionary(
            grouping: tasks.filter { $0.parentTaskID != nil },
            by: { $0.parentTaskID! })
        var rows: [WorkVisibleTaskRow] = []
        var visited = Set<String>()

        func descend(_ parentID: String, depth: Int) {
            let children = (byParent[parentID] ?? [])
                .sorted { $0.producerOrder < $1.producerOrder }
            for child in children {
                // Cycle guard: a malformed loop renders each node
                // once, never recursing forever.
                guard visited.insert(child.id).inserted else { continue }
                rows.append(WorkVisibleTaskRow(task: child, depth: depth))
                if child.kind == .group,
                    !collapsedGroupIDs.contains(child.id)
                {
                    descend(child.id, depth: depth + 1)
                }
            }
        }

        // Roots first, in producer order; then depth-first.
        let roots = tasks
            .filter { $0.parentTaskID == nil }
            .sorted { $0.producerOrder < $1.producerOrder }
        for root in roots {
            guard visited.insert(root.id).inserted else { continue }
            rows.append(WorkVisibleTaskRow(task: root, depth: 0))
            if root.kind == .group, !collapsedGroupIDs.contains(root.id) {
                descend(root.id, depth: 1)
            }
        }
        return rows
    }

    /// The deepest visible nesting (for the bounded-indentation cap).
    static func maxDepth(of rows: [WorkVisibleTaskRow]) -> Int {
        rows.map(\.depth).max() ?? 0
    }
}

// MARK: - The sheet

/// The read-only work inspector: Tasks and Subagents tabs. Presented
/// as a sheet by the agent header menu (and full-screen by the demo
/// route for captures).
struct WorkInspectorSheet: View {
    /// The conversation's snapshot — derived once by the caller from
    /// the same ChatContent the chat renders.
    let snapshot: WorkInspectorSnapshot
    @State private var selectedTab: WorkInspectorTab = .tasks
    @State private var expansion = WorkInspectorExpansion()

    /// The header menu's one-call entrypoint: present
    /// `WorkInspectorSheet(content:)` with the SAME ChatContent the
    /// chat surface renders — the snapshot derives inside.
    init(content: ChatContent) {
        self.snapshot = WorkInspectorSnapshotBuilder.build(from: content)
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Picker("Work inspector section", selection: $selectedTab) {
                    ForEach(WorkInspectorTab.allCases) { tab in
                        Label(tab.title, systemImage: tab.icon)
                            .tag(tab)
                    }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal, 16)
                .padding(.vertical, 10)

                switch selectedTab {
                case .tasks:
                    WorkTasksList(
                        snapshot: snapshot, expansion: expansion)
                case .subagents:
                    WorkSubagentsList(snapshot: snapshot)
                }
            }
            .navigationTitle("Work inspector")
            .navigationBarTitleDisplayMode(.inline)
        }
    }
}

// MARK: - The Tasks tab

/// The hierarchical checklist. Empty/unsupported/not-loaded each
/// render their OWN honest state (design: "queried-empty differs
/// from not loaded"; relevant unsupported capabilities show a
/// reason).
struct WorkTasksList: View {
    let snapshot: WorkInspectorSnapshot
    @Bindable var expansion: WorkInspectorExpansion
    @State private var selectedTask: WorkTask?

    var body: some View {
        Group {
            switch snapshot.taskObservation {
            case .notLoaded:
                WorkInspectorNotice(
                    icon: "circle.slash", title: "Not loaded",
                    detail: "The transcript hasn't been read yet — no task list was queried.")
            case .empty:
                WorkInspectorNotice(
                    icon: "tray", title: "No tasks",
                    detail: "The agent's todo list is empty or cleared — nothing is open.")
            case .unsupported(let reason):
                WorkInspectorNotice(
                    icon: "questionmark.square", title: "Task list unavailable",
                    detail: reason)
            case .loaded:
                list
            }
        }
    }

    private var list: some View {
        let visibleRows = WorkVisibleRows.walk(
            snapshot.tasks, collapsedGroupIDs: expansion.collapsedGroupIDs)
        let progress = snapshot.leafProgress
        return List {
            Section {
                // Leaf-only totals (design: never count both parent
                // and children). Read-only marks, never checkboxes.
                Text(verbatim: progress.summaryLine)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .accessibilityLabel(accessibilityProgress(progress))
                    .listRowSeparator(.hidden)
            }
            Section {
                ForEach(visibleRows) { row in
                    WorkTaskRow(
                        row: row,
                        hasChildren: snapshot.tasks.contains {
                            $0.parentTaskID == row.task.id
                        },
                        isCollapsed: expansion.isCollapsed(row.task.id),
                        toggle: {
                            expansion.toggle(row.task.id)
                        },
                        showDetail: { selectedTask = row.task })
                }
            }
        }
        .listStyle(.insetGrouped)
        .sheet(item: $selectedTask) { task in
            WorkTaskDetailSheet(task: task)
        }
        .onAppear {
            expansion.prune(
                validGroupIDs: Set(
                    snapshot.tasks.filter { $0.kind == .group }.map(\.id)))
        }
    }

    private func accessibilityProgress(
        _ progress: WorkInspectorSnapshot.LeafProgress
    ) -> String {
        var parts = [
            "\(progress.completed) of \(progress.total) tasks completed"
        ]
        if progress.blocked > 0 {
            parts.append("\(progress.blocked) blocked")
        }
        if progress.inProgress > 0 {
            parts.append("\(progress.inProgress) in progress")
        }
        return parts.joined(separator: ", ")
    }
}

/// One hierarchical checklist row: the left state icon is the ONLY
/// visible state carrier; the accessible label names the state.
/// ≥44pt, 12pt bounded indentation per nesting level. Read-only
/// (never an editable checkbox). Parent disclosure (chevron) and
/// task detail (row tap) are SEPARATE actions.
struct WorkTaskRow: View {
    let row: WorkVisibleTaskRow
    let hasChildren: Bool
    let isCollapsed: Bool
    let toggle: () -> Void
    let showDetail: () -> Void

    /// Design: bounded indentation — 12pt per level, capped so deep
    /// ancestry never pushes content off-screen.
    private var indentLevel: Int {
        min(row.depth, 3)
    }

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            // Left state icon ONLY — no redundant text-state column.
            Image(systemName: row.task.state.iconSystemName)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(iconColor)
                .frame(width: 24, alignment: .center)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: row.task.title)
                    .font(.body)
                    .lineLimit(2)
                if row.task.kind != .group, let detail = row.task.detail {
                    Text(verbatim: detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 0)

            if row.task.kind == .group, hasChildren {
                // Parent disclosure is its OWN a11y action, separate
                // from the row's detail action (design: "Parent
                // disclosure and task detail are separate actions").
                Button(action: toggle) {
                    Image(systemName: "chevron.right")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(isCollapsed ? 0 : 90))
                        .contentShape(Rectangle())
                        .padding(6)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(
                    isCollapsed
                        ? "Expand group"
                        : "Collapse group")
            }
        }
        .frame(minHeight: 44)
        .padding(.leading, CGFloat(indentLevel * 12))
        .contentShape(Rectangle())
        .onTapGesture(perform: showDetail)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityHint("Shows task details")
        .accessibilityAddTraits(.isButton)
    }



    private var iconColor: Color {
        switch row.task.state {
        case .completed: .green
        case .inProgress: .orange
        case .blocked: .red
        case .pending, .cancelled, .unknown: .secondary
        }
    }

    private var accessibilityLabel: String {
        var parts: [String] = [row.task.title]
        parts.append(row.task.state.accessibilityName)
        if let detail = row.task.detail {
            parts.append(detail)
        }
        if row.task.kind == .group {
            parts.append("group")
            parts.append(isCollapsed ? "collapsed" : "expanded")
        }
        return parts.joined(separator: ", ")
    }
}

// MARK: - Task detail

/// Expanded row details (design: "Expand rows for full details").
/// Read-only; names the state explicitly and shows the producer's
/// detail (blocked reason) plus deeper ancestry when indentation
/// was capped.
struct WorkTaskDetailSheet: View {
    let task: WorkTask
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section("State") {
                    Label(
                        task.state.accessibilityName,
                        systemImage: task.state.iconSystemName)
                    if let detail = task.detail {
                        Text(verbatim: detail)
                    }
                }
                Section("Task") {
                    Text(verbatim: task.title)
                }
            }
            .navigationTitle("Task")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}

// MARK: - The Subagents tab

/// The subagent identity rows (design: "a distinct compact two-line
/// identity row with name and assigned-work subtitle; their LEFT
/// rounded icon also identifies runtime state, with no right-side
/// text-state badge"). Runtime state and result verdict are shown
/// as SEPARATE things — both honestly Unknown/Not reported for
/// transcript-observed children.
struct WorkSubagentsList: View {
    let snapshot: WorkInspectorSnapshot

    var body: some View {
        Group {
            switch snapshot.subagentObservation {
            case .notLoaded:
                WorkInspectorNotice(
                    icon: "circle.slash", title: "Not loaded",
                    detail: "The transcript hasn't been read yet — no subagent spawns were queried.")
            case .empty:
                WorkInspectorNotice(
                    icon: "tray", title: "No subagents",
                    detail: "The agent hasn't spawned any background children in this conversation.")
            case .unsupported(let reason):
                WorkInspectorNotice(
                    icon: "questionmark.square", title: "Subagents unavailable",
                    detail: reason)
            case .loaded:
                List(snapshot.subagents) { subagent in
                    WorkSubagentRow(subagent: subagent)
                }
                .listStyle(.insetGrouped)
            }
        }
    }
}

/// One subagent identity row: ≥52pt, 26pt rounded LEFT state icon,
/// two text lines (display name + assigned work). The icon carries
/// the runtime state; the verdict renders in the DETAIL only
/// (never a right-side text badge).
struct WorkSubagentRow: View {
    let subagent: WorkSubagent
    @State private var showsDetail = false

    var body: some View {
        Button {
            showsDetail = true
        } label: {
            HStack(alignment: .center, spacing: 12) {
                Image(systemName: subagent.runtimeState.iconSystemName)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 26, height: 26)
                    .background(
                        Circle().fill(Color.secondary.opacity(0.12)))
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(verbatim: subagent.displayName)
                            .font(.body.weight(.medium))
                            .lineLimit(1)
                        Text(verbatim: subagent.kind)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(
                                Capsule().fill(Color.secondary.opacity(0.1)))
                    }
                    Text(verbatim: subagent.assignedWork)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                Spacer(minLength: 0)
            }
            .frame(minHeight: 52)
        }
        .buttonStyle(.plain)
        .sheet(isPresented: $showsDetail) {
            WorkSubagentDetailSheet(subagent: subagent)
        }
        .accessibilityLabel(accessibilityLabel)
        .accessibilityHint("Shows subagent details")
    }

    private var accessibilityLabel: String {
        var parts: [String] = [
            subagent.displayName, subagent.kind,
            "assigned: \(subagent.assignedWork)",
        ]
        parts.append("runtime state: \(subagent.runtimeState.accessibilityName)")
        parts.append(
            "result: \(subagent.resultVerdict?.accessibilityName ?? "Not reported")")
        return parts.joined(separator: ", ")
    }
}

/// Subagent details: runtime state and result verdict as SEPARATE
/// lines (design: "Runtime completion and result acceptance are
/// different fields"). An unobservable runtime state shows the
/// honest unsupported note — no fabricated conversation action.
struct WorkSubagentDetailSheet: View {
    let subagent: WorkSubagent
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section("Runtime state") {
                    Label(
                        subagent.runtimeState.accessibilityName,
                        systemImage: subagent.runtimeState.iconSystemName)
                    if let note = subagent.runtimeStateNote {
                        Text(verbatim: note)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
                Section("Result verdict") {
                    Label(
                        subagent.resultVerdict?.accessibilityName
                            ?? "Not reported",
                        systemImage: subagent.resultVerdict == nil
                            ? "minus.circle" : "checkmark.seal")
                    Text(verbatim: subagent.spawnAcknowledged
                        ? "The spawn was acknowledged by the producer."
                        : "The spawn acknowledgment hasn't arrived in this transcript yet.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                Section("Assignment") {
                    Text(verbatim: subagent.assignedWork)
                }
            }
            .navigationTitle(subagent.displayName)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}

// MARK: - Honest empty states

/// The shared notice for not-loaded / empty / unsupported. The
/// design's distinction: queried-empty ≠ not loaded; unsupported
/// shows the reason.
struct WorkInspectorNotice: View {
    let icon: String
    let title: String
    let detail: String

    var body: some View {
        ContentUnavailableView {
            Label(title, systemImage: icon)
        } description: {
            Text(verbatim: detail)
        }
    }
}
