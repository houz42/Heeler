import SwiftUI

// SPDX-License-Identifier: Apache-2.0
//
// The Agents list region (approved redesign, handoff §B): search bar,
// result count + the ordering/grouping view menu (Agents view menu ONLY,
// never Settings), the rows/sections themselves, and the empty state.
// ConsoleView consumes this; navigation scaffolding stays in ConsoleView
// (the NAV slice's lane).

/// The count line + ordering/grouping menu, one compact bar at the list
/// top. "3 of 5 agents" reflects filtered matches.
struct AgentListCountBarView: View {
    let matchCount: Int
    let totalCount: Int
    @Bindable var layoutStore: AgentListLayoutStore
    let onReset: () -> Void
    enum ViewSheet: Identifiable {
        case view
        var id: String { "view" }
    }
    @State private var viewSheet: ViewSheet?

    var body: some View {
        HStack(spacing: 8) {
            Text("\(matchCount) of \(totalCount) agents")
                .font(.caption)
                .foregroundStyle(.secondary)
                .accessibilityLabel("\(matchCount) of \(totalCount) agents")
            Spacer(minLength: 8)
            // The approved view sheet (user device finding): the system
            // Menu was an ugly tall card — the design is a compact SHEET
            // cascade: 'Agent list view' with two setting-style rows
            // (Order, Grouping) each opening its own chooser; one tap
            // selects, applies, and closes.
            Button {
                viewSheet = .view
            } label: {
                HStack(spacing: 4) {
                    // The design's .agent-list-viewbar: color var(--accent)
                    // — the accent green, not muted (v2 directive).
                    Text("\(layoutStore.grouping.label) · \(layoutStore.order.label)")
                        .font(.caption)
                        .foregroundStyle(Color.accentColor)
                        .lineLimit(1)
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(Color.accentColor)
                }
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Agent list view options")
            .accessibilityValue("\(layoutStore.grouping.label), \(layoutStore.order.label)")
            .sheet(item: $viewSheet) { _ in
                AgentListViewSheet(
                    layoutStore: layoutStore,
                    onReset: onReset,
                    onClose: { viewSheet = nil })
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
    }
}

/// One collapsible group header of the grouped Agents list: chevron, title,
/// the full parent identity as a quiet line, and the matching count.
struct AgentListGroupHeaderView: View {
    let section: AgentListSection
    let isCollapsed: Bool
    let onToggle: () -> Void

    var body: some View {
        Button(action: onToggle) {
            HStack(spacing: 8) {
                Image(systemName: isCollapsed ? "chevron.right" : "chevron.down")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 12, alignment: .center)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 1) {
                    Text(section.title)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    if !section.parentLine.isEmpty {
                        Text(section.parentLine)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 8)
                Text("\(section.count)")
                    .font(.caption2.monospacedDigit().weight(.semibold))
                    .foregroundStyle(.secondary)
                    .fixedSize()
            }
            .contentShape(Rectangle())
            .padding(.vertical, 4)
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(section.title), \(section.count) agents")
        .accessibilityValue(isCollapsed ? "Collapsed" : "Expanded")
        .accessibilityHint(isCollapsed ? "Expands this group." : "Collapses this group.")
        .accessibilityAddTraits(.isHeader)
    }
}

/// The approved quick-state chips (user device finding): All / Needs you /
/// Working, trailing of the count row. A chip is SELECTED iff the search
/// model holds a state: filter with that value ("All" iff none). Tapping
/// Needs you/Working sets the state filter to exactly that value;
/// tapping All removes every state filter. They ride the SAME filter
/// model as typed state: chips — both surfaces agree by construction.
/// "Needs you is a filter, not a permanent reorder": rows keep the
/// chosen sort.
struct AgentQuickStateChips: View {
    @Bindable var searchStore: AgentSearchBarStore

    /// The quick labels map onto the state filter's search values.
    private var activeStateValues: Set<String> {
        Set(searchStore.engine.filters
            .filter { $0.field == .state }
            .map { AgentFuzzyMatcher.normalize($0.value) })
    }

    private func isSelected(_ label: String) -> Bool {
        activeStateValues.contains(AgentFuzzyMatcher.normalize(label))
    }

    private var allSelected: Bool {
        activeStateValues.isEmpty
    }

    private func setQuickState(_ label: String) {
        if label == "All" {
            // Remove every state filter.
            for filter in searchStore.engine.filters where filter.field == .state {
                searchStore.removeFilter(filter)
            }
        } else {
            // Single-state quick filter: replaces any other state value.
            searchStore.setQuickStateFilter(label)
        }
    }

    var body: some View {
        HStack(spacing: 6) {
            ForEach(["All", "Needs you", "Working"], id: \.self) { label in
                Button {
                    setQuickState(label)
                } label: {
                    Text(label)
                        .font(.caption.weight(.medium))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(
                            isSelected(label) || (label == "All" && allSelected)
                                ? Color.accentColor.opacity(0.15)
                                : Color(.tertiarySystemFill),
                            in: Capsule())
                        .foregroundStyle(
                            isSelected(label) || (label == "All" && allSelected)
                                ? Color.primary
                                : Color.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(label) filter")
                .accessibilityAddTraits(
                    isSelected(label) || (label == "All" && allSelected)
                        ? [.isSelected] : [])
            }
        }
    }
}

/// The approved 'Agent list view' sheet (user device finding): exactly two
/// setting-style rows — Order and Grouping, each with its current value and
/// a trailing chevron opening its own chooser — the quiet note, and the
/// Reset action. Compact like the design's card, not a 10-row menu.
struct AgentListViewSheet: View {
    enum Page {
        case root, order, grouping
    }

    @Bindable var layoutStore: AgentListLayoutStore
    let onReset: () -> Void
    /// Closes the presentation via the owner's binding — @Environment
    /// dismiss from inside the content races the presenting view on
    /// re-presentation; the binding round-trips cleanly.
    let onClose: () -> Void
    @State private var page: Page = .root

    var body: some View {
        NavigationStack {
            Group {
                switch page {
                case .root: rootPage
                case .order:
                    AgentListChooserList(
                        title: "Order agents",
                        options: AgentListOrder.allCases.map { (label: $0.label, description: $0.description) },
                        selected: layoutStore.order.label,
                        note: "Controls row order within each group.")
                    { selected in
                        if let order = AgentListOrder.allCases.first(where: { $0.label == selected }) {
                            layoutStore.select(order: order)
                        }
                        // Choice applies immediately and returns to the
                        // parent sheet's root (the sanctioned Back-to-
                        // parent flow; Done closes everything) — also
                        // sidesteps the iOS 27 re-presentation flake.
                        page = .root
                    }
                case .grouping:
                    AgentListChooserList(
                        title: "Group agents",
                        options: AgentListGrouping.allCases.map { (label: $0.label, description: $0.description) },
                        selected: layoutStore.grouping.label,
                        note: "Keep each agent's full location visible.")
                    { selected in
                        if let grouping = AgentListGrouping.allCases.first(where: { $0.label == selected }) {
                            layoutStore.select(grouping: grouping)
                        }
                        page = .root
                    }
                }
            }
            .navigationTitle(page == .root ? "Agent list view" : (page == .order ? "Order agents" : "Group agents"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    if page == .root {
                        Button("Done") { onClose() }
                    } else {
                        Button("Back") { page = .root }
                    }
                }
            }
        }
    }

    private var rootPage: some View {
        List {
            Button {
                page = .order
            } label: {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Order")
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(.primary)
                        Text(layoutStore.order.description)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Text(layoutStore.order.label)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.tertiary)
                }
            }
            .buttonStyle(.plain)
            .contentShape(Rectangle())
            .accessibilityLabel("Order")
            .accessibilityValue(layoutStore.order.label)

            Button {
                page = .grouping
            } label: {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Grouping")
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(.primary)
                        Text(layoutStore.grouping.description)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Text(layoutStore.grouping.label)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.tertiary)
                }
            }
            .buttonStyle(.plain)
            .contentShape(Rectangle())
            .accessibilityLabel("Grouping")
            .accessibilityValue(layoutStore.grouping.label)

            Section {
                Text(
                    "Search and context filters apply before grouping. "
                        + "Group counts show matching agents only.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Button("Reset list layout", role: .destructive) {
                layoutStore.reset()
                onReset()
                onClose()
            }
            .buttonStyle(.borderless)
        }
    }
}

/// One chooser page: the choices with the current one marked; one tap
/// selects, applies immediately, and closes the whole sheet.
struct AgentListChooserList: View {
    let title: String
    let options: [(label: String, description: String)]
    let selected: String
    let note: String
    let onSelect: (String) -> Void

    var body: some View {
        List {
            Text(note)
                .font(.caption)
                .foregroundStyle(.secondary)
            ForEach(options, id: \.label) { option in
                // A tap row (not a List-row Button — plain-styled row
                // buttons swallow taps inside iOS 27 sheets): the same
                // pattern the suggestion list uses.
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(option.label)
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(.primary)
                        Text(option.description)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    if option.label == selected {
                        Image(systemName: "checkmark")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(Color.accentColor)
                    }
                }
                .padding(.vertical, 6)
                .contentShape(Rectangle())
                .onTapGesture { onSelect(option.label) }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(option.label)
                .accessibilityValue(option.description)
                .accessibilityAddTraits(
                    option.label == selected ? [.isButton, .isSelected] : [.isButton])
                .accessibilityHint("Applies this choice.")
            }
        }
    }
}

