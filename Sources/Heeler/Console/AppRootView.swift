import SwiftUI

// SPDX-License-Identifier: Apache-2.0

/// The adaptive top-level destination container (#A, narrow-sidebar
/// revision). Root pages carry a small hamburger trigger beside their
/// plain titles: narrow windows open a 184 pt drawer OVERLAY (the page
/// viewport never changes); wide windows (≥900 pt) show the same
/// destinations in a collapsible 184 pt reserved sidebar, and the same
/// trigger toggles the fold — collapsed state persists.
///
/// ALL global destination chrome — trigger, drawer, sidebar — hides while
/// any page's own navigation covers the window (chat/terminal, host or
/// route details, file reader): Back/Close restores the originating page
/// and its prior sidebar state untouched.
///
/// Page state preservation is structural, not snapshot-based: all three
/// pages stay mounted and only the hidden ones stop hit-testing, and the
/// drawer is an overlay — so query/filter/scroll state survives every
/// open/close and switch exactly as it was.
struct AppRootView: View {
    @State private var destination: AppDestination = .agents
    /// Wide layouts only: the destination sidebar's fold. Sticky per
    /// window session — a pushed detail that hides the chrome restores
    /// the same fold on Back (#A).
    @State private var isSidebarCollapsed = false
    /// Phone drawer presentation (v2 interactive): the LIVE slide
    /// distance, 0 … 184 pt — every path (trigger, left-edge swipe,
    /// drag-to-close) writes this one value, so the motion is
    /// continuous across gesture and settle. `isDrawerOpen` is the
    /// RESTING state; the drawer MOUNTS while presented (see
    /// `drawerOverlay`).
    @State private var drawerReveal: CGFloat = 0
    /// The drawer's RESTING state (v2): true once an open is committed —
    /// the trigger's toggle, the edge swipe's settle, or a completed
    /// drag-snap. The LIVE slide distance is `drawerReveal`.
    @State private var isDrawerOpen = false
    /// True ONLY while a finger is driving the drawer live (edge pan
    /// or drag-to-close) — keeps the drawer MOUNTED during the
    /// gesture so the finger tracks 1:1 without a mount flash.
    @State private var isTrackingDrawer = false
    /// True only while a gesture-committed close is still sliding out
    /// — keeps the drawer mounted through the exit spring so the
    /// close is a slide, not a vanish (unmount happens on settle).
    @State private var isSettlingDrawer = false
    /// Focus return (#A): the trigger that opened the drawer receives
    /// focus back on dismissal.
    @FocusState private var isTriggerFocused: Bool
    /// VoiceOver/switch-control focus (review rounds): focus moves INTO
    /// the drawer on open and back to the TRIGGER on dismissal — the
    /// trigger itself is the assistive-focus target.
    @AccessibilityFocusState private var isDrawerAXFocused: Bool
    /// Which pages currently cover the window with their OWN navigation
    /// — reported upward through `AppDestinationPageFocusKey`.
    @State private var unfocusedPages: Set<AppDestination> = []
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    let agents: AnyView
    let hosts: AnyView
    let settings: AnyView
    /// Legacy single-signal focus (the Console's pushed detail, provided
    /// by the production/demo roots), combined with the per-page focus
    /// reports.
    private let isAgentsPageFocused: () -> Bool

    /// The width at which the reserved sidebar takes over from the
    /// drawer — the preview's `@container (min-width:900px)` rule.
    private static let sidebarMinimumWidth: CGFloat = 900
    init(
        agents: some View,
        hosts: some View,
        settings: some View,
        isPageContentFocused: (() -> Bool)? = nil
    ) {
        self.agents = AnyView(agents)
        self.hosts = AnyView(hosts)
        self.settings = AnyView(settings)
        self.isAgentsPageFocused = isPageContentFocused ?? { true }
    }

    /// The page views, one per destination. Kept alive across switches by
    /// the mounted stack below; the trigger/drawer/sidebar only change
    /// `destination`.
    @ViewBuilder
    private func page(_ destination: AppDestination) -> some View {
        switch destination {
        case .agents: agents
        case .hosts: hosts
        case .settings: settings
        }
    }

