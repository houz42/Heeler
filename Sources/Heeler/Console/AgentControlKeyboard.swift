import SwiftUI
import UIKit

/// Both pages live inside the tools dock's measured system-keyboard footprint.
/// Page changes never update the keyboard inset or recreate the Composer.
struct AgentControlKeyboard: View {
    let isEnabled: Bool
    let keyboardControl: TerminalKeyboardControl
    let send: (AgentQuickKey) -> Void
    /// The Macros page (KeyboardChords): this pane's macro slots, bound per
    /// pane id. Nil keeps the original two-page layout untouched.
    var macros: MacroKeyboardContext? = nil
    /// herdr prefix chords (KeyboardChords): when wired, a swipe on the
    /// Agent key row sends prefix + direction bytes instead of paging —
    /// the page buttons still switch pages, and the pager keeps its exact
    /// old behavior while this is nil.
    var sendChord: ((Data) -> Void)? = nil

    private enum Page: Hashable {
        case agent
        case macros
        case terminal

        var title: String {
            switch self {
            case .agent: "Agent"
            case .macros: "Macros"
            case .terminal: "Terminal"
            }
        }

        /// The attach suites assert the two original labels; keep them
        /// byte-identical.
        var accessibilityLabel: String {
            switch self {
            case .agent: "Agent controls page"
            case .macros: "Macros page"
            case .terminal: "Terminal keyboard page"
            }
        }
    }

    @State private var page: Page = .agent
    @GestureState private var horizontalDrag: CGFloat = 0
    /// Set while a prefix-chord swipe tracks on the Agent key row, so the
    /// keys stand down mid-swipe the way the pager used to make them.
    @GestureState private var prefixSwipeActive = false
    /// The long-press chord session for the Agent pad's keys. One machine:
    /// one session spans one touch.
    @State private var chord = LongPressChordMachine<KeyChordVariant>()
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// The pages this keyboard shows: the two originals, with Macros
    /// inserted between them only when that feature is wired in.
    private var visiblePages: [Page] {
        [.agent] + (macros == nil ? [] : [.macros]) + [.terminal]
    }

