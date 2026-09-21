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

    /// The user-approved prototype marks, scoped to the runtimes the
    /// design drew them for (review finding #7): omp/pi get the π,
    /// codex the brackets, claude the sunburst. Every OTHER kind —
    /// including the pi-family's opencode and the codex-adjacent
    /// copilot — renders its distinct neutral symbol.
    private static func glyph(for kind: String) -> AgentKindGlyph? {
        switch SupportedAgentKind(rawValue: kind.lowercased()) {
        case .pi, .omp: .pi
        case .codex: .brackets
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
        case .pi, .omp: return "infinity"
        case .opencode: return "curlybraces"
        case .claude: return "sun.max"
        case .codex: return "chevron.left.forwardslash.chevron.right"
        case .copilot: return "airplane"
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

/// The leading kind icon: the approved accent TILE (soft wash, rounded
    /// rect, 30pt) with the kind's glyph — the prototype marks for the core
    /// runtimes, neutral symbols for the long tail. The runtime name rides
    /// the accessibility label and the tooltip.
struct AgentKindBadgeIcon: View {
    let model: AgentKindBadgeModel
    /// Set on tree rows: the row's depth padding already separates the icon
    /// from the edge.
    var omitsLeadingPadding = false

    @ViewBuilder
    private var icon: some View {
        // The tile IS the design; the glyph is the kind (visual follow-up):
        // ALL kinds render inside the approved accent tile — the three
        // prototype marks and the neutral symbol fallbacks alike.
        if let glyph = model.glyph {
            AgentKindGlyphView(glyph: glyph)
        } else {
            Image(systemName: model.systemImage)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(Color(AgentKindTilePalette.accent))
                .padding(4)
                .frame(width: 30, height: 30)
                .background(
                    Color(AgentKindTilePalette.wash),
                    in: RoundedRectangle(cornerRadius: 8))
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
