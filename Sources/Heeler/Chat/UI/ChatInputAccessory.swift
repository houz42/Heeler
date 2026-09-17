import SwiftUI
import UIKit

// SPDX-License-Identifier: Apache-2.0
//
// The chat input's prefix-key bar: one accessory row above the system
// keyboard with `/ # @ !` keys, replacing the QuickType prediction bar.
// The keys exist because every composer mode starts with one of these
// characters, and iOS offers no way to tap them from the default keyboard
// without a secondary-symbol page hunt. Autocorrection and spell-check are
// off on the input's text view (below), which is what hides the prediction
// row — so the prefix bar is the one bar above the keys, in the user's words
// "instead of the recommended words".

/// The four composer-mode prefixes the bar offers. The router classifies
/// by these characters; the bar is their one-tap entry.
enum ChatPrefixKey: CaseIterable, Identifiable, Sendable {
    case slash
    case hash
    case mention
    case bash

    var id: Self { self }

    /// The character the key inserts at the draft cursor.
    var character: Character {
        switch self {
        case .slash: "/"
        case .hash: "#"
        case .mention: "@"
        case .bash: "!"
        }
    }

    /// What the key's insert re-arms, for accessibility.
    var accessibilityLabel: String {
        switch self {
        case .slash: "Slash commands"
        case .hash: "Tag filter"
        case .mention: "Mention an agent"
        case .bash: "Run a shell command"
        }
    }
}

/// The pure insert: one prefix character into a draft at the cursor.
/// `selection` is a UTF-16 offset (Swift's String index distance matches
/// UITextView's selectedRange on the same string). The cursor lands AFTER
/// the inserted character so the suggestion menu — recomputed by the
/// caller from the returned draft — targets the new token.
func chatDraftByInserting(
    _ character: Character, into draft: String, selection: Int
) -> (draft: String, selection: Int) {
    // UITextView clamps selectedRange to the text length; mirror that so a
    // stale selection (e.g. after programmatic draft replacement) cannot
    // crash or silently re-anchor.
    let clamped = min(max(selection, 0), draft.utf16.count)
    let inserted = String(character)
    guard let index = draft.utf16.index(
        draft.startIndex, offsetBy: clamped, limitedBy: draft.endIndex)
    else { return (draft + inserted, draft.utf16.count + inserted.utf16.count) }
    var newDraft = draft
    newDraft.insert(contentsOf: inserted, at: index)
    return (newDraft, clamped + inserted.utf16.count)
}

/// The four-key accessory bar rendered above the chat input's keyboard.
/// Equal-width keys; the frame's own chevron stays the dismiss control, so
/// the bar carries no dismiss affordance of its own.
struct ChatPrefixKeyBar: View {
    /// Inserts one prefix character at the draft cursor.
    let insert: (ChatPrefixKey) -> Void

    var body: some View {
        HStack(spacing: 0) {
            ForEach(ChatPrefixKey.allCases) { key in
                Button {
                    insert(key)
                } label: {
                    Text(String(key.character))
                        .font(.body.weight(.medium))
                        .fontDesign(.monospaced)
                        .frame(maxWidth: .infinity, minHeight: 44)
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(key.accessibilityLabel)
                .accessibilityHint("Inserts \(key.character) at the cursor")
            }
        }
        .frame(maxWidth: .infinity)
        .background(.bar)
        .overlay(alignment: .bottom) { Divider() }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Composer prefix keys")
    }
}

/// The chat input's UIKit text view: owns the prefix-key bar as its input
/// accessory, so the bar is mounted/unmounted with the keyboard and never
/// outlives the field. Autocorrection/spell-check stay off (set by the
/// representable) so the accessory is the only bar above the keys.
@MainActor
final class ChatInputUITextView: UITextView {
    let prefixBar: UIHostingController<ChatPrefixKeyBar>

    override init(frame: CGRect, textContainer: NSTextContainer?) {
        prefixBar = Self.makePrefixBar()
        super.init(frame: frame, textContainer: textContainer)
        installPrefixBar()
    }

    required init?(coder: NSCoder) {
        prefixBar = Self.makePrefixBar()
        super.init(coder: coder)
        installPrefixBar()
    }

    private static func makePrefixBar() -> UIHostingController<ChatPrefixKeyBar> {
        let bar = UIHostingController(rootView: ChatPrefixKeyBar(insert: { _ in }))
        bar.sizingOptions = [.intrinsicContentSize]
        bar.view.backgroundColor = .clear
        return bar
    }

    private func installPrefixBar() {
        inputAccessoryView = prefixBar.view
    }

    /// Routes a prefix-key tap to the installed insert handler.
    func insert(_ key: ChatPrefixKey) {
        prefixBar.rootView.insert(key)
    }
}

/// The chat input's text field. A UITextView rather than SwiftUI's
/// TextField for two reasons the bar's contract needs:
///
/// 1. Prefix keys insert AT THE CURSOR, and the draft is freely editable
///    (drafts survive rejected submits for editing), so the field is not
///    append-only — the bar must read and move the real text selection,
///    which SwiftUI's TextField binding does not expose.
/// 2. The bar is the field's `inputAccessoryView`, which is the only way
///    to get exactly one bar above the keys: autocorrection and
///    spell-check are off (hiding the QuickType prediction row) and the
///    accessory view renders in its place.
///
/// Draft and focus state are SwiftUI-side; this representable only owns
/// the UIKit text-system mechanics.
struct ChatInputTextView: UIViewRepresentable {
    /// The current draft; edits flow out through `onEdit`.
    let text: String
    /// The draft placeholder (the frame's hint line).
    let placeholder: String
    /// Reports every draft/selection change, including the prefix-key
    /// inserts below. The owner updates its binding and re-runs the
    /// router's suggestion pass.
    let onEdit: (String, Int) -> Void
    @Binding var isFocused: Bool

