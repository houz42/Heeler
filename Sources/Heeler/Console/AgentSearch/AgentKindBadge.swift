import SwiftUI

// SPDX-License-Identifier: Apache-2.0
//
// The agent kind icon at the row's leading edge (user addendum, superseding
// revision + review rework): it replaces the old task-initial avatar
// entirely. The kind resolves ONLY from the snapshot's runtime metadata
// (`Agent.kind`, herdr's detected agent program), never from the title; the
// human-readable name stays in the accessibility label. The three CORE
// runtimes render the user-approved prototype glyphs (π / angle brackets /
// sunburst, ported 1:1 in AgentKindGlyphs); the long tail uses neutral SF
// Symbols; unrecognized kinds get the neutral fallback. Never a guessed
// value and never an avatar initial.

/// Pure presentation for the kind badge, so what the row renders and what
/// VoiceOver reads stay unit-testable.
struct AgentKindBadgeModel: Equatable, Sendable {
    /// The snapshot's agent kind, verbatim (`Agent.kind`).
    let kind: String
    /// The approved prototype glyph for the three core runtimes
    /// (omp→π, codex→brackets, claude→sunburst); nil for every other kind.
    let glyph: AgentKindGlyph?
    /// SF Symbol name for the badge; the neutral fallback for unrecognized
    /// kinds, and the long-tail set for kinds without a prototype mark.
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
        glyph = Self.glyph(for: kind)
        systemImage = Self.symbol(for: kind)
        accessibilityLabel = known?.displayName ?? kind
    }

    init(agent: ConsoleAgent) {
        self.init(kind: agent.agent.kind)
    }

    /// The user-approved prototype marks for the core runtimes; ported
    /// 1:1 from the design's SVG geometry (see AgentKindGlyphs).
    private static func glyph(for kind: String) -> AgentKindGlyph? {
        switch SupportedAgentKind(rawValue: kind.lowercased()) {
        case .pi, .omp, .opencode: .pi
        case .codex, .copilot: .brackets
        case .claude: .sunburst
        default: nil
        }
    }

    /// The long-tail symbol set: neutral SF Symbols for kinds without a
    /// prototype mark. The symbols describe the runtime family, not any
    /// vendor's brand; no brand assets ship with the app.
    private static func symbol(for kind: String) -> String {
        guard let supported = SupportedAgentKind(rawValue: kind.lowercased()) else {
            return fallbackSystemImage
        }
        switch supported {
        case .pi, .omp, .opencode: return "infinity"
        case .claude: return "sun.max"
        case .codex, .copilot: return "chevron.left.forwardslash.chevron.right"
        case .gemini, .qwen: return "sparkles"
        case .cursor: return "plus.forwardslash.minus"
        case .devin: return "wand.and.stars"
        case .antigravity: return "globe"
        case .cline, .kilo: return "bolt"
        case .mastracode: return "shippingbox"
        case .kimi: return "moon"
        case .kiro: return "lightbulb"
        case .droid, .amp: return "cpu"
        case .grok: return "xmark.circle"
        case .hermes: return "paperplane"
        case .qodercli, .maki, .muse: return "square.stack.3d.up"
        }
    }
}

/// The leading kind icon. Fixed square footprint (28 pt) so rows align; the
/// runtime name rides the accessibility label and the tooltip. Core
/// runtimes draw their approved prototype glyph; the rest their symbol.
struct AgentKindBadgeIcon: View {
    let model: AgentKindBadgeModel
    /// Set on tree rows: the row's depth padding already separates the icon
    /// from the edge.
    var omitsLeadingPadding = false

    @ViewBuilder
    private var icon: some View {
        if let glyph = model.glyph {
            AgentKindGlyphView(glyph: glyph)
        } else {
            Image(systemName: model.systemImage)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(Color.secondary)
                .frame(width: 21, height: 21)
                .accessibilityHidden(true)
        }
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
    /// The Agent.kind fallback (herdr reports "unknown" when it cannot
    /// detect the program): the neutral icon, never a guessed name.
    static let unknownKindLabel = "unknown"
}
