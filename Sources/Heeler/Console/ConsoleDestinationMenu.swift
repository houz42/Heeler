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

/// The root pages' top-left heading (#A revision): a small hamburger
/// trigger (the prototype's 3-line icon, AX "Open navigation" on phone,
/// "Collapse/Expand navigation sidebar" on wide layouts) followed by the
/// page's PLAIN title text. The former title-dropdown is gone — the
/// trigger opens the drawer (phone) or folds the sidebar (wide) instead.

/// The drawer trigger's identity and action, computed by the root for the
/// current width and surface.
struct AppNavigationTriggerContext {
    var accessibilityLabel: String
    var accessibilityValue: String
    var action: () -> Void
}

struct AppDestinationHeading: View {
    let pageTitle: String
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
            HStack(spacing: 10) {
                let triggerButton = Button {
                    triggerFocus?.wrappedValue = true
                    trigger.action()
                } label: {
                    Image(systemName: "line.3.horizontal")
                        .font(.system(size: 16, weight: .medium))
                        .frame(width: 40, height: 40)
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
                // The plain page title. Fixed layout + a measured frame so
                // the toolbar NEVER collapses it (review finding 1: the
                // title must RENDER beside the trigger on every page).
                Text(pageTitle)
                    .font(.headline.weight(.semibold))
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
                    .frame(minWidth: 60, alignment: .leading)
            }
            .fixedSize(horizontal: true, vertical: false)
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

/// The left-edge swipe that opens the drawer (v2; reliability widening
/// v3): SwiftUI has no edge-restricted pan, and the pushed detail's
/// interactive back-swipe must stay the system's own — so this is a
/// UIKit recognizer pair bridged into the drawer's reveal, attached to
/// the window's root view (an ancestor of every page — the same
/// parent-walk ChatScreen's PopGestureEnabler uses to reach its
/// UINavigationController):
///
/// - `EdgePan` — a UIScreenEdgePanGestureRecognizer, edges .left. Its
///   begin region is the system's own fixed ~20 pt bezel band (no
///   public API widens it).
/// - `NearEdgePan` — the v3 reliability fix: a plain pan that may only
///   BEGIN for a touch that started within `nearEdgeWidth` (44 pt, the
///   HIG touch target) of the left edge AND moves horizontal-dominant
///   RIGHTWARD. A real-phone swipe routinely starts 20–44 pt in from
///   the bezel, where the stock screen-edge recognizer silently never
///   engaged and the user had to retry — the sim proofs never caught
///   it because synthesized HID drags start exactly at the bezel.
///   The dominance gate keeps the design's rule: a vertical drag that
///   starts near the edge stays the page's scroll, and a leftward
///   fling opens nothing.
///
/// Both are enabled ONLY on the phone's ROOT pages, the same
/// suppression seam as the hamburger trigger: a pushed detail disables
/// them, so the back-swipe never competes — and both carry the
/// fail-closed pushed-detail veto (see the delegate below), so no
/// transient seam state can ever open the drawer over a pushed screen.
/// The trigger stays the accessible path; the gesture is additive,
/// never the only affordance.
struct DrawerEdgePanBridge: UIViewControllerRepresentable {
    /// The recognizer-level pre-gate (the trigger's seam): a disabled
    /// recognizer never even claims the edge. The AUTHORITATIVE veto
    /// is UIKit ground truth — the pushed-detail VC-tree walk,
    /// captured at touch start, retained for the gesture, and
    /// re-checked live at arbitration (see the delegate below); the
    /// seam proved unreliable for arbitration (it can report a root
    /// page focused while a detail is pushed), so it only keeps the
    /// recognizer from engaging where the drawer could never apply.
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

    /// Attaches the recognizers once the parent chain to the window's
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
            // recognizers see the edge gesture anywhere on the current
            // page, while their enabled state still follows the seam.
            var root: UIViewController? = self
            while let parent = root?.parent {
                root = parent
            }
            guard let rootView = root?.view else { return }
            rootView.addGestureRecognizer(coordinator.recognizer)
            rootView.addGestureRecognizer(coordinator.nearEdgePan)
            isAttached = true
        }
    }

