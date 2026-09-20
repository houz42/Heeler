import SwiftUI

// SPDX-License-Identifier: Apache-2.0
//
// The chat surface: a thin status strip over a full-bleed transcript.
// Everything visible beyond text is governed by the per-agent detail level
// (persistent, never modal). The screen is dumb about levels —
// `ChatFiltering` decides, rows render.

/// The data one chat pane renders: the messages and results the windowing
/// layer holds, plus the blocked-agent pending interactions (if any).
internal struct ChatContent: Sendable, Equatable {
    var messages: [ChatMessage]
    var toolResults: [ToolResult]
    var pending: [PendingInteraction]

    init(
        messages: [ChatMessage] = [], toolResults: [ToolResult] = [],
        pending: [PendingInteraction] = []
    ) {
        self.messages = messages
        self.toolResults = toolResults
        self.pending = pending
    }
}

/// The pending-question answer seam: one store per chat surface, holding
/// the locally chosen answers (optimistic state until the transcript's
/// own `ask` result record lands) and delivering a chosen option to the
/// agent's terminal dialog exactly once.
///
/// The delivery channel is KEYS, not agent.prompt: a blocked agent is
/// blocked precisely because it waits on the ask dialog, and herdr's
/// agent.prompt REFUSES blocked agents (`agent_blocked`). omp's dialog is
/// arrow-key driven (verified against a live blocked agent: plain typed
/// text opens a NOTE for the highlighted option; ↓ + Enter selects), so
/// an answer is the question's `selectionKeys` sequence, one key per
/// send, through the pane/agent key channel.
///
/// Pure @MainActor class with injected dependencies — no network, no
/// SwiftUI — so the tap → deliver → answered transition is unit-testable
/// with stubs, exactly like `ComposerRouterStore`.
@MainActor
@Observable
final class PendingAnswerDelivery {
    /// How one answer attempt ended.
    enum Outcome: Equatable {
        /// The option's keys were delivered to the agent's dialog; the
        /// interaction is now answered (locally optimistic — the
        /// transcript's `ask` result record confirms it on the next poll).
        case delivered
        /// Delivery threw: the interaction stays answerable and the card
        /// stays loud so the user can retry.
        case failed(String)
        /// The question is already answered (locally or by the
        /// transcript) or the same tap is still in flight; ignored.
        case alreadyAnswered
    }

    /// The last delivery failure per interaction, for the card to render.
    /// A successful retry (or the transcript's own answer) clears it.
    private(set) var deliveryErrors: [String: String] = [:]
    private(set) var localAnswers: [String: String] = [:]
    private var inFlight: Set<String> = []
    /// Sends one key name (e.g. "down", "enter") to the agent's pane.
    private let sendKey: (_ key: String) async throws -> Void
    private let describeError: (any Error) -> String

    init(
        sendKey: @escaping (_ key: String) async throws -> Void,
        describeError: @escaping (any Error) -> String = {
            ($0 as? LocalizedError)?.errorDescription ?? String(describing: $0)
        }
    ) {
        self.sendKey = sendKey
        self.describeError = describeError
    }

    /// The answer for a pending interaction, if any: the local choice
    /// wins over the transcript's (they agree by construction once the
    /// result record arrives).
    func answer(for interaction: PendingInteraction) -> String? {
        localAnswers[interaction.id] ?? interaction.answer
    }

    /// True while a delivery for this interaction is in flight: the card
    /// shows progress and suppresses further taps (the deliver-once guard
    /// also holds, but the user should SEE why nothing happens).
    func isDelivering(to interaction: PendingInteraction) -> Bool {
        inFlight.contains(interaction.id)
    }

    /// The user-visible failure text for this interaction, if the last
    /// delivery attempt threw.
    func failureMessage(for interaction: PendingInteraction) -> String? {
        deliveryErrors[interaction.id]
    }

