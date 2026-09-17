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
    /// Host / workspace badge slot.
    let badge: String?
    let content: ChatContent
    let changeLevel: (DetailLevel, String) -> Void
    /// True while the window holds older pages the user has not loaded.
    var hasOlder: Bool = false
    /// True while an older-page fetch is in flight.
    var isLoadingOlder: Bool = false
    /// Pages older history when the user scrolls to the top. nil keeps
    /// the transcript static (previews, unavailable panes).
    var loadOlder: (() async -> Void)? = nil

    @State private var level: DetailLevel
    init(
        paneID: String,
        agentName: String,
        state: ChatAgentState,
        badge: String? = nil,
        content: ChatContent,
        initialLevel: DetailLevel,
        changeLevel: @escaping (DetailLevel, String) -> Void,
        hasOlder: Bool = false,
        isLoadingOlder: Bool = false,
        loadOlder: (@Sendable () async -> Void)? = nil
    ) {
        self.paneID = paneID
        self.agentName = agentName
        self.state = state
        self.badge = badge
        self.content = content
        self.changeLevel = changeLevel
        self.hasOlder = hasOlder
        self.isLoadingOlder = isLoadingOlder
        self.loadOlder = loadOlder
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
            ChatStatusStrip(
                agentName: agentName, state: state, badge: badge, level: level
            ) { newLevel in
                level = newLevel
                changeLevel(newLevel, paneID)
            }
            Divider()
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
}
