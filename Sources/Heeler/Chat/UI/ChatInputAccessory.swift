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
enum ChatPrefixKey: CaseIterable, Sendable {
    case slash
    case hash
    case mention
    case bash

    /// The character the key inserts at the draft cursor.
    var character: Character {
        switch self {
        case .slash: "/"
        case .hash: "#"
        case .mention: "@"
        case .bash: "!"
        }
    }

    /// What the key opens, for accessibility.
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

/// The prefix-key bar as a plain UIKit view, not hosted SwiftUI: a
/// UIHostingController's view docked as an inputAccessoryView reports its
/// intrinsic height only after the keyboard has already laid out, which
/// clipped the bar behind the keys' top edge on device. A stack of four
/// fill-equally buttons with one fixed height constraint has no sizing
/// to get wrong. The frame's own chevron stays the dismiss control, so
/// the bar carries no dismiss affordance of its own.
@MainActor
final class ChatPrefixKeyBarView: UIView {
    var onInsert: ((ChatPrefixKey) -> Void)?

    private static let barHeight: CGFloat = 44

    /// The keyboard's accessory hosting sizes the bar by frame/intrinsic
    /// size, not by constraints: the bar is created with frame .zero and
    /// autoresizing .flexibleWidth, so without this it docks at zero
    /// height — invisible behind the keys even though its constraints
    /// would measure 44pt. (A `systemLayoutSizeFitting` test passes
    /// either way; the keyboard does not call it.)
    override var intrinsicContentSize: CGSize {
        CGSize(width: UIView.noIntrinsicMetric, height: Self.barHeight)
    }

    /// The keyboard's accessory hosting frames the bar, it does not run
    /// a constraint-solving size pass: created with frame .zero and
    /// autoresizing-based layout, a zero frame docks at zero height —
    /// invisible behind the keys even though `systemLayoutSizeFitting`
    /// (which DOES solve constraints) would measure 44pt. Start at the
    /// declared height; .flexibleWidth keeps width following the screen.
    convenience init() {
        self.init(frame: CGRect(x: 0, y: 0, width: 0, height: Self.barHeight))
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        install()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        install()
    }

    private func install() {
        autoresizingMask = .flexibleWidth
        backgroundColor = .clear

        let blur = UIVisualEffectView(effect: UIBlurEffect(style: .systemChromeMaterial))
        blur.translatesAutoresizingMaskIntoConstraints = false
        addSubview(blur)

        let stack = UIStackView()
        stack.axis = .horizontal
        stack.distribution = .fillEqually
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)

        for key in ChatPrefixKey.allCases {
            let button = UIButton(type: .system)
            button.setTitle(String(key.character), for: .normal)
            if let descriptor = UIFont.systemFont(
                ofSize: UIFont.preferredFont(forTextStyle: .body).pointSize,
                weight: .medium
            ).fontDescriptor.withDesign(.monospaced) {
                button.titleLabel?.font = UIFont(descriptor: descriptor, size: 0)
            }
            button.titleLabel?.adjustsFontForContentSizeCategory = true
            button.accessibilityLabel = key.accessibilityLabel
            button.accessibilityHint = "Inserts \(key.character) at the cursor"
            button.addAction(
                UIAction { [weak self] _ in self?.onInsert?(key) },
                for: .touchUpInside)
            stack.addArrangedSubview(button)
        }

        let hairline = UIView()
        hairline.backgroundColor = .separator
        hairline.translatesAutoresizingMaskIntoConstraints = false
        hairline.contentMode = .scaleToFill
        addSubview(hairline)

        let separatorHeight = hairline.traitCollection.displayScale > 1 ? 0.5 : 1
        NSLayoutConstraint.activate([
            blur.leadingAnchor.constraint(equalTo: leadingAnchor),
            blur.trailingAnchor.constraint(equalTo: trailingAnchor),
            blur.topAnchor.constraint(equalTo: topAnchor),
            blur.bottomAnchor.constraint(equalTo: bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: hairline.topAnchor),
            hairline.leadingAnchor.constraint(equalTo: leadingAnchor),
            hairline.trailingAnchor.constraint(equalTo: trailingAnchor),
            hairline.bottomAnchor.constraint(equalTo: bottomAnchor),
            hairline.heightAnchor.constraint(equalToConstant: separatorHeight),
            // No self heightAnchor: with autoresizing layout that would
            // fight the autoresizing-derived height constraint. Frame +
            // intrinsicContentSize carry the 44pt.
        ])
    }
}