    /// True while a top-level page owns the window — no pushed detail on
    /// any page. ALL destination chrome is visible only in this state.
    private var isPageFocused: Bool {
        isAgentsPageFocused() && unfocusedPages.isEmpty
    }

    var body: some View {
        GeometryReader { geometry in
            let isWide = geometry.size.width >= Self.sidebarMinimumWidth
            let showsSidebar = isWide && !isSidebarCollapsed && isPageFocused
            HStack(spacing: 0) {
                if showsSidebar {
                    // A reserved column: page content reflows beside it.
                    AppDestinationSidebar(selection: $destination)
                }
                pages
            }
            // The phone drawer (v2 interactive): an overlay; the page
            // viewport is untouched behind it. The drawer slides by
            // `drawerReveal` — the trigger, the left-edge swipe, and
            // the drag-to-close all write that one value, so the motion
            // is continuous and the scrim fades in sync
            // (reveal-proportional). Mounting (see `drawerOverlay`)
            // removes the closed drawer from the AX tree entirely —
            // the v1 containment. On open: assistive focus moves INTO
            // the drawer; on dismissal it returns to the trigger
            // (review finding 3).
            .overlay {
                drawerOverlay
            }
            // The left-edge swipe open (v2): a UIKit screen-edge pan on
            // the window's root view, enabled on the phone's ROOT pages
            // ONLY — the same suppression seam as the trigger, so the
            // pushed detail's interactive back-swipe is never competed
            // with. Additive to the hamburger trigger (the accessible
            // path), never its replacement.
            .background(
                DrawerEdgePanBridge(
                    isEnabled: !isWide && isPageFocused && !isDrawerOpen,
                    onBegan: { isTrackingDrawer = true },
                    onTranslate: { translation in
                        // The finger tracks the reveal 1:1, rubber
                        // damped past full open.
                        drawerReveal = AppDestinationDrawer.dampedReveal(
                            raw: translation)
                    },
                    onRelease: { translation, velocity, cancelled in
                        settleEdgeOpen(
                            translation: translation,
                            velocity: velocity,
                            cancelled: cancelled)
                    }))
            .onChange(of: isDrawerOpen) { _, open in
                if open {
                    // Move assistive focus into the drawer once it
                    // lands. GUARD (review round): a fast scrim-dismiss
                    // inside the delay must not steal focus back onto an
                    // already-dismissed drawer. 0.6 s clears the
                    // presentation spring (v2): the drawer is not an
                    // AX target until its frame settles flush, so the
                    // assignment must land after.
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                        if isDrawerOpen {
                            isDrawerAXFocused = true
                        }
                    }
                }
            }
            // A width crossing RESETS the compact presentation (review
            // round v2): an open narrow drawer must not survive the
            // transition to the wide layout — the reserved sidebar owns
            // destinations there, and a leftover modal drawer (with its
            // scrim and AX containment) would cover it. The drawer is
            // dropped WITHOUT the exit settle: the window is resizing
            // under it, and the wide layout's sidebar slide-in is the
            // transition the user sees.
            .onChange(of: isWide) { _, wide in
                if wide, drawerIsPresented {
                    isDrawerOpen = false
                    isTrackingDrawer = false
                    isSettlingDrawer = false
                    drawerReveal = 0
                    isDrawerAXFocused = false
                }
            }
            .environment(\.appDestination, $destination)
            .environment(\.appNavigationTrigger, triggerContext(isWide: isWide))
            .environment(\.appNavigationTriggerFocus, $isTriggerFocused)
            // Direct focus reports: preferences do not reliably cross
            // navigationDestination boundaries, so pages ALSO report
            // their pushed state through this closure (onChange-driven).
            .environment(
                \.appNavigationFocusReport,
                AppNavigationFocusReport { page, isPushed in
                    if isPushed {
                        unfocusedPages.insert(page)
                    } else {
                        unfocusedPages.remove(page)
                    }
                })
            // ALL global destination chrome — trigger included — hides
            // while any page's pushed detail owns the window (#A).
            .environment(
                \.appDestinationMenuSuppressed, !isPageFocused)
            // Pages report their own pushed-navigation state upward; the
            // root aggregates it into the per-page focus used above.
            .onPreferenceChange(AppDestinationPageFocusKey.self) { reports in
                unfocusedPages = reports
            }
        }
    }

    /// The trigger's identity + action for the CURRENT width: fold toggle
    /// on wide layouts, drawer toggle on narrow ones. A width change
    /// simply recomputes this — never a page rebuild. The gesture is
    /// additive (v2): the trigger stays the accessible path.
    private func triggerContext(isWide: Bool) -> AppNavigationTriggerContext? {
        guard isPageFocused else { return nil }
        if isWide {
            return AppNavigationTriggerContext(
                accessibilityLabel: isSidebarCollapsed
                    ? "Expand navigation sidebar"
                    : "Collapse navigation sidebar",
                accessibilityValue: isSidebarCollapsed ? "Collapsed" : "Expanded",
                action: {
                    withAnimation(.snappy) { isSidebarCollapsed.toggle() }
                })
        }
        return AppNavigationTriggerContext(
            accessibilityLabel: "Open navigation",
            accessibilityValue: isDrawerOpen ? "Open" : "Closed",
            action: {
                if isDrawerOpen {
                    closeDrawer(restoreFocus: true)
                } else {
                    openDrawer()
                }
            })
    }

    /// Opens the drawer to its resting state (v2) — the trigger's path
    /// and a committed edge swipe. Mounts (if not already tracking)
    /// with the standard move-from-edge transition, then springs the
    /// reveal full. The exit-settle flag clears: a fresh open cancels
    /// any still-sliding prior close.
    private func openDrawer() {
        isTrackingDrawer = false
        isSettlingDrawer = false
        withAnimation(AppDestinationDrawer.presentationSpring) {
            drawerReveal = AppDestinationDrawer.width
            isDrawerOpen = true
        }
    }

    /// Closes the drawer (v2): springs the reveal to zero, clears the
    /// resting state, and — for the assistive/keyboard dismissal paths —
    /// hands focus back to the trigger (keyboard + the .screenChanged
    /// VoiceOver post; the trigger is the page's FIRST accessible
    /// element, topBarLeading, so the notification's default target IS
    /// the trigger — binding an AccessibilityFocusState through env
    /// into a toolbar item suppresses the item's rendering, verified).
    private func closeDrawer(restoreFocus: Bool) {
        settleClosed()
        withAnimation(AppDestinationDrawer.presentationSpring) {
            isDrawerOpen = false
        }
        isDrawerAXFocused = false
        if restoreFocus {
            // Keyboard focus returns to the trigger.
            isTriggerFocused = true
            // Assistive focus returns to the trigger too (review
            // round): the trigger is the page's FIRST accessible
            // element (topBarLeading), so a .screenChanged post lands
            // VoiceOver on it — binding an AccessibilityFocusState
            // through env into a toolbar item suppresses the item's
            // rendering (verified), so the notification is the
            // mechanism.
            UIAccessibility.post(
                notification: .screenChanged, argument: nil)
        }
    }

    /// The edge-swipe release (v2): the finger's projected position —
    /// translation plus momentum (velocity × the settle horizon) —
    /// decides. Past the settle point commits the open; anything less
    /// snaps closed. Same rule as the drag-to-close, mirrored.
    private func settleEdgeOpen(
        translation: CGFloat, velocity: CGFloat, cancelled: Bool
    ) {
        let projected = AppDestinationDrawer.dampedReveal(
            raw: translation + velocity * 0.12)
        let committed = !cancelled
            && (projected >= AppDestinationDrawer.settlePoint
                || translation >= AppDestinationDrawer.settlePoint)
        if committed {
            openDrawer()
        } else {
            settleClosed()
        }
    }

    /// The snapped-closed settle (v2): the reveal springs to zero; the
    /// drawer stays MOUNTED through the slide (isSettlingDrawer) and
    /// unmounts when the spring has died — the exit is a slide, not a
    /// vanish.
    private func settleClosed() {
        withAnimation(AppDestinationDrawer.presentationSpring) {
            drawerReveal = 0
        }
        isTrackingDrawer = false
        isSettlingDrawer = true
        DispatchQueue.main.asyncAfter(
            deadline: .now() + AppDestinationDrawer.settleOutInterval
        ) {
            isSettlingDrawer = false
        }
    }

    /// The phone drawer overlay (v2 revision): the standard SwiftUI
    /// slide-over — a ZStack-layered sibling that MOUNTS only while
    /// presented (resting open, finger-tracked, or mid-settle) with a
    /// `.move(.leading)` transition, sliding by `drawerReveal`. The
    /// scrim fades IN SYNC (reveal-proportional), so the edge-swipe
    /// open and the drag-to-close both carry it. MOUNTING is what
    /// keeps the closed drawer out of the AX tree — the v1 property
    /// that every always-mounted AX gate (hidden, children-ignore,
    /// focus-detach, opacity-0, rendered-geometry) failed to
    /// reproduce (verified: the offscreen × stayed resolvable through
    /// all of them; XCUITest kept matching it minutes after close).
    private var drawerOverlay: some View {
        let presented = drawerIsPresented
        return ZStack(alignment: .leading) {
            if presented {
                // The scrim: reveal-proportional (v2), outside-tap
                // dismissal + inert content behind.
                Color.black
                    .opacity(
                        0.19 * min(
                            drawerReveal / AppDestinationDrawer.width, 1))
                    .ignoresSafeArea()
                    .onTapGesture { closeDrawer(restoreFocus: true) }
                    .accessibilityLabel("Dismiss navigation")
                    .accessibilityAddTraits(.isButton)

                    .allowsHitTesting(true)
                AppDestinationDrawer(
                    selection: $destination,
                    close: { restoreFocus in
                        closeDrawer(restoreFocus: restoreFocus)
                    },
                    reveal: $drawerReveal,
                    isOpen: isDrawerOpen,
                    isPresented: drawerIsPresented,
                    isFocused: $isDrawerAXFocused,
                    onTracking: { tracking in
                        isTrackingDrawer = tracking
                    })
                    // While a finger drives the drawer the mount must
                    // NOT play the insertion transition (the reveal
                    // already places it); programmatic opens get the
                    // standard move-from-edge slide instead.
                    .transition(
                        isTrackingDrawer ? .identity
                        : .move(edge: .leading).combined(with: .opacity))
            }
        }
        // While the drawer is presented, the pages behind must be inert
        // to touch AND absent from the AX tree (v1 containment, applied
        // to the WHOLE overlay layer so the scrim/drawer pair contains
        // the user; pages are separately hidden through `pages`).
        .accessibilityHidden(!presented)
        .allowsHitTesting(presented)
    }

    /// ONE presentation predicate for the drawer's whole lifecycle
    /// (review round v2): mounting, the pages' AX/hit-test exclusion,
    /// and the overlay's modal containment all read THIS — resting
    /// open, finger-tracked, mid-settle, or any live reveal. Containment
    /// ends exactly when the mount drops (dismissal complete), never
    /// earlier.
    private var drawerIsPresented: Bool {
        isDrawerOpen || isTrackingDrawer || isSettlingDrawer
            || drawerReveal > 0
    }

    /// All three pages stay mounted; only the selected one is on stage.
    /// While the drawer is presented — resting open, finger-tracked, OR
    /// MID-SETTLE (review round v2: the pages' exclusion must read the
    /// SAME lifecycle predicate as the drawer's MOUNT, not the raw
    /// reveal — settleClosed() zeroes `drawerReveal` at once while the
    /// exit spring is still sliding and `isSettlingDrawer` holds the
    /// mount 0.5 s, so a reveal-only gate re-exposed the page to AX
    /// under the still-mounted drawer mid-exit) — the on-stage page is
    /// excluded from AX AND hit-testing (review finding 3): a modal
    /// must contain the user; containment releases only when the
    /// dismissal completes (the mount drops).
    private var pages: some View {
        ZStack {
            ForEach(AppDestination.allCases) { candidate in
                page(candidate)
                    .opacity(candidate == destination ? 1 : 0)
                    .allowsHitTesting(
                        candidate == destination && !drawerIsPresented)
                    .accessibilityHidden(
                        candidate != destination || drawerIsPresented)
            }
        }
    }

    /// Sidebar by AVAILABLE WIDTH (the preview's container query), not
    /// size class alone — a narrow split window on iPad keeps the compact
    /// menu — and only while a top-level page owns the window.
    private func sidebarWanted(width: CGFloat, isPageFocused: Bool) -> Bool {
        width >= Self.sidebarMinimumWidth && !isSidebarCollapsed
            && isPageFocused
    }

    /// The fold's expand handle: wide window, sidebar folded, top-level
    /// page on stage.
    private func sidebarCollapsedWanted(width: CGFloat, isPageFocused: Bool) -> Bool {
        width >= Self.sidebarMinimumWidth && isSidebarCollapsed
            && isPageFocused
    }
}


