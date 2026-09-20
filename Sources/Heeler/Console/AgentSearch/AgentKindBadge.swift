import SwiftUI

// SPDX-License-Identifier: Apache-2.0
//
// The agent kind icon at the row's leading edge (user addendum, superseding
// revision): it replaces the old task-initial avatar entirely. The kind
// resolves ONLY from the snapshot's runtime metadata (`Agent.kind`, herdr's
// detected agent program), never from the title; the human-readable name
// stays in the accessibility label. No brand assets ship in this app, so
// the icon set is SF Symbols only, with one neutral fallback for kinds this
// build has no symbol for. Never a guessed value and never an avatar
// initial.

/// Pure presentation for the kind badge, so what the row renders and what
/// VoiceOver reads stay unit-testable.
struct AgentKindBadgeModel: Equatable, Sendable {
    /// The snapshot's agent kind, verbatim (`Agent.kind`).
    let kind: String
    /// SF Symbol name for the badge; the neutral fallback for unrecognized
    /// kinds.
    let systemImage: String
    /// The runtime name VoiceOver reads ("Claude Code", "Codex", "OMP", …),
    /// from the supported-kinds catalog when it knows the kind, otherwise
    /// the raw snapshot kind. Never guessed.
    let accessibilityLabel: String
    /// True when the kind is one this build's catalog recognizes.
    let isRecognized: Bool

    static let fallbackSystemImage = "circlebadge.2"

    init(kind: String) {
        self.kind = kind
        let known = SupportedAgentKind(rawValue: kind.lowercased())
        isRecognized = known != nil
        systemImage = Self.symbol(for: kind)
        accessibilityLabel = known?.displayName ?? kind
    }

    init(agent: ConsoleAgent) {
        self.init(kind: agent.agent.kind)
    }

    /// One neutral, recognizable SF Symbol per supported kind. The symbols
    /// describe the runtime family, not any vendor's brand: no brand marks
    /// ship with the app. Distinct symbols for the kinds the user runs
    /// today; shared shapes only between kinds that genuinely read alike.
    private static func symbol(for kind: String) -> String {
        guard let supported = SupportedAgentKind(rawValue: kind.lowercased()) else {
            return fallbackSystemImage
        }
        switch supported {
        case .pi, .omp, .opencode: "infinity"
        case .claude: "sun.max"
        case .codex, .copilot: "chevron.left.forwardslash.chevron.right"
        case .gemini, .qwen: "sparkles"
        case .cursor: "plus.forwardslash.minus"
        case .devin: "wand.and.stars"
        case .antigravity: "globe"
        case .cline, .kilo: "bolt"
        case .mastracode: "shippingbox"
        case .kimi: "moon"
        case .kiro: "lightbulb"
        case .droid, .amp: "cpu"
        case .grok: "xmark.circle"
        case .hermes: "paperplane"
        case .qodercli, .maki, .muse: "square.stack.3d.up"
        }
    }
}

/// The leading kind icon. Fixed square footprint (28 pt) so rows align; the
/// runtime name rides the accessibility label and the tooltip.
struct AgentKindBadgeIcon: View {
    let model: AgentKindBadgeModel
    /// Set on tree rows: the row's depth padding already separates the icon
    /// from the edge.
    var omitsLeadingPadding = false

    private var icon: some View {
        Image(systemName: model.systemImage)
            .font(.system(size: 15, weight: .medium))
            .foregroundStyle(Color.secondary)
            .frame(width: 21, height: 21)
            .accessibilityHidden(true)
    }

    var body: some View {
        icon
            .padding(.leading, omitsLeadingPadding ? 0 : 6)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(model.accessibilityLabel)
            .accessibilityAddTraits(.isStaticText)
            .help(model.accessibilityLabel)
    }
}

extension AgentKindBadgeModel {
    /// A "kind: value" string with the fallback for missing values.
    static let unknownKindLabel = "unknown"

    init(kind: String?) {
        self.init(kind: kind ?? Self.unknownKindLabel)
    }
}
