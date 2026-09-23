import SwiftUI

// SPDX-License-Identifier: Apache-2.0

/// The app's three top-level destinations. Hosts and Settings live as peer
/// pages of Agents (#A); the narrow-sidebar revision reaches them through a
/// small hamburger trigger: a 184 pt drawer overlay on phone, a collapsible
/// reserved sidebar on wide iPad layouts.
enum AppDestination: String, CaseIterable, Identifiable, Hashable {
    case agents
    case hosts
    case settings

    var id: String { rawValue }

    var title: String {
        switch self {
        case .agents: "Agents"
        case .hosts: "Hosts"
        case .settings: "Settings"
        }
    }

    /// The prototype's destination glyphs (window-list / stacked servers /
    /// sliders, 20 px stroke 1.6) as native SF Symbols.
    var systemImage: String {
        switch self {
        case .agents: "list.bullet.rectangle"
        case .hosts: "server.rack"
        case .settings: "slider.horizontal.3"
        }
    }
}

/// One destination row, shared by the phone drawer and the wide sidebar so
/// both carry identical glyph + label + check chrome (#A): the current
/// destination reads as an explicit ✓, never a tint alone.
struct AppDestinationRow: View {
    let destination: AppDestination
    let isSelected: Bool
    let select: () -> Void

    var body: some View {
        Button(action: select) {
            HStack(spacing: 9) {
                Image(systemName: destination.systemImage)
                    .font(.system(size: 15, weight: .medium))
                    .frame(width: 20)
                    .foregroundStyle(isSelected ? Color.accentColor : Color.primary)
                Text(destination.title)
                    .font(.footnote)
                    .foregroundStyle(isSelected ? Color.accentColor : Color.primary)
                Spacer(minLength: 0)
                if isSelected {
                    Image(systemName: "checkmark")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(Color.accentColor)
                        .accessibilityHidden(true)
                }
            }
            .frame(minHeight: 44)
            .padding(.horizontal, 12)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .hoverEffect(.highlight)
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }
}

/// The root pages' top-left heading (#A revision; v3 header directive):
/// a small hamburger trigger, ICON ONLY — no text label beside it. AX
/// "Open navigation" on phone, "Collapse/Expand navigation sidebar" on
/// wide layouts. The former title-dropdown and the plain page-title text
/// are gone; the trigger opens the drawer (phone) or folds the sidebar
/// (wide).

/// The drawer trigger's identity and action, computed by the root for the
/// current width and surface.
struct AppNavigationTriggerContext {
    var accessibilityLabel: String
    var accessibilityValue: String
    var action: () -> Void
}

struct AppDestinationHeading: View {
    /// The trigger's action and AX identity come from the root — the pages
    /// never know which surface (drawer vs sidebar) they are steering.
    @Environment(\.appNavigationTrigger) private var trigger
    /// Focus return (#A): the drawer hands keyboard/VoiceOver focus back to
    /// the trigger on dismissal.
    @Environment(\.appNavigationTriggerFocus) private var triggerFocus
    @Environment(\.appDestinationMenuSuppressed) private var isSuppressed

