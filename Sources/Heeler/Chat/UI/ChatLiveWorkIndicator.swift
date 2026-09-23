import SwiftUI

// SPDX-License-Identifier: Apache-2.0
//
// The v3 producer-backed live-work indicator — the compact "work
// spark" at the transcript's live edge. The design doc's activity
// decisions are the authoritative contract (v3-ui-architecture-
// design.md, 'Activity animation preview' + 'Idle agent'):
//
// - Shown ONLY when a fresh producer activity report says the agent
//   is working. Connection success alone does not imply thinking;
//   this view never derives its state from transport phase. The
//   caller maps producer facts into `ChatLiveWorkState`.
// - No visible status sentence; tap opens details. Accessible
//   labels name the state.
// - Idle has NEITHER an animation NOR a reserved marker row: the
//   row renders nothing (zero height, no placeholder space).
// - Unknown/blocked/completed do not animate: a small STATIC mark
//   (no motion) carries the state.
// - Reduce Motion always renders the static spark frame — never
//   the animation — including for working.

/// The producer's reported working state — the ONLY driver of the
/// indicator. Members follow the wire `AgentStatus` vocabulary
/// (`idle`/`working`/`blocked`/`done`/`unknown`) so the call site
/// maps producer facts 1:1 with no interpretation of its own. A nil
/// `ChatLiveWorkState` (no fresh producer report yet) renders
/// NOTHING — absence of a report is not "idle", it is unknown, and
/// the design forbids assuming work from connection state.
enum ChatLiveWorkState: Equatable, Sendable {
    case working
    case idle
    case blocked
    case completed
    case unknown
}

/// The state → visibility/animation mapping, as a pure value so the
/// unit suite pins the contract without a render tree. This is the
/// slice's core: which states are visible, which animate, and which
/// frame the static render uses.
struct ChatLiveWorkPresentation: Equatable, Sendable {
    /// The spark animation's frame count (dot → cross → starburst →
    /// cross → contraction → dot again; the cycle is symmetric, six
    /// frames at ~0.9s).
    static let frameCount = 6
    /// One full animation cycle's duration (~0.9s per the design).
    static let cycleDuration: TimeInterval = 0.9

    /// Whether the indicator row renders ANYTHING. `idle` and a nil
    /// state render nothing — idle has no marker AND no reserved
    /// space.
    let isVisible: Bool
    /// Whether the spark animates. ONLY `working` animates — the
    /// view folds Reduce Motion / forceStatic in by clearing this
    /// on its local copy; the init's value describes the STATE's
    /// own contract.
    var isAnimated: Bool
    /// The static frame the spark renders when not animating (the
    /// working state under Reduce Motion renders the mid starburst
    /// frame so it still reads as "active" without motion).
    let staticFrame: Int

    init(_ state: ChatLiveWorkState?) {
        switch state {
        case .working:
            isVisible = true
            isAnimated = true
            // The starburst's peak frame (index 2 of 0..5) is the
            // most legible "something is happening" glyph; Reduce
            // Motion freezes here.
            staticFrame = 2
        case .idle, nil:
            // No animation AND no reserved marker row.
            isVisible = false
            isAnimated = false
            staticFrame = 0
        case .blocked, .completed, .unknown:
            // Static mark, never animated.
            isVisible = true
            isAnimated = false
            staticFrame = 0
        }
    }

    /// The accessibility string for the whole indicator — no visible
    /// status sentence, but the tree keeps the state nameable.
    static func accessibilityLabel(for state: ChatLiveWorkState) -> String {
        switch state {
        case .working: "Agent working"
        case .idle: "Agent idle"
        case .blocked: "Agent waiting for input"
        case .completed: "Agent finished"
        case .unknown: "Agent status unknown"
        }
    }
}

/// The compact work spark: one small glyph on the live edge. The six
/// frame shapes are drawn from straight strokes (terminal-style
/// expanding/contracting marks — original graphic, not a copied
/// Claude Code/omp animation): dot, small cross, starburst,
/// contraction back to cross, then dot.
struct ChatLiveWorkSpark: View {
    /// 0-based frame index within one cycle.
    let frame: Int

    /// The glyph's design radius (pt). 11pt matches the agent-card
    /// status badge footprint so the live-edge mark reads as the
    /// same visual language.
    static let glyphSize: CGFloat = 11

    /// The per-frame cardinal ray length as a fraction of the radius
    /// (0 = no ray). Frame cycle: 0 dot · 1 short 4-ray cross ·
    /// 2 full 8-ray starburst · 3 contracting 4-ray cross · 4 short
    /// cross · 5 dot.
    private static let cardinalRays: [CGFloat] = [
        0, 0.45, 1.0, 0.45, 0, 0,
    ]
    /// The 45° rays only appear on the starburst frame.
    private static let diagonalRay: [Bool] = [
        false, false, true, false, false, false,
    ]
    /// The frame's core dot radius (fraction of radius).
    private static let coreDot: [CGFloat] = [0.5, 0.3, 0.16, 0.3, 0.5, 0.3]

    nonisolated private static func frameIndex(_ frame: Int) -> Int {
        ((frame % ChatLiveWorkPresentation.frameCount)
            + ChatLiveWorkPresentation.frameCount)
            % ChatLiveWorkPresentation.frameCount
    }

