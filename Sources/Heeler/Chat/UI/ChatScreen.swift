import PhotosUI
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

/// Full chat surface for one agent pane. Owns nothing: transcript and level
/// both arrive; level changes flow back out through `changeLevel` so the
/// owner persists them per pane. Scroll paging (Phase 5): a sentinel row
/// above the transcript fires `loadOlder` when the user reaches the top and
/// older history exists; prepended rows keep their stable ids so the
/// LazyVStack anchors the visible row instead of jumping.
struct ChatScreen: View {
    /// Pane identifier (one window = one agent); keys the level persistence.
    /// Pane ids are HOST-LOCAL: two hosts can each have a pane "w1:p1".
    let paneID: String
    /// The pane's Host — draft persistence is keyed by the HOST-QUALIFIED
    /// identity (hostID + paneID); a bare pane id would collide across
    /// hosts (the review's cross-host draft bleed). Level persistence
    /// stays keyed by the pane id alone (its own store contract).
    var hostID: Host.ID? = nil
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
    /// Review gap 2: retries a failed outgoing echo (tap on the failed
    /// bubble's error row). Nil keeps failed echoes visible but inert.
    var retrySend: ((String) async throws -> Void)? = nil
    /// Review gap 7: the structured deliver — text + real image
    /// content. Nil degrades to the text-only deliver.
    var deliverStructured: ((_ text: String, _ images: [AgentChatOutgoingImage]) async throws -> Void)? = nil
    /// True when the pending (ask) rows must render as an honest
    /// unsupported state — the broker backend has no verified answering
    /// API in v1. False keeps the JSONL backend's interactive rows.
    var pendingUnsupported: Bool = false
    /// The assistant article's author line, e.g. "Heeler · omp" —
    /// resolved from the real runtime identity by the surface owner.
    var authorLabel: String = ""
    /// The chat input's attachment bundle (the + button/paste flow).
    /// Nil keeps the frame exactly as before (previews, unwired hosts).
    var attachments: ChatAttachments? = nil

    @State private var level: DetailLevel
    init(
        paneID: String,
        hostID: Host.ID? = nil,
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
        /// Review gap 7 (delivery): the structured deliver — the text
        /// AND its images reach the broker as one prompt.send. Nil
        /// degrades to the text-only deliver.
        deliverStructured: ((_ text: String, _ images: [AgentChatOutgoingImage]) async throws -> Void)? = nil,
        /// Review gap 2: retries a failed outgoing echo (the tap on
        /// the failed bubble's error row). Nil keeps failed echoes
        /// visible but inert.
        retrySend: ((String) async throws -> Void)? = nil,
        pendingUnsupported: Bool = false,
        authorLabel: String = "",
        attachments: ChatAttachments? = nil,
        onAskAnswer: ((PendingInteraction, [PendingAskAnswerPayload]) async throws -> Void)? = nil,
        onAskCancel: ((PendingInteraction) async throws -> Void)? = nil,
        imageFetcher: ((String) async throws -> Data)? = nil,
        fetch: RemoteFileFetcher? = nil
    ) {
        self.paneID = paneID
        self.hostID = hostID
        self.agentName = agentName
        self.state = state
        self.content = content
        self.changeLevel = changeLevel
        self.retrySend = retrySend
        self.deliverStructured = deliverStructured
        self.deliver = deliver
        self.loadOlder = loadOlder
        self.stripAccessory = stripAccessory
        self.router = router
        self.pendingUnsupported = pendingUnsupported
        self.authorLabel = authorLabel
        self.attachments = attachments
        self.onAskAnswer = onAskAnswer
        self.onAskCancel = onAskCancel
        self.imageFetcher = imageFetcher
        self.fetch = fetch
        self._level = State(initialValue: initialLevel)
    }

    /// The HOST-QUALIFIED draft identity (item 18 + review): pane ids
    /// are host-local, so a bare pane id would let two hosts' panes
    /// named "w1:p1" share one draft (text + attachment paths). The
    /// draft store keys on this; level persistence keeps its own
    /// pane-keyed store contract.
    private var draftKey: String {
        guard let hostID else { return paneID }
        return "\(hostID.uuidString)#\(paneID)"
    }

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
    /// The measured keyboard overlap (item 5): the composer pins to
    /// this height instead of SwiftUI's two-stage keyboard avoidance.
    @State private var keyboardInset = ChatKeyboardInset()
    @State private var topSentinelVisible = false

    /// Item 18: per-pane draft persistence (load on appear, save per
    /// edit, clear on successful send).
    private let draftStore = ChatDraftPersistenceStore.shared
    /// The bottom sentinel's visibility drives the jump control's
    /// newest-end button.
    @State private var bottomSentinelVisible = false