    var body: some View {
        GeometryReader { geometry in
            // Keep the Agent pad and page selector compact while the Terminal
            // page uses the full dock width, including during a page swipe.
            let contentWidth = min(geometry.size.width, InputChromeLayout.maxKeyboardContentWidth)
            VStack(spacing: 0) {
                HStack(spacing: 8) {
                    ForEach(Array(visiblePages.enumerated()), id: \.element) { index, destination in
                        pageButton(destination)
                        // The page indicator keeps its original position:
                        // after the Agent button, before everything else.
                        if index == 0 { pageDots }
                    }
                }
                .frame(height: 26)
                .frame(maxWidth: contentWidth)

                GeometryReader { viewport in
                    pagerContent(contentWidth: contentWidth, viewport: viewport.size)
                        .frame(width: viewport.size.width, height: viewport.size.height, alignment: .leading)
                        .contentShape(.rect)
                        .clipped()
                        // A high-priority drag makes repeating buttons wait for
                        // it to fail, blocking Backspace repeats while held.
                        // Recognize alongside the buttons and disable the keys
                        // once horizontal movement starts to cancel their press.
                        .simultaneousGesture(pageSwipeGesture(width: viewport.size.width))
                        // The herdr prefix-chord recognizer shares the same
                        // touch: inert while `sendChord` is nil, and never while
                        // a chord menu is open (that drag is the held finger's
                        // own selection drag).
                        .simultaneousGesture(prefixSwipeGesture)
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
            .clipped()
        }
        .onChange(of: page) { _, _ in
            clearModifiers()
            // A page change abandons any open chord menu. Suppression
            // survives it: the held key's release still must not send.
            chord.cancel()
        }
        .onDisappear {
            clearModifiers()
            // Nothing can release anymore, so nothing needs suppressing.
            chord.reset()
        }
    }

    private func pagerContent(contentWidth: CGFloat, viewport: CGSize) -> some View {
        HStack(spacing: 0) {
            AgentQuickKeyPad(
                isEnabled: isEnabled,
                send: send,
                chord: $chord,
                sendVariant: sendChordVariant)
                .frame(width: contentWidth)
                .frame(width: viewport.width, height: viewport.height)
                .accessibilityElement(children: .contain)
                .accessibilityHidden(page != .agent)
                .allowsHitTesting(page == .agent)
                .disabled(page != .agent || horizontalDrag != 0 || prefixSwipeActive)
            if let macros {
                MacrosKeyboardPane(
                    store: MacroKeyStore.shared,
                    context: macros,
                    isEnabled: isEnabled,
                    onFired: { selectPage(.agent) })
                    .frame(width: contentWidth)
                    .frame(width: viewport.width, height: viewport.height)
                    .accessibilityElement(children: .contain)
                    .accessibilityHidden(page != .macros)
                    .allowsHitTesting(page == .macros)
                    .disabled(page != .macros || horizontalDrag != 0)
            }
            TerminalFullKeyboard(
                isEnabled: isEnabled, keyboardControl: keyboardControl, send: send)
                .frame(width: viewport.width, height: viewport.height)
                .accessibilityElement(children: .contain)
                .accessibilityHidden(page != .terminal)
                .allowsHitTesting(page == .terminal)
                .disabled(page != .terminal || horizontalDrag != 0)
        }
        .offset(x: pageOffset(width: viewport.width))
    }

    private var pageDots: some View {
        HStack(spacing: 5) {
            ForEach(visiblePages, id: \.self) { destination in
                Circle().fill(page == destination ? Color.accentColor : .secondary.opacity(0.4))
            }
        }
        .frame(width: InputChromeLayout.keyboardPageIndicatorWidth, height: 5)
        .accessibilityHidden(true)
    }

    private func pageButton(_ destination: Page) -> some View {
        Button {
            selectPage(destination)
        } label: {
            Text(destination.title)
                .font(.caption.weight(page == destination ? .semibold : .regular))
                .foregroundStyle(page == destination ? Color.primary : .secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(destination.accessibilityLabel)
        .accessibilityAddTraits(page == destination ? .isSelected : [])
        .accessibilityHint(
            // Prefix chords replace the horizontal page swipe when wired,
            // so the hint stops advertising it.
            sendChord == nil
                ? "Swipe horizontally to switch keyboard pages"
                : "Switches the keyboard to this page")
    }

    private func selectPage(_ destination: Page) {
        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.2)) { page = destination }
    }

    private func pageOffset(width: CGFloat) -> CGFloat {
        // The offset follows the page's position in `visiblePages`, so the
        // two original pages keep their exact former offsets.
        let index = CGFloat(visiblePages.firstIndex(of: page) ?? 0)
        let resting = -width * index
        let widest = -width * CGFloat(visiblePages.count - 1)
        return min(0, max(widest, resting + horizontalDrag))
    }

    private func pageSwipeGesture(width: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 16)
            .updating($horizontalDrag) { value, translation, _ in
                // While prefix chords own the key row's swipes, or a chord
                // menu is open, the pager neither tracks nor pages.
                guard sendChord == nil, !chord.isMenuOpen,
                    abs(value.translation.width) > abs(value.translation.height)
                else { return }
                translation = value.translation.width
            }
            .onEnded { value in
                guard sendChord == nil, !chord.isMenuOpen,
                    abs(value.translation.width) > abs(value.translation.height),
                    abs(value.translation.width) >= min(60, width * 0.2)
                else { return }
                let index = visiblePages.firstIndex(of: page) ?? 0
                let target = value.translation.width < 0 ? index + 1 : index - 1
                guard visiblePages.indices.contains(target) else { return }
                selectPage(visiblePages[target])
            }
    }

    private var prefixSwipeGesture: some Gesture {
        DragGesture(minimumDistance: PrefixSwipeRecognizer.trackingDistance)
            .updating($prefixSwipeActive) { value, state, _ in
                // Stand the keys down mid-swipe, matching the pager's old
                // behavior for the touches the pager no longer claims.
                guard sendChord != nil, isEnabled, page == .agent, !chord.isMenuOpen,
                    Self.isHorizontalOrUpward(value.translation)
                else { return }
                state = true
            }
            .onEnded { value in
                guard sendChord != nil, isEnabled, page == .agent, !chord.isMenuOpen,
                    let direction = PrefixSwipeRecognizer.direction(translation: value.translation)
                else { return }
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                sendChord?(PrefixSwipeRecognizer.chord(for: direction))
            }
    }

    private static func isHorizontalOrUpward(_ translation: CGSize) -> Bool {
        abs(translation.width) > abs(translation.height) || translation.height < 0
    }

    /// Sends a confirmed chord variant. Its steps carry their own one-shot
    /// modifiers, so an accidentally armed cap is discarded first — the
    /// interrupt path's rule that an advertised chord cannot grow extras.
    private func sendChordVariant(_ variant: KeyChordVariant) {
        keyboardControl.setModifierArmed([.control, .option, .shift], armed: false)
        for step in variant.steps {
            _ = keyboardControl.sendQuickKey(step.key, combining: step.modifiers)
        }
    }

    private func clearModifiers() {
        keyboardControl.setModifierArmed([.control, .option, .shift], armed: false)
    }
}

private struct AgentQuickKeyPad: View {
    let isEnabled: Bool
    let send: (AgentQuickKey) -> Void
    @Binding var chord: LongPressChordMachine<KeyChordVariant>
    let sendVariant: (KeyChordVariant) -> Void
    /// The measured overlay strip; the drag-to-select math needs its size.
    @State private var stripSize: CGSize = .zero
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private static let rows: [[AgentQuickKey]] = [
        [.escape, .tab, .backspace],
        [.left, .up, .right],
        [.shiftTab, .down, .enter],
    ]