    /// Tapping an option: delivers the question's selection keys once,
    /// one key at a time (the dialog moves its highlight per press). A
    /// second tap (or a tap on an already-answered question) is a no-op;
    /// a failed delivery records the failure for the card to show and
    /// keeps the question answerable.
    @discardableResult
    func choose(
        _ option: PendingInteraction.Option, for interaction: PendingInteraction
    ) async -> Outcome {
        guard answer(for: interaction) == nil, !inFlight.contains(interaction.id) else {
            return .alreadyAnswered
        }
        inFlight.insert(interaction.id)
        deliveryErrors[interaction.id] = nil
        defer { inFlight.remove(interaction.id) }
        do {
            for key in interaction.selectionKeys(for: option) {
                try await sendKey(key)
            }
            localAnswers[interaction.id] = option.label
            return .delivered
        } catch {
            deliveryErrors[interaction.id] = describeError(error)
            return .failed(describeError(error))
        }
    }
}

/// Full chat surface for one agent pane. Owns nothing: transcript and level
/// both arrive; level changes flow back out through `changeLevel` so the
/// owner persists them per pane. Scroll paging (Phase 5): a sentinel row
/// above the transcript fires `loadOlder` when the user reaches the top and
/// older history exists; prepended rows keep their stable ids so the
/// LazyVStack anchors the visible row instead of jumping.
struct ChatScreen: View {
    /// Pane identifier (one window = one agent); keys the level persistence.
    let paneID: String
    let agentName: String
    let state: ChatAgentState
    let content: ChatContent
    let changeLevel: (DetailLevel, String) -> Void
    /// True while the window holds older pages the user has not loaded.
    var hasOlder: Bool = false
    /// True while an older-page fetch is in flight.
    var isLoadingOlder: Bool = false
    /// Pages older history when the user scrolls to the top. nil keeps
    /// the transcript static (previews, unavailable panes).
    var loadOlder: (() async -> Void)? = nil
    /// Extra chrome pinned in the status strip before the level switcher
    /// (the surface toggle lives here). Nil = no slot.
    var stripAccessory: AnyView? = nil
    /// The composer's submit router (Phase 2); enables the floating input
    /// button. Nil = read-only chat (previews, unwired hosts).
    var router: ComposerRouterStore? = nil
    /// Delivers plain text to the agent (`agent.prompt` equivalent). Called
    /// only when the router returns `.passthrough`.
    var deliver: ((String) async throws -> Void)? = nil
    /// Sends one key name (e.g. "down", "enter") to the agent's pane —
    /// the pending-question answer channel (blocked agents refuse
    /// agent.prompt; the ask dialog is arrow-key driven). nil = the
    /// question card renders read-only.
    var sendAnswerKey: ((_ key: String) async throws -> Void)? = nil

    @State private var level: DetailLevel
    init(
        paneID: String,
        agentName: String,
        state: ChatAgentState,
        content: ChatContent,
        initialLevel: DetailLevel,
        changeLevel: @escaping (DetailLevel, String) -> Void,
        hasOlder: Bool = false,
        isLoadingOlder: Bool = false,
        loadOlder: (@Sendable () async -> Void)? = nil,
        stripAccessory: AnyView? = nil,
        router: ComposerRouterStore? = nil,
        deliver: ((String) async throws -> Void)? = nil,
        sendAnswerKey: ((_ key: String) async throws -> Void)? = nil
    ) {
        self.paneID = paneID
        self.agentName = agentName
        self.state = state
        self.content = content
        self.changeLevel = changeLevel
        self.hasOlder = hasOlder
        self.isLoadingOlder = isLoadingOlder
        self.loadOlder = loadOlder
        self.stripAccessory = stripAccessory
        self.router = router
        self.deliver = deliver
        self.sendAnswerKey = sendAnswerKey
        self._level = State(initialValue: initialLevel)
        // Built in init, not on appear: the closures are fixed at
        // construction, so a tap on first render is already wired — no
        // read-only window, and no dependence on a .task firing before
        // the first tap.
        if let sendAnswerKey {
            _pendingAnswers = State(
                initialValue: PendingAnswerDelivery(sendKey: sendAnswerKey))
        }
    }

    /// The pending-question answer store, built from the injected
    /// `sendAnswerKey` closure in init (nil = read-only, previews).
    @State private var pendingAnswers: PendingAnswerDelivery?

    /// The pane's link-open router (Phase 4 openers): every detected
    /// target in chat text routes through it. One instance per screen.
    @State private var openRouter = OpenRouterCore()
    /// The silent remote-file fetch the openers use (whole-file SFTP
    /// read; nil while no fetch source is wired keeps links inert).
    var fetch: RemoteFileFetcher? = nil

