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
    /// Phone drawer presentation. An overlay, never a viewport change.
    @State private var isDrawerOpen = false
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
            // The phone drawer: an overlay; the page viewport is untouched
            // behind it. On open: assistive focus moves INTO the drawer;
            // on dismissal it returns to the trigger (review finding 3).
            .overlay {
                if isDrawerOpen {
                    AppDestinationDrawer(
                        selection: $destination,
                        close: { restoreFocus in
                            withAnimation(.snappy) { isDrawerOpen = false }
                            isDrawerAXFocused = false
                            if restoreFocus {
                                // Keyboard focus returns to the trigger.
                                isTriggerFocused = true
                                // Assistive focus returns to the trigger
                                // too (review round): the trigger is the
                                // page's FIRST accessible element
                                // (topBarLeading), so a .screenChanged
                                // post lands VoiceOver on it — binding an
                                // AccessibilityFocusState through env
                                // into the toolbar suppresses the item's
                                // rendering (verified), so the
                                // notification is the mechanism.
                                UIAccessibility.post(
                                    notification: .screenChanged,
                                    argument: nil)
                            }
                        })
                        .accessibilityFocused($isDrawerAXFocused)
                }
            }
            .onChange(of: isDrawerOpen) { _, open in
                if open {
                    // Move assistive focus into the drawer once it lands.
                    // GUARD (review round): a fast scrim-dismiss inside
                    // the delay must not steal focus back onto an
                    // already-dismissed drawer.
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                        if isDrawerOpen {
                            isDrawerAXFocused = true
                        }
                    }
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
    /// simply recomputes this — never a page rebuild.
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
            action: { withAnimation(.snappy) { isDrawerOpen.toggle() } }
        )
    }


    /// All three pages stay mounted; only the selected one is on stage.
    /// While the drawer is open, the on-stage page is excluded from AX
    /// AND hit-testing too (review finding 3): a modal must contain the
    /// user — the scrim blocks sighted touches, but VoiceOver/switch
    /// control would still reach the page without this.
    private var pages: some View {
        ZStack {
            ForEach(AppDestination.allCases) { candidate in
                page(candidate)
                    .opacity(candidate == destination ? 1 : 0)
                    .allowsHitTesting(
                        candidate == destination && !isDrawerOpen)
                    .accessibilityHidden(
                        candidate != destination || isDrawerOpen)
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