    var body: some View {
        VStack(spacing: 8) {
            ForEach(Self.rows.indices, id: \.self) { row in
                HStack(spacing: 8) {
                    ForEach(Self.rows[row], id: \.self) { key in
                        Group {
                            if key == .backspace {
                                TerminalBackspaceButton {
                                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                                    send(key)
                                }
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                            } else {
                                keyButton(key)
                            }
                        }
                        .disabled(!isEnabled)
                        .opacity(isEnabled ? 1 : 0.45)
                        .accessibilityLabel(key.accessibilityLabel)
                        .accessibilityHint("Sends this key directly to the Agent")
                    }
                }
                .frame(maxHeight: .infinity)
            }
        }
        .padding(.horizontal, 10)
        .padding(.top, 4)
        .padding(.bottom, 8)
        .overlay {
            if chord.isMenuOpen {
                LongPressChordOverlay(
                    variants: chord.variants,
                    selection: chord.selection,
                    onStripSize: { stripSize = $0 },
                    fire: { variant in
                        sendVariant(variant)
                        // The strip's own taps (a second finger, VoiceOver)
                        // confirm and close in one move; the held finger's
                        // release stays suppressed past its key's action.
                        chord.cancel()
                    },
                    dismiss: { chord.cancel() })
                    .transition(reduceMotion ? .identity : .opacity)
            }
        }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: chord.isMenuOpen)
    }

    @ViewBuilder
    private func keyButton(_ key: AgentQuickKey) -> some View {
        if let variants = LongPressChordVariants.variants(for: key) {
            // Hold opens the chord menu; a quick tap never starts the
            // long-press stage, so the key's tap behavior is untouched and
            // only the session's own release is suppressed instead.
            keyButtonBody(key)
                .simultaneousGesture(chordGesture(variants: variants))
        } else {
            keyButtonBody(key)
        }
    }

    private func keyButtonBody(_ key: AgentQuickKey) -> some View {
        Button {
            // A cancelled swipe must never confirm a key press — nor may a
            // chord session's release, which is what `isTapSuppressed`
            // records (consumed here, reset by the next session's press).
            if chord.isTapSuppressed {
                chord.clearTapSuppression()
                return
            }
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            send(key)
        } label: {
            Group {
                if let image = key.systemImageName {
                    Image(systemName: image)
                } else {
                    Text(key.title ?? "")
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                }
            }
            .font(.system(size: 13, weight: .medium))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .buttonStyle(TerminalKeyboardButtonStyle())
    }

    private func chordGesture(variants: [KeyChordVariant]) -> some Gesture {
        LongPressGesture(minimumDuration: 0.45)
            .sequenced(before: DragGesture(
                minimumDistance: 10,
                coordinateSpace: .named(LongPressChordOverlay.stripSpaceName)))
            .onChanged { value in
                switch value {
                case .first(let pressed):
                    // The long-press stage succeeded: start the session and
                    // open its menu — the machine's press and long-press
                    // transitions, coalesced because the recognizer emits no
                    // event between the two.
                    chord.press(variants: variants)
                    if pressed, chord.longPressFired() {
                        UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    }
                case .second(_, let drag?):
                    select(at: drag.location)
                default:
                    break
                }
            }
            .onEnded { value in
                if case .second(_, let drag?) = value {
                    select(at: drag.location)
                }
                if let variant = chord.end() {
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    sendVariant(variant)
                }
            }
    }

    private func select(at location: CGPoint) {
        chord.select(
            atX: location.x, y: location.y,
            stripWidth: stripSize.width, stripHeight: stripSize.height)
    }
}
