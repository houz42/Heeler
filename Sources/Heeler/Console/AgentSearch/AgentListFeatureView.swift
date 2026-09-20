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

    var body: some View {
        HStack(spacing: 8) {
            Text("\(matchCount) of \(totalCount) agents")
                .font(.caption)
                .foregroundStyle(.secondary)
                .accessibilityLabel("\(matchCount) of \(totalCount) agents")
            Spacer(minLength: 8)
            Menu {
                Section("Order") {
                    ForEach(AgentListOrder.allCases) { order in
                        Button {
                            layoutStore.select(order: order)
                        } label: {
                            if layoutStore.order == order {
                                Label(order.label, systemImage: "checkmark")
                            } else {
                                Text(order.label)
                            }
                        }
                    }
                }
                Section("Grouping") {
                    ForEach(AgentListGrouping.allCases) { grouping in
                        Button {
                            layoutStore.select(grouping: grouping)
                        } label: {
                            if layoutStore.grouping == grouping {
                                Label(grouping.label, systemImage: "checkmark")
                            } else {
                                Text(grouping.label)
                            }
                        }
                    }
                }
                Button("Reset list layout", role: .destructive) {
                    layoutStore.reset()
                    onReset()
                }
            } label: {
                HStack(spacing: 4) {
                    Text("\(layoutStore.grouping.label) · \(layoutStore.order.label)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.tertiary)
                }
            }
            .accessibilityLabel("Agent list view options")
            .accessibilityValue("\(layoutStore.grouping.label), \(layoutStore.order.label)")
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
