import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

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
    /// The input frame's attachment flow (+ menu, pickers, paste). Nil
    /// keeps the frame exactly as before — read-only chat surfaces and
    /// previews get no + button and stock paste.
    var attachments: ChatAttachments? = nil
    /// Delivers plain text to the agent (`agent.prompt` equivalent). Called
    /// only when the router returns `.passthrough`.
    var deliver: ((String) async throws -> Void)? = nil

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
        attachments: ChatAttachments? = nil,
        deliver: ((String) async throws -> Void)? = nil
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
        self.attachments = attachments
        self.deliver = deliver
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

    @Environment(\.openURL) private var openURL

    var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        topSentinel
                        ForEach(rows) { row in
                            LinkifiedChatRow(row: row, router: openRouter)
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
    /// The + menu's Add Image picker (matching: .images).
    @State private var selectedPhoto: PhotosPickerItem?
    @State private var isSelectingPhoto = false
    /// The + menu's Add File importer (allowedContentTypes: [.data]).
    @State private var isSelectingFile = false
    /// True while the in-flight/completed upload belongs to a paste
    /// (thumbnail-chip flow) rather than an explicit + menu add
    /// (path-in-draft flow). Pickers set this false; paste sets true.
    @State private var isPasteImageAttachment = false
    /// The pasted image's local preview bytes, kept for the thumbnail
    /// chip until Send (the upload itself streams to the Host).
    @State private var pendingImagePreviewData: Data?

    /// The thumbnail chip's image source; nil hides the chip.
    private var pendingImagePreview: Data? {
        pendingImagePreviewData
    }

    /// The x on the thumbnail chip: drops the held image. The remote
    /// file stays (ADR 0005 — completed Host files outlive the flow);
    /// only the message reference is dropped.
    private func removePendingImage() {
        attachments?.draftStore.clearPendingImage()
        pendingImagePreviewData = nil
    }

    /// The draft seam the staging store inserts into: mirrors the
    /// text-view edits so a completed upload lands its remote path at
    /// the caret. Kept in sink with `draft` on every onEdit.
    private func sinkEdit(_ text: String, caret: Int) {
        draft = text
        attachments?.draftStore.applyEditorDraft(text, selection: NSRange(location: caret, length: 0))
    }

    /// The + button's actions, mirroring the terminal Composer's
    /// `AgentComposerActions` shape but scoped to attachments only.
    private var attachmentActions: AgentComposerActions? {
        guard let attachments else { return nil }
        return AgentComposerActions(
            canBegin: attachments.staging.canBegin,
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

    /// Uploads a pasted image's bytes and shows the pending chip once
    /// the remote path lands. A failure surfaces in the frame's error
    /// row, never a silent no-op.
    private func beginPasteImageAttachment(_ data: Data) {
        guard let attachments else { return }
        isPasteImageAttachment = true
        pendingImagePreviewData = data
        attachments.draftStore.clearUploadFailure()
        guard let operationStarted = attachments.staging.begin(
            .photo(DataImageSelection(data: data)))
        else {
            // The pipeline is mid-upload; the paste is not lost — the
            // user retries once the current attachment settles.
            attachments.draftStore.recordUploadFailure(
                "An attachment is already uploading. Try again once it finishes.")
            pendingImagePreviewData = nil
            isPasteImageAttachment = false
            return
        }
        _ = operationStarted
    }


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
    /// commands; plain text flows to `deliver`. The + menu (attachments
    /// wired) offers Add Image / Add File, the terminal Composer's
    /// attachment flow on the chat surface.
    @ViewBuilder
    private var inputFrame: some View {
        if inputPresented, let router {
            VStack(spacing: 0) {
                if router.hasActiveSuggestions {
                    ComposerSuggestionRow(
                        router: router, draft: draft,
                        applyDraft: { newDraft in
                            // Every token case lands the insertion at the
                            // applied draft's end (slash tokens are
                            // trailing, a tag replaces the whole draft, a
                            // mention's remainder is empty while the menu
                            // is open), so the accept's caret — end of the
                            // insertion, after its trailing space — is the
                            // new draft's end.
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
                if let attachments, let presentation = attachments.staging.presentation,
                    attachments.staging.state.isBusy
                {
                    // The upload's live progress, the staging store's
                    // own presentation ("Preparing Image…" /
                    // "Uploading Image… 42%") on the chat frame.
                    HStack(spacing: 6) {
                        ProgressView()
                            .controlSize(.mini)
                        Text(presentation.title)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 12)
                    .padding(.top, 6)
                }
                if let attachments, let uploadFailure = attachments.draftStore.uploadFailureMessage {
                    Text(uploadFailure)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 12)
                        .padding(.top, 6)
                }
                if let attachments, let pending = attachments.draftStore.pendingImage,
                    let imageSource = pendingImagePreview {
                    // The pasted image, held for Send: one thumbnail chip
                    // above the text field, removable with its x.
                    HStack(spacing: 8) {
                        ChatAttachmentThumbnail(imageSource: imageSource)
                            .overlay(alignment: .topTrailing) {
                                Button {
                                    removePendingImage()
                                } label: {
                                    Image(systemName: "xmark.circle.fill")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .background(Circle().fill(.bar))
                                }
                                .accessibilityLabel("Remove attachment")
                            }
                        Spacer(minLength: 0)
                    }
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
                    if let actions = attachmentActions {
                        Menu {
                            AgentActionMenuContent(
                                actions: actions,
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
                    ChatInputTextView(
                        text: draft,
                        placeholder: "Message — / # @ ! for commands",
                        onEdit: { newText, caret in
                            sinkEdit(newText, caret: caret)
                        },
                        onReturnKey: {
                            // Return with the menu open accepts the
                            // highlighted suggestion (no newline); with
                            // it closed the stock newline insert keeps
                            // working, matching the Composer.
                            let result = router.handleReturnKey(into: draft)
                            if let accepted = result.accepted {
                                pendingAccept = accepted
                            }
                            return result.consumedKey
                        },
                        onPaste: attachments != nil ? { handlePaste() } : nil,
                        pendingAccept: $pendingAccept,
                        isFocused: $inputFocused)
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
                // The + menu's Add Image picker: same shape the terminal
                // Composer's photo picker uses.
                guard let item else { return }
                selectedPhoto = nil
                isPasteImageAttachment = false
                attachments?.draftStore.clearUploadFailure()
                attachments?.staging.begin(.photo(PhotosPickerImageSelection(item: item)))
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
                isPasteImageAttachment = false
                attachments?.draftStore.clearUploadFailure()
                attachments?.staging.begin(.file(url))
            }
            .onChange(of: attachments?.staging.state) { _, newState in
                syncAttachmentUploadState(newState)
            }
        }
    }

    /// Send needs either draft text or a pending image attachment: a
    /// pasted image with no message text still sends (the path reference
    /// is the message).
    private var canSend: Bool {
        if attachments?.draftStore.pendingImage != nil { return true }
        return !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// The staging store's state machine, surfaced: progress inline in
    /// the frame, failures in the error row, and a completed paste-image
    /// upload held for the Send flow (its path removed from the draft —
    /// the thumbnail is the visible attachment).
    private func syncAttachmentUploadState(_ newState: ComposerStagingStore.State?) {
        guard let attachments else { return }
        switch newState {
        case .idle, .preparing, .uploading:
            attachments.draftStore.clearUploadFailure()
        case .failed(let failure), .backgroundInterrupted(let failure):
            attachments.draftStore.recordUploadFailure(failure.message)
        case .completed(let outcome):
            attachments.draftStore.clearUploadFailure()
            if outcome.medium == .image, isPasteImageAttachment {
                // Hold the image for Send: remove the path the staging
                // store inserted — the thumbnail chip shows the
                // attachment instead of a bare path in the text.
                removePathFromDraft(outcome.path)
                attachments.draftStore.holdPendingImage(path: outcome.path)
            }
        case nil:
            break
        }
    }


    /// Removes one remote path reference (and one trailing space) the
    /// staging store inserted, keeping the caret anchored at the end of
    /// the remaining text.
    private func removePathFromDraft(_ path: String) {
        let inserted = "\(path) "
        guard let range = draft.range(of: inserted) else { return }
        draft = draft.replacingCharacters(in: range, with: "")
        attachments?.draftStore.replaceDraft(with: draft)
    }

    private func sendDraft() {
        let text = draft
        guard canSend, !isSending, let router
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
                    // The delivered text carries a pending image's path
                    // reference ahead of the draft text — the same
                    // convention a bare path insert produces.
                    try await deliver?(
                        attachments?.draftStore.messageText(forDraft: text) ?? text)
                    clearDraftAfterSend()
                } catch {
                    // Delivery failed: keep the draft for retry.
                }
            }
        }
    }

    /// A successful send clears the draft and the pending image chip
    /// together: the message carried the path reference.
    private func clearDraftAfterSend() {
        draft = ""
        attachments?.draftStore.replaceDraft(with: "")
        attachments?.draftStore.clearPendingImage()
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
