import SwiftUI
import UIKit

// SPDX-License-Identifier: Apache-2.0
//
// The Macros page of the tools keyboard (ADR 0013's pages mechanic): the
// pane's macro slots, bound per pane in MacroKeyStore. A tap fires the
// bound Snippet's body with the binding's args appended — through the
// draft, the Snippets pane's ADR-0009 arrangement, since a macro is
// authored text and the Agent pad's sibling keys are the only things that
// bypass the draft. Binding is touch-and-hold (the context menu): a
// keyboard pane cannot host a text field (the responder trap the Snippets
// pane documents) or a management sheet, so it takes args from the
// clipboard instead of typing them.

/// What the Macros page needs from its owner: the pane id its bindings are
/// keyed by, the live Snippet catalog to resolve bindings against, and the
/// draft insertion path a fired macro edits.
@MainActor
struct MacroKeyboardContext {
    let paneID: String
    /// The Snippet catalog, read live so rows track edits and bindings.
    let snippets: () -> [Snippet]
    /// Inserts a fired macro's text into the Composer draft.
    let insert: (String) -> Void
}

/// One pane's macro slots: `MacroKeyStore.slotRange` rows, a bound row
/// showing its Snippet (and args), an empty row showing "Empty".
struct MacrosKeyboardPane: View {
    let store: MacroKeyStore
    let context: MacroKeyboardContext
    let isEnabled: Bool
    /// Returns to the Agent page after a macro fires — the Snippets pane's
    /// return-to-controls convention.
    let onFired: () -> Void

    @State private var bindings: [Int: MacroBinding] = [:]

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(MacroKeyStore.slotRange, id: \.self) { slot in
                        slotRow(slot)
                        Divider().padding(.leading, 16)
                    }
                }
            }
            .scrollBounceBehavior(.basedOnSize)

            Divider()
            hint
        }
        .onAppear { reload() }
        .onChange(of: context.paneID) { _, _ in reload() }
    }

    private func slotRow(_ slot: Int) -> some View {
        let binding = bindings[slot]
        let snippet = binding.flatMap { binding in
            context.snippets().first { $0.id == binding.snippetID }
        }
        return Button {
            // An empty or dangling slot has nothing to fire. Binding is the
            // touch-and-hold path, which stays live while input is off —
            // it edits local configuration, not the Agent.
            guard isEnabled, let binding, let snippet else { return }
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            context.insert(snippet.body + binding.args)
            onFired()
        } label: {
            HStack(spacing: 10) {
                Text("M\(slot)")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 28, alignment: .leading)
                VStack(alignment: .leading, spacing: 2) {
                    Text(snippet?.displayTitle ?? "Empty")
                        .font(.subheadline)
                        .foregroundStyle(snippet == nil ? Color.secondary : Color.primary)
                        .lineLimit(1)
                    if let binding, !binding.args.isEmpty {
                        Text(binding.args)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
                Image(systemName: "quote.bubble")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .contentShape(.rect)
            .opacity(isEnabled || snippet == nil ? 1 : 0.45)
        }
        .buttonStyle(.plain)
        .contextMenu { bindMenu(slot: slot, binding: binding) }
        .accessibilityLabel("Macro slot \(slot)")
        .accessibilityValue(snippet?.displayTitle ?? "Empty")
        .accessibilityHint("Inserts the bound Snippet into the Composer draft")
    }

    @ViewBuilder
    private func bindMenu(slot: Int, binding: MacroBinding?) -> some View {
        let snippets = context.snippets()
        if snippets.isEmpty {
            Text("No Snippets yet")
        } else {
            ForEach(snippets) { snippet in
                Button {
                    _ = store.setBinding(
                        slot: slot, paneID: context.paneID,
                        snippetID: snippet.id, args: "")
                    reload()
                } label: {
                    Label("Bind \(snippet.displayTitle)", systemImage: "quote.bubble")
                }
            }
        }
        if let binding,
            UIPasteboard.general.hasStrings,
            let text = UIPasteboard.general.string,
            MacroKeyStore.isValidArgs(TerminalTextSafety.normalizingNewlines(text))
        {
            Button {
                _ = store.setBinding(
                    slot: slot, paneID: context.paneID,
                    snippetID: binding.snippetID, args: text)
                reload()
            } label: {
                Label("Use copied text as args", systemImage: "doc.on.clipboard")
            }
        }
        if binding != nil {
            Button(role: .destructive) {
                store.clearBinding(slot: slot, paneID: context.paneID)
                reload()
            } label: {
                Label("Clear macro", systemImage: "trash")
            }
        }
    }

    private var hint: some View {
        Text("Touch and hold a slot to bind a Snippet. A tap inserts it into the draft.")
            .font(.caption2)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
    }

    private func reload() {
        bindings = store.bindings(paneID: context.paneID)
    }
}
