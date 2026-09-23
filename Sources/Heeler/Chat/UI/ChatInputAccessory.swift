import SwiftUI
import UIKit

// SPDX-License-Identifier: Apache-2.0
//
// The chat input's UIKit text view + its representable (v3: the
// composer is Messages-clean — no accessory bar; the OS keyboard's
// own language/globe + dismissal controls, never replaced keys).
// Command modes work from TYPED text (the ComposerRouterStore
// classifies a leading / # @ ! from the draft as before) and from
// the + menu (v3). Writing assistance follows the chat
// writing-assistance policy: ordinary chat defaults to the system
// keyboard's own correction/prediction; an explicit Off disables it
// — see `applyChatInputConfiguration(writingAssistance:)`.

/// The chat input's UIKit text view (v3: no inputAccessoryView;
/// the keyboard presents clean, exactly as the OS provides it).
/// Writing assistance is a configuration on the representable.
/// Reports externally-applied drafts (suggestion accepts) through
/// ``onExternalDraft`` so the owner's draft binding and the
/// router's suggestion pass see them.
@MainActor
final class ChatInputUITextView: UITextView {
    /// Reports an externally-applied draft (a suggestion accept) the
    /// same way a typed edit reports, so the owner's draft binding and
    /// the router's suggestion pass see it.
    var onExternalDraft: ((String, Int) -> Void)?
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
    /// Paste arbitration for the attachment flow: consulted before the
    /// pasteboard payload lands in the text. Returns true when the
    /// paste was consumed — the pasteboard holds an image and the
    /// attachment flow took it, so no text lands. Returning false keeps
    /// the stock text paste. Nil keeps the stock paste entirely.
    /// Consulted both from the system paste menu (`paste(_:)` below) and
    /// from a hardware keyboard Cmd+V, which arrives through the
    /// responder-chain `paste:` action too — one seam covers both.
    var onPaste: (() -> Bool)?
    /// True while the attachment flow can consume an image paste —
    /// the owner (ChatScreen.handlePaste) sets this whenever
    /// attachments are wired. The system edit menu consults
    /// `canPerformAction` (via `pasteboard` eligibility) before it
    /// offers Paste; a plain UITextView only declares text pasteability,
    /// so an IMAGE-ONLY pasteboard shows no Paste item at all (the
    /// device regression: "no where to paste"). Overriding the action's
    /// availability adds the item back; the `paste(_:)` override then
    /// routes the image into the attachment flow.
    var canPasteImages = false
    /// The pasteboard-change observer's token, kept so the view dies
    /// with its observer. nonisolated(unsafe): only deinit (nonisolated)
    /// touches it after init, and removeObserver is thread-safe.
    private nonisolated(unsafe) var pasteboardObserver: NSObjectProtocol?

    override init(frame: CGRect, textContainer: NSTextContainer?) {
        super.init(frame: frame, textContainer: textContainer)
        observePasteboardChanges()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        observePasteboardChanges()
    }

    deinit {
        if let pasteboardObserver {
            NotificationCenter.default.removeObserver(pasteboardObserver)
        }
    }

    /// Keeps ``imagePasteboardAvailable`` fresh without ever touching
    /// the pasteboard inside canPerformAction (the device crash path).
    /// The refresh DEFERS one runloop hop: changedNotification fires
    /// DURING the setter's own pasteboard mutation (a Copy action in
    /// the message rail sets UIPasteboard.string from this same app),
    /// and reading `hasImages` inside that in-flight mutation is the
    /// pasteboard re-entrancy that crashed the device — the read must
    /// land AFTER the write completes.
    private func observePasteboardChanges() {
        pasteboardObserver = NotificationCenter.default.addObserver(
            forName: UIPasteboard.changedNotification,
            object: UIPasteboard.general,
            queue: .main
        ) { [weak self] _ in
            DispatchQueue.main.async {
                self?.refreshImagePasteboardAvailability()
            }
        }
    }

    /// The system paste command (paste menu, Cmd+V): when the paste
    /// arbitration consumes the payload (pasteboard image → attach), no
    /// text lands; otherwise the stock UIKit paste runs.
    override func paste(_ sender: Any?) {
        if onPaste?() == true { return }
        super.paste(sender)
    }

    /// Paste availability: stock text pasteability OR (the attachment
    /// flow is armed AND the cached pasteboard image flag is set).
    ///
    /// NEVER touch `UIPasteboard` here: the device crash stack shows
    /// UIKit resolving canPerformAction during responder-chain setup,
    /// and `hasImages`' synchronous cache queue re-enters
    /// canPerformAction from within the pasteboard getter — seven
    /// recursions deep, then EXC_BAD_ACCESS. The menu resolution only
    /// ever consults the cached flag (``imagePasteboardAvailable``),
    /// refreshed out-of-band by ``refreshImagePasteboardAvailability()``
    /// on pasteboard-change and focus events.
    ///
    /// The re-entrancy guard is defense-in-depth: if anything in the
    /// responder chain re-enters canPerformAction mid-resolution, the
    /// nested call short-circuits to super instead of recursing.
    override func canPerformAction(
        _ action: Selector, withSender sender: Any?
    ) -> Bool {
        guard !isResolvingPasteAvailability else {
            return super.canPerformAction(action, withSender: sender)
        }
        if action == #selector(paste(_:)), canPasteImages,
            imagePasteboardAvailable
        {
            isResolvingPasteAvailability = true
            defer { isResolvingPasteAvailability = false }
            return true
        }
        return super.canPerformAction(action, withSender: sender)
    }

