import SwiftUI

// SPDX-License-Identifier: Apache-2.0
//
// The Composer's input-mode suggestion menu (fork plan, Phase 2): live
// filtering for `/` slash commands (omp built-ins plus client-local), `#`
// tag values, and `@` agent names, shown above the text area while the
// draft's active token is one of those prefixes. Selection state and
// keyboard navigation live in ``ComposerRouterStore`` — up/down cycle,
// Enter accepts, Escape dismisses — so this row only renders and forwards
// taps. Mirrors the Skills suggestion row's shape: nothing is sent on
// accept, only the draft changes, and prose that happens to contain a
// prefix is not nagged (the menu only opens on the active token).

/// The router-backed suggestion menu above the Composer's text area.
/// Also carries the router's rejection banner so a rejected draft (bad
/// `/level` arguments, unresolved `@mention`, failed delivery) shows its
/// reason at the point of typing.
struct ComposerSuggestionRow: View {
    let router: ComposerRouterStore
    /// The current draft; an accepted suggestion is applied to it.
    let draft: String
    /// Applies an accepted suggestion's replacement to the Composer draft.
    let applyDraft: (String) -> Void

    /// The suggestion list's measured content height. The scroll view is
    /// sized to it so one match does not reserve the full cap of empty
    /// space; the cap only bounds long lists.
    @State private var listHeight: CGFloat = Self.maximumListHeight

    private static let maximumListHeight: CGFloat = 176

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let error = router.routingError {
                errorBanner(error)
            }
            if router.hasActiveSuggestions {
                header
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(
                            Array(router.suggestions.enumerated()),
                            id: \.element.id
                        ) { index, suggestion in
                            row(suggestion, isSelected:
                                index == router.selectedSuggestionIndex)
                        }
                    }
                    .onGeometryChange(for: CGFloat.self) { proxy in
                        proxy.size.height
                    } action: { height in
                        listHeight = height
                    }
                }
                .frame(height: min(listHeight, Self.maximumListHeight))
                .scrollBounceBehavior(.basedOnSize)
                Divider()
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Composer Suggestions")
    }

    private var header: some View {
        HStack(spacing: 8) {
            Text(headerTitle)
                .font(.caption.weight(.semibold))
                .textCase(.uppercase)
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
            Button {
                router.handleKey(.escape)
            } label: {
                Image(systemName: "xmark")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 28, height: 28)
                    .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Dismiss Composer Suggestions")
        }
    }

    private var headerTitle: String {
        switch router.suggestions.first?.kind {
        case .slash, .local: "Commands"
        case .tag: "Tags"
        case .mention: "Agents"
        case nil: "Composer"
        }
    }

    private func row(
        _ suggestion: ComposerSuggestion, isSelected: Bool
    ) -> some View {
        Button {
            router.selectSuggestion(at: router.suggestions.firstIndex(
                where: { $0.id == suggestion.id }) ?? 0)
            if let newDraft = router.acceptSelectedSuggestion(into: draft) {
                applyDraft(newDraft)
            }
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(String(suggestion.prefixCharacter))
                    .font(.callout.weight(.bold))
                    .fontDesign(.monospaced)
                    .foregroundStyle(.secondary)
                    .frame(width: 22)
                VStack(alignment: .leading, spacing: 1) {
                    Text(suggestion.title)
                        .font(.subheadline.weight(.medium))
                        .fontDesign(.monospaced)
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    if let detail = suggestion.detail {
                        Text(detail)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    if let usage = suggestion.usage {
                        Text(usage)
                            .font(.caption2)
                            .fontDesign(.monospaced)
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 7)
            .padding(.horizontal, 8)
            .background(
                isSelected
                    ? Color(uiColor: .secondarySystemFill)
                    : .clear,
                in: .rect(cornerRadius: 8))
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(suggestion.title)
        .accessibilityHint("Inserts \(suggestion.insertion) without sending it")
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }

    private func errorBanner(_ message: String) -> some View {
        HStack(spacing: 8) {
            Label(message, systemImage: "exclamationmark.triangle")
                .font(.caption)
                .foregroundStyle(.red)
                .lineLimit(2)
            Spacer(minLength: 0)
            Button {
                router.clearRoutingError()
            } label: {
                Image(systemName: "xmark")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 28, height: 28)
                    .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Dismiss Error")
        }
        .padding(.bottom, 4)
    }
}
