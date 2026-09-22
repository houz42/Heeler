import SwiftUI

// SPDX-License-Identifier: Apache-2.0
//
// The three kind glyphs the user approved in the design prototype
// (agent-layout.js), ported 1:1 from its SVG path geometry: omp's π mark,
// Codex's angle brackets with the slash motif, Claude Code's sunburst.
// 24×24 coordinate space, stroke-width 1.6, round caps — the prototype's
// exact drawing parameters. The long tail of kinds (gemini, cursor, …)
// keeps its SF Symbol set; these three marks are the core runtimes.

/// Which approved prototype glyph a kind renders. `nil` kinds render their
/// SF Symbol from the long-tail set.
enum AgentKindGlyph: Equatable, Sendable {
    /// omp (and the pi/opencode family): the prototype's stylized π.
    case pi
    /// Codex (and copilot): the prototype's angle brackets + slash.
    case brackets
    /// Claude Code: the prototype's radial sunburst.
    case sunburst
}

/// One approved glyph as a stroke path in 24×24 coordinates.
struct AgentKindGlyphShape: Shape {
    let glyph: AgentKindGlyph

    func path(in rect: CGRect) -> Path {
        // The prototype draws in a 24×24 viewBox; scale into the frame.
        let sx = rect.width / 24
        let sy = rect.height / 24
        func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            CGPoint(x: x * sx, y: y * sy)
        }
        var path = Path()
        switch glyph {
        case .pi:
            // M5 7h14 M9 7v10 m7-10v8q0 3 3 2 — bar, left leg, curved right leg.
            path.move(to: point(5, 7))
            path.addLine(to: point(19, 7))
            path.move(to: point(9, 7))
            path.addLine(to: point(9, 17))
            path.move(to: point(16, 7))
            path.addLine(to: point(16, 15))
            path.addQuadCurve(to: point(19, 17), control: point(16, 18))
        case .brackets:
            // m8 6-5 6 5 6m8-12 5 6-5 6m-3-14-2 16 — <, >, and the slash.
            path.move(to: point(8, 6))
            path.addLine(to: point(3, 12))
            path.addLine(to: point(8, 18))
            path.move(to: point(16, 6))
            path.addLine(to: point(21, 12))
            path.addLine(to: point(16, 18))
            path.move(to: point(13, 4))
            path.addLine(to: point(11, 20))
        case .sunburst:
            // M12 3v18 M3 12h18 + two long diagonals + four shorter spokes.
            path.move(to: point(12, 3))
            path.addLine(to: point(12, 21))
            path.move(to: point(3, 12))
            path.addLine(to: point(21, 12))
            path.move(to: point(5.6, 5.6))
            path.addLine(to: point(18.4, 18.4))
            path.move(to: point(5.6, 18.4))
            path.addLine(to: point(18.4, 5.6))
            path.move(to: point(8.5, 3.7))
            path.addLine(to: point(15.5, 20.3))
            path.move(to: point(3.7, 8.5))
            path.addLine(to: point(20.3, 15.5))
            path.move(to: point(3.7, 15.5))
            path.addLine(to: point(20.3, 8.5))
            path.move(to: point(8.5, 20.3))
            path.addLine(to: point(15.5, 3.7))
        }
        return path
    }
}

/// The glyph as rendered: the approved TILE — soft accent wash background,
/// accent glyph, rounded-rect container (prototype: wash #eaf2ed, glyph
/// #22644d; dark pair in AgentStatusPalette). 1.6 stroke at the
/// prototype's weight, round caps. Dynamic Type scales the slot.
struct AgentKindGlyphView: View {
    let glyph: AgentKindGlyph

    var body: some View {
        AgentKindGlyphShape(glyph: glyph)
            .stroke(
                Color(AgentStatusPalette.kindTileAccent),
                style: StrokeStyle(lineWidth: 1.6, lineCap: .round, lineJoin: .round))
            .padding(4)
            .frame(width: 30, height: 30)
            .background(
                Color(AgentStatusPalette.kindTileWash),
                in: RoundedRectangle(cornerRadius: 8))
            .accessibilityHidden(true)
    }
}