    var body: some View {
        // While a pushed detail owns the window, ALL global destination
        // chrome is hidden — trigger included (#A).
        if !isSuppressed, let trigger {
            let triggerButton = Button {
                triggerFocus?.wrappedValue = true
                trigger.action()
            } label: {
                Image(systemName: "line.3.horizontal")
                    .font(.system(size: 16, weight: .medium))
                    // A real 44pt-scale hit region, not a contentShape
                    // enlarging a smaller frame (v3 header rule).
                    .frame(minWidth: 44, minHeight: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .hoverEffect(.highlight)
            .accessibilityLabel(trigger.accessibilityLabel)
            .accessibilityValue(trigger.accessibilityValue)
            // Assistive-focus return note (review round): VoiceOver
            // lands on the trigger after dismissal via the root's
            // .screenChanged post — the trigger is the page's FIRST
            // accessible element (topBarLeading), so the
            // notification's default focus target IS this button.
            // (Binding an AccessibilityFocusState through environment
            // into a toolbar item suppresses the item's rendering —
            // verified: the trigger vanished from the AX tree — so
            // the notification is the mechanism here.)
            if let triggerFocus {
                // Keyboard focus return.
                triggerButton.focused(triggerFocus)
            } else {
                triggerButton
            }
        }
    }
}


/// The phone's on-demand navigation surface (#A revision; v2 interactive
/// presentation): a 184 pt drawer overlay — the page viewport NEVER
/// changes width. Destinations only, current one checked; dismissal via
/// close ×, outside tap, Escape, or a leftward drag; content behind is
/// inert while open; focus returns to the trigger.
///
/// v2: the drawer slides by `reveal` (pt) — ONE edge-following,
/// momentum-aware motion shared by the trigger open, the left-edge
/// swipe open, and the drag-to-close, with the scrim fading in sync
/// (reveal-proportional, driven from the root alongside). The drawer
/// MOUNTS only while presented (the root's `if`) — mounting is what
/// keeps the closed drawer out of the AX tree; the always-mounted
/// variant leaked offscreen buttons through every AX gate tried.
struct AppDestinationDrawer: View {
    let selection: Binding<AppDestination>
    let close: (_ restoreFocus: Bool) -> Void
    /// The live slide distance (pt): 0 closed … `width` open, rubber
    /// damped past full open. Gesture paths write it bare (finger 1:1);
    /// programmatic paths animate it with `presentationSpring`.
    @Binding var reveal: CGFloat
    /// Presented (resting open OR mid-gesture). Gates the close
    /// button's Escape shortcut — an offscreen drawer must never
    /// intercept hardware Escape meant for the pages.
    let isOpen: Bool
    /// The UNIFIED lifecycle predicate (review re-round): the root's
    /// `drawerIsPresented` — resting open, finger-tracked, MID-SETTLE,
    /// or any live reveal — the SAME value that drives the mount and
    /// the pages' exclusion. The drawer's modal containment, escape
    /// action, and focus binding (DrawerAccessibilityChrome) track
    /// THIS, so the AX chrome never detaches while the drawer is
    /// still mounted (settling included).
    let isPresented: Bool
    /// Assistive focus (v1 semantics): the AccessibilityFocusState
    /// binding — part of the drawer's AX chrome, mounted with it.
    var isFocused: AccessibilityFocusState<Bool>.Binding?
    /// Live tracking report (v2): the drag-to-close gesture tells the
    /// root a finger is driving the drawer, so the root keeps the
    /// drawer MOUNTED through the gesture (its `if` would otherwise
    /// flash a mount transition) and unmounts after the settle.
    var onTracking: (_ tracking: Bool) -> Void = { _ in }

    /// 184 pt TOTAL occupied width (review finding 2): the outer frame
    /// wraps the padded content, so the padding lands inside the 184 —
    /// the app viewport under the drawer is unchanged and the drawer
    /// itself measures exactly 184 pt.
    static let width: CGFloat = 184
    /// The commit horizon (v2): a release whose projected position is
    /// past half the width opens/closes; anything else snaps back. The
    /// prediction comes from SwiftUI's predictedEndTranslation (drag) or
    /// the pan's velocity × this horizon (edge swipe) — the same
    /// position-plus-momentum rule in both directions.
    static let settlePoint: CGFloat = width * 0.5
    /// How long the exit settle holds the drawer MOUNTED after a
    /// committed close (v2): past the presentation spring's visible
    /// tail, the root unmounts — mounting is what removes a view
    /// from the AX tree, so the unmount must not fire while the
    /// slide-out is still on screen.
    static let settleOutInterval: TimeInterval = 0.5
    /// The standard slide-over feel (v2): a gentle spring with a slight
    /// settle bounce — the curve behind the trigger open, the snap
    static let presentationSpring: Animation = .spring(
        response: 0.4, dampingFraction: 0.85)

    /// Reveal tracking with resistance (v2): 1:1 up to full open, then
    /// rubber-banded — a quarter of the overshoot, like a scroll view.
    static func dampedReveal(raw: CGFloat) -> CGFloat {
        min(max(raw, 0), width) + max(0, raw - width) * 0.25
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Meadow")
                    .font(.headline.weight(.semibold))
                Spacer(minLength: 0)
                escapeCloseButton
            }
            .padding(.horizontal, 8)
            .padding(.bottom, 18)

            VStack(spacing: 5) {
                ForEach(AppDestination.allCases) { destination in
                    AppDestinationRow(
                        destination: destination,
                        isSelected: destination == selection.wrappedValue
                    ) {
                        selection.wrappedValue = destination
                        close(false)
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 20)
        .padding(.horizontal, 8)
        .frame(width: 184)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(Color(.systemBackground))
        .clipShape(.rect(bottomTrailingRadius: 18, topTrailingRadius: 18))
        .shadow(color: .black.opacity(0.12), radius: 28, x: 10)
        // The slide itself (v2): offscreen at reveal 0, flush at full
        // reveal — every path (trigger, edge swipe, drag) writes the
        // one `reveal` value, so the motion is continuous by
        // construction. The MOUNTING (root) carries the .move
        // transition; this offset carries the finger.
        .offset(x: reveal - Self.width)
        // Drag-to-close on the open drawer (v2): the finger tracks the
        // reveal 1:1, then the settle springs to closed or back open.
        // The root's `onTracking` keeps the drawer MOUNTED through the
        // gesture (no transition flash) and drops it after the settle.
        .gesture(
            DragGesture(minimumDistance: 12)
                .onChanged { value in
                    // Horizontal-dominant only (v2): a mostly-vertical
                    // slide (future list content, accidental touches)
                    // must not jitter the drawer sideways.
                    guard abs(value.translation.width)
                        > abs(value.translation.height)
                    else { return }
                    onTracking(true)
                    reveal = Self.dampedReveal(
                        raw: Self.width + value.translation.width)
                }
                .onEnded { value in
                    settleClose(
                        currentTranslation: value.translation.width,
                        predictedEndTranslation:
                            value.predictedEndTranslation.width)
                })
        // AX chrome (v2): the drawer is only MOUNTED while presented
        // (root), so its modal containment, escape action, and focus
        // binding are simply part of the mounted view — the v1
        // identity. The always-mounted variant needed every gate
        // (hidden, children-ignore, focus-detach, opacity-0,
        // rendered-geometry) and STILL leaked offscreen buttons into
        // the AX tree (verified: the × stayed resolvable long after
        // close) — mounting is the one mechanism that actually
        // removes a view from the tree.
        .modifier(DrawerAccessibilityChrome(
            isPresented: isPresented,
            close: close,
            isFocused: isFocused))
    }

    /// The close × — Escape shortcut mounted ONLY while presented (v2):
    /// a closed, offscreen .cancelAction would otherwise intercept
    /// hardware Escape aimed at the pages behind.
    @ViewBuilder
    private var escapeCloseButton: some View {
        let button = Button {
            close(true)
        } label: {
            Image(systemName: "xmark")
                .font(.system(size: 14, weight: .semibold))
                .frame(width: 40, height: 40)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .hoverEffect(.highlight)
        .accessibilityLabel("Close navigation")
        if isOpen {
            // Escape dismissal: .cancelAction is the system's Escape
            // routing (a raw .escape shortcut is intercepted by the OS
            // keyboard-dismiss path and never reaches the button —
            // verified in the UITest).
            button.keyboardShortcut(.cancelAction)
        } else {
            button
        }
    }

    /// Drag-to-close settle (v2): momentum-aware — the flick's projected
    /// end position decides. Past the settle point commits the close;
    /// anything else springs back open (the standard drawer snap-back).
    private func settleClose(
        currentTranslation: CGFloat, predictedEndTranslation: CGFloat
    ) {
        let projected = Self.dampedReveal(
            raw: Self.width + predictedEndTranslation)
        let current = Self.dampedReveal(raw: Self.width + currentTranslation)
        if projected < Self.settlePoint || current < Self.settlePoint {
            // The finger is gone — the root's close path owns the
            // settle-out mount window from here.
            onTracking(false)
            // A finger dismissal: keyboard focus never moved to the
            // drawer, so it does not steal the trigger — but VoiceOver
            // (if running) still needs the focus hand-off back to the
            // page, same as every other dismissal path.
            close(UIAccessibility.isVoiceOverRunning)
        } else {
            // Snapped back open: this is the RESTING state now.
            onTracking(false)
            withAnimation(Self.presentationSpring) { reveal = Self.width }
        }
    }
}

/// The drawer's modal AX chrome, attached ONLY while the open has
/// settled (v2): containment trait + the accessibility escape action.
/// Gated through a modifier so the escape ACTION detaches with the
/// chrome — a custom-action container is retained by the AX system,
/// which pinned the closed drawer into the tree when the action was
/// permanently attached.
private struct DrawerAccessibilityChrome: ViewModifier {
    let isPresented: Bool
    let close: (_ restoreFocus: Bool) -> Void
    var isFocused: AccessibilityFocusState<Bool>.Binding?

    func body(content: Content) -> some View {
        if isPresented, let isFocused {
            content
                .accessibilityAddTraits(.isModal)
                .accessibilityFocused(isFocused)
                // Escape dismissal (review round): the accessibility
                // ESCAPE action — VoiceOver's two-finger Z scrub
                // gesture, switch-control escape, and XCUITest's
                // performAccessibilityAction(.escape). (The
                // hardware-keyboard route also exists: the close
                // button's .cancelAction shortcut. Both land in the
                // same close path.)
                .accessibilityAction(.escape) { close(true) }
        } else {
            content
        }
    }
}

/// The leading-edge swipe that opens the drawer (v2; v3 reliability
/// revision): a UIKit recognizer PAIR bridged into the drawer's
/// reveal, attached to the window's root view (an ancestor of every
/// page; the same parent-walk ChatScreen's PopGestureEnabler uses),
/// with DISJOINT territories so the pair never races one finger:
///
/// - `EdgePan` — the stock UIScreenEdgePanGestureRecognizer, owning
///   the 0–~20 pt bezel. Measured on the agent list: the system's
///   bezel gesture gate CANCELS a plain pan whose touch starts in
///   the bezel strip, so the stock class must keep that territory —
///   a plain recognizer cannot replace it there.
/// - `DrawerEdgeBandPan` — the v3 reliability fix: a plain pan
///   owning (20, 44] pt from the leading edge (mirrored for RTL).
///   A real-phone swipe routinely starts 20–44 pt in from the
///   bezel, where the stock recognizer silently never engaged and
///   the drawer needed retries. It resolves direction EARLY
///   (~8 pt of movement: inward-horizontal intent continues toward
///   the begin; vertical or outward intent fails at once,
///   promptly releasing the touch to scrolling) and wins the race
///   with the touched scroll view through an explicit require-to-
///   fail dependency pointed the only safe way: the descendant
///   scroll pan waits for the band pan's brief directional
///   decision — never the reverse (the drawer must never wait for
///   a scroll pan that merely claims the touch). The scroll pan is
///   identified by CLASS, not view: SwiftUI hosts List content in
///   generic UIView wrappers, so a `view as? UIScrollView` cast
///   never matched and the dependency silently never installed
///   (measured — the agent list's scroll pan cancelled the band
///   pan mid-analysis before the class-name fix).
///
/// ELIGIBILITY is captured at touch start, fail closed, on the
/// VISIBLE destination's nav state — no VISIBLE navigation
/// controller with a pushed detail (hidden pages' retained stacks
/// do not veto) — and re-checked live at begin, so a finger that
/// started over a pushed detail never opens the drawer (a
/// cancelled Back gesture never becomes a drawer gesture). Both
/// recognizers ride the same suppression seam as the hamburger
/// trigger, so pushed details never participate at all. The
/// trigger stays the accessible path; the gesture is additive,
/// never the only affordance.
struct DrawerEdgePanBridge: UIViewControllerRepresentable {
    /// The recognizer-level pre-gate (the trigger's seam): a disabled
    /// recognizer never even claims the edge. The AUTHORITATIVE veto
    /// is UIKit ground truth — the visible-nav walk below — captured
    /// at touch start, retained for the gesture, and re-checked live
    /// at begin; the seam proved unreliable for arbitration (it can
    /// report a root page focused while a detail is pushed), so it
    /// only keeps the recognizer from engaging where the drawer
    /// could never apply.
    let isEnabled: Bool
    let onBegan: () -> Void
    let onTranslate: (_ translationX: CGFloat) -> Void
    let onRelease: (
        _ translationX: CGFloat, _ velocityX: CGFloat, _ cancelled: Bool
    ) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeUIViewController(context: Context) -> HostViewController {
        let host = HostViewController()
        host.coordinator = context.coordinator
        return host
    }

    func updateUIViewController(
        _ uiViewController: HostViewController, context: Context
    ) {
        context.coordinator.isEnabled = isEnabled
        context.coordinator.onBegan = onBegan
        context.coordinator.onTranslate = onTranslate
        context.coordinator.onRelease = onRelease
    }

    /// Attaches the recognizer once the parent chain to the window's
    /// root view controller is complete — `viewDidAppear`, the same
    /// timing PopGestureEnabler's verified parent-walk relies on.
    final class HostViewController: UIViewController {
        weak var coordinator: Coordinator?
        private var isAttached = false

        override func viewDidAppear(_ animated: Bool) {
            super.viewDidAppear(animated)
            guard !isAttached, let coordinator else { return }
            // Walk the parent chain to its ROOT — the window's own view
            // controller, an ancestor of every page (the same chain
            // PopGestureEnabler walks to find its
            // UINavigationController). Attaching there means the
            // recognizer sees the edge gesture anywhere on the current
            // page, while its enabled state still follows the seam.
            var root: UIViewController? = self
            while let parent = root?.parent {
                root = parent
            }
            guard let rootView = root?.view else { return }
            rootView.addGestureRecognizer(coordinator.recognizer)
            rootView.addGestureRecognizer(coordinator.bandPan)
            isAttached = true
        }
    }

    /// Routes the recognizer into the drawer's reveal and owns the
    /// arbitration, on UIKit ground truth: the app's focus seam
    /// proved unreliable for gesture arbitration (instrumented run:
    /// it re-enabled the recognizer while a detail was pushed).
    @MainActor
    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        let recognizer = EdgePan()
        /// The 20–44 pt band's pan (v3 revision; see the struct's doc
        /// comment for why the bezel needs its own stock recognizer).
        let bandPan = DrawerEdgeBandPan()
        var onBegan: () -> Void = {}
        var onTranslate: (CGFloat) -> Void = { _ in }
        var onRelease: (CGFloat, CGFloat, Bool) -> Void = { _, _, _ in }
        var isEnabled = true {
            didSet {
                guard !isRecognizingFlag else { return }
                recognizer.isEnabled = isEnabled
                bandPan.isEnabled = isEnabled
            }
        }
        /// True while EITHER recognizer is mid-gesture: the drawer is
        /// tracking a finger, so seam-driven enable/disable writes
        /// are held off until the gesture finishes (the release
        /// restores the seam state in `finish()`).
        var isRecognizingFlag = false
        /// Which recognizer is routing the in-flight gesture (nil
        /// when idle). Set at the first .began; cleared on finish.
        private var activeRecognizer: UIPanGestureRecognizer?

        override init() {
            super.init()
            recognizer.edges = .left
            recognizer.delegate = self
            recognizer.addTarget(self, action: #selector(pan(_:)))
            bandPan.delegate = self
            bandPan.addTarget(self, action: #selector(pan(_:)))
        }

        /// The bezel's stock screen-edge pan (v2, kept by measurement
        /// — see the struct's doc comment): the ONLY recognizer
        /// class the system's bezel gesture gate defers to, so the
        /// 0–20 pt territory must stay its.
        final class EdgePan: UIScreenEdgePanGestureRecognizer {
            /// UIKit ground truth captured at touch start, retained
            /// for the gesture. Starts NOT eligible (fail closed).
            var beganEligible = false

            override func touchesBegan(
                _ touches: Set<UITouch>, with event: UIEvent
            ) {
                beganEligible =
                    (delegate as? Coordinator)?.noVisiblePushedDetail(self)
                    ?? false
                super.touchesBegan(touches, with: event)
            }
        }

        /// The 20–44 pt band's directional pan (v3 revision): a plain
        /// pan — the stock screen-edge recognizer's begin band is a
        /// fixed system-owned ~20 pt and cannot be widened, so a
        /// swipe that starts 20–44 pt in never engaged and the
        /// drawer was "unreliable" on a real phone. The band's
        /// territory is EXCLUSIVE of the bezel (the stock EdgePan
        /// owns 0–~20 pt) so the pair never races one finger:
        ///   - BAND: the touch must START in (bezelWidth, bandWidth]
        ///     from the leading edge (RTL-mirrored), captured
        ///     fail-closed at touchesBegan;
        ///   - DIRECTION resolved EARLY: as soon as movement passes
        ///     `decisionDistance` (~8 pt), non-inward intent fails
        ///     the recognizer at once — the touch releases promptly
        ///     to the waiting scroll view — while inward-horizontal
        ///     intent carries through to the begin;
        ///   - ELIGIBILITY captured at touch start (the visible-nav
        ///     veto) and re-checked live at begin, so a finger that
        ///     started over a pushed detail never opens the drawer
        ///     (a cancelled Back gesture never becomes a drawer
        ///     gesture) no matter what state changes underneath.
        final class DrawerEdgeBandPan: UIPanGestureRecognizer {
            /// How far from the leading edge a touch may start and
            /// still open the drawer — 44 pt, the HIG minimum touch
            /// target, full height.
            static let bandWidth: CGFloat = 44
            /// The bezel strip the stock screen-edge recognizer owns
            /// (measured: the system's bezel gesture gate cancels a
            /// plain pan whose touch starts inside it). The band's
            /// territory starts just past it.
            static let bezelWidth: CGFloat = 20
            /// Movement (pt) after which the direction is judged —
            /// the FIRST move event ≥ this distance decides. 3 pt:
            /// small enough to precede the ~6 pt edge-gate cancel
            /// window (measured), large enough to ride a real first
            /// move event.
            static let decisionDistance: CGFloat = 3

            /// UIKit ground truth captured at touch start, retained
            /// for the gesture. Starts NOT eligible (fail closed).
            var beganEligible = false
            /// The touch started inside the leading band.
            var beganInBand = false
            /// The touch's start point in the attached view's
            /// coordinates — the direction verdict is computed from
            /// RAW touch locations, NOT the recognizer's
            /// translation: `translation(in:)` is UNDEFINED while
            /// the pan sits in .possible over the list's scroll
            /// stack (measured: it reads a constant 0.0 through an
            /// entire moving stroke — 21 move events, locations 24→
            /// 204 pt, translation 0.0 every event — so any gate on
            /// translation never decides).
            var beganLocation: CGPoint?
            /// The early-direction verdict: inward-horizontal intent.
            var decidedInward = false

            /// The screen's leading edge, mirrored for RTL — the
            /// drawer slides in from the leading side either way.
            private var isRTL: Bool {
                view?.effectiveUserInterfaceLayoutDirection == .rightToLeft
            }

            override func touchesBegan(
                _ touches: Set<UITouch>, with event: UIEvent
            ) {
                // Fail closed: until the visible-nav walk proves no
                // VISIBLE navigation controller has a pushed
                // detail, the touch is not drawer-eligible — and a
                // recognizer can claim a touch that began before it
                // was enabled, so eligibility is grounded at touch
                // start, not at arbitration time.
                beganEligible =
                    (delegate as? Coordinator)?.noVisiblePushedDetail(self)
                    ?? false
                beganInBand = {
                    guard let view,
                        let x = touches.first?.location(in: view).x
                    else { return false }
                    // The WHOLE band (≤ bandWidth from the leading
                    // edge), overlapping the stock EdgePan's bezel
                    // territory on purpose: the system bezel band's
                    // exact width is private (measured behavior puts
                    // it somewhere under ~20 pt), and a non-overlap
                    // split left a dead gap at 12 pt — no
                    // recognizer's territory. The overlap's race is
                    // between the drawer's OWN two recognizers and
                    // is settled by UIKit exclusivity plus the
                    // active-routing guards in `pan(_:)`; on true
                    // bezel starts the stock EdgePan wins anyway
                    // (its system-level precedence).
                    let fromLeading = isRTL
                        ? view.bounds.width - x
                        : x
                    return fromLeading <= Self.bandWidth
                }()
                beganLocation = touches.first?.location(in: view)
                decidedInward = false
                super.touchesBegan(touches, with: event)
            }
            override func touchesMoved(
                _ touches: Set<UITouch>, with event: UIEvent
            ) {
                super.touchesMoved(touches, with: event)
                guard state == .possible, beganInBand, beganEligible,
                    let start = beganLocation,
                    let location = touches.first?.location(in: view)
                else { return }
                // The direction verdict on RAW LOCATIONS: the
                // recognizer's translation(in:) is undefined in
                // .possible over the list's scroll stack (measured
                // constant 0.0 through a full stroke — see
                // beganLocation's comment), so the delta is
                // computed from the touch's own coordinates. The
                // FIRST move event that carries ≥3 pt of movement
                // from the start decides (measured: the edge gate
                // cancels an undecided in-band pan at ~6 pt): a
                // straight-line stroke's ratio is already its true
                // direction by then, inward-horizontal carries
                // through to the begin, and anything else — a
                // vertical scroll that started in the band, a
                // leftward fling — fails AT ONCE, promptly
                // releasing the touch to the scroll pan that is
                // waiting on this pan's verdict.
                let dx = location.x - start.x
                let dy = location.y - start.y
                guard abs(dx) >= Self.decisionDistance
                    || abs(dy) >= Self.decisionDistance
                else { return }
                let inwardX = isRTL ? -dx : dx
                if inwardX > 0, abs(dx) > abs(dy) {
                    decidedInward = true
                } else {
                    state = .failed
                }
            }
        }

        /// The pushed-detail veto on UIKit ground truth (design
        /// contract revision): true only when the walk over the
        /// window's view-controller tree proves NO VISIBLE
        /// navigation controller currently has a pushed detail.
        /// VISIBLE matters: AppRootView keeps every page mounted
        /// (hidden ones at opacity 0), and a hidden page's retained
        /// stack — a deep-linked route that landed while the user
        /// was elsewhere — must not deaden the edge on the page the
        /// user is actually looking at. Used at touch START
        /// (captured, fail closed) and at begin time.
        nonisolated private func noVisiblePushedDetail(
            _ gestureRecognizer: UIGestureRecognizer
        ) -> Bool {
            MainActor.assumeIsolated {
                guard let window = gestureRecognizer.view?.window,
                    let root = window.rootViewController
                else { return false }
                var stack = [root]
                while let next = stack.popLast() {
                    if let nav = next as? UINavigationController,
                        nav.viewControllers.count > 1,
                        Self.isEffectivelyVisible(nav)
                    {
                        return false
                    }
                    stack.append(contentsOf: next.children)
                    if let presented = next.presentedViewController {
                        stack.append(presented)
                    }
                }
                return true
            }
        }

        /// A view controller is effectively visible when its view
        /// is mounted in a window and nothing on its UIKit ancestor
        /// chain is hidden or faded to (near) zero — the state
        /// AppRootView puts non-staged pages in (opacity 0). The
        /// seam can lie; this is the UIKit ground truth the veto
        /// trusts.
        private static func isEffectivelyVisible(
            _ viewController: UIViewController
        ) -> Bool {
            guard let view = viewController.viewIfLoaded,
                view.window != nil
            else { return false }
            var current: UIView? = view
            while let candidate = current {
                if candidate.isHidden || candidate.alpha < 0.01 {
                    return false
                }
                current = candidate.superview
            }
            return true
        }

        nonisolated func gestureRecognizerShouldBegin(
            _ gestureRecognizer: UIGestureRecognizer
        ) -> Bool {
            guard gestureRecognizer === recognizer
                || gestureRecognizer === bandPan
            else { return true }
            return MainActor.assumeIsolated {
                // The touch-start UIKit veto RETAINED: a finger that
                // started over a pushed detail NEVER opens the
                // drawer, no matter what state changes underneath
                // (an interactive pop completing mid-drag included).
                // Each recognizer reads ITS OWN captured flag — the
                // pair never trusts one sibling's capture for the
                // other.
                let beganEligible =
                    gestureRecognizer === bandPan
                    ? bandPan.beganEligible
                    : recognizer.beganEligible
                guard beganEligible,
                    noVisiblePushedDetail(gestureRecognizer)
                else { return false }
                if gestureRecognizer === bandPan {
                    // The band's own gates: the touch started past
                    // the bezel but inside the band, and the EARLY
                    // direction verdict already read inward intent.
                    guard bandPan.beganInBand, bandPan.decidedInward
                    else { return false }
                }
                return true
            }
        }

        /// EXPLICIT arbitration with the touched scroll view
        /// (design contract): UIKit gives a stock screen-edge pan
        /// system-level precedence over scroll views, but a plain
        /// pan gets NONE — so without this dependency the agent
        /// list's scroll pan raced the band pan and won
        /// slightly-diagonal in-band swipes (the reported
        /// list-specific failure). This hook installs the same
        /// dependency by hand, pointed the ONLY safe way: the
        /// descendant scroll pan must wait for the band pan's
        /// verdict when the touch started in the band — and the
        /// band pan resolves FAST (the early-direction verdict in
        /// `touchesMoved`, ~8 pt), so the scroll is held only for
        /// that brief decision window and proceeds the moment the
        /// band pan fails. The reverse dependency — the drawer
        /// waiting for the scroll — would starve the drawer (a
        /// scroll pan never fails for a touch it merely claims),
        /// and is deliberately NOT what this returns. The stock
        /// EdgePan needs nothing here — the bezel's system gate
        /// already holds every scroll off its territory.
        nonisolated func gestureRecognizer(
            _ gestureRecognizer: UIGestureRecognizer,
            shouldBeRequiredToFailBy
            otherGestureRecognizer: UIGestureRecognizer
        ) -> Bool {
            guard gestureRecognizer === bandPan else { return false }
            return MainActor.assumeIsolated {
                // UNCONDITIONAL while enabled (measured ordering
                // race): the beganInBand flag is set in touchesBegan,
                // but UIKit's dependency analysis can run BEFORE that
                // flag is set for the very touch it is analyzing —
                // the first swipe of a session then carried a STALE
                // false, the dependency silently never installed, and
                // the scroll stack damped the band pan's touch
                // delivery into starvation (measured: 21 zero-
                // translation move events, then silence — the pan
                // could never produce the verdict the scroll was
                // owed). Conditioning on ENABLED alone is safe: a
                // touch that starts OUTSIDE the band never reaches
                // the band pan's touchesBegan, so the pan is not a
                // participant and fails instantly for it — the
                // scroll proceeds with no measurable delay.
                guard bandPan.isEnabled
                else { return false }
                // Descendant of the recognizer's own view (the
                // window root): the current page's scroll stack,
                // never a sibling surface's.
                guard let rootView = bandPan.view,
                    let otherView = otherGestureRecognizer.view,
                    otherView !== rootView,
                    otherView.isDescendant(of: rootView)
                else { return false }
                // The scroll pan is identified by CLASS, not by its
                // view: SwiftUI hosts List/ScrollView content inside
                // generic UIView wrappers, so the pan's own view is
                // a plain UIView and a `view as? UIScrollView` cast
                // never matched (measured on the agent list — the
                // dependency silently never installed, and the
                // scroll pan cancelled the band pan mid-analysis).
                // The DELAYED-TOUCHES gate is deliberately EXCLUDED:
                // it is the scroll view's touch-delivery damper, and
                // making IT wait for the band pan's verdict starves
                // the very movement events the verdict needs
                // (measured on a fresh sim: 21 zero-translation move
                // events then silence — the gate must keep DELIVERING
                // while the pan alone is held).
                let otherType =
                    String(describing: type(of: otherGestureRecognizer))
                guard otherType.contains("ScrollViewPan"),
                    otherGestureRecognizer is UIPanGestureRecognizer
                else { return false }
                return true
            }
        }

        @objc private func pan(
            _ sender: UIPanGestureRecognizer
        ) {
            // ONE active track: only the recognizer that reached
            // .began FIRST routes the reveal; the loser (if it ever
            // sees a callback for the touch) is ignored by the
            // guards. The sibling is NOT force-disabled here —
            // disabling a recognizer mid-arbitration made it fail
            // out from under the system's own dependency analysis
            // (measured: the scroll pan that natively requires the
            // stock edge pan's failure saw the edge pan fail and
            // began first, stealing the touch from the band pan).
            // The pair's territories are disjoint (bezel vs past
            // the bezel), so a genuine race is not reachable.
            let isActive =
                sender === activeRecognizer && isRecognizingFlag
            let view = sender.view
            let translationX = sender.translation(in: view).x
            switch sender.state {
            case .began:
                guard !isRecognizingFlag else { break }
                activeRecognizer = sender
                isRecognizingFlag = true
                onBegan()
            case .changed:
                guard isActive else { break }
                onTranslate(translationX)
            case .ended:
                guard isActive else { break }
                onRelease(
                    translationX, sender.velocity(in: view).x, false)
                finish()
            case .cancelled, .failed:
                if isActive {
                    onRelease(translationX, 0, true)
                    finish()
                }
            default:
                break
            }
        }

        private func finish() {
            isRecognizingFlag = false
            activeRecognizer = nil
            recognizer.isEnabled = isEnabled
            bandPan.isEnabled = isEnabled
        }

        /// The drawer's pans never run simultaneously with anything:
        /// exclusivity is the default, and it is exactly what the
        /// reveal needs — one writer.
        nonisolated func gestureRecognizer(
            _ gestureRecognizer: UIGestureRecognizer,
            shouldRecognizeSimultaneouslyWith
            otherGestureRecognizer: UIGestureRecognizer
        ) -> Bool {
            false
        }
    }
}