/// The chat input's UIKit text view: owns the prefix-key bar as its input
/// accessory, so the bar is mounted/unmounted with the keyboard and never
/// outlives the field. Autocorrection/spell-check stay off (set by the
/// representable) so the accessory is the only bar above the keys.
@MainActor
final class ChatInputUITextView: UITextView {
    let prefixBar = ChatPrefixKeyBarView()
    /// Reports a prefix-key insert the same way a typed edit reports, so
    /// the owner's draft binding and the router's suggestion pass see it.
    var onPrefixInsert: ((String, Int) -> Void)?
    /// Return-key arbitration for the suggestion menu: consulted before
    /// a newline is inserted. Returning true consumes the key, so with
    /// the menu open Return accepts instead of inserting "\n". Nil keeps
    /// the stock newline behavior.
    var onReturnKey: (() -> Bool)?
    /// A caret position (UTF-16) the next `updateUIView` text sync must
    /// apply after an external draft rewrite (suggestion accept). The
    /// representable distinguishes "preserve the caret" (typical
    /// SwiftUI-side rewrite, e.g. rejected-draft restore) from "place
    /// the caret at the accept's insertion end".
    var pendingCaretLocation: Int?
    /// One gate for caret placement: `textViewDidChangeSelection` fires
    /// for programmatic selectedRange changes too, and without this the
    /// accept path and the delegate callback would fight over the caret
    /// within the same update cycle.
    var isApplyingExternalCaret = false

    override init(frame: CGRect, textContainer: NSTextContainer?) {
        super.init(frame: frame, textContainer: textContainer)
        installPrefixBar()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        installPrefixBar()
    }

    private func installPrefixBar() {
        inputAccessoryView = prefixBar
        prefixBar.onInsert = { [weak self] in
            self?.insertPrefix($0)
        }
    }

    /// Inserts one prefix key at the cursor and reports it as an edit.
    /// Lives here (not the representable) so the bar works even if a
    /// SwiftUI layout pass has not run yet, and so tests can drive the
    /// exact path a touch takes.
    func insertPrefix(_ key: ChatPrefixKey) {
        let (newDraft, newSelection) = chatDraftByInserting(
            key.character, into: text, selection: selectedRange.location)
        text = newDraft
        selectedRange = NSRange(location: newSelection, length: 0)
        onPrefixInsert?(newDraft, newSelection)
    }