    /// Test seam for the re-entrancy guard: drives the flag a nested
    /// canPerformAction call would observe inside the pasteboard path.
    func setPasteAvailabilityResolving(_ resolving: Bool) {
        isResolvingPasteAvailability = resolving
    }

    /// The cached answer to "does the pasteboard hold an image" —
    /// updated out-of-band, never queried during menu resolution.
    /// Default true so an un-refreshed view still offers Paste and the
    /// paste arbitration itself (``paste(_:)`` → the resolver) decides
    /// with the real pasteboard; the false case only comes from an
    /// observed change or an explicit refresh.
    var imagePasteboardAvailable = true
    /// One gate for menu-resolution re-entrancy (see the crash note on
    /// ``canPerformAction(_:withSender:)``).
    private var isResolvingPasteAvailability = false

    /// Refreshes the cached image-availability from the real
    /// pasteboard — called from pasteboard-change/focus events, never
    /// from canPerformAction. Reading `hasImages` here is safe: the
    /// call is not inside UIKit's menu-resolution path.
    func refreshImagePasteboardAvailability() {
        imagePasteboardAvailable = UIPasteboard.general.hasImages
    }

    /// Applies an externally-computed draft with an explicit caret
    /// (suggestion accept): the text and selection land together, so the
    /// caret sits at the end of the insertion — after the trailing space
    /// "/agents " carries — and reports as an edit so the owner's
    /// binding and the router's suggestion pass both see it. The report
    /// rides ``onExternalDraft`` (the bar's prefix-insert path is gone).
    ///
    /// A programmatic `.text` assignment does NOT fire the delegate's
    /// `textViewDidChange` (UIKit only calls it for user edits), so this
    /// drives the delegate's text-state work directly: the placeholder's
    /// visibility toggle and the height re-measure. Without it the
    /// placeholder stayed visible under the accepted draft — a
    /// device-verified regression. `delegate` is `@objc optional`, hence
    /// the optional-chain call.
    func applyExternalDraft(_ newDraft: String, caret: Int) {
        isApplyingExternalCaret = true
        text = newDraft
        selectedRange = NSRange(
            location: min(max(caret, 0), newDraft.utf16.count), length: 0)
        isApplyingExternalCaret = false
        delegate?.textViewDidChange?(self)
        onExternalDraft?(newDraft, selectedRange.location)
    }

