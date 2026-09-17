import SwiftUI

// SPDX-License-Identifier: Apache-2.0
//
// The concrete half of the long-press chord layer: the Agent-key variant
// table that drives it and the overlay menu it opens. The interaction
// states live in LongPressChordLayer.swift.

/// One step of a chord variant: what to send, with which one-shot modifiers.
/// Reuses the full keyboard's key encoding — a ⇧Enter variant rides the
/// same Ctrl-J remap the ⇧Enter cap already uses.
struct KeyChordStep: Hashable {
    let key: AgentQuickKey
    let modifiers: TerminalKeyModifiers
}

/// One entry in the long-press chord menu.
struct KeyChordVariant: Identifiable, Hashable {
    let id: String
    let title: String
    let steps: [KeyChordStep]
}

/// The data-driven variant table behind the long-press chord layer. Hold a
/// key cap and the variants it hides appear as an overlay row: Tab also
/// hides Backtab and Ctrl-I, Esc also hides Esc-Esc, arrows also hide their
/// Ctrl, Alt, and Shift forms. Keys absent from the table (Backspace above
/// all — its cap is a repeating button) have no chord and keep their exact
/// existing touch behavior.
enum LongPressChordVariants {
    static func variants(for key: AgentQuickKey) -> [KeyChordVariant]? {
        table[key]
    }

    private static let table: [AgentQuickKey: [KeyChordVariant]] = [
        .escape: [
            KeyChordVariant(
                id: "escape", title: "Esc",
                steps: [KeyChordStep(key: .escape, modifiers: [])]),
            KeyChordVariant(
                id: "escape-escape", title: "Esc Esc",
                steps: [
                    KeyChordStep(key: .escape, modifiers: []),
                    KeyChordStep(key: .escape, modifiers: []),
                ]),
        ],
        .tab: [
            KeyChordVariant(
                id: "tab", title: "Tab",
                steps: [KeyChordStep(key: .tab, modifiers: [])]),
            KeyChordVariant(
                id: "backtab", title: "⇧Tab",
                steps: [KeyChordStep(key: .shiftTab, modifiers: [])]),
            KeyChordVariant(
                id: "ctrl-i", title: "⌃I",
                steps: [KeyChordStep(key: .character("i"), modifiers: .control)]),
        ],
        .shiftTab: [
            KeyChordVariant(
                id: "shift-tab", title: "⇧Tab",
                steps: [KeyChordStep(key: .shiftTab, modifiers: [])]),
            KeyChordVariant(
                id: "tab", title: "Tab",
                steps: [KeyChordStep(key: .tab, modifiers: [])]),
        ],
        .enter: [
            KeyChordVariant(
                id: "enter", title: "Enter",
                steps: [KeyChordStep(key: .enter, modifiers: [])]),
            KeyChordVariant(
                id: "shift-enter", title: "⇧Enter",
                steps: [KeyChordStep(key: .shiftEnter, modifiers: [])]),
        ],
        .left: arrowRow("←", key: .left),
        .up: arrowRow("↑", key: .up),
        .right: arrowRow("→", key: .right),
        .down: arrowRow("↓", key: .down),
    ]

    /// An arrow cap plus its Ctrl, Alt, and Shift forms.
    private static func arrowRow(_ glyph: String, key: AgentQuickKey) -> [KeyChordVariant] {
        [
            KeyChordVariant(
                id: "\(glyph)", title: glyph,
                steps: [KeyChordStep(key: key, modifiers: [])]),
            KeyChordVariant(
                id: "\(glyph)-ctrl", title: "⌃\(glyph)",
                steps: [KeyChordStep(key: key, modifiers: .control)]),
            KeyChordVariant(
                id: "\(glyph)-alt", title: "⌥\(glyph)",
                steps: [KeyChordStep(key: key, modifiers: .option)]),
            KeyChordVariant(
                id: "\(glyph)-shift", title: "⇧\(glyph)",
                steps: [KeyChordStep(key: key, modifiers: .shift)]),
        ]
    }
}

/// The overlay menu of the long-press chord layer: a scrim that owns the pad
/// while open, and a strip of variant caps above the key rows. Drag to
/// select — the strip's named coordinate space feeds the machine's
/// position mapping — and release to confirm; a second finger (or
/// VoiceOver) can tap a cap directly.
struct LongPressChordOverlay: View {
    /// The named space the key's drag gesture reads finger positions in.
    /// The strip measures itself through `onGeometryChange` in this same
    /// box, so the two can never disagree.
    static let stripSpaceName = "chord.strip"

    let variants: [KeyChordVariant]
    let selection: Int?
    let onStripSize: (CGSize) -> Void
    let fire: (KeyChordVariant) -> Void
    let dismiss: () -> Void

    var body: some View {
        ZStack {
            // Absorbs every other touch on the pad while the menu is open —
            // a second finger cannot reach a key cap — and offers an
            // explicit tap-out to dismiss.
            Rectangle()
                .fill(Color.black.opacity(0.18))
                .contentShape(.rect)
                .onTapGesture { dismiss() }
                .accessibilityHidden(true)
            strip
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private var strip: some View {
        HStack(spacing: 6) {
            ForEach(Array(variants.enumerated()), id: \.element.id) { index, variant in
                Button {
                    fire(variant)
                } label: {
                    Text(variant.title)
                        .font(.system(size: 13, weight: .medium))
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                        .frame(width: 46, height: 34)
                }
                .buttonStyle(TerminalKeyboardButtonStyle(isSelected: index == selection ? true : nil))
                .accessibilityLabel(variant.title)
                .accessibilityHint("Sends this variant to the Agent")
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(.thinMaterial, in: .rect(cornerRadius: 11))
        .shadow(color: .black.opacity(0.25), radius: 8, y: 2)
        .padding(.top, 2)
        .onGeometryChange(for: CGSize.self) { proxy in
            proxy.size
        } action: { onStripSize($0) }
        .coordinateSpace(name: Self.stripSpaceName)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Key variants")
    }
}