    /// Applies an externally-computed draft with an explicit caret
    /// (suggestion accept): the text and selection land together, so the
    /// caret sits at the end of the insertion — after the trailing space
    /// "/agents " carries — and reports as an edit so the owner's
    /// binding and the router's suggestion pass both see it.
    func applyExternalDraft(_ newDraft: String, caret: Int) {
        isApplyingExternalCaret = true
        text = newDraft
        selectedRange = NSRange(
            location: min(max(caret, 0), newDraft.utf16.count), length: 0)
        isApplyingExternalCaret = false
        onPrefixInsert?(newDraft, selectedRange.location)
    }
    /// The chat-input text configuration, in one place: the one-bar
    /// contract (autocorrection/spell-check off hides QuickType), literal
    /// ASCII typing, and the composer's return-key arbitration. `makeUIView`
    /// applies it; tests apply the same method so they measure the
    /// production configuration, not UIKit defaults.
    func applyChatInputConfiguration() {
        backgroundColor = .clear
        font = .preferredFont(forTextStyle: .body)
        adjustsFontForContentSizeCategory = true
        autocorrectionType = .no
        spellCheckingType = .no
        smartQuotesType = .no
        smartDashesType = .no
        textContainerInset = UIEdgeInsets()
        textContainer.lineFragmentPadding = 0
        keyboardType = .asciiCapable
        returnKeyType = .default
        // Hug measured content (sizeThatFits) instead of fighting the
        // proposal; scrolling switches off/on per the 5-line cap.
        setContentCompressionResistancePriority(.defaultLow, for: .vertical)
        setContentHuggingPriority(.defaultLow, for: .vertical)
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
/// the UIKit text-system mechanics. Sizing mirrors the Composer's text
/// editor: an explicit `sizeThatFits` measuring the text and clamping to
/// one…5 lines — without it a scroll-enabled UITextView's internal
/// required constraints override whatever height SwiftUI proposes and the
/// field balloons to fill the safe-area inset.
struct ChatInputTextView: UIViewRepresentable {
    /// The current draft; edits flow out through `onEdit`.
    let text: String
    /// The draft placeholder (the frame's hint line).
    let placeholder: String
    /// Reports every draft/selection change, including the prefix-key
    /// inserts and the suggestion accepts below. The owner updates its
    /// binding and re-runs the router's suggestion pass.
    let onEdit: (String, Int) -> Void
    /// Return-key arbitration for the suggestion menu: consulted when
    /// the user presses Return, before the newline lands. True consumes
    /// the key — the menu is open and the key accepted the highlighted
    /// suggestion, or the menu is stale and must not leak a newline.
    /// Nil keeps the stock newline behavior.
    let onReturnKey: (() -> Bool)?
    /// An accepted suggestion waiting to apply: the new draft plus the
    /// caret the accept leaves (end of the insertion). Applied on the
    /// text view directly — text and caret together — instead of relying
    /// on the updateUIView text sync, which preserves the old (stale)
    /// caret on external rewrites. A binding so applying consumes it:
    /// the next update pass (an ordinary edit) must not re-apply a
    /// settled accept over the user's newer typing.
    @Binding var pendingAccept: (draft: String, caret: Int)?
    @Binding var isFocused: Bool

    func makeCoordinator() -> Coordinator {
        Coordinator(onEdit: onEdit, isFocused: $isFocused)
    }

    func makeUIView(context: Context) -> ChatInputUITextView {
        let textView = ChatInputUITextView()
        textView.delegate = context.coordinator
        textView.applyChatInputConfiguration()
        textView.accessibilityLabel = placeholder
        context.coordinator.attachPlaceholder(
            to: textView, placeholder: placeholder)
        textView.onPrefixInsert = onEdit
        return textView
    }

    func updateUIView(_ textView: ChatInputUITextView, context: Context) {
        context.coordinator.onEdit = onEdit
        // A new representable value carries a new onEdit closure; the
        // text view's insert path must keep reporting through the
        // current one.
        textView.onPrefixInsert = onEdit
        textView.onReturnKey = onReturnKey
        if let accept = pendingAccept {
            // The suggestion-accept path: text and caret land together,
            // so the caret follows the end of the insertion (after the
            // trailing space "/agents " carries). The accept reports
            // through onEdit, so the owner's binding and the router's
            // suggestion pass both see the new draft. Consumed here: a
            // settled accept must not re-apply over the next edit.
            textView.applyExternalDraft(accept.draft, caret: accept.caret)
            pendingAccept = nil
        } else if textView.text != text {
            // Preserve the caret when the SwiftUI side rewrote the draft
            // (rejected-draft restore): a plain text assignment would
            // drop it to the end.
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

    func sizeThatFits(
        _ proposal: ProposedViewSize,
        uiView: ChatInputUITextView,
        context _: Context
    ) -> CGSize? {
        guard let width = proposal.width else { return nil }
        return Self.measuredSize(for: uiView, width: width)
    }

    /// The frame height contract: hug the measured text, clamped to one
    /// line minimum and five lines cap; past the cap the text view
    /// scrolls instead of growing.
    /// UIKit-only inputs so the clamp is testable without a SwiftUI
    /// layout pass.
    static func measuredSize(
        for textView: ChatInputUITextView, width: CGFloat
    ) -> CGSize {
        let wasScrollEnabled = textView.isScrollEnabled
        textView.isScrollEnabled = false
        let measured = textView.sizeThatFits(
            CGSize(width: width, height: .greatestFiniteMagnitude))
        textView.isScrollEnabled = wasScrollEnabled
        let lineHeight = textView.font?.lineHeight ?? 20
        let maximumHeight = lineHeight * 5
        let height = min(max(36, measured.height), maximumHeight)
        textView.isScrollEnabled = measured.height > maximumHeight
        return CGSize(width: width, height: height)
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

        func textView(
            _ textView: UITextView, shouldChangeTextIn range: NSRange,
            replacementText replacement: String
        ) -> Bool {
            // Return with the suggestion menu open accepts the highlighted
            // suggestion (the router consumes the key); with it closed the
            // stock newline insert is unchanged. The arbitration runs
            // before the newline lands, so an accept can never leave a
            // stray "\n" between the prefix and the command name.
            if replacement == "\n" || replacement == "\r",
                let chatTextView = textView as? ChatInputUITextView,
                chatTextView.onReturnKey?() == true
            {
                return false
            }
            return true
        }

        func textViewDidChange(_ textView: UITextView) {
            // A suggestion accept applies the text and then the caret;
            // the intermediate change-notification would report the new
            // draft with the stale caret. Suppressed — the accept reports
            // once, with the final caret, through onEdit.
            if let chatTextView = textView as? ChatInputUITextView,
                chatTextView.isApplyingExternalCaret
            {
                return
            }
            syncPlaceholderVisibility(for: textView)
            // Re-measure so a draft that grows past the 5-line cap starts
            // scrolling instead of stretching the frame (and vice versa).
            textView.invalidateIntrinsicContentSize()
            onEdit(textView.text, textView.selectedRange.location)
        }

        func textViewDidChangeSelection(_ textView: UITextView) {
            // A suggestion accept places the caret programmatically right
            // after changing the text; that callback is ours, not the
            // user's, and the accept already reported the new draft with
            // its caret through onEdit. Re-reporting here would push the
            // pre-accept caret back into the owner's state.
            if let chatTextView = textView as? ChatInputUITextView,
                chatTextView.isApplyingExternalCaret
            {
                return
            }
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
