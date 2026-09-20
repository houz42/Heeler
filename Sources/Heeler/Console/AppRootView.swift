import SwiftUI

// SPDX-License-Identifier: Apache-2.0

/// The adaptive top-level destination container (#A). Narrow windows switch
/// between the three pages behind the compact `AppDestinationMenu`; wide
/// windows (≥900 pt available width, matching the approved preview's 900 px
/// container breakpoint) get the collapsible `AppDestinationSidebar` beside
/// the pages instead — a RESERVED column, never an overlay, so page content
/// reflows rather than being covered.
///
/// Destination chrome disappears entirely while a page's own navigation
/// holds the window (an Agent detail pushed in the Console): no sidebar, no
/// in-page menu — nothing destination-shaped competes inside chat,
/// terminal, or detail screens.
///
/// Page state preservation is structural, not snapshot-based: all three
/// pages stay mounted and only the hidden ones stop hit-testing, so Console
/// list scroll/selection, the Hosts stack path, and Settings scroll each
/// survive a round trip exactly as they were.
struct AppRootView: View {
    @State private var destination: AppDestination = .agents
    /// Wide layouts only: the destination sidebar's fold. Sticky per window
    /// session, matching the approved preview's collapsible behavior.
    @State private var isSidebarCollapsed = false
    /// Which pages currently cover the window with their OWN navigation
    /// (a pushed Agent detail, a pushed Host detail, a pushed Settings
    /// page) — reported upward through `AppDestinationPageFocusKey`. Any
    /// page being unfocused steps the destination chrome aside (#A: no
    /// destination navigation competes inside chat/terminal/details).
    @State private var unfocusedPages: Set<AppDestination> = []
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    let agents: AnyView
    let hosts: AnyView
    let settings: AnyView
    /// Legacy single-signal focus (the Console's pushed detail, provided
    /// by the production/demo roots). Combined with the per-page focus
    /// reports below — the Console could not report through the preference
    /// without an extra wrapper, and this closure was already wired.
    private let isAgentsPageFocused: () -> Bool

    /// The width at which the destination sidebar takes over from the
    /// compact menu — the preview's `@container (min-width:900px)` rule.
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
    /// the mounted stack below; the menu/sidebar only changes `destination`.
    @ViewBuilder
    private func page(_ destination: AppDestination) -> some View {
        switch destination {
        case .agents: agents
        case .hosts: hosts
        case .settings: settings
        }
    }

    var body: some View {
        GeometryReader { geometry in
            let isPageFocused =
                isAgentsPageFocused() && unfocusedPages.isEmpty
            let showsSidebar =
                sidebarWanted(width: geometry.size.width, isPageFocused: isPageFocused)
            HStack(spacing: 0) {
                if showsSidebar {
                    // A reserved column: page content reflows beside it.
                    AppDestinationSidebar(
                        selection: $destination, isCollapsed: $isSidebarCollapsed)
                }
                pages
            }
            // The collapsed state's expand control rides in the header band
            // (the preview's ☰ at the top of the screen), never a mid-content
            // tab — and only while a top-level page owns the window.
            .overlay(alignment: .topTrailing) {
                if sidebarCollapsedWanted(
                    width: geometry.size.width, isPageFocused: isPageFocused)
                {
                    AppDestinationSidebarHandle {
                        withAnimation(.snappy) { isSidebarCollapsed = false }
                    }
                    .padding(.trailing, 16)
                    .padding(.top, 4)
                }
            }
            .environment(\.appDestination, $destination)
            // The in-page menus render inert ONLY while the reserved
            // sidebar column is in this frame's layout (the preview's
            // pointer-events:none), or while ANY page's pushed detail owns
            // the window (no destination chrome inside chat/terminal/
            // details — the Console's path, a Host detail, a pushed
            // Settings page alike). Computed from the same geometry that
            // drew the sidebar, so a phone window never inerts its menu.
            .environment(
                \.appDestinationMenuInert,
                !isPageFocused || showsSidebar)
            // A pushed detail (any page) suppresses the in-page
            // destination menus entirely: plain title, no Menu semantics.
            .environment(
                \.appDestinationMenuSuppressed, !isPageFocused)
            // Pages report their own pushed-navigation state upward; the
            // root aggregates it into the per-page focus used above.
            .onPreferenceChange(AppDestinationPageFocusKey.self) { reports in
                unfocusedPages = reports
            }
        }
    }


    /// All three pages stay mounted; only the selected one is on stage.
    private var pages: some View {
        ZStack {
            ForEach(AppDestination.allCases) { candidate in
                page(candidate)
                    .opacity(candidate == destination ? 1 : 0)
                    .allowsHitTesting(candidate == destination)
                    .accessibilityHidden(candidate != destination)
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
    /// The root destination switcher, so any page's toolbar can host the
    /// compact `AppDestinationMenu` without threading a binding through
    /// every initializer (ConsoleView's and HostListView's signatures stay
    /// untouched; both read this instead). Nil outside `AppRootView`.
    @Entry var appDestination: Binding<AppDestination>? = nil
    /// True while the in-page destination menus must render inert (the
    /// sidebar carries the destinations, or a pushed detail owns the
    /// window) — `AppRootView` sets it; pages render their menu
    /// non-hit-testable when set.
    @Entry var appDestinationMenuInert: Bool = false
    /// True while a page's pushed detail owns the window — the in-page
    /// destination menus then render as PLAIN titles: no chevron, no
    /// capsule, no Menu semantics (#A: no destination chrome at all
    /// inside chat/terminal/details).
    @Entry var appDestinationMenuSuppressed: Bool = false
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