    /// The chat-input text configuration, in one place. `makeUIView`
    /// applies it; tests apply the same method so they measure the
    /// production configuration, not UIKit defaults.
    ///
    /// Writing assistance (v3 design doc, "Writing assistance"):
    /// ordinary chat DEFAULTS to the system keyboard's own
    /// correction/prediction (`.default` traits + the user's language
    /// keyboard); an explicit Off disables it. The keyboard itself is
    /// never replaced — this only configures text traits.
    func applyChatInputConfiguration(
        writingAssistance: Bool = false
    ) {
        backgroundColor = .clear
        font = .preferredFont(forTextStyle: .body)
        adjustsFontForContentSizeCategory = true
        if writingAssistance {
            autocorrectionType = .default
            spellCheckingType = .default
            smartQuotesType = .default
            smartDashesType = .default
        } else {
            autocorrectionType = .no
            spellCheckingType = .no
            smartQuotesType = .no
            smartDashesType = .no
        }
        textContainerInset = UIEdgeInsets()
        textContainer.lineFragmentPadding = 0
        // The DEFAULT OS keyboard with its language/globe + dismissal
        // controls as the device provides them (v3: never replace
        // system keys). Ordinary chat (assistance on) uses the
        // standard multilingual keyboard; the literal/command mode
        // pins asciiCapable (a freeform field cannot reliably disable
        // corrections for inline code spans — the design doc's rule).
        keyboardType = writingAssistance ? .default : .asciiCapable
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
    /// The composer collapse state (conversation redesign): true while
    /// the draft is empty or the field is unfocused — the field renders
    /// a single row; focused-with-text grows it, bounded at three
    /// lines. The draft itself NEVER clears on blur; only the frame
    /// height collapses.
    var collapsed: Bool = false
    /// The draft placeholder (the frame's hint line).
    let placeholder: String
    /// Ordinary chat follows the system keyboard's own
    /// correction/prediction by default (the v3 writing-assistance
    /// policy): `true` applies `.default` text traits so QuickType
    /// and the user's language keyboard work; `false` disables
    /// correction entirely (the literal/command mode). The keyboard
    /// itself is ALWAYS the OS default — no custom input view, no
    /// replaced system keys.
    var writingAssistance: Bool = false
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
    /// Paste arbitration for the attachment flow: consulted when the
    /// user pastes (system paste menu or hardware Cmd+V, both the
    /// `paste:` responder action). True consumes the paste — the
    /// pasteboard holds an image and the attachment flow took it, no
    /// text lands. False keeps the stock text paste. Nil keeps the
    /// stock paste entirely (previews, unwired hosts).
    var onPaste: (() -> Bool)? = nil
    /// An accepted suggestion waiting to apply: the new draft plus the
    /// caret the accept leaves (end of the insertion). Applied on the
    /// text view directly — text and caret together — instead of relying
    /// on the updateUIView text sync, which preserves the old (stale)
    /// caret on external rewrites. A binding so applying consumes it:
    /// the next update pass (an ordinary edit) must not re-apply a
    /// settled accept over the user's newer typing.
    @Binding var pendingAccept: (draft: String, caret: Int)?
    @Binding var isFocused: Bool
    /// One-shot caret placement (Quote's draft insert): the text view
    /// moves the caret to this location the next time it applies a
    /// request it has not seen. The id makes a request single-apply —
    /// re-renders carrying the same request never move the caret again.
    var caretRequest: ChatCaretRequest? = nil

    func makeCoordinator() -> Coordinator {
        Coordinator(onEdit: onEdit, isFocused: $isFocused)
    }

    func makeUIView(context: Context) -> ChatInputUITextView {
        let textView = ChatInputUITextView()
        textView.delegate = context.coordinator
        textView.applyChatInputConfiguration(writingAssistance: writingAssistance)
        textView.accessibilityLabel = placeholder
        context.coordinator.attachPlaceholder(
            to: textView, placeholder: placeholder)
        textView.onExternalDraft = onEdit
        return textView
    }

    func updateUIView(_ textView: ChatInputUITextView, context: Context) {
        context.coordinator.onEdit = onEdit
        // The writing-assistance trait is re-applied every pass: the
        // user can flip Settings → Chat → Writing assistance
        // mid-session and the live field follows without a rebuild.
        textView.applyChatInputConfiguration(writingAssistance: writingAssistance)
        // A new representable value carries a new onEdit closure; the
        // text view's external-draft path must keep reporting through
        // the current one.
        textView.onExternalDraft = onEdit
        textView.onReturnKey = onReturnKey
        textView.onPaste = onPaste
        // The edit menu's Paste item needs the image arm whenever the
        // paste arbitration is wired (an image-only pasteboard hides it
        // otherwise).
        textView.canPasteImages = onPaste != nil
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
        // Quote's caret placement: applied once per request, after the
        // text assignment above settles, and only within the text's
        // bounds.
        if let caretRequest, context.coordinator.appliedCaret != caretRequest,
            caretRequest.location <= (text as NSString).length
        {
            context.coordinator.appliedCaret = caretRequest
            textView.selectedRange = NSRange(
                location: caretRequest.location, length: 0)
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
        return Self.measuredSize(for: uiView, width: width, collapsed: collapsed)
    }

    /// The frame height contract (conversation redesign): hug the
    /// measured text with a one-line (36 pt) floor and a THREE-line cap
    /// when focused-with-text; while collapsed (empty draft or unfocused)
    /// the field claims exactly one line regardless of content. Past the
    /// cap the text view scrolls instead of growing.
    /// UIKit-only inputs so the clamp is testable without a SwiftUI
    /// layout pass.
    static func measuredSize(
        for textView: ChatInputUITextView, width: CGFloat,
        collapsed: Bool = false
    ) -> CGSize {
        let wasScrollEnabled = textView.isScrollEnabled
        textView.isScrollEnabled = false
        let measured = textView.sizeThatFits(
            CGSize(width: width, height: .greatestFiniteMagnitude))
        textView.isScrollEnabled = wasScrollEnabled
        let lineHeight = textView.font?.lineHeight ?? 20
        if collapsed {
            // Compact resting row (v2 device note): the collapsed floor
            // matches the row's 28pt controls (chevron/add/send), so the
            // resting composer is one tight row — the transcript keeps
            // maximum content area when no keyboard is up.
            let height = max(28, min(measured.height, lineHeight))
            textView.isScrollEnabled = measured.height > lineHeight
            return CGSize(width: width, height: height)
        }
        let maximumHeight = lineHeight * 3
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
        /// The last applied one-shot caret request; a request equal to
        /// this has already moved the caret and never will again.
        var appliedCaret: ChatCaretRequest?
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
            // once, with the final caret, through onEdit. The placeholder
            // toggle and the height re-measure are NOT suppressible: they
            // react to the text itself, and skipping them left the
            // placeholder visible under the accepted draft (a
            // device-verified regression).
            if let chatTextView = textView as? ChatInputUITextView,
                chatTextView.isApplyingExternalCaret
            {
                syncPlaceholderVisibility(for: textView)
                textView.invalidateIntrinsicContentSize()
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