    /// Scroll paging (Phase 5): one gate per screen, plus whether the top
    /// sentinel row is on screen. Plain state so the trigger is a pure
    /// transition the tests can drive.
    @State private var pagingGate = ChatPagingGate()
    @State private var topSentinelVisible = false
    /// The bottom sentinel's visibility drives the jump control's
    /// newest-end button.
    @State private var bottomSentinelVisible = false

    @Environment(\.openURL) private var openURL

    var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        topSentinel
                        ForEach(items) { item in
                            transcriptView(for: item)
                                .padding(.horizontal, 12)
                        }
                        bottomSentinel
                    }
                    .padding(.vertical, 10)
                }
                // A transcript that parsed to zero rows (metadata-only session
                // file, or a resumed session writing elsewhere) must not render
                // as a blank screen.
                .overlay {
                    if rows.isEmpty {
                        ContentUnavailableView(
                            "No Messages Yet",
                            systemImage: "text.bubble",
                            description: Text(
                                "This transcript has no conversation records. The agent may be writing to a different session file."))
                    }
                }
                // Chat convention: open on the LATEST message; prepended
                // older pages keep the visible row anchored (no jump).
                .defaultScrollAnchor(.bottom)
                .onChange(of: pagingInputs) { _, _ in
                    firePagingIfNeeded()
                }
                .modifier(
                    ChatOpenersSurface(
                        router: openRouter,
                        fetch: fetch ?? { _ in throw CocoaError(.fileNoSuchFile) }))
                // The terminal Attach surface's jump chrome, adapted: one
                // floating pill on the trailing edge, up = oldest loaded,
                // down = latest. Each appears only when its end is offscreen.
                .overlay(alignment: .trailing) {
                    ChatJumpControl(
                        showsOldest: !topSentinelVisible && !rows.isEmpty,
                        showsNewest: !bottomSentinelVisible,
                        onOldest: {
                            if let first = rows.first {
                                withAnimation(.snappy) {
                                    proxy.scrollTo(first.id, anchor: .top)
                                }
                            }
                        },
                        onNewest: {
                            if let last = rows.last {
                                withAnimation(.snappy) {
                                    proxy.scrollTo(last.id, anchor: .bottom)
                                }
                            }
                        })
                    .padding(.trailing, 8)
                }
            }
            // A transcript that parsed to zero rows (metadata-only session
            // file, or a resumed session writing elsewhere) must not render
            // as a blank screen.
            .overlay {
                if rows.isEmpty {
                    ContentUnavailableView(
                        "No Messages Yet",
                        systemImage: "text.bubble",
                        description: Text(
                            "This transcript has no conversation records. The agent may be writing to a different session file."))
                }
            }
            // Chat convention: open on the LATEST message; prepended
            // older pages keep the visible row anchored (no jump).
            .defaultScrollAnchor(.bottom)
            .onChange(of: pagingInputs) { _, _ in
                firePagingIfNeeded()
            }
            .modifier(
                ChatOpenersSurface(
                    router: openRouter,
                    fetch: fetch ?? { _ in throw CocoaError(.fileNoSuchFile) }))
        }
        // The iMessage-style bubble focus presentation, above everything
        // (transcript, composer, keyboard): blurred dim behind, lifted
        // bubble with the Tapback pill and action menu.
        .overlay { bubbleFocusOverlay }
        // The input affordance floats bottom-trailing and only while the
        // input frame is closed; the frame's own chevron closes it.
        .overlay {
            if !inputPresented, router != nil && deliver != nil { inputOverlay }
        }
        .safeAreaInset(edge: .bottom) { inputFrame }
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(true)
        // Hiding the back button also disables the interactive pop gesture;
        // re-enable it — the left-edge swipe is the chat surface's way back.
        .background(PopGestureEnabler())
        .toolbar {
            // Top-leading, where the back button used to be: the level
            // switcher. Chat-only — the terminal surface has no levels.
            ToolbarItem(placement: .topBarLeading) {
                DetailLevelSwitcher(level: level) { newLevel in
                    level = newLevel
                    changeLevel(newLevel, paneID)
                }
            }
        }
    }

    /// The zero-height row above the transcript: presence reports "the user
    /// has reached the top", and the loading affordance rides it.
    @ViewBuilder
    private var topSentinel: some View {
        Group {
            if hasOlder || isLoadingOlder {
                if isLoadingOlder {
                    HStack(spacing: 6) {
                        ProgressView()
                            .controlSize(.mini)
                        Text("Loading older…")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.horizontal, 12)
                    .padding(.top, 2)
                }
                Color.clear
                    .frame(height: 0)
                    .onAppear { topSentinelVisible = true }
                    .onDisappear { topSentinelVisible = false }
            }
        }
    }

    /// Zero-height row below the transcript: visibility here means the
    /// latest message is on screen, which hides the jump pill's down button.
    private var bottomSentinel: some View {
        Color.clear
            .frame(height: 0)
            .onAppear { bottomSentinelVisible = true }
            .onDisappear { bottomSentinelVisible = false }
    }

    private var pagingInputs: [Bool] {
        ChatPagingGate.inputs(
            sentinelVisible: topSentinelVisible, hasOlder: hasOlder,
            isLoadingOlder: isLoadingOlder)
    }

    private func firePagingIfNeeded() {
        guard let loadOlder,
            pagingGate.update(
                sentinelVisible: topSentinelVisible,
                hasOlder: hasOlder,
                isLoadingOlder: isLoadingOlder)
        else { return }
        Task { await loadOlder() }
    }

    private var rows: [ChatRow] {
        ChatFiltering.visibleRows(
            messages: content.messages,
            toolResults: content.toolResults,
            pending: content.pending,
            level: level
        )
    }

    /// The bubble-grouped transcript: conversation text renders as per-
    /// message bubbles (the unit the reaction/quote affordances hang
    /// off); every other row keeps its plain shape.
    private var items: [ChatTranscriptItem] {
        ChatFiltering.visibleItems(from: rows)
    }

    @ViewBuilder
    private func transcriptView(for item: ChatTranscriptItem) -> some View {
        switch item {
        case .bubble(let bubble):
            ChatBubbleView(
                bubble: bubble,
                router: openRouter,
                isFocused: focusedBubble == bubble,
                onLongPress: { enterBubbleFocus(bubble) })
        case .row(.pending(let interaction)):
            // The ask question card rides at its call's transcript position
            // (ChatFiltering places it inline); wired form when the answer
            // channel is available, read-only otherwise.
            pendingCard(interaction)
        case .row(let row):
            LinkifiedChatRow(row: row, router: openRouter)
        }
    }

    /// The iMessage-style long-press focus: at most one bubble lifted at
    /// a time, its id (the first row's) keying which in-place copy hides.
    @State private var focusedBubble: ChatBubble?

    private func enterBubbleFocus(_ bubble: ChatBubble) {
        guard router != nil else { return }
        withAnimation(.snappy) { focusedBubble = bubble }
    }

    /// Sends one quick reaction's composed message (emoji + block-quoted
    /// target) as a plain user message through the composer's passthrough
    /// path (it never starts with / # @ !). The in-flight gate keeps a
    /// double-tap from duplicating the send.
    private func reactAffordance(_ text: String) {
        guard !isSending, let router else { return }
        isSending = true
        Task {
            defer { isSending = false }
            if case .passthrough = await router.submit(text) {
                try? await deliver?(text)
            }
        }
    }

    /// Prefills the composer with the quoted draft and opens the input,
    /// caret at the draft's end (the blank line after the quote).
    private func quoteAffordance(_ text: String) {
        let quoted = ChatQuote.draft(for: text)
        draft = quoted
        caretRequest = ChatCaretRequest(location: ChatQuote.caretLocation(for: quoted))
        inputPresented = true
        inputFocused = true
    }

    /// A one-shot caret placement for the composer's text view.
    @State private var caretRequest: ChatCaretRequest?

    /// Puts the bubble's plain text on the pasteboard.
    private func copyAffordance(_ text: String) {
        ChatBubbleCopy.perform(text)
    }

    /// The full-screen focus presentation over everything: blurred,
    /// dimmed transcript behind; the lifted bubble, Tapback pill above,
    /// and action menu above the composer/keyboard.
    @ViewBuilder
    private var bubbleFocusOverlay: some View {
        if let bubble = focusedBubble {
            ChatBubbleFocusLayer(
                bubble: bubble,
                router: openRouter,
                react: reactAffordance,
                quote: quoteAffordance,
                copy: copyAffordance,
                dismiss: {
                    withAnimation(.snappy) { focusedBubble = nil }
                })
        }
    }

    /// The blocked-question card as the transcript renders it: the wired
    /// form when delivery is available, the read-only form otherwise
    /// (previews, unwired hosts).
    @ViewBuilder
    private func pendingCard(_ interaction: PendingInteraction) -> some View {
        if let pendingAnswers {
            ChatPendingRow(
                interaction: interaction,
                answer: pendingAnswers.answer(for: interaction),
                isDelivering: pendingAnswers.isDelivering(to: interaction),
                failureMessage: pendingAnswers.failureMessage(for: interaction),
                choose: { option in
                    Task { await pendingAnswers.choose(option, for: interaction) }
                })
        } else {
            ChatPendingRow(interaction: interaction, answer: nil, choose: { _ in })
        }
    }

    /// Test-only: the pending-answer store (nil when `deliver` was not
    /// injected), so tests can pin that the store exists from init — the
    /// first tap on first render must already be wired.
    var pendingAnswersForTesting: PendingAnswerDelivery? { pendingAnswers }
    // MARK: - Floating input

    /// The lower-right input affordance: one floating button that opens the
    /// input frame (and the keyboard). Nothing lives on the chat's vertical
    /// axis until the user asks for it.
    @State private var inputPresented = false
    @State private var draft = ""
    @State private var isSending = false
    @State private var inputFocused = false
    /// A suggestion accept waiting for the text view: the applied draft
    /// plus the caret the accept leaves (end of the insertion). Applied
    /// on the next representable update so text and caret land together;
    /// cleared there so an ordinary edit cannot re-apply it.
    @State private var pendingAccept: (draft: String, caret: Int)?

    private var inputOverlay: some View {
        VStack {
            Spacer()
            HStack {
                Spacer()
                Button {
                    inputPresented = true
                    inputFocused = true
                } label: {
                    Image(systemName: "text.cursor")
                        .font(.title3)
                        .frame(width: 52, height: 52)
                }
                .buttonStyle(.borderedProminent)
                .clipShape(Circle())
                .shadow(radius: 3, y: 2)
                .accessibilityLabel("Message the agent")
                .padding()
            }
        }
    }

    /// The input frame: a bottom bar with the draft field. The router owns
    /// prefix classification, suggestions, and delivery of non-plain
    /// commands; plain text flows to `deliver`.
    @ViewBuilder
    private var inputFrame: some View {
        if inputPresented, let router {
            VStack(spacing: 0) {
                if router.hasActiveSuggestions {
                    ComposerSuggestionRow(
                        router: router, draft: draft,
                        applyDraft: { newDraft in
                            // The owner's draft updates HERE, in the
                            // action — not inside the representable's
                            // update pass, where a @State write is
                            // dropped (the device-verified regression:
                            // the accepted text rendered in the field
                            // while draft stayed "", so Send stayed
                            // disabled). Every token case lands the
                            // insertion at the applied draft's end
                            // (slash tokens are trailing, a tag replaces
                            // the whole draft, a mention's remainder is
                            // empty while the menu is open), so the
                            // accept's caret — end of the insertion,
                            // after its trailing space — is the new
                            // draft's end.
                            draft = newDraft
                            pendingAccept = (newDraft, newDraft.utf16.count)
                        })
                }
                if let error = router.routingError {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 12)
                        .padding(.top, 6)
                }
                HStack(spacing: 8) {
                    Button {
                        inputPresented = false
                        inputFocused = false
                    } label: {
                        Image(systemName: "chevron.down")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .frame(width: 28, height: 28)
                            .contentShape(Rectangle())
                    }
                    .accessibilityLabel("Close input")
                    ChatInputTextView(
                        text: draft,
                        placeholder: "Message — / # @ ! for commands",
                        onEdit: { newText, _ in
                            draft = newText
                        },
                        onReturnKey: {
                            // Return with the menu open accepts the
                            // highlighted suggestion (no newline); with
                            // it closed the stock newline insert keeps
                            // working, matching the Composer. The owner's
                            // draft updates here in the action — the
                            // representable's update-pass report is not
                            // enough (a @State write during view update
                            // is dropped).
                            let result = router.handleReturnKey(into: draft)
                            if let accepted = result.accepted {
                                draft = accepted.draft
                                pendingAccept = accepted
                            }
                            return result.consumedKey
                        },
                        pendingAccept: $pendingAccept,
                        isFocused: $inputFocused,
                        caretRequest: caretRequest)
                    Button {
                        sendDraft()
                    } label: {
                        Image(systemName: "arrow.up.circle.fill")
                            .font(.title2)
                    }
                    .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isSending)
                    .accessibilityLabel("Send")
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
            }
            .background(.bar)
            .overlay(alignment: .top) { Divider() }
            // Suggestion parity with the old TextField wiring: the
            // suggestion row's accepts rewrite the draft outside the text
            // view, so the suggestion pass also needs to run on
            // SwiftUI-side draft changes.
            .onChange(of: draft) { _, new in
                router.updateSuggestions(forDraft: new)
            }
        }
    }

    private func sendDraft() {
        let text = draft
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            !isSending, let router
        else { return }
        isSending = true
        Task {
            defer { isSending = false }
            let outcome = await router.submit(text)
            switch outcome {
            case .handled:
                draft = ""
            case .rejected:
                break  // draft stays for editing; routingError explains
            case .passthrough:
                do {
                    try await deliver?(text)
                    draft = ""
                } catch {
                    // Delivery failed: keep the draft for retry.
                }
            }
        }
    }
}

