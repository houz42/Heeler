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
    /// host:session · workspace · tab, shown in the nav bar's title slot
    /// beside the back button. Nil leaves the bar titleless.
    var breadcrumb: String? = nil
    /// The composer's submit router (Phase 2); enables the floating input
    /// button. Nil = read-only chat (previews, unwired hosts).
    var router: ComposerRouterStore? = nil
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
        breadcrumb: String? = nil,
        router: ComposerRouterStore? = nil,
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
        self.breadcrumb = breadcrumb
        self.router = router
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

    @Environment(\.openURL) private var openURL

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    topSentinel
                    ForEach(rows) { row in
                        LinkifiedChatRow(row: row, router: openRouter)
                            .padding(.horizontal, 12)
                    }
                }
                .padding(.vertical, 10)
            }
            .onChange(of: pagingInputs) { _, _ in
                firePagingIfNeeded()
            }
            .modifier(
                ChatOpenersSurface(
                    router: openRouter,
                    fetch: fetch ?? { _ in throw CocoaError(.fileNoSuchFile) }))
        }
        // The floating input affordance only exists when a router is wired.
        .overlay { if router != nil && deliver != nil { inputOverlay } }
        .safeAreaInset(edge: .bottom) { inputFrame }
        .navigationTitle(breadcrumb ?? "")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            // The whole header lives on the back button's row: state dot +
            // title at principal, level switcher + surface toggle trailing.
            // No second strip row — the chat owns the vertical space.
            ToolbarItem(placement: .principal) {
                HStack(spacing: 6) {
                    Circle()
                        .fill(stateColor)
                        .frame(width: 8, height: 8)
                        .accessibilityLabel(Text(state.rawValue))
                    VStack(alignment: .leading, spacing: 0) {
                        Text(agentName)
                            .font(.subheadline.weight(.semibold))
                            .lineLimit(1)
                        if let breadcrumb {
                            Text(breadcrumb)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                HStack(spacing: 4) {
                    DetailLevelSwitcher(level: level) { newLevel in
                        level = newLevel
                        changeLevel(newLevel, paneID)
                    }
                    if let stripAccessory {
                        stripAccessory
                    }
                }
            }
        }
    }

    private var stateColor: Color {
        switch state {
        case .idle: .secondary
        case .running: .green
        case .blocked: .orange
        case .offline: .red
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
    @FocusState private var inputFocused: Bool

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
                        applyDraft: { draft = $0 })
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
                    TextField("Message — / # @ ! for commands", text: $draft, axis: .vertical)
                        .textFieldStyle(.plain)
                        .focused($inputFocused)
                        .onChange(of: draft) { _, new in
                            router.updateSuggestions(forDraft: new)
                        }
                        .onSubmit { sendDraft() }
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
