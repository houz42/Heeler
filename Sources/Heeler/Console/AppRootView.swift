import SwiftUI

// SPDX-License-Identifier: Apache-2.0

/// The adaptive top-level destination container (#A). Compact widths switch
/// between the three pages behind the compact `AppDestinationMenu`; regular
/// widths (iPad, split windows) put `AppDestinationSidebar` beside the pages
/// instead. The bottom destination tab bar does not exist and does not come
/// back.
///
/// Page state preservation is structural, not snapshot-based: all three pages
/// stay mounted and only the hidden ones stop hit-testing, so Console list
/// scroll/selection/search, the Hosts stack path, and Settings scroll each
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

    init(
        agents: some View,
        hosts: some View,
        settings: some View
    ) {
        self.agents = AnyView(agents)
        self.hosts = AnyView(hosts)
        self.settings = AnyView(settings)
    }

    /// The page views, one per destination. Kept alive across switches by
    /// the ZStack below; the menu/sidebar only changes `destination`.
    @ViewBuilder
    private func page(_ destination: AppDestination) -> some View {
        switch destination {
        case .agents: agents
        case .hosts: hosts
        case .settings: settings
        }
    }

    var body: some View {
        ZStack {
            ForEach(AppDestination.allCases) { candidate in
                page(candidate)
                    .opacity(candidate == destination ? 1 : 0)
                    .allowsHitTesting(candidate == destination)
                    .accessibilityHidden(candidate != destination)
            }
        }
        .overlay(alignment: .leading) {
            if let sidebar = sidebarChrome { sidebar }
        }
        .environment(\.appDestination, $destination)
    }

    /// Wide layouts: the collapsible destination sidebar over the page's
    /// own leading edge; compact layouts get nil — the in-page
    /// `AppDestinationMenu` carries the destinations there.
    @ViewBuilder
    private var sidebarChrome: (some View)? {
        if horizontalSizeClass == .regular {
            if isSidebarCollapsed {
                AppDestinationSidebarHandle {
                    withAnimation(.snappy) { isSidebarCollapsed = false }
                }
            } else {
                AppDestinationSidebar(
                    selection: $destination, isCollapsed: $isSidebarCollapsed)
            }
        }
    }
}

extension EnvironmentValues {
    /// The root destination switcher, so any page's toolbar can host the
    /// compact `AppDestinationMenu` without threading a binding through
    /// every initializer (ConsoleView's and HostListView's signatures stay
    /// untouched; both read this instead).
    @Entry var appDestination: Binding<AppDestination>? = nil
}

#Preview {
    AppRootView(
        agents: NavigationStack {
            List {
                ForEach(0..<20, id: \.self) { n in
                    Text("Agent \(n)")
                }
            }
            .navigationTitle("Agents")
        },
        hosts: NavigationStack {
            Text("Hosts")
        },
        settings: NavigationStack {
            Text("Settings")
        }
    )
}
