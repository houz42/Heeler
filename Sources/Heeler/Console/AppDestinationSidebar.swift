import SwiftUI

// SPDX-License-Identifier: Apache-2.0

/// The wide-layout navigation (#A, narrow-sidebar revision): the same three
/// destinations as the phone drawer, drawn as a collapsible 184 pt reserved
/// column. The revision removes the in-sidebar collapse button — the page
/// heading's hamburger trigger toggles the fold (AX "Collapse/Expand
/// navigation sidebar") and the collapsed state persists.
struct AppDestinationSidebar: View {
    @Binding var selection: AppDestination

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text("Meadow")
                    .font(.headline.weight(.semibold))
                    .padding(.leading, 8)
                Spacer(minLength: 0)
            }
            .padding(.bottom, 15)

            VStack(spacing: 5) {
                ForEach(AppDestination.allCases) { destination in
                    AppDestinationRow(
                        destination: destination,
                        isSelected: destination == selection
                    ) {
                        selection = destination
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .frame(width: 184)
        .background(.bar)
        .overlay(alignment: .trailing) {
            Rectangle()
                .fill(.separator)
                .frame(width: 0.5)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("App destinations")
    }
}

#Preview("Sidebar") {
    AppDestinationSidebar(selection: .constant(.agents))
        .frame(width: 184, height: 640)
}

#Preview("Sidebar — dark") {
    AppDestinationSidebar(selection: .constant(.hosts))
        .preferredColorScheme(.dark)
        .frame(width: 184, height: 640)
}
