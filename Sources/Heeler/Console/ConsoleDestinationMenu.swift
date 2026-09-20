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
                if let triggerFocus {
                    // Focus return (#A): the drawer hands focus back here.
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


/// The phone's on-demand navigation surface (#A revision): a 184 pt drawer
/// overlay — the page viewport NEVER changes width. Destinations only,
/// current one checked; dismissal via close ×, outside tap, or Escape;
/// content behind is inert while open; focus returns to the trigger.
struct AppDestinationDrawer: View {
    let selection: Binding<AppDestination>
    let close: (_ restoreFocus: Bool) -> Void

    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Text("Heeler")
                        .font(.headline.weight(.semibold))
                    Spacer(minLength: 0)
                    Button {
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
                    .keyboardShortcut(.escape)
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
            // 184 pt TOTAL occupied width (review finding 2): the outer
            // frame wraps the padded content, so the padding lands inside
            // the 184 — the app viewport under the drawer is unchanged
            // and the drawer itself measures exactly 184 pt.
            .padding(.vertical, 20)
            .padding(.horizontal, 8)
            .frame(width: 184)
            .frame(maxHeight: .infinity, alignment: .top)
            .background(Color(.systemBackground))
            .clipShape(.rect(bottomTrailingRadius: 18, topTrailingRadius: 18))
            .shadow(color: .black.opacity(0.12), radius: 28, x: 10)

            // The scrim: outside-tap dismissal + inert content behind.
            Color.black.opacity(0.19)
                .ignoresSafeArea()
                .onTapGesture { close(true) }
                .accessibilityLabel("Dismiss navigation")
                .accessibilityAddTraits(.isButton)
        }
        .accessibilityAddTraits(.isModal)
        .transition(.move(edge: .leading).combined(with: .opacity))
    }
}