/// Upward focus reports: a page whose own navigation is pushed (Host
/// detail, Settings sub-page) reports its destination here, so the root
/// can step the destination chrome aside for EVERY page, not just the
/// Console. Values merge across pages; empty = every top-level page owns
/// its window.
private struct AppDestinationPageFocusKey: PreferenceKey {
    static var defaultValue: Set<AppDestination> { [] }

    static func reduce(value: inout Set<AppDestination>, nextValue: () -> Set<AppDestination>) {
        value.formUnion(nextValue())
    }
}

/// The modifier a page applies to report pushed-navigation state upward.
/// Applied INSIDE the page (on the NavigationStack's content), so hidden
/// pages report too — their detail is real state even while not visible.
/// A page's direct focus report to the root. Preferences do not cross
/// navigationDestination boundaries; this closure does.
struct AppNavigationFocusReport {
    var report: (AppDestination, Bool) -> Void

    func callAsFunction(_ page: AppDestination, _ isPushed: Bool) {
        report(page, isPushed)
    }
}

struct AppDestinationPageFocusModifier: ViewModifier {
    let destination: AppDestination
    let isContentPushed: Bool

    func body(content: Content) -> some View {
        content.preference(
            key: AppDestinationPageFocusKey.self,
            value: isContentPushed ? [destination] : [])
    }
}