/// The chat scroll jump pill: the terminal Attach surface's
/// MessageJumpControlView adapted for the transcript. One floating capsule
/// on the trailing edge — up goes to the oldest loaded row (the top
/// sentinel keeps paging older on arrival), down goes to the latest. A
/// direction renders only while its end is offscreen; nothing shows at rest.
struct ChatJumpControl: View {
    let showsOldest: Bool
    let showsNewest: Bool
    let onOldest: () -> Void
    let onNewest: () -> Void

    var body: some View {
        if showsOldest || showsNewest {
            VStack(spacing: 0) {
                if showsOldest {
                    jumpButton("chevron.up", label: "Oldest message", action: onOldest)
                }
                if showsOldest, showsNewest {
                    Rectangle()
                        .fill(.primary.opacity(0.14))
                        .frame(width: 18, height: 1)
                        .allowsHitTesting(false)
                }
                if showsNewest {
                    jumpButton("chevron.down", label: "Latest message", action: onNewest)
                }
            }
            .background {
                Capsule()
                    .fill(.ultraThinMaterial)
                    .overlay {
                        Capsule().strokeBorder(.primary.opacity(0.2), lineWidth: 1)
                    }
                    .shadow(color: .black.opacity(0.3), radius: 12, y: 4)
                    .allowsHitTesting(false)
            }
            .transition(.scale(scale: 0.85).combined(with: .opacity))
            .animation(.snappy(duration: 0.22), value: showsOldest || showsNewest)
            .accessibilityElement(children: .contain)
        }
    }