    func makeCoordinator() -> Coordinator {
        Coordinator(onEdit: onEdit, isFocused: $isFocused)
    }

    func makeUIView(context: Context) -> ChatInputUITextView {
        let textView = ChatInputUITextView()
        textView.delegate = context.coordinator
        textView.backgroundColor = .clear
        textView.font = .preferredFont(forTextStyle: .body)
        textView.adjustsFontForContentSizeCategory = true
        // The one-bar contract: no QuickType row above the prefix bar.
        textView.autocorrectionType = .no
        textView.spellCheckingType = .no
        textView.smartQuotesType = .no
        textView.smartDashesType = .no
        textView.textContainerInset = UIEdgeInsets()
        textView.textContainer.lineFragmentPadding = 0
        textView.keyboardType = .asciiCapable
        textView.returnKeyType = .default
        textView.accessibilityLabel = placeholder
        context.coordinator.attachPlaceholder(
            to: textView, placeholder: placeholder)
        textView.prefixBar.rootView = ChatPrefixKeyBar(insert: { [weak textView] key in
            insert(key, into: textView)
        })
        return textView
    }

    func updateUIView(_ textView: ChatInputUITextView, context: Context) {
        context.coordinator.onEdit = onEdit
        context.coordinator.setPlaceholder(placeholder)
        if textView.text != text {
            // Preserve the caret when the SwiftUI side rewrote the draft
            // (suggestion accept, rejected-draft restore): a plain text
            // assignment would drop it to the end.
            let selection = textView.selectedRange
            textView.text = text
            textView.selectedRange = selection
        }
        context.coordinator.wantsFocus = isFocused
        if isFocused != textView.isFirstResponder {
            DispatchQueue.main.async { [weak textView] in
                guard let textView,
                    isFocused != textView.isFirstResponder
                else { return }
                if isFocused {
                    textView.becomeFirstResponder()
                } else {
                    textView.resignFirstResponder()
                }
            }
        }
    }

    /// Inserts one prefix key at the text view's cursor, through the text
    /// system (so undo and candidate handling see it) and reports it as an
    /// edit so the router's suggestion pass re-runs.
    private func insert(_ key: ChatPrefixKey, into textView: ChatInputUITextView?) {
        guard let textView else { return }
        let (newDraft, newSelection) = chatDraftByInserting(
            key.character, into: textView.text, selection: textView.selectedRange.location)
        textView.text = newDraft
        textView.selectedRange = NSRange(location: newSelection, length: 0)
        onEdit(newDraft, newSelection)
    }

    @MainActor
    final class Coordinator: NSObject, UITextViewDelegate {
        var onEdit: (String, Int) -> Void
        /// The latest focus intent, from either side, so a deferred focus
        /// change re-checks before acting (the same race the Composer's
        /// editor guards).
        var wantsFocus = false
        private var placeholderLabel: UILabel?
        private var isFocused: Binding<Bool>

        init(onEdit: @escaping (String, Int) -> Void, isFocused: Binding<Bool>) {
            self.onEdit = onEdit
            self.isFocused = isFocused
        }

        func attachPlaceholder(to textView: UITextView, placeholder: String) {
            let label = UILabel()
            label.textColor = .placeholderText
            label.font = .preferredFont(forTextStyle: .body)
            label.adjustsFontForContentSizeCategory = true
            label.translatesAutoresizingMaskIntoConstraints = false
            label.numberOfLines = 0
            label.text = placeholder
            label.isHidden = true
            textView.addSubview(label)
            NSLayoutConstraint.activate([
                label.leadingAnchor.constraint(
                    equalTo: textView.leadingAnchor),
                label.trailingAnchor.constraint(
                    lessThanOrEqualTo: textView.trailingAnchor),
                label.topAnchor.constraint(
                    equalTo: textView.topAnchor, constant: 8),
            ])
            self.placeholderLabel = label
            syncPlaceholderVisibility(for: textView)
        }

        func setPlaceholder(_ placeholder: String) {
            placeholderLabel?.text = placeholder
        }

        func textViewDidChange(_ textView: UITextView) {
            syncPlaceholderVisibility(for: textView)
            onEdit(textView.text, textView.selectedRange.location)
        }

        func textViewDidChangeSelection(_ textView: UITextView) {
            onEdit(textView.text, textView.selectedRange.location)
        }

        func textViewDidBeginEditing(_ textView: UITextView) {
            wantsFocus = true
            isFocused.wrappedValue = true
            syncPlaceholderVisibility(for: textView)
        }

        func textViewDidEndEditing(_ textView: UITextView) {
            wantsFocus = false
            isFocused.wrappedValue = false
            syncPlaceholderVisibility(for: textView)
        }

        private func syncPlaceholderVisibility(for textView: UITextView) {
            placeholderLabel?.isHidden = !textView.text.isEmpty
        }
    }
}
