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

    /// Longer explanations in the menu itself, so the trade-off of each level
    /// is discoverable at the point of choice.
    private static let hints: [DetailLevel: String] = [
        .l0: "Assistant text only",
        .l1: "Tool names",
        .l2: "Tool results & diffs",
        .l3: "Thinking blocks",
    ]

    var body: some View {
        Menu {
            ForEach(DetailLevel.allCases, id: \.rawValue) { candidate in
                Button {
                    changeLevel(candidate)
                } label: {
                    if candidate == level {
                        Label(Self.labels[candidate]!, systemImage: "checkmark")
                    } else {
                        Text("\(Self.labels[candidate]!) — \(Self.hints[candidate]!)")
                    }
                }
            }
        } label: {
            HStack(spacing: 3) {
                Image(systemName: "line.3.horizontal.decrease")
                    .imageScale(.small)
                Text(Self.labels[level]!)
            }
        }
        .menuIndicator(.hidden)
        .buttonStyle(.borderless)
        .accessibilityLabel("Detail level: \(Self.labels[level]!)")
    }
}