    /// The frame's ray descriptors — angle degrees + length
    /// fraction — so the unit suite can pin the six-frame cycle's
    /// SHAPE sequence (dot → cross → starburst → contraction).
    nonisolated static func rayLengths(frame: Int) -> [(angle: Double, fraction: CGFloat)] {
        let index = frameIndex(frame)
        var rays: [(angle: Double, fraction: CGFloat)] = []
        let cardinal = cardinalRays[index]
        if cardinal > 0 {
            for angle in [0.0, 90, 180, 270] {
                rays.append((angle, cardinal))
            }
        }
        if diagonalRay[index] {
            for angle in [45.0, 135, 225, 315] {
                rays.append((angle, 1))
            }
        }
        return rays
    }

    nonisolated static func coreFraction(frame: Int) -> CGFloat {
        coreDot[frameIndex(frame)]
    }

    var body: some View {
        Canvas { context, size in
            let center = CGPoint(x: size.width / 2, y: size.height / 2)
            let radius = min(size.width, size.height) / 2
            let ink = Color(AgentStatusPalette.yellowInk)

            // The core dot.
            let core = radius * Self.coreFraction(frame: frame)
            context.fill(
                Path(ellipseIn: CGRect(
                    x: center.x - core, y: center.y - core,
                    width: core * 2, height: core * 2)),
                with: .color(ink))

            // The rays: rounded strokes radiating from the core.
            let strokeWidth: CGFloat = 2
            for ray in Self.rayLengths(frame: frame) {
                let inner = core + 1
                let outer = radius * ray.fraction - strokeWidth / 2
                guard outer > inner else { continue }
                let radians = ray.angle * .pi / 180
                let dx = CGFloat(cos(radians))
                let dy = CGFloat(sin(radians))
                var path = Path()
                path.move(to: CGPoint(
                    x: center.x + dx * inner, y: center.y + dy * inner))
                path.addLine(to: CGPoint(
                    x: center.x + dx * outer, y: center.y + dy * outer))
                context.stroke(
                    path,
                    with: .color(ink),
                    style: StrokeStyle(
                        lineWidth: strokeWidth, lineCap: .round))
            }
        }
        .frame(width: Self.glyphSize * 2, height: Self.glyphSize * 2)
        .accessibilityHidden(true)
    }
}

/// The live-edge row itself: renders ONLY what its presentation
/// allows. Idle/nil states contribute NO view and NO height — the
/// transcript's bottom edge is exactly the sentinel's. Tap opens
/// the details sheet (the design's "no visible plain status text;
/// tap for details").
struct ChatLiveWorkIndicator: View {
    /// The producer's reported state; nil = no fresh report yet
    /// (renders nothing — never an assumed state).
    let state: ChatLiveWorkState?
    /// Overrides state-driven animation (Reduce Motion): the spark
    /// renders its static frame even while working.
    var forceStatic: Bool = false
    /// The details presented on tap. Both states are simple text
    /// rows: working names the state; the others add the hint the
    /// design's details surface requires.
    var detail: String = ""
    /// Optional external details presenter. Default nil renders
    /// the built-in sheet.
    var onShowDetails: (() -> Void)? = nil

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var showsDetails = false

    private var presentation: ChatLiveWorkPresentation {
        var value = ChatLiveWorkPresentation(state)
        if reduceMotion || forceStatic { value.isAnimated = false }
        return value
    }

    var body: some View {
        if presentation.isVisible, let state {
            Button {
                if let onShowDetails {
                    onShowDetails()
                } else {
                    showsDetails = true
                }
            } label: {
                HStack(spacing: 6) {
                    if presentation.isAnimated {
                        // The spark: a repeating six-frame cycle
                        // (~0.9s), driven by TimelineView — no
                        // explicit animation object that Reduce
                        // Motion or state transitions would need
                        // to unwind.
                        TimelineView(.animation) { timeline in
                            spark(at: timeline.date)
                        }
                    } else {
                        spark(at: nil)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 2)
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(
                ChatLiveWorkPresentation.accessibilityLabel(for: state))
            .accessibilityHint("Shows agent status details")
            .sheet(isPresented: $showsDetails) {
                ChatLiveWorkDetails(state: state, detail: detail)
            }
        }
        // Idle / no fresh report: NOTHING — no marker, no reserved
        // space, no placeholder row.
    }

    private func spark(at date: Date?) -> some View {
        let frame: Int
        if presentation.isAnimated, let date {
            let phase =
                date.timeIntervalSinceReferenceDate.truncatingRemainder(
                    dividingBy: ChatLiveWorkPresentation.cycleDuration)
            frame = Int(
                phase / ChatLiveWorkPresentation.cycleDuration
                    * Double(ChatLiveWorkPresentation.frameCount))
        } else {
            frame = presentation.staticFrame
        }
        return ChatLiveWorkSpark(frame: frame)
    }
}

/// The tap-for-details surface: a small sheet naming the state and
/// the producer's own detail line (the design's "retain accessible
/// labels" counterpart — the visible surface has no status
/// sentence; the details sheet carries it).
struct ChatLiveWorkDetails: View {
    let state: ChatLiveWorkState
    var detail: String = ""

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text(detail.isEmpty ? defaultDetail : detail)
                        .foregroundStyle(.secondary)
                } header: {
                    Text(
                        ChatLiveWorkPresentation.accessibilityLabel(
                            for: state))
                }
            }
            .navigationTitle("Agent Status")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    private var defaultDetail: String {
        switch state {
        case .working:
            "The agent reported it is working on your request."
        case .idle:
            "The agent reported it is idle — no work in progress."
        case .blocked:
            "The agent is waiting for an answer before it can continue."
        case .completed:
            "The agent reported its latest task is complete."
        case .unknown:
            "The agent's working state has not been reported."
        }
    }
}
