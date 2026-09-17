import SwiftUI

// SPDX-License-Identifier: Apache-2.0
//
// The chat surface's ONLY chrome: a thin status strip (agent name + state +
// host/workspace badge slot) carrying the persistent detail-level switcher.
// Never a modal — the level is always visible and one tap away.

/// The agent state shown in the status strip.
internal enum ChatAgentState: String, Sendable {
    case idle
    case running
    case blocked   // pending interaction awaiting an answer
    case offline
}

/// Thin status strip pinned above the full-bleed chat. The level switcher
/// lives here so switching detail level never interrupts reading.
struct ChatStatusStrip: View {
    let agentName: String
    let state: ChatAgentState
    let level: DetailLevel
    let changeLevel: (DetailLevel) -> Void
    /// Extra chrome pinned at the strip's trailing edge, before the level
    /// switcher (the surface picker lives here). Nil = no slot.
    var accessory: AnyView? = nil


    private static let stateLabels: [ChatAgentState: String] = [
        .idle: "Idle",
        .running: "Running",
        .blocked: "Blocked",
        .offline: "Offline",
    ]

    var body: some View {
        HStack(spacing: 8) {
            HStack(spacing: 6) {
                Circle()
                    .fill(stateColor)
                    .frame(width: 8, height: 8)
                Text(agentName)
                    .lineLimit(1)
                Text(Self.stateLabels[state] ?? state.rawValue)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .truncationMode(.tail)
            .accessibilityElement(children: .combine)

            Spacer(minLength: 4)

            if let accessory {
                accessory
            }

            DetailLevelSwitcher(level: level, changeLevel: changeLevel)
        }
        .font(.caption)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.bar)
    }

    private var stateColor: Color {
        switch state {
        case .idle: .secondary
        case .running: .green
        case .blocked: .orange
        case .offline: .red
        }
    }
}

/// The persistent, non-modal level control: a compact menu (segmented would
/// burn 4× its width in the strip at large type sizes). The current level is
/// always readable; the rest are one tap away.
struct DetailLevelSwitcher: View {
    let level: DetailLevel
    let changeLevel: (DetailLevel) -> Void

    private static let labels: [DetailLevel: String] = [
        .l0: "Text",
        .l1: "Tools",
        .l2: "Results",
        .l3: "Thinking",
    ]

    /// One icon per level; the bar shows the CURRENT level's icon, so the
    /// control is one glyph wide and still reads its state.
    private static let icons: [DetailLevel: String] = [
        .l0: "text.alignleft",
        .l1: "hammer",
        .l2: "tray.full",
        .l3: "brain.head.profile",
    ]

    /// Longer explanations in the menu itself, so the trade-off of each level
    /// is discoverable at the point of choice.
    private static let hints: [DetailLevel: String] = [
        .l0: "Assistant text only",
        .l1: "Tool names",
        .l2: "Tool results & diffs",
        .l3: "Thinking blocks",
    ]

    /// The system Menu can't tint a selection or shrink its rows, so the
    /// switcher is a custom card: the floating button shows the current
    /// level's icon; the card lists every level with ITS OWN icon (selection
    /// reads as a tinted background, never a checkmark that steals the icon).
    @State private var expanded = false

    var body: some View {
        Button {
            withAnimation(.easeOut(duration: 0.15)) { expanded.toggle() }
        } label: {
            Image(systemName: Self.icons[level]!)
                .font(.subheadline)
                .frame(width: 36, height: 36)
                .background(.ultraThinMaterial, in: Circle())
                .shadow(radius: 2, y: 1)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Detail level: \(Self.labels[level]!)")
        .popover(
            isPresented: $expanded,
            attachmentAnchor: .point(.top),
            arrowEdge: .bottom
        ) {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(DetailLevel.allCases, id: \.rawValue) { candidate in
                    Button {
                        changeLevel(candidate)
                        expanded = false
                    } label: {
                        let selected = candidate == level
                        HStack(spacing: 8) {
                            Image(systemName: Self.icons[candidate]!)
                                .frame(width: 18)
                            VStack(alignment: .leading, spacing: 0) {
                                Text(Self.labels[candidate]!)
                                    .font(.caption.weight(.medium))
                                Text(Self.hints[candidate]!)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                        }
                        // Selection reads as accent-colored icon + label —
                        // no background rectangle to fight the popover card's
                        // system-drawn corner radius.
                        .foregroundStyle(selected ? Color.accentColor : Color.primary)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .presentationCompactAdaptation(.popover)
        }
    }
}