    /// The shared reading-size choice (#A settings revision, review
    /// finding 4): applied to the TRANSCRIPT content only — reading
    /// text, never the chrome (status strip, composer, nav bar keep
    /// the design's scale).
    @Environment(\.appReadingTextSize) private var readingTextSize

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
                    // Reading-size applies here: the transcript's reading
                    // text only (review finding 4) — the chrome (status
                    // strip, composer, nav bar) keeps the design's scale.
                    .modifier(ReadingTextSizeModifier(
                        size: readingTextSize?.readingSize))
                }
                // Chat convention: open on the LATEST message. The
                // anchor applies to the INITIAL offset only — NOT to
                // alignment or size changes. A transcript shorter than
                // the viewport then renders from the TOP (content
                // where the reader starts; no blank page above it),
                // while long transcripts still open at the bottom and
                // prepended older pages keep the visible row anchored
                // (no jump).
                .defaultScrollAnchor(.bottom, for: .initialOffset)
                // A transcript that parsed to zero rows (metadata-only
                // session file, or a resumed session writing elsewhere)
                // must not render as a blank screen.
                .overlay {
                    if rows.isEmpty {
                        ContentUnavailableView(
                            "No Messages Yet",
                            systemImage: "text.bubble",
                            description: Text(
                                "This transcript has no conversation records. The agent may be writing to a different session file."))
                    }
                }
                .onChange(of: pagingInputs) { _, _ in
                    firePagingIfNeeded()
                }
                .modifier(
                    ChatOpenersSurface(
                        router: openRouter,
                        fetch: fetch ?? { _ in throw CocoaError(.fileNoSuchFile) }))
                // Outside-tap dismisses the open message-actions rail
                // (taps on a message row win the gesture over this —
                // they toggle the rail instead).
                .onTapGesture { dismissActions() }
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
            // The composer is a LAYOUT SIBLING (not a safe-area inset):
            // stock SwiftUI keyboard avoidance follows the two-stage
            // UIKit notifications an accessory-bearing responder
            // publishes, so the composer parked at the accessory-less
            // frame between the stages and the transcript showed
            // through the strip (the intermittent device gap). The
            // ChatKeyboardInset measures the FINAL frame (coalesced)
            // and the whole surface pads by exactly that — the
            // composer's bottom IS the keyboard stack's top under
            // every state.
            // Read-only transcripts (no router/deliver) keep the
            // composer absent; the keyboard inset stays zero because
            // nothing becomes first responder.
            if router != nil, deliver != nil {
                inputFrame
            }
        }
        .padding(.bottom, keyboardInset.height)
        .ignoresSafeArea(.keyboard, edges: .bottom)
        .chatKeyboardInsetWindow(keyboardInset)
        // Item 18: the identity's draft loads on appear and on any
        // identity change (host or pane — keyed by draftKey), and
        // every draft/item/caret change persists immediately.
        .onAppear { loadPersistedDraft() }
        .onChange(of: draftKey, initial: false) { _, _ in
            loadPersistedDraft()
        }
        .onChange(of: draft) { _, _ in persistDraft() }
        .onChange(of: draftItems) { _, _ in persistDraft() }
        // A caret move WITHOUT typing must persist too (the review's
        // case: move-caret → leave → reopen lands the caret where it
        // was, not at the last typed position).
        .onChange(of: draftCaret) { _, _ in persistDraft() }

        // The +N collection sheet: every draft item, removable there.
        .sheet(isPresented: $showsDraftCollection) {
            ChatDraftCollectionSheet(
                items: draftItems,
                removeItem: { id in removeDraftItem(id) },
                openPreview: { item in
                    showsDraftCollection = false
                    previewedDraftItem = item
                })
                .presentationDetents([.medium, .large])
        }
        // The tapped tile's full preview.
        .sheet(item: $previewedDraftItem) { item in
            ChatDraftItemPreview(item: item, fileFetch: fetch)
                .presentationDetents([.large])
        }
        // A transcript image's full reader (loads via the fetch seam).
        .sheet(item: $viewingImage) { image in
            ChatTranscriptImageReader(image: image, fetch: imageFetcher ?? fetch)
                .presentationDetents([.large])
        }
        // A sent file's in-app reader.
        .sheet(item: $viewingFile) { file in
            NavigationStack {
                ChatDraftFileReader(
                    name: file.ref.split(separator: "/").last
                        .map(String.init) ?? file.ref,
                    path: file.ref,
                    fetch: fetch)
            }
            .presentationDetents([.large])
        }
        // The L1 Work inspector's call details.
        .sheet(item: $inspectedWork) { detail in
            ChatWorkInspectorSheet(detail: detail)
                // A content-fit collapsed detent (a compact 1-call
                // list), plus the taller scrollable forms for
                // expanded results.
                .presentationDetents([.height(220), .medium, .large])
        }
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
        ChatFiltering.visibleItems(from: rows, level: level)
    }

    @ViewBuilder
    private func transcriptView(for item: ChatTranscriptItem) -> some View {
        switch item {
        case .bubble(let bubble):
            // Conversation redesign: USER keeps the compact bubble;
            // ASSISTANT renders as the full-width article (author
            // line + reading-width text). Both keep the long-press
            // affordances via the same focus layer.
            // Message actions (final interaction spec): a short tap
            // toggles the inline Copy/Quote/Helpful rail under the
            // message — one open at a time, outside tap dismisses.
            // Long press is RESERVED for native text selection.
            VStack(alignment: bubble.role == .user ? .trailing : .leading, spacing: 4) {
                if bubble.role == .user {
                    ChatBubbleView(
                        bubble: bubble,
                        router: openRouter,
                        onToggleActions: { toggleActionsBubble(bubble) },
                        imageFetch: imageFetcher ?? fetch,
                        openImageReader: { ref in
                            if ref.mimeType == "file" {
                                viewingFile = ref
                            } else {
                                viewingImage = ref
                            }
                        })
                } else {
                    ChatAssistantArticleView(
                        bubble: bubble,
                        router: openRouter,
                        authorLabel: authorLabel,
                        onToggleActions: { toggleActionsBubble(bubble) })
                }
                if selectedActionsBubble == bubble {
                    let _ = helpfulRefresh
                    ChatMessageActionsRail(
                        isAssistant: bubble.role == .assistant,
                        supportsQuote: router != nil,
                        isMarkedHelpful: helpfulReactions.contains(bubble.id),
                        copy: { copyAffordance(bubble.text); dismissActions() },
                        quote: {
                            quoteAffordance(
                                bubble.text,
                                author: bubble.role == .user ? "You" : "Heeler")
                            dismissActions()
                        },
                        helpful: { toggleHelpful(bubble.id); dismissActions() })
                }
            }
        case .row(let row):
            if pendingUnsupported, case .pending(let interaction) = row {
                AgentUnsupportedAskRow(interaction: interaction)
            } else if case .pending(let interaction) = row {
                askCard(interaction)
            } else if case .image(_, _, let image) = row {
                // Non-consecutive singles still render as one tile
                // (they arrive grouped via .imageGallery otherwise).
                ChatTranscriptImageTile(
                    image: image, fetch: imageFetcher ?? fetch, side: 56)
                { viewingImage = image }
            } else {
                LinkifiedChatRow(
                    row: row, router: openRouter,
                    onRetry: retrySend.map { retry in
                        { Task { @MainActor in
                            guard case .notice(_, _, let text, _) = row
                            else { return }
                            // The notice text is the failed echo's
                            // failure copy; strip the appended
                            // affordance suffix to recover the echo's
                            // own text (the retry key).
                            let echoText = text
                                .replacingOccurrences(
                                    of: " Tap to retry.", with: "")
                            guard !echoText.isEmpty else { return }
                            try? await retry(echoText)
                        } }
                    })
            }
        case .imageGallery(_, let images):
            // One message's images as a single small-square gallery:
            // MEASURED capacity (the same tile+gap math as the draft
            // rail) — the +N tile opens the COLLECTION SHEET (every
            // image, all reachable), never a single hidden one.
            ChatTranscriptImageGallery(
                images: images,
                fetch: imageFetcher ?? fetch,
                openReader: { image in viewingImage = image })
        case .workSummary(_, let calls):
            let names = calls.map { $0.name }
            // The L1 Work inspector: one compact summary of the call
            // run, TAPPABLE — the sheet lists every call with its
            // result. The level switcher expands to per-call rows (L2).
            Button {
                inspectedWork = ChatWorkCallDetail(
                    id: "inspector",
                    entries: calls.map { call in
                        ChatWorkCallDetail.Entry(
                            name: call.name, result: call.result)
                    })
            } label: {
                HStack(spacing: 6) {
                    Label(
                        "Work · \(names.count) call\(names.count == 1 ? "" : "s")",
                        systemImage: "wrench.and.screwdriver")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 4) {
                            ForEach(Array(names.enumerated()), id: \.offset) { _, name in
                                Text(name)
                                    .font(.caption2.monospaced())
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(
                                        Color.secondary.opacity(0.08),
                                        in: Capsule())
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    Image(systemName: "chevron.right")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                .padding(.horizontal, 12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(
                ChatWorkEntry.accessibilitySummaryLabel(count: names.count))
        }
    }

    // -- Pending ask flow (real multi-question, requestId-keyed) --

    /// The ask delivery seams: nil keeps the card read-only (options
    /// render, choosing does nothing, Cancel hidden — honest). THROWS:
    /// a failed/stale submission RETAINS every choice and surfaces the
    /// error on the card; nothing is silently swallowed.
    var onAskAnswer: ((PendingInteraction, _ answers: [PendingAskAnswerPayload]) async throws -> Void)? = nil
    var onAskCancel: ((PendingInteraction) async throws -> Void)? = nil
    /// The last ask seam failure, rendered on the card; choices stay.
    @State private var askError: String?

    /// 1-based step per requestId (a re-ask after resolution starts
    /// fresh because the id changes).
    @State private var askStepByRequest: [String: Int] = [:]
    /// Choices so far per requestId: questionId -> option ids.
    @State private var askChoices: [String: [String: Set<String>]] = [:]

    /// One built answer payload per answered question.
    struct PendingAskAnswerPayload {
        let questionId: String
        let optionIds: [String]
    }

    @ViewBuilder
    private func askCard(_ interaction: PendingInteraction) -> some View {
        let questions = interaction.effectiveQuestions
        let step = askStepByRequest[interaction.id] ?? 1
        let question = questions[min(step, questions.count) - 1]
        let choices = askChoices[interaction.id] ?? [:]
        let selected = choices[question.id] ?? []
        AgentPendingQuestionCard(
            interaction: interaction,
            step: min(step, questions.count),
            stepCount: questions.count,
            isMultiSelect: question.multi,
            selectedOptionIds: selected,
            choose: { optionId in
                chooseAskOption(interaction, question: question, optionId: optionId)
            },
            confirmMultiSelect:
                (question.multi && onAskAnswer != nil)
                ? { confirmMultiAsk(interaction) } : nil,
            back: step > 1 ? {
                askStepByRequest[interaction.id] = step - 1
            } : nil,
            cancel: onAskCancel.map { cancel in
                { Task { @MainActor in
                    do { try await cancel(interaction) }
                    catch {
                        askError = Self.askErrorText(
                            error, prefix: "Cancel failed")
                    }
                } } as () -> Void
            },
            errorMessage: askError)
    }

    /// Choosing records the answer; ANY question (single or multi)
    /// advances — only the LAST question's choice submits the whole
    /// payload once. Multi-select toggles still submit via Confirm.
    private func chooseAskOption(
        _ interaction: PendingInteraction,
        question: PendingAskQuestion, optionId: String
    ) {
        var perQuestion = askChoices[interaction.id] ?? [:]
        if question.multi {
            // Multi questions NEVER advance on a toggle (the user may
            // want more selections); their explicit Confirm both
            // advances (middle questions) and submits (the last one).
            var set = perQuestion[question.id] ?? []
            if set.contains(optionId) { set.remove(optionId) }
            else { set.insert(optionId) }
            perQuestion[question.id] = set
            askChoices[interaction.id] = perQuestion
        } else {
            perQuestion[question.id] = [optionId]
            askChoices[interaction.id] = perQuestion
            let step = askStepByRequest[interaction.id] ?? 1
            let questions = interaction.effectiveQuestions
            if step >= questions.count {
                submitAsk(interaction)
            } else {
                askStepByRequest[interaction.id] = step + 1
            }
        }
    }

    /// A multi question's Confirm: ADVANCES to the next question when
    /// more remain (choices preserved), SUBMITS the full payload when
    /// this was the last one. The card's Confirm is disabled until the
    /// current set is non-empty; earlier steps all recorded.
    private func confirmMultiAsk(_ interaction: PendingInteraction) {
        let step = askStepByRequest[interaction.id] ?? 1
        let questions = interaction.effectiveQuestions
        guard step >= 1, step <= questions.count else { return }
        let current = questions[step - 1]
        guard let set = askChoices[interaction.id]?[current.id], !set.isEmpty
        else { return }
        if step >= questions.count {
            submitAsk(interaction)
        } else {
            askStepByRequest[interaction.id] = step + 1
        }
    }

    /// An ask error's honest copy: the wire message when present (the
    /// raw localizedDescription renders 'AgentChatError error 0' —
    /// opaque); never a bare domain dump.
    private static func askErrorText(
        _ error: any Error, prefix: String
    ) -> String {
        if case AgentChatError.wire(_, let message, _) = error {
            return "\(prefix): \(message)"
        }
        return "\(prefix): \(error.localizedDescription)"
    }

    /// The final answer delivery: EVERY question must carry a choice —
    /// a partial payload is never sent (the caller's Confirm gates the
    /// last multi question; earlier single-choice steps all recorded).
    private func submitAsk(_ interaction: PendingInteraction) {
        guard let onAskAnswer else { return }
        let perQuestion = askChoices[interaction.id] ?? [:]
        var payloads: [PendingAskAnswerPayload] = []
        for question in interaction.effectiveQuestions {
            guard let ids = perQuestion[question.id], !ids.isEmpty else { return }
            payloads.append(PendingAskAnswerPayload(
                questionId: question.id, optionIds: ids.sorted()))
        }
        Task { @MainActor in
            do {
                try await onAskAnswer(interaction, payloads)
                askError = nil
            } catch {
                // Retain every choice; the user re-submits or Backs.
                askError = Self.askErrorText(
                    error, prefix: "Answer failed")
            }
        }
    }

    /// The message-actions selection (final interaction spec): the one
    /// message whose inline Copy/Quote/Helpful rail is open. A tap
    /// toggles; tapping another message switches; outside tap dismisses.
    @State private var selectedActionsBubble: ChatBubble?

    private func toggleActionsBubble(_ bubble: ChatBubble) {
        withAnimation(.snappy) {
            selectedActionsBubble = selectedActionsBubble == bubble ? nil : bubble
        }
    }

    private func dismissActions() {
        withAnimation(.snappy) { selectedActionsBubble = nil }
    }

    /// 'Helpful' on a message: a REAL local reaction, persisted
    /// on-device (ChatHelpfulReactions). No feedback contract exists
    /// yet — nothing is claimed sent; the state shown is the honest
    /// local truth.
    private let helpfulReactions = ChatHelpfulReactions()
    /// Bumps when a reaction toggles so the rail re-renders its state.
    @State private var helpfulRefresh = 0
    private func toggleHelpful(_ id: String) {
        helpfulReactions.toggle(id)
        helpfulRefresh += 1
    }

    /// Prefills the composer with the quoted draft and opens the input,
    /// caret at the draft's end (the blank line after the quote).
    /// Quote adds a REMOVABLE draft item (the tile rail shows it with
    /// its author); the user's draft text is never replaced. Send
    /// composes each held quote as a block-quoted prefix.
    private func quoteAffordance(_ text: String, author: String = "Heeler") {
        let id = "quote-" + String(text.hashValue)
        guard !draftItems.contains(where: { $0.id == id }) else {
            inputFocused = true
            return
        }
        draftItems.append(.quote(id: id, text: text, author: author))
        inputFocused = true
    }

    /// A one-shot caret placement for the composer's text view.
    @State private var caretRequest: ChatCaretRequest?

    /// The + menu's attachment actions. The menu renders whenever the
    /// surface is interactive (router + deliver wired), not whenever
    /// the attachments bundle happens to be alive — a stranded bundle
    /// (spurious disappear teardown) must never hide the button. With
    /// no bundle the menu items honestly report unavailability.
    private var attachmentActions: AgentComposerActions {
        let canBegin = attachments?.staging.canBegin ?? false
        return AgentComposerActions(
            canBegin: canBegin,
            attachLinkCount: 0,
            addImage: { isSelectingPhoto = true },
            addFile: { isSelectingFile = true },
            showAttachLinks: {},
            openTerminal: nil,
            isOpeningTerminal: false,
            startAgent: {},
            manageSnippets: {},
            showSkills: nil,
            showWorktreeDetails: nil,
            renameAgent: {},
            renameWorkspace: {},
            closeAgent: {})
    }

    /// The paste arbitration: an image-only pasteboard attaches the
    /// image (upload via the same staging pipeline); text pastes stay
    /// literal; both-present prefers text. Runs synchronously (the
    /// paste action must decide now); the upload proceeds async inside.
    private func handlePaste() -> Bool {
        guard let attachments else { return false }
        let intent = ChatPasteResolver.resolve()
        guard intent.attachesImage, let data = intent.imageData else {
            return false  // stock text paste
        }
        beginPasteImageAttachment(data)
        return true
    }

    /// Uploads a pasted image's bytes and shows the pending tile once
    /// the remote path lands. A failure surfaces in the frame's error
    /// row, never a silent no-op.
    private func beginPasteImageAttachment(_ data: Data) {
        guard let attachments else { return }
        isPasteImageAttachment = true
        pendingImagePreviewData = data
        attachmentErrorMessage = nil
        attachments.draftStore.clearUploadFailure()
        let canBegin = attachments.staging.begin(
            .photo(DataImageSelection(data: data)), insertPathIntoComposer: false)
        if canBegin == nil {
            attachments.draftStore.recordUploadFailure(
                "An attachment is already uploading. Try again once it finishes.")
            pendingImagePreviewData = nil
            isPasteImageAttachment = false
        }
    }

    /// The staging store's state machine, surfaced: completed uploads
    /// hold as ONE draft item (the tile is the visible attachment; the
    /// path never touches the prose — the staging store is begun with
    /// insertPathIntoComposer:false, so nothing needs stripping here);
    /// failures land in the error row.
    private func syncAttachmentUploadState(_ newState: ComposerStagingStore.State?) {
        guard let attachments else { return }
        switch newState {
        case .idle, .preparing, .uploading:
            attachments.draftStore.clearUploadFailure()
        case .failed(let failure), .backgroundInterrupted(let failure):
            attachments.draftStore.recordUploadFailure(failure.message)
        case .completed(let outcome):
            attachments.draftStore.clearUploadFailure()
            if isPasteImageAttachment {
                // Paste image: the tile carries the attachment; the
                // path rides the Send composition exactly once.
                draftItems.append(.image(
                    id: UUID().uuidString,
                    remotePath: outcome.path,
                    previewData: pendingImagePreviewData))
                pendingImagePreviewData = nil
                isPasteImageAttachment = false
            } else {
                // Picker completion: exactly one draft item by medium.
                switch outcome.medium {
                case .image:
                    draftItems.append(.image(
                        id: UUID().uuidString,
                        remotePath: outcome.path,
                        previewData: pendingPickerImageData))
                    pendingPickerImageData = nil
                case .file:
                    let name = pendingFileURL?.lastPathComponent ?? "File"
                    draftItems.append(.file(
                        id: UUID().uuidString,
                        name: name, remotePath: outcome.path))
                    pendingFileURL = nil
                }
            }
        case nil:
            break
        }
    }

    /// Send needs draft text or a held pending image: a pasted image
    /// with no message text still sends (the path reference IS the
    /// message).
    private var canSend: Bool {
        if !draftItems.isEmpty { return true }
        return !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Puts the bubble's plain text on the pasteboard.
    private func copyAffordance(_ text: String) {
        ChatBubbleCopy.perform(text)
    }


    // MARK: - Floating input

    @State private var draft = ""
    @State private var isSending = false
    /// The last delivery failure, shown inline above the composer —
    /// never silent (the send that vanishes is a build gate).
    @State private var deliveryError: String?
    /// SENDING → SENT (transcript-confirmed) / FAILED: the honest
    /// delivery state. The transcript's own poll merges the sent
    /// record into content; the confirmation flag shows SENT until
    /// the message renders (then it's simply there).
    @State private var showSentConfirmation = false
    @State private var inputFocused = false
    /// A suggestion accept waiting for the text view: the applied draft
    /// plus the caret the accept leaves (end of the insertion). Applied
    /// on the next representable update so text and caret land together;
    /// cleared there so an ordinary edit cannot re-apply it.
    @State private var pendingAccept: (draft: String, caret: Int)?

    /// §D draft items: attachments and quotes held as removable tiles
    /// above the field. Send composes the message from them — image
    /// paths ride ahead of the prose, quotes land block-quoted. The
    /// rail preserves across blur (draft state, not focus state).
    @State private var draftItems: [ChatDraftItem] = []
    /// The +N collection sheet.
    @State private var showsDraftCollection = false
    /// The tapped tile's full preview (image zoom or quote text).
    @State private var previewedDraftItem: ChatDraftItem?
    /// Resolves a wire image ref to bytes (broker blob.read). Nil =
    /// images render as honest unavailable tiles.
    var imageFetcher: ((String) async throws -> Data)? = nil
    /// The transcript image being read full-size.
    @State private var viewingImage: ChatImageRef?
    /// A file reference being read in-app (the sent-file chip opens
    /// this reader — every file previews before any external app).
    @State private var viewingFile: ChatImageRef?
    /// The L1 work inspector's call detail (tapped summary row).
    @State private var inspectedWork: ChatWorkCallDetail?

    // -- Attachment flow state (the + button's pickers and the image
    // paste share the staging pipeline; the pending-image tile rides
    // the draft tile rail above the field) --

    @State private var isSelectingPhoto = false
    @State private var selectedPhoto: PhotosPickerItem?
    @State private var isSelectingFile = false
    /// The pending image's preview bytes (the tile's thumbnail).
    @State private var pendingImagePreviewData: Data?
    /// True while the current upload began from the PASTE path (its
    /// completed upload holds in draftStore.pendingImage with the path
    /// removed from the draft); false = picker path (path stays in the
    /// draft, inserted at the caret).
    @State private var isPasteImageAttachment = false
    /// A picker firing before the bundle exists: honest error, no silent
    /// no-op.
    @State private var attachmentErrorMessage: String?
    /// The file picker's last selection (name for the rail tile).
    @State private var pendingFileURL: URL?
    /// The photo picker's item data (the tile's preview thumbnail).
    @State private var pendingPickerImageData: Data?

    /// The composer's text field (the growing/collapsing input), split
    /// out to keep each view expression within the type-checker's
    /// budget. The closures are plain methods so the call expression
    /// stays small.
    @ViewBuilder
    private var composerField: some View {
        if let router {
            ChatInputTextView(
                text: draft,
                // Composer collapse (conversation redesign): empty OR
                // unfocused = single row; focused with text grows to
                // the 3-line cap. The draft survives blur untouched.
                placeholder: "Message — / # @ ! for commands",
                onEdit: { [self] newText, caret in
                    self.applyComposerEdit(newText, caret: caret)
                },
                onReturnKey: { [self] in self.composerReturnKey(router) },
                onPaste: { [self] in self.handlePaste() },
                pendingAccept: $pendingAccept,
                isFocused: $inputFocused,
                caretRequest: caretRequest)
        }
    }

    /// The draft's live caret (UTF-16), tracked so a persisted draft can
    /// restore it (item 18). The representable reports it with every
    /// edit; the suggestion-accept path lands its own caret through
    /// pendingAccept, and the next edit tracks the settled result.
    @State private var draftCaret = 0

    private func applyComposerEdit(_ newText: String, caret: Int = 0) {
        draft = newText
        draftCaret = caret
    }

    /// Return with the suggestion menu open accepts the highlighted
    /// suggestion (no newline); with it closed the stock newline insert
    /// keeps working, matching the Composer. The owner's draft updates
    /// here in the action — the representable's update-pass report is
    /// not enough (a @State write during view update is dropped).
    private func composerReturnKey(_ router: ComposerRouterStore) -> Bool {
        let result = router.handleReturnKey(into: draft)
        if let accepted = result.accepted {
            draft = accepted.draft
            pendingAccept = accepted
        }
        return result.consumedKey
    }

    /// The composer row: close chevron, the + (add attachment) menu,
    /// the growing/collapsing text field, and Send. Split out of
    /// inputFrame so neither expression overloads the type-checker.
    @ViewBuilder
    private var composerRow: some View {
        if let router {
        HStack(spacing: 8) {
            if keyboardInset.height > 0 {
                // Keyboard-dismiss chevron (v2 device note): ONLY when
                // the keyboard is actually up — a dead dismiss control
                // on the collapsed resting row (keyboard down) is
                // misleading chrome. Tapping focuses the field instead
                // via the field's own tap.
                Button {
                    // Collapse to the resting row: keyboard down, focus
                    // off — the draft and the frame PERSIST.
                    inputFocused = false
                } label: {
                    Image(systemName: "chevron.down")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 28, height: 28)
                        .contentShape(Rectangle())
                }
                .accessibilityLabel("Collapse input")
            }
            if router != nil && deliver != nil {
                Menu {
                    AgentActionMenuContent(
                        actions: attachmentActions,
                        sections: AgentActionMenuPolicy.composerAddSections)
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 15, weight: .semibold))
                        .frame(width: 18, height: 18)
                }
                .buttonStyle(.bordered)
                .buttonBorderShape(.circle)
                .tint(Color(uiColor: .label).opacity(0.72))
                .frame(minWidth: 28, minHeight: 28)
                .accessibilityLabel("Add")
                .accessibilityHint("Adds an image or file to the draft")
            }
            composerField
            Button {
                sendDraft()
            } label: {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.title2)
            }
            .disabled(!canSend || isSending)
            .accessibilityLabel("Send")
        }
        .padding(.horizontal, 12)
        // Compact resting state (v2 device note): empty/unfocused draft
        // AND keyboard down — the composer shrinks to the tightest row
        // so the transcript keeps maximum content area. Keyboard up
        // keeps the full working padding.
        .padding(.vertical, isResting ? 4 : 8)
        }
    }

    /// The composer's most compact state: an empty (or unfocused) draft
    /// with the keyboard down. Focused typing keeps the working frame;
    /// a non-empty draft with the keyboard down keeps the middle
    /// padding so a held draft never looks squeezed.
    private var isResting: Bool {
        !inputFocused && keyboardInset.height == 0 && draft.isEmpty
    }

    /// The input frame: a bottom bar with the draft field. The router owns
    /// prefix classification, suggestions, and delivery of non-plain
    /// commands; plain text flows to `deliver`.
    @ViewBuilder
    private var inputFrame: some View {
        if let router, deliver != nil {
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
                if let attachmentError = attachmentErrorMessage
                    ?? attachments?.draftStore.uploadFailureMessage
                {
                    Text(attachmentError)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 12)
                        .padding(.top, 6)
                }
                // The draft tile rail (§D): every draft item (images,
                // files, quotes) as a small square tile, corner-x
                // removes; +N (only on real overflow) opens the
                // collection sheet. Preserved across blur.
                if !draftItems.isEmpty {
                    ChatDraftTileRail(
                        items: draftItems,
                        removeItem: { id in removeDraftItem(id) },
                        openPreview: { item in previewedDraftItem = item },
                        openCollection: { showsDraftCollection = true })
                        .padding(.horizontal, 12)
                        .padding(.top, 6)
                }
                // The row carries its own horizontal+vertical padding;
                // the frame adds NO second vertical band (the resting
                // state is the row's tight padding alone).
                composerRow
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
            .onChange(of: selectedPhoto) { _, item in
                guard let item else { return }
                selectedPhoto = nil
                guard let attachments else {
                    attachmentErrorMessage =
                        "Attachments are still loading. Try again."
                    return
                }
                isPasteImageAttachment = false
                attachmentErrorMessage = nil
                attachments.draftStore.clearUploadFailure()
                // The tile's preview: the picked item's own bytes.
                Task { @MainActor in
                    pendingPickerImageData =
                        try? await item.loadTransferable(type: Data.self) ?? nil
                }
                attachments.staging.begin(
                    .photo(PhotosPickerImageSelection(item: item)),
                    insertPathIntoComposer: false)
            }
            .photosPicker(
                isPresented: $isSelectingPhoto,
                selection: $selectedPhoto,
                matching: .images)
            .fileImporter(
                isPresented: $isSelectingFile,
                allowedContentTypes: [.data]
            ) { result in
                guard case .success(let url) = result else { return }
                guard let attachments else {
                    attachmentErrorMessage =
                        "Attachments are still loading. Try again."
                    return
                }
                isPasteImageAttachment = false
                attachmentErrorMessage = nil
                attachments.draftStore.clearUploadFailure()
                pendingFileURL = url
                attachments.staging.begin(.file(url), insertPathIntoComposer: false)
            }
            .onChange(of: attachments?.staging.state) { _, newState in
                syncAttachmentUploadState(newState)
            }
        }
    }

    /// The message Send delivers: each held quote as a block-quoted
    /// prefix, then the draft's own text. Attachment paths ride ahead
    /// (the reference convention the agent already reads).
    /// The message Send delivers, built so every draft item rides
    /// EXACTLY ONCE and the user's text is preserved verbatim:
    /// each attachment's remote path (paste images never had one in
    /// the draft; picker items do — the path is stripped from the
    /// draft text as it is emitted into the message), then quotes
    /// block-quoted, then the remaining prose.
    private func composedMessageText() -> String {
        ChatDraftComposer.messageText(items: draftItems, draft: draft)
    }

    /// A successful Send clears the composer AND its persisted draft
    /// (item 18: the next message starts clean; a cleared composer stays
    /// cleared across surfaces).
    private func clearDraftAfterSend() {
        draft = ""
        draftItems = []
        draftStore.clear(paneID: draftKey)
    }

    /// The pane's persisted draft (item 18): loaded on appear (and on
    /// identity change) so a half-typed message survives leaving and
    /// returning to the chat. A MISSING entry installs the EMPTY
    /// state — the review's case: switching identities in the same
    /// view must not leave the previous identity's text/items/caret on
    /// screen. The caret rides the draft via a one-shot placement so
    /// the restore never fights an in-progress selection.
    private func loadPersistedDraft() {
        guard let saved = draftStore.draft(paneID: draftKey) else {
            // No draft for THIS identity: empty composer, no stale
            // caret request from the previous identity.
            draft = ""
            draftItems = []
            draftCaret = 0
            return
        }
        draft = saved.text
        draftItems = saved.items.map(ChatDraftItem.init)
        draftCaret = saved.caretLocation
        caretRequest = ChatCaretRequest(location: saved.caretLocation)
    }

    /// Persists the live draft per edit (item 18). An EMPTY draft clears
    /// the entry — cheap enough to run on every keystroke (the encode is
    /// a small Codable; image preview BYTES never persist by design).
    /// Keyed by the HOST-QUALIFIED identity (draftKey): two hosts' same-
    /// named panes keep independent drafts.
    private func persistDraft() {
        draftStore.save(
            ChatPaneDraft(
                text: draft,
                caretLocation: draftCaret,
                items: draftItems.map(\.paneDraftItem)),
            paneID: draftKey)
    }

    private func removeDraftItem(_ id: String) {
        draftItems.removeAll { $0.id == id }
    }

    private func sendDraft() {
        let text = composedMessageText()
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            !isSending, let router
        else { return }
        isSending = true
        deliveryError = nil
        Task {
            defer { isSending = false }
            // An attachment-bearing message is a PROMPT by definition —
            // bypass the prefix classification entirely (the old path
            // let a leading attachment path classify as a shell
            // command and the message landed in a terminal pane, never
            // the agent).
            if ChatDraftComposer.carriesAttachments(items: draftItems) {
                do {
                    // Review gap 7: image draft items ride the
                    // structured send as REAL image content (the
                    // staged remote path is the broker's img: ref);
                    // file items keep their '@path' text reference in
                    // the composed prose.
                    let images: [AgentChatOutgoingImage] = draftItems.compactMap {
                        item in
                        guard case .image(_, let remotePath, _) = item else {
                            return nil
                        }
                        return AgentChatOutgoingImage(
                            ref: remotePath, mimeType: "image/png")
                    }
                    try await deliverWithImages(text, images)
                    clearDraftAfterSend()
                    showSentConfirmation = true
                    Task { @MainActor in
                        try? await Task.sleep(for: .seconds(2))
                        showSentConfirmation = false
                    }
                } catch {
                    // Visible + retryable: the draft (and items) stay.
                    deliveryError = "Send failed — your message may not have been delivered. Retry when ready."
                }
                return
            }
            let outcome = await router.submit(text)
            switch outcome {
            case .handled:
                clearDraftAfterSend()
            case .rejected:
                break  // draft stays for editing; routingError explains
            case .passthrough:
                do {
                    try await deliver?(text)
                    clearDraftAfterSend()
                    showSentConfirmation = true
                    Task { @MainActor in
                        try? await Task.sleep(for: .seconds(2))
                        showSentConfirmation = false
                    }
                } catch {
                    // Visible + retryable: the draft (and items) stay.
                    deliveryError = "Send failed — your message may not have been delivered. Retry when ready."
                }
            }
        }
    }

    /// Review gap 7: the structured-send path for attachment-bearing
    /// sends. The deliver closure stays text-only (the router's
    /// passthrough contract); when the images seam is wired the send
    /// routes through it so the broker receives REAL image content
    /// blocks alongside the text — otherwise it degrades to the
    /// text-only deliver (the pre-wire path).
    private func deliverWithImages(
        _ text: String, _ images: [AgentChatOutgoingImage]
    ) async throws {
        if let deliverStructured {
            try await deliverStructured(text, images)
        } else {
            try await deliver?(text)
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