    private func jumpButton(
        _ systemImage: String, label: String, action: @escaping () -> Void
    ) -> some View {
        Button {
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            action()
        } label: {
            Image(systemName: systemImage)
                .font(.system(size: 15, weight: .semibold))
                .frame(width: 40, height: 40)
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }
}

/// Re-enables the navigation stack's interactive pop gesture, which
/// `.navigationBarBackButtonHidden(true)` silently disables. The chat
/// surface has no visible back button, so the edge swipe IS the way back.
private struct PopGestureEnabler: UIViewControllerRepresentable {
    func makeUIViewController(context: Context) -> UIViewController {
        PopGestureViewController()
    }

    func updateUIViewController(_ uiViewController: UIViewController, context: Context) {}

    final class PopGestureViewController: UIViewController {
        override func viewDidAppear(_ animated: Bool) {
            super.viewDidAppear(animated)
            enable()
        }

        override func viewWillAppear(_ animated: Bool) {
            super.viewWillAppear(animated)
            enable()
        }

        private func enable() {
            guard let navigation = sequence(
                first: parent as UIViewController?,
                next: { $0?.parent }
            ).compactMap({ $0 as? UINavigationController }).first
            else { return }
            navigation.interactivePopGestureRecognizer?.isEnabled = true
            navigation.interactivePopGestureRecognizer?.delegate = nil
        }
    }
}