    /// Routes the recognizer into the drawer's reveal, and owns the
    /// ARBITRATION (v2 revision): the app's focus seam proved
    /// unreliable for gesture arbitration — it can report "root page
    /// focused" while a detail is pushed (verified by instrumented
    /// run: the recognizer was re-enabled mid-push; the trigger never
    /// surfaced the lie because the pushed detail's NavigationStack
    /// toolbar swap hides it anyway). So the VETO lives here, on
    /// UIKit ground truth: `gestureRecognizerShouldBegin` walks the
    /// window and refuses the edge whenever ANY navigation controller
    /// has a pushed detail — returning false there lets the touch
    /// fall through to the system's interactive pop gesture, which is
    /// exactly the behavior the seam promised.
    @MainActor
    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        let recognizer = EdgePan()
        /// The widened begin region (v3): a plain pan that only begins
        /// for touches starting within `nearEdgeWidth` of the left
        /// edge and moving horizontal-dominant RIGHTWARD. See the
        /// struct's doc comment for why the stock screen-edge
        /// recognizer alone made the drawer unreliable on a real
        /// phone (its begin region is a fixed ~20 pt system band).
        let nearEdgePan = NearEdgePan()
        /// How far from the left edge a touch may start and still open
        /// the drawer — 44 pt, the HIG minimum touch target. True
        /// bezel starts (0–20 pt) stay the stock recognizer's; the
        /// widened band only ADDS coverage.
        static let nearEdgeWidth: CGFloat = 44
        var onBegan: () -> Void = {}
        var onTranslate: (CGFloat) -> Void = { _ in }
        var onRelease: (CGFloat, CGFloat, Bool) -> Void = { _, _, _ in }

        var isEnabled = true {
            didSet {
                guard !isRecognizingFlag else { return }
                recognizer.isEnabled = isEnabled
                nearEdgePan.isEnabled = isEnabled
            }
        }
        /// True while EITHER recognizer is mid-gesture: the drawer is
        /// tracking a finger, so seam-driven enable/disable writes are
        /// held off until the gesture finishes (the release restores
        /// the seam state in `finish()`).
        var isRecognizingFlag = false

