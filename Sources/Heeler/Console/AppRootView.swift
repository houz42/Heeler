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
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    let agents: AnyView
    let hosts: AnyView
    let settings: AnyView
    /// False while a page's own navigation covers the window — an Agent
    /// detail pushed in the Console — so destination chrome can step aside.
    /// Defaults to "top-level always focused" for previews and simple hosts.
    private let isPageContentFocused: () -> Bool

    /// The width at which the destination sidebar takes over from the
    /// compact menu — the preview's `@container (min-width:900px)` rule.
    private static let sidebarMinimumWidth: CGFloat = 900
    private static let sidebarWidth: CGFloat = 184

    init(
        agents: some View,
        hosts: some View,
        settings: some View,
        isPageContentFocused: (() -> Bool)? = nil
    ) {
        self.agents = AnyView(agents)
        self.hosts = AnyView(hosts)
        self.settings = AnyView(settings)
        self.isPageContentFocused = isPageContentFocused ?? { true }
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
            let showsSidebar = sidebarWanted(width: geometry.size.width)
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
                if sidebarCollapsedWanted(width: geometry.size.width) {
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
            // pointer-events:none), or while a pushed detail owns the
            // window. Computed from the same geometry that drew the
            // sidebar, so a phone window never inerts its menu.
            .environment(
                \.appDestinationMenuInert,
                !isPageContentFocused() || showsSidebar)
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
    private func sidebarWanted(width: CGFloat) -> Bool {
        width >= Self.sidebarMinimumWidth && !isSidebarCollapsed
            && isPageContentFocused()
    }

    /// The fold's expand handle: wide window, sidebar folded, top-level
    /// page on stage.
    private func sidebarCollapsedWanted(width: CGFloat) -> Bool {
        width >= Self.sidebarMinimumWidth && isSidebarCollapsed
            && isPageContentFocused()
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
    /// non-hit-testable and accessibility-hidden when set.
    @Entry var appDestinationMenuInert: Bool = false
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
