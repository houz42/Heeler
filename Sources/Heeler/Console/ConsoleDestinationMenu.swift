import SwiftUI

// SPDX-License-Identifier: Apache-2.0

/// The app's three top-level destinations. Hosts and Settings used to live
/// behind Console toolbar buttons as sheets; the approved redesign promotes
/// them to peer pages, reached from one selector that sits top-left on every
/// page (#A: same compact typography everywhere, bottom tab bar never
/// returns).
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

    var systemImage: String {
        switch self {
        case .agents: "person.2"
        case .hosts: "server.rack"
        case .settings: "gearshape"
        }
    }
}

/// The compact top-left destination selector (#A): one tappable
/// title-and-chevron that opens a menu of the three destinations with the
/// current one checked. Identical typography, size, and inset on every page
/// — the size the user approved for the Agents page is the standard, so this
/// view is the ONLY place that draws a destination title.
///
/// Wide layouts do not show this menu's long-press affordance at all: the
/// adaptive sidebar (`AppDestinationSidebar`) carries the same destinations
/// there, and the menu stays available for the collapsed-sidebar state.
struct AppDestinationMenu: View {
    @Binding var selection: AppDestination
    /// True while destination chrome must not be a control at all — a
    /// pushed detail owns the window (no destination navigation competes
    /// inside chat/terminal/details, #A). The title renders as PLAIN
    /// text: no chevron, no capsule, no Menu semantics in the AX tree.
    @Environment(\.appDestinationMenuSuppressed) private var isSuppressed
    /// True while the destination sidebar carries the destinations (wide
    /// layouts — the preview's `pointer-events:none` on the page title).
    /// The title stays legible but stops being tappable.
    @Environment(\.appDestinationMenuInert) private var isInert

    var body: some View {
        if isSuppressed {
            // Plain title, exactly the approved compact typography — no
            // chevron, no capsule, no button: the capsule itself was the
            // review finding, so a suppressed state must not render ANY
            // destination-control chrome.
            Text(selection.title)
                .font(.headline)
                .frame(minHeight: 36)
        } else {
            Menu {
                Picker("Destination", selection: $selection) {
                    ForEach(AppDestination.allCases) { destination in
                        Label(destination.title, systemImage: destination.systemImage)
                            .tag(destination)
                    }
                }
            } label: {
                // 17 pt semibold + 36 pt height, matching the approved
                // compact Agents title: `.plain` keeps the system's default
                // large-title button chrome out of the way so all three
                // pages render the same inset.
                HStack(spacing: 7) {
                    Text(selection.title)
                        .font(.headline)
                        .foregroundStyle(.primary)
                    Image(systemName: "chevron.down")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
                .frame(minHeight: 36)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .allowsHitTesting(!isInert)
            .accessibilityLabel("\(selection.title), switch destination")
            .accessibilityAddTraits(isInert ? [] : [.isButton])
            .accessibilityHint(
                isInert
                    ? "Destinations are in the sidebar."
                    : "Opens the Agents, Hosts, and Settings menu.")
        }
    }
}

#Preview {
    AppDestinationMenu(selection: .constant(.agents))
        .padding()
}