extension EnvironmentValues {
    /// The root destination switcher, so any page's toolbar can host its
    /// destination chrome without threading a binding through every
    /// initializer. Nil outside `AppRootView`.
    @Entry var appDestination: Binding<AppDestination>? = nil
    /// The hamburger trigger's identity + action for the current width
    /// (drawer toggle on phone, sidebar fold on wide layouts). Nil while a
    /// pushed detail owns the window — ALL destination chrome hides.
    @Entry var appNavigationTrigger: AppNavigationTriggerContext? = nil
    /// True while the in-page destination menus must render inert.
    @Entry var appDestinationMenuInert: Bool = false
    /// True while a page's pushed detail owns the window — ALL global
    /// destination chrome (trigger, drawer, sidebar) hides (#A).
    @Entry var appDestinationMenuSuppressed: Bool = false
    /// Direct per-page focus reporting: pages call this when their own
    /// pushed-navigation state changes. `isPushed` true = the page's
    /// detail owns the window.
    @Entry var appNavigationFocusReport:
        AppNavigationFocusReport? = nil
    /// The shared reading-text-size store (#A settings revision): the
    /// Settings page and the chat reading text consume ONE instance.
    /// Nil outside the roots that inject it.
    @Entry var appReadingTextSize: ReadingTextSizeSettings? = nil
    /// Focus return (#A): the drawer hands focus back to the trigger on
    /// dismissal. Optional — nil outside `AppRootView`, where the heading
    /// simply does not participate in focus return.
    var appNavigationTriggerFocus: FocusState<Bool>.Binding? {
        get { self[AppNavigationTriggerFocusKey.self] }
        set { self[AppNavigationTriggerFocusKey.self] = newValue }
    }
}

/// The absent key-focus default. A computed `static var` — unlike a
/// stored `let`, it is not shared mutable state, so the concurrency check
/// passes for the non-Sendable `FocusState.Binding`.
private struct AppNavigationTriggerFocusKey: EnvironmentKey {
    static var defaultValue: FocusState<Bool>.Binding? { nil }
}

#Preview {
    AppRootView(
        agents: NavigationStack {
            List {
                ForEach(0..<20, id: \.self) { n in
                    Text("Agent \(n)")
                }
            }
        },
        hosts: NavigationStack {
            Text("Hosts")
        },
        settings: NavigationStack {
            Text("Settings")
        }
    )
}