        override init() {
            super.init()
            recognizer.edges = .left
            recognizer.delegate = self
            recognizer.addTarget(self, action: #selector(pan(_:)))
            nearEdgePan.delegate = self
            nearEdgePan.addTarget(self, action: #selector(pan(_:)))
        }

        /// The screen-edge pan itself (v2 revision): captures UIKit's
        /// pushed-detail veto AT TOUCH START and retains it for the
        /// whole gesture. A recognizer can claim a touch that began
        /// BEFORE it was enabled — so an interactive back-swipe that
        /// POPS the detail mid-drag would otherwise see this
        /// recognizer come alive and steal the still-down finger,
        /// opening the drawer over the root the moment the pop lands
        /// (verified in the proof video). The touch-start check is
        /// the SAME VC-tree walk the arbitration uses — the app's
        /// focus seam proved unreliable for gesture arbitration
        /// (instrumented run: it re-enabled the recognizer while a
        /// detail was pushed) — and it FAILS CLOSED: until the walk
        /// proves no navigation controller has a pushed detail, the
        /// touch is not drawer-eligible, so no transient seam state
        /// can ever open the drawer over a pushed screen.
        final class EdgePan: UIScreenEdgePanGestureRecognizer {
            /// UIKit ground truth captured at touch start, retained
            /// for the gesture. Starts NOT eligible (fail closed).
            var beganEligible = false

            override func touchesBegan(
                _ touches: Set<UITouch>, with event: UIEvent
            ) {
                beganEligible =
                    (delegate as? Coordinator)?.noPushedDetail(self)
                    ?? false
                super.touchesBegan(touches, with: event)
            }
        }

        /// The widened begin-region recognizer (v3): a plain pan — the
        /// stock screen-edge recognizer's begin band is a fixed
        /// system-owned ~20 pt and cannot be widened, so a swipe that
        /// starts 20–44 pt in never engaged and the drawer was
        /// "unreliable" on a real phone. This pan may only BEGIN when
        /// `gestureRecognizerShouldBegin` sees ALL of:
        ///   - the touch STARTED within `nearEdgeWidth` of the left
        ///     edge (captured at touchesBegan, same fail-closed
        ///     pattern as EdgePan: ineligible until proven),
        ///   - horizontal-dominant RIGHTWARD motion (a vertical drag
        ///     near the edge stays the page's scroll — the design's
        ///     rule; a leftward fling opens nothing),
        ///   - the pushed-detail veto, at touch start AND live.
        /// Outside that region the recognizer fails, so the touch
        /// belongs to whatever the page was doing (scroll, tap) — the
        /// added coverage never steals an interior horizontal drag.
        final class NearEdgePan: UIPanGestureRecognizer {
            /// Touch-start facts, captured at touchesBegan and
            /// retained for the gesture (fail closed until then).
            var beganEligible = false
            var beganNearLeftEdge = false

            override func touchesBegan(
                _ touches: Set<UITouch>, with event: UIEvent
            ) {
                // The same captured-veto pattern as EdgePan: a
                // recognizer can claim a touch that began before it
                // was enabled, so eligibility is grounded at touch
                // start, not at arbitration time.
                beganEligible =
                    (delegate as? Coordinator)?.noPushedDetail(self)
                    ?? false
                beganNearLeftEdge =
                    (touches.first?.location(in: view).x
                        ?? .infinity)
                    <= Coordinator.nearEdgeWidth
                super.touchesBegan(touches, with: event)
            }
        }

        /// The pushed-detail veto on UIKit ground truth (v2): true
        /// only when the walk over the window's view-controller tree
        /// proves NO navigation controller currently has a pushed
        /// detail. Used at touch START (captured, fail closed) and at
        /// gesture-arbitration time.
        nonisolated private func noPushedDetail(
            _ gestureRecognizer: UIGestureRecognizer
        ) -> Bool {
            MainActor.assumeIsolated {
                guard let window = gestureRecognizer.view?.window,
                    let root = window.rootViewController
                else { return false }
                var stack = [root]
                while let next = stack.popLast() {
                    if let nav = next as? UINavigationController,
                        nav.viewControllers.count > 1 {
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

        nonisolated func gestureRecognizerShouldBegin(
            _ gestureRecognizer: UIGestureRecognizer
        ) -> Bool {
            guard gestureRecognizer === recognizer
                || gestureRecognizer === nearEdgePan
            else { return true }
            return MainActor.assumeIsolated {
                // The touch-start UIKit veto RETAINED: a finger that
                // started over a pushed detail NEVER opens the
                // drawer, no matter what state changes underneath
                // (an interactive pop completing mid-drag included).
                // Each recognizer reads ITS OWN captured flag — a
                // screen-edge recognizer's touch delivery outside its
                // band is not guaranteed, so the pair never trusts
                // one sibling's capture for the other.
                let beganEligible =
                    gestureRecognizer === nearEdgePan
                    ? nearEdgePan.beganEligible
                    : recognizer.beganEligible
                guard beganEligible,
                    noPushedDetail(gestureRecognizer)
                else { return false }
                if gestureRecognizer === nearEdgePan {
                    // The widened band's own gates: the touch must
                    // have started within `nearEdgeWidth` of the left
                    // edge, and the motion must be
                    // horizontal-dominant RIGHTWARD — a vertical
                    // drag near the edge stays the page's scroll (the
                    // design's rule), and a leftward fling opens
                    // nothing.
                    guard nearEdgePan.beganNearLeftEdge else {
                        return false
                    }
                    let view = nearEdgePan.view
                    let translation = nearEdgePan.translation(in: view)
                    guard translation.x > 0,
                        abs(translation.x) > abs(translation.y)
                    else { return false }
                }
                return true
            }
        }

        @objc private func pan(
            _ sender: UIPanGestureRecognizer
        ) {
            // ONE active track: only the recognizer that reached
            // .began routes into the reveal. When it begins, the
            // sibling is disabled, which fails it out of the same
            // touch — and that .failed fires through this same
            // handler. Without the guard, the loser's release
            // callback would `onRelease(cancelled: true)` and snap a
            // drawer the winner was still tracking.
            let isActive =
                sender === activeRecognizer && isRecognizingFlag
            let view = sender.view
            let translationX = sender.translation(in: view).x
            switch sender.state {
            case .began:
                guard !isRecognizingFlag else { break }
                activeRecognizer = sender
                isRecognizingFlag = true
                // Claim the edge exclusively: whichever recognizer
                // began first wins; the sibling is disabled (fail
                // closed for this touch) and restored on finish().
                let other =
                    sender === self.recognizer
                    ? nearEdgePan : self.recognizer
                other.isEnabled = false
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

        /// Which recognizer is routing the in-flight gesture (nil when
        /// idle). Set at .began; cleared on finish.
        private var activeRecognizer: UIPanGestureRecognizer?

        private func finish() {
            isRecognizingFlag = false
            activeRecognizer = nil
            recognizer.isEnabled = isEnabled
            nearEdgePan.isEnabled = isEnabled
        }

        /// The pair never tracks one finger twice: two recognizers
        /// feed one reveal, so simultaneous recognition would
        /// double-write the drawer's offset. (Both shouldBegin in
        /// overlapping territory; exclusivity is settled at the first
        /// .began above, and this refusal covers the same-touch
        /// overlap window before it.) Every OTHER pair keeps UIKit's
        /// default: exclusive — the drawer's pans never run
        /// simultaneously with the pages' scroll either.
        nonisolated func gestureRecognizer(
            _ gestureRecognizer: UIGestureRecognizer,
            shouldRecognizeSimultaneouslyWith
            otherGestureRecognizer: UIGestureRecognizer
        ) -> Bool {
            false
        }
    }
}
