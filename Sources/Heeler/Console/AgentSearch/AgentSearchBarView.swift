import SwiftUI
import UIKit

// SPDX-License-Identifier: Apache-2.0
//
// The Agents search surface (approved redesign, handoff §B): a compact
// field with fuzzy suggestions, removable filter chips, and keyboard
// semantics that NEVER submit a message — Enter/Tab accepts the highlighted
// suggestion, arrows navigate, Esc dismisses, and typing routes to the
// agent-list engine only.

/// One row of the suggestion list.
struct AgentSearchSuggestionRow: View {
    let suggestion: AgentSearchEngine.Suggestion
    let isHighlighted: Bool
    let isSelected: Bool

    var body: some View {
        HStack(spacing: 8) {
            Text(suggestion.field.label)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Color(.tertiarySystemFill), in: Capsule())
                .fixedSize()
            Text(suggestion.label)
                .font(.subheadline)
                .foregroundStyle(isHighlighted ? Color.primary : Color.secondary)
                .lineLimit(1)
            Spacer(minLength: 4)
            if suggestion.kind == .value {
                Text("\(suggestion.count)")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.tertiary)
            }
            if isSelected {
                Image(systemName: "checkmark")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Color.accentColor)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(isHighlighted ? Color(.secondarySystemFill) : .clear)
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
            "\(suggestion.field.label) \(suggestion.label)"
                + (suggestion.kind == .value ? ", \(suggestion.count) agents" : ""))
        .accessibilityAddTraits(.isButton)
        .accessibilityHint(
            suggestion.kind == .value
                ? "Adds this value as a filter."
                : "Completes the query with this field.")
    }
}

/// The compact search field: magnifier, text, clear button; suggestions
/// render in an attached list; filter chips render in a rail below.
struct AgentSearchBarView: View {
    @Bindable var store: AgentSearchBarStore
    /// The list the engine matches over, projected by the owner.
    var agents: [ConsoleAgent]

    @FocusState.Binding var isFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            field
            if !store.engine.filters.isEmpty {
                chipsRail
            }
            if isFocused, store.showsSuggestions {
                suggestionsList
            }
        }
        .background(Color(.systemBackground))
        // The preview's onblur rule: losing focus dismisses suggestions
        // without touching the query — the phone's Esc-parity affordance.
        .onChange(of: isFocused) { _, focused in
            if !focused { store.dismissSuggestions() }
        }
    }

    private var field: some View {
        HStack(spacing: 8) {
            // The magnifier is a labeled control, not decoration: it
            // raises the keyboard when unfocused and — the phone's
            // Esc-parity affordance — dismisses the suggestions when they
            // are visible (hardware Esc is handled by the key-press chain).
            Button {
                if isFocused, store.showsSuggestions {
                    store.dismissSuggestions()
                } else {
                    isFocused = true
                    if !store.engine.rawQuery.isEmpty { store.reopenSuggestions() }
                }
            } label: {
                Image(systemName: "magnifyingglass")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    // A real hit target, not a 20pt glyph: the row's
                    // height, so the toggle is tappable at thumb scale.
                    .frame(minWidth: 32, minHeight: 32)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(
                isFocused && store.showsSuggestions
                    ? "Hide suggestions" : "Search agent titles or filter by context")
            TextField(
                "Title, host:, workspace:…",
                text: Binding(
                    get: { store.engine.rawQuery },
                    set: { store.updateQuery($0) }))
                .focused($isFocused)
                .textFieldStyle(.plain)
                .font(.subheadline)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .submitLabel(.search)
                .onSubmit { store.acceptHighlighted(over: agents) }
                .accessibilityLabel("Search agent titles or filter by context")
                .accessibilityAddTraits(.isSearchField)
                .onKeyPress(.downArrow) {
                    store.moveHighlight(1, over: agents)
                    return .handled
                }
                .onKeyPress(.upArrow) {
                    store.moveHighlight(-1, over: agents)
                    return .handled
                }
                .onKeyPress(.escape) {
                    store.dismissSuggestions()
                    return .handled
                }
                .onKeyPress(.tab) {
                    store.acceptHighlighted(over: agents)
                    return .handled
                }
            if !store.engine.rawQuery.isEmpty {
                Button {
                    store.clearQuery()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.subheadline)
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear search text")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .contentShape(Rectangle())
        .onTapGesture { isFocused = true }
    }

    private var chipsRail: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(store.engine.filters) { filter in
                    AgentSearchFilterChip(filter: filter) {
                        store.removeFilter(filter)
                    }
                }
                Button("Clear all") { store.clearAll() }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("Clear all filters")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
        }
    }

    /// The suggestion list (review finding #6): bounded and scrollable —
    /// at most ~5 rows visible, so a raised keyboard can never wall the
    /// results off.
    @ViewBuilder
    private var suggestionsList: some View {
        let suggestions = store.engine.suggestions(over: agents)
        if !suggestions.isEmpty {
            ScrollView {
                VStack(spacing: 0) {
                    Text(store.suggestionsHelp)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 4)
                    ForEach(Array(suggestions.enumerated()), id: \.element.id) { index, suggestion in
                        AgentSearchSuggestionRow(
                            suggestion: suggestion,
                            isHighlighted: index == store.highlightIndex,
                            isSelected: suggestion.kind == .value
                                && store.engine.filters.contains {
                                    $0.field == suggestion.field && $0.value == suggestion.value
                                })
                            .onTapGesture { store.accept(suggestion) }
                    }
                }
            }
            .frame(maxHeight: 5 * 44)
            .background(Color(.secondarySystemBackground))
        }
    }
}

/// One removable context filter chip: field name + value + corner remove.
struct AgentSearchFilterChip: View {
    let filter: AgentSearchFilter
    let onRemove: () -> Void

    var body: some View {
        HStack(spacing: 4) {
            Text(filter.field.label)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(filter.value)
                .font(.caption)
                .foregroundStyle(.primary)
                .lineLimit(1)
            Button(action: onRemove) {
                Image(systemName: "xmark")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .padding(3)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Remove \(filter.field.label) filter \(filter.value)")
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Color(.tertiarySystemFill), in: Capsule())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(filter.field.label) filter, \(filter.value)")
        .accessibilityAddTraits(.isButton)
        .accessibilityHint("Removes this filter.")
    }
}
