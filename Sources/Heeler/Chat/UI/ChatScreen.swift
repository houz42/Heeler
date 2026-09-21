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
        pendingUnsupported: Bool = false,
        authorLabel: String = "",
        attachments: ChatAttachments? = nil,
        onAskAnswer: ((PendingInteraction, [PendingAskAnswerPayload]) async throws -> Void)? = nil,
        onAskCancel: ((PendingInteraction) async throws -> Void)? = nil,
        imageFetcher: ((String) async throws -> Data)? = nil,
        fetch: RemoteFileFetcher? = nil
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
        self.pendingUnsupported = pendingUnsupported
        self.authorLabel = authorLabel
        self.attachments = attachments
        self.onAskAnswer = onAskAnswer
        self.onAskCancel = onAskCancel
        self.imageFetcher = imageFetcher
        self.fetch = fetch
        self._level = State(initialValue: initialLevel)
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
    @State private var topSentinelVisible = false
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
        .safeAreaInset(edge: .bottom) { inputFrame }
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
                        onToggleActions: { toggleActionsBubble(bubble) })
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
                LinkifiedChatRow(row: row, router: openRouter)
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
                    catch { askError = "Cancel failed: \(error.localizedDescription)" }
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
                askError = "Answer failed: \(error.localizedDescription)"
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
            .photo(DataImageSelection(data: data)))
        if canBegin == nil {
            attachments.draftStore.recordUploadFailure(
                "An attachment is already uploading. Try again once it finishes.")
            pendingImagePreviewData = nil
            isPasteImageAttachment = false
        }
    }

    /// The staging store's state machine, surfaced: completed
    /// paste-image uploads hold for the Send flow (path removed from
    /// the draft — the tile is the visible attachment); failures land
    /// in the error row.
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
                // Paste image: the path the staging store inserted into
                // the draft mirror comes OUT of the draft (the tile is
                // the visible attachment) and lands as ONE draft item.
                draft = attachments.draftStore.draft
                if let range = draft.range(of: outcome.path) {
                    draft.removeSubrange(range)
                }
                draftItems.append(.image(
                    id: UUID().uuidString,
                    remotePath: outcome.path,
                    previewData: pendingImagePreviewData))
                pendingImagePreviewData = nil
                isPasteImageAttachment = false
            } else {
                // Picker completion: exactly one draft item; the
                // staging store's inserted path comes OUT of the prose
                // AT INSERT TIME (the tile is the visible attachment),
                // so the prose stays ONLY the user's own text — never
                // stripped again at Send.
                draft = attachments.draftStore.draft
                if let range = draft.range(of: outcome.path) {
                    draft.removeSubrange(range)
                }
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
                collapsed: draft.isEmpty || !inputFocused,
                placeholder: "Message — / # @ ! for commands",
                onEdit: { [self] newText, _ in self.applyComposerEdit(newText) },
                onReturnKey: { [self] in self.composerReturnKey(router) },
                onPaste: { [self] in self.handlePaste() },
                pendingAccept: $pendingAccept,
                isFocused: $inputFocused,
                caretRequest: caretRequest)
        }
    }

    private func applyComposerEdit(_ newText: String) {
        draft = newText
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
        .padding(.vertical, 8)
        }
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
                composerRow
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
                attachments.staging.begin(.photo(PhotosPickerImageSelection(item: item)))
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
                attachments.staging.begin(.file(url))
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

    private func clearDraftAfterSend() {
        draft = ""
        draftItems = []
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
        Task {
            defer { isSending = false }
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
                } catch {
                    // Delivery failed: keep the draft (and items) for retry.
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
