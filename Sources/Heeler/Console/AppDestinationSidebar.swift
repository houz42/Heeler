import SwiftUI

// SPDX-License-Identifier: Apache-2.0

/// The wide-layout navigation (#A): the same three destinations as
/// `AppDestinationMenu`, drawn as a collapsible sidebar instead. Phone keeps
/// the title menu; iPad portrait/landscape and split windows get this
/// column. Collapsing is a local presentation choice — the selected page and
/// all page state survive both the switch and the fold.
struct AppDestinationSidebar: View {
    @Binding var selection: AppDestination
    @Binding var isCollapsed: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text("Heeler")
                    .font(.subheadline.weight(.semibold))
                Spacer(minLength: 0)
                Button {
                    withAnimation(.snappy) { isCollapsed = true }
                } label: {
                    Image(systemName: "sidebar.leading")
                }
                .font(.subheadline)
                .frame(width: 36, height: 36)
                .contentShape(Rectangle())
                .buttonStyle(.plain)
                .hoverEffect(.highlight)
                .accessibilityLabel("Collapse sidebar")
            }
            .padding(.horizontal, 6)
            .padding(.bottom, 10)

            ForEach(AppDestination.allCases) { destination in
                sidebarButton(destination)
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .frame(width: 184)
        .background(.bar)
        .overlay(alignment: .trailing) {
            Rectangle()
                .fill(.separator)
                .frame(width: 0.5)
        }
    }

    private func sidebarButton(_ destination: AppDestination) -> some View {
        let isSelected = destination == selection
        return Button {
            selection = destination
        } label: {
            HStack(spacing: 10) {
                Image(systemName: destination.systemImage)
                    .frame(width: 20)
                Text(destination.title)
                Spacer(minLength: 0)
            }
            .font(.footnote.weight(isSelected ? .semibold : .regular))
            .foregroundStyle(isSelected ? Color.accentColor : Color.primary)
            .padding(.horizontal, 12)
            .frame(maxHeight: .infinity)
            .frame(height: 36)
            .background(
                isSelected
                    ? RoundedRectangle(cornerRadius: 8).fill(.quaternary)
                    : nil)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .hoverEffect(.highlight)
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }
}

/// The thin strip that replaces the sidebar when it is collapsed: one
/// expand control, so a folded sidebar never strands the user on a wide
/// layout with no way back.
struct AppDestinationSidebarHandle: View {
    let expand: () -> Void

    var body: some View {
        Button(action: expand) {
            Image(systemName: "sidebar.leading")
                .font(.subheadline)
                .frame(width: 40, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .hoverEffect(.highlight)
        .background(.bar)
        .overlay(alignment: .trailing) {
            Rectangle()
                .fill(.separator)
                .frame(width: 0.5)
        }
        .accessibilityLabel("Expand sidebar")
        .accessibilityHint("Shows the Agents, Hosts, and Settings destinations.")
    }
}

#Preview("Sidebar") {
    AppDestinationSidebar(
        selection: .constant(.agents), isCollapsed: .constant(false))
        .frame(height: 640)
}

#Preview("Sidebar — dark, collapsed handle") {
    AppDestinationSidebarHandle(expand: {})
        .preferredColorScheme(.dark)
        .frame(height: 640)
}
