import SwiftUI

/// The default Agent detail surface. Ghostty renders the live Attach stream.
/// Composer owns authored delivery by default; Direct Input (ADR 0016) is an
/// explicit opt-in that types the Attach PTY with the system keyboard.
struct AgentDetailView: View {
    let agent: ConsoleAgent
    private let console: ConsoleStore
    private let terminal: TerminalSettings
    private let inputMode: AgentInputModeSettings
    private let hosts: [Host]
    /// The live Host catalog (ConsoleView wiring): the connection-time
    /// broker-path auto-configure and the first-connect flow write the
    /// Host record through it. Previews/tests may omit it.
    private let hostCatalog: HostStore?
    private let activity: AppActivityCoordinator
    private let keyboardHandoff: TerminalKeyboardHandoff
    private let keyboardInset: TerminalKeyboardInset
    private let isOnStage: () -> Bool
    private let isVisible: () -> Bool
    private let onSwitch: (ConsoleAgent.ID) -> Void
    private let onClosed: () -> Void
    @State private var focus = AgentFocusCoordinator()
    @State private var hasAppeared = false
    @Environment(\.scenePhase) private var scenePhase
    @State private var composer: AgentComposerStore
    @State private var attach: AgentAttachStore
    /// The chat input's submit router (/ # @ ! routing). Built with the
    /// same per-agent task as the chat store.
    /// The broker-backed chat store, one per (host, pane). Preferred
    /// over the JSONL store when the Host has a broker configured and
    /// the agent's session matches a live registration; the JSONL
    /// backend stays the fallback (and the only backend on Hosts
    /// without a broker).
    @State private var brokerChat: AgentChatStore?
    @State private var isShowingFirstConnectFlow = false
    /// The work inspector's requested tab (nil = not presented).
    /// Opened from the agent menu's Tasks/Subagents rows.
    @State private var showsWorkInspectorTab: WorkInspectorTab?
    /// The chat input's submit router (/ # @ ! routing). Built with the
    /// same per-agent task as the chat store.
    @State private var chatRouter: ComposerRouterStore?
    /// The chat input's attachment bundle (+ button/paste flow). Built
    /// beside the chat store; torn down with it.
    @State private var chatAttachments: ChatAttachments?
    /// Which surface the detail shows. Set on first appearance from the
    /// agent's session shape; the picker is the only other writer.
    @State private var surface: AgentDetailSurface?
    /// Retains the terminal's UIKit surface across chat↔terminal toggles.
    /// The terminal mounts only on the user's terminal-icon tap (chat stays
    /// the default surface on agent-open); once mounted, every later toggle
    /// returns the SAME laid-out surface — the grid, scrollback, and the
    /// pipeline's size reports are never lost (#device). Cleared when the
    /// DETAIL itself departs; the toggle never clears it. Ported from
    /// upstream's TerminalSurfaceRetention.
    @State private var terminalSurfaceRetention = TerminalSurfaceRetention()
    /// The chat pane's rendered rows' detail level persistence.
    @State private var chatLevels = ChatDetailLevelStore.shared
    /// The in-Agent header's layout mode + custom layout persistence.
    @State private var headerLayoutStore = HeaderLayoutSettingsStore.shared
    @State private var openTerminal: AgentOpenTerminalStore
    /// Presents the New conversation launch sheet (the Agent menu's
    /// agent.start entry): StartAgentView with this agent as the origin.
    @State private var isStartingConversation = false
    /// The most recent Interrupt-turn delivery failure, surfaced on the
    /// detail's existing alert surface.
    @State private var interruptionFailure: String?
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    /// root, where this detail always holds it.
    @Environment(\.agentSceneRouting) private var sceneRouting

    init(
        agent: ConsoleAgent,
        console: ConsoleStore,
        terminal: TerminalSettings,
        inputMode: AgentInputModeSettings,
        hosts: [Host],
        hostCatalog: HostStore? = nil,
        activity: AppActivityCoordinator,
        keyboardHandoff: TerminalKeyboardHandoff,
        keyboardInset: TerminalKeyboardInset,
        stage: AgentDetailStage,
        onSwitch: @escaping (ConsoleAgent.ID) -> Void,
        onClosed: @escaping () -> Void,
        composerStore: AgentComposerStore? = nil,
        attachStore: AgentAttachStore? = nil,
        openTerminalStore: AgentOpenTerminalStore? = nil
    ) {
        self.agent = agent
        self.console = console
        self.terminal = terminal
        self.inputMode = inputMode
        self.hosts = hosts
        self.hostCatalog = hostCatalog
        self.activity = activity
        self.keyboardHandoff = keyboardHandoff
        self.keyboardInset = keyboardInset
        let isOnStage = stage.isOnStage
        self.isOnStage = isOnStage
        self.isVisible = stage.isVisible
        self.onSwitch = onSwitch
        self.onClosed = onClosed
        let composer = composerStore ?? console.composerStore(for: agent)
        _composer = State(initialValue: composer)
        let attach = attachStore
            ?? AgentAttachStore(
                target: agent.agent.paneID,
                paneTitle: AgentTerminalView.displayTitle(for: agent),
                transportGeneration: console.hostConnectionGenerations[agent.hostID],
                isOnStage: isOnStage,
                runTerminal: console.terminalRunner(for: agent.hostID),
                stageImage: console.imageStager(for: agent.hostID),
                stageFile: console.fileStager(for: agent.hostID),
                composer: composer
            ) {
                try await console.closePane(agent.agent.paneID, on: agent.hostID)
            }
        _attach = State(initialValue: attach)
        let hostID = agent.hostID
        let workspaceID = agent.agent.workspaceID
        _openTerminal = State(
            initialValue: openTerminalStore
                ?? AgentOpenTerminalStore(
                    agent: agent,
                    transportGeneration: console.hostConnectionGenerations[agent.hostID],
                    isDetailOnStage: isOnStage,
                    createTerminal: { [console] request in
                        try await console.createShellTerminal(request, on: hostID)
                    },
                    runTerminal: console.terminalRunner(for: agent.hostID),
                    leaveAgent: { attach.leaveForTerminalHandoff() },
                    rejoinAgent: { attach.rejoin() },
                    recallTerminal: { [console] in
                        console.recallShellTerminal(
                            forWorkspaceID: workspaceID, on: hostID)
                    },
                    rememberTerminal: { [console] identity in
                        console.rememberShellTerminal(
                            identity, forWorkspaceID: workspaceID, on: hostID)
                    },
                    forgetTerminal: { [console] in
                        console.forgetShellTerminal(
                            forWorkspaceID: workspaceID, on: hostID)
                    },
                    verifyTerminal: { [console] identity in
                        try await console.shellTerminalStillExists(identity, on: hostID)
                    },
                    closeRemoteTerminal: { [console] identity in
                        try await console.closePane(identity.paneID, on: hostID)
                    }))
    }

    private var terminalAccess: HostTerminalAccess {
        sceneRouting?.terminalAccess(for: agent.hostID) ?? .holds
    }

    private func applyTerminalAccess() {
        guard openTerminal.shell == nil, !openTerminal.isOpening else { return }
        switch terminalAccess {
        case .holds:
            attach.rejoin()
        case .liveInAnotherWindow:
            attach.leaveForTerminalHandoff()
        }
    }

    private var focusViewingState: AgentFocusCoordinator.ViewingState {
        let current = console.agents.first { $0.id == agent.id }
        return .init(
            agentID: agent.id,
            terminalID: current?.agent.terminalID ?? agent.agent.terminalID,
            transportGeneration: console.hostConnectionGenerations[agent.hostID],
            status: current?.agent.status,
            isHostReady: console.hostStatuses[agent.hostID] == .connected
                && !console.hostsAwaitingSnapshot.contains(agent.hostID),
            isSceneActive: scenePhase == .active,
            isOnStage: hasAppeared && isOnStage(),
            showsShellTerminal: openTerminal.shell != nil || openTerminal.isOpening)
    }

    private func updateFocus() {
        let state = focusViewingState
        focus.update(state) { id in
            // A queued task can begin after selection or Shell ownership moved,
            // before SwiftUI has delivered the next onChange callback.
            guard focusViewingState == state else { throw CancellationError() }
            try await console.focusAgent(id.paneID, on: id.hostID)
        }
    }


    /// The Agent detail's two surfaces. Chat (the parsed transcript) is the
    /// default when the agent carries a `.path` agent session; the live
    /// Terminal (ADR 0013's Attach surface, still the fallback and always
    /// available) remains one tap away.
    private enum AgentDetailSurface: Hashable {
        case chat
        case terminal

        /// The surface a detail opens on: Chat when a transcript is
        /// readable, Terminal otherwise.
        static func initial(agent: ConsoleAgent) -> AgentDetailSurface {
            agent.agent.agentSession?.kind == AgentSessionRefKind.path
                ? .chat : .terminal
        }
    }

    /// The chat pane's rendered state, projecting the store's phase into
    /// ChatScreen's inputs.
    /// The nav-bar principal content: the user-configured agent-list layout
    /// (Settings → Agent list fields) rendered in place — row 0 as the title,
    /// row 1 as the subtitle. Separators keep their spacing; token styling
    /// (fg/bold/dim) is honored at text scale.
    private struct AgentDetailHeaderTokens: View {
        let rows: [[RenderedToken]]

        var body: some View {
            VStack(alignment: .leading, spacing: 0) {
                if let title = rows.first {
                    tokenLine(title, font: .subheadline.weight(.semibold))
                }
                if rows.count > 1 {
                    tokenLine(rows[1], font: .caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }

        private func tokenLine(_ tokens: [RenderedToken], font: Font) -> some View {
            tokens.reduce(Text("")) { partial, token in
                var text = Text(token.text)
                if token.bold == true { text = text.bold() }
                if token.dim == true { text = text.foregroundStyle(.secondary) }
                var view = text.font(token.isSeparator ? nil : font)
                if let hex = token.fg {
                    view = view.foregroundStyle(Color(
                        red: Double(hex.red) / 255,
                        green: Double(hex.green) / 255,
                        blue: Double(hex.blue) / 255))
                }
                return partial + view
            }
            .lineLimit(1)
        }
    }

    /// The header's token rows, following the in-Agent header setting
    /// (Settings → In-Agent Header): the Host's agent-list layout when it
    /// says "Same as agent list", the stored custom layout otherwise.
    private var headerTokens: some View {
        AgentDetailHeaderTokens(
            rows: AgentRowRenderer.render(
                layout: headerLayoutStore.headerLayout(
                    sameAsList: { [console] hostID in console.rowLayout(for: hostID) },
                    for: agent.hostID),
                agent: agent))
    }

    private var chatStateColor: Color {
        switch chatAgentState {
        case .idle: .secondary
        case .running: .green
        case .blocked: .orange
        case .offline: .red
        }
    }

    private var chatAgentState: ChatAgentState {
        switch console.agents.first(where: { $0.id == agent.id })?.agent.status {
        case .working: .running
        case .blocked: .blocked
        case .done, .idle, nil: .idle
        default: .idle
        }
    }

    /// The v3 live-work spark's producer-backed state: the producer's
    /// own working report (herdr's pane status), 1:1 — NO transport
    /// inference. `unknown` (or an unrecognized raw value) renders the
    /// static mark; a nil report (agent not in the snapshot) renders
    /// nothing.
    private var liveWorkState: ChatLiveWorkState? {
        switch console.agents.first(where: { $0.id == agent.id })?.agent.status {
        case .working: .working
        case .blocked: .blocked
        case .done: .completed
        case .idle: .idle
        case .unknown: .unknown
        case nil: nil
        default:
            // An unrecognized raw value: herdr's schema is closed but
            // has no stability guarantee — render the honest unknown.
            .unknown
        }
    }

    /// One icon, one tap: on the chat surface it switches to the terminal,
    /// on the terminal surface it switches back to chat. The icon names the
    /// destination, not the current surface.
    private var surfacePicker: some View {
        Button {
            surface = (surface == .chat) ? .terminal : .chat
        } label: {
            Image(
                systemName: surface == .chat
                    ? "terminal" : "bubble.left.and.bubble.right")
        }
        .labelStyle(.iconOnly)
        .hoverEffect(.highlight)
        .accessibilityLabel(surface == .chat ? "Show Terminal" : "Show Chat")
    }

    /// The v3 Agent header menu: the header's agent identity area opens
    /// the Agent menu (identity/context → Statistics → Actions →
    /// Companion terminal). Back and the surface selector stay separate
    /// controls; this owns the principal slot only. The menu also carries
    /// agent switching — the title's pre-v3 meaning — under its own
    /// "Switch to" section, so the header's one tap still reaches every
    /// other Agent without a detour back to the list.
    private var agentTitleMenu: some View {
        Menu {
            AgentHeaderMenuContent(
                model: headerMenuModel,
                agentDisplayName: agent.agent.displayName,
                interruptTurn: {
                    Task { await interruptTurn() }
                },
                startNewConversation: { isStartingConversation = true },
                companionTerminal: companionTerminalEntry)
            if console.agents.count > 1 {
                Section("Switch to") {
                    ForEach(console.agents) { candidate in
                        Button {
                            onSwitch(candidate.id)
                        } label: {
                            if candidate.id == agent.id {
                                Label(candidate.agent.displayName, systemImage: "checkmark")
                            } else {
                                Text(candidate.agent.displayName)
                            }
                        }
                        .disabled(candidate.id == agent.id)
                    }
                }
            }
            // The work inspector entry (design: "Tap the existing
            // chat header to open the Agent menu, then choose Tasks
            // or Subagents"): read-only rows, opening the inspector
            // on the matching tab.
            Section {
                Button {
                    showsWorkInspectorTab = .tasks
                } label: {
                    Label("Tasks", systemImage: "checklist")
                }
                Button {
                    showsWorkInspectorTab = .subagents
                } label: {
                    Label("Subagents", systemImage: "person.2")
                }
            }
        } label: {
            HStack(spacing: 4) {
                headerTokens
                Image(systemName: "chevron.down")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.tertiary)
                    .accessibilityHidden(true)
            }
        }
        // The plain button style keeps the compact header typography —
        // no menu-chrome background behind the agent's title.
        .buttonStyle(.plain)
        // Minimum 44pt target: the plain-style menu label must still be
        // a comfortably tappable identity area, not a hairline title.
        .frame(minHeight: 44)
        .accessibilityLabel("Agent menu, \(agent.agent.displayName)")
        .accessibilityAddTraits(.isButton)
        .accessibilityHint(
            "Opens the Agent menu: context, statistics, actions, and agent switching.")
    }

    /// The header menu's model, projected live from the console's row,
    /// the Host's ACTUAL snapshot freshness (connected is not proof of
    /// current data — a host still awaiting its first post-reconnect
    /// snapshot reads Last known), and the broker chat store's
    /// registration capabilities where a chat store exists.
    private var headerMenuModel: AgentHeaderMenuModel {
        AgentHeaderMenuModel(
            agent: agent,
            hostSnapshotFreshness: AgentHeaderMenuModel.SnapshotFreshness(
                hostIsConnected: console.hostStatuses[agent.hostID] == .connected,
                hostIsAwaitingSnapshot: console.hostsAwaitingSnapshot.contains(agent.hostID)),
            interruptSupport: headerMenuInterruptSupport)
    }

    /// Interrupt support from the broker registration's capability flag:
    /// the broker's own interrupt contract (AgentChatStore.interrupt,
    /// guarded by capabilities.interrupt) — never a generic Esc
    /// keystroke whose meaning per agent is unverified.
    private var headerMenuInterruptSupport: AgentHeaderMenuModel.InterruptSupport {
        guard let brokerChat, brokerChat.capabilities?.interrupt == true else {
            let hasStore = brokerChat != nil
            return .unsupported(
                reason: hasStore
                    ? "This agent's registration did not advertise interrupt support, "
                        + "so Meadow does not send a generic interrupt."
                    : "No chat registration for this agent — interrupt support is "
                        + "unverified, so Meadow does not send a generic interrupt.")
        }
        return .supported
    }

    /// Interrupt stops only the current turn through the broker's
    /// capability-gated interrupt contract — never guaranteed
    /// reversible, so the action is presented as interrupt, not stop.
    /// EXECUTION-TIME recheck (not just menu-construction time): the
    /// live agent row must still be the same runtime (pane identity),
    /// still connected, and still have a turn in flight; the broker
    /// store re-validates its own registration/generation against the
    /// session it targets.
    private func interruptTurn() async {
        // Re-resolve the LIVE row: the menu could have been constructed
        // before a status change, agent switch, or disconnect.
        guard let live = console.agents.first(where: { $0.id == agent.id }) else {
            interruptionFailure = "This agent is no longer in the Console list."
            return
        }
        guard console.hostStatuses[live.hostID] == .connected else {
            interruptionFailure = "The Host is not connected."
            return
        }
        let turnInFlight =
            live.agent.status == .working || live.agent.status == .blocked
        guard turnInFlight else {
            interruptionFailure = "No turn is in flight to interrupt."
            return
        }
        guard let brokerChat else {
            interruptionFailure =
                "No chat registration for this agent — interrupt is not verified."
            return
        }
        do {
            // The store re-validates registration + capabilities
            // (stale generation / missing capability throw honestly).
            try await brokerChat.interrupt()
        } catch let error as AgentChatError {
            if case .wire(_, let message, _) = error {
                interruptionFailure = message
            } else {
                interruptionFailure = "Interrupt failed."
            }
        } catch {
            interruptionFailure = error.localizedDescription
        }
    }

    /// The Companion terminal entry: availability mirrors the detail's
    /// open-terminal store, which already refuses a missing working
    /// directory and another window's terminal channel.
    private var companionTerminalEntry: AgentHeaderCompanionTerminal? {
        guard agent.shellTerminalCreationRequest != nil else {
            return AgentHeaderCompanionTerminal(
                canOpen: false,
                isOpening: false,
                unavailableReason:
                    "No reported working directory — herdr cannot open a shell here.",
                open: {})
        }
        guard terminalAccess == .holds else {
            return AgentHeaderCompanionTerminal(
                canOpen: false,
                isOpening: false,
                unavailableReason:
                    "Another window holds this Host's terminal channel.",
                open: {})
        }
        return AgentHeaderCompanionTerminal(
            canOpen: openTerminal.canOpen,
            isOpening: openTerminal.isOpening,
            unavailableReason: nil,
            open: { openTerminal.open() })
    }

    /// The graceful empty state for an agent whose chat surface has no
    /// readable transcript (no `.path` agent session): the surface stays
    /// reachable, telling the user why it is empty.
    private struct ChatUnavailablePlaceholder: View {
        var body: some View {
            ContentUnavailableView(
                "No Transcript",
                systemImage: "bubble.left.and.bubble.right",
                description: Text(
                    "This agent has no transcript file to read. Use the surface menu to open the live Terminal."))
        }
    }

    /// Builds and starts the chat store + input router when the agent's
    /// session is a readable transcript path. Idempotent: re-entry with a
    /// live store is a no-op. Called from the agent-identity task and from
    /// late arrival of the session path / a manual switch to the chat
    /// surface, so agents whose integration registers after first render
    //  still get a chat.
    private func buildChatIfPossible() async {
        guard agent.agent.agentSession?.kind == AgentSessionRefKind.path
        else { return }

        // Connection-time auto-configure: a Host with NO recorded broker
        // path gets the standard Meadow path resolved host-side,
        // hello-probed, and written — so the plugin-owned broker (the
        // consolidation runs it at the standard path) lights up chat
        // with zero manual edit. One probe per Host per session.
        if brokerChat == nil, console.host(for: agent.hostID)?.hasBrokerChat != true,
            let hostCatalog, !hostCatalog.hosts.isEmpty,
            let hostOnRecord = hostCatalog.hosts.first(where: { $0.id == agent.hostID }),
            !hostOnRecord.hasBrokerChat
        {
            let autoConfigure = MeadowBrokerPathAutoConfiguration(
                console: console, catalog: hostCatalog)
            await autoConfigure.autoConfigure(hostID: agent.hostID)
            if let updated = hostCatalog.hosts.first(where: { $0.id == agent.hostID }),
                updated.hasBrokerChat
            {
                console.setHosts(hostCatalog.hosts)
            }
        }

        // Broker backend: only when this Host configured a broker socket
        // path. One store per agent identity; started here so surface
        // entry only renders.
        if brokerChat == nil, console.host(for: agent.hostID)?.hasBrokerChat == true {
            let agentChatStore = AgentChatStore(
                pipeFactory: .console(console, hostID: agent.hostID),
                paneIdentity: { [agent] in
                    // Simulator-proof pin: when the proof environment
                    // names a sessionFile, it wins — explicit selection
                    // over the pane's own agent_session. Dead without
                    // the env var; never affects production matching.
                    if let pinned = ProcessInfo.processInfo.environment[
                        "HEELER_AGENT_CHAT_PROOF_SESSION_FILE"]
                    {
                        return HerdrPaneSessionIdentity(sessionFilePath: pinned)
                    }
                    guard let path = agent.agent.agentSession?.value else {
                        return nil
                    }
                    return HerdrPaneSessionIdentity(sessionFilePath: path)
                })
            brokerChat = agentChatStore
            await agentChatStore.start()
        }

        // JSONL transcript lane: DEPRECATED (user direction — superseded by
        // the broker API). Never built: its ChatStore.start does a blocking
        // whole-transcript SFTP read (readWhole) that hangs on long sessions.
        // The broker lane is the only chat path; hosts without a broker show
        // ChatUnavailablePlaceholder. The conversation slice's fix round
        // removes the lane's code entirely.
        // The chat input's attachment bundle: the staging pipeline the
        // + button's pickers and the image paste share, plus the draft
        // seam its path inserts land in. Idempotent per agent identity.
        if chatAttachments == nil {
            let draftStore = ChatAttachmentDraftStore()
            chatAttachments = ChatAttachments(
                staging: ComposerStagingStore(
                    stageImage: console.imageStager(for: agent.hostID),
                    stageFile: console.fileStager(for: agent.hostID),
                    composer: draftStore),
                draftStore: draftStore)
        }
        // The chat input's router: / # @ ! classification + plain delivery
        // through agent.prompt. The scratch-shell pane for ! is created
        // lazily on first use by the store.
        chatRouter = ComposerRouterStore(
            dependencies: ComposerRouterStore.makeChatDependencies(
                console: console, agent: agent,
                bashIO: ComposerBashIO(
                    createScratchPane: { hostID in
                        try await console.createShellTerminal(
                            ShellTerminalCreationRequest(
                                workspaceID: agent.agent.workspaceID,
                                cwd: agent.agent.cwd),
                            on: hostID).paneID
                    },
                    sendText: { hostID, paneID, text in
                        try await console.sendPaneInput(
                            paneID, text: text, on: hostID)
                    },
                    readPaneText: { hostID, paneID in
                        try await console.readPaneOutput(
                            paneID, lines: 200, on: hostID).text
                    }),
                commandFileIO: AgentCommandFileIO.console(
                    console, hostID: agent.hostID),
                // v3 structured command delivery (review r2): a
                // + menu/chooser agent-command selection invokes
                // STRUCTURALLY over the broker's command.invoke,
                // never slash text through prompt.send. The seam
                // resolves the catalog entry's NAME to the broker
                // command id (the catalog is name-keyed today;
                // commands.list ids travel unchanged once it feeds
                // the catalog). A missing store or a registration
                // without the commands capability surfaces as the
                // router's honest rejection in the chooser.
                deliverCommand: { _, name, arguments in
                    guard let store = await MainActor.run(
                        body: { brokerChat })
                    else {
                        throw AgentChatError.wire(
                            code: "unsupported_capability",
                            message: "This agent cannot run commands.",
                            retryable: false)
                    }
                    _ = try await store.sendCommand(
                        commandId: name, arguments: arguments)
                }))
        // No JSONL ChatStore.start: the lane is deprecated (see above).
    }

    /// Builds (once per agent identity) and starts the chat store, then
    /// renders the chat surface.
    @ViewBuilder
    private var chatSurface: some View {
        if let brokerChat {
            brokerChatSurface(brokerChat)
        } else {
            ChatUnavailablePlaceholder()
        }
    }

    /// The broker-backed chat surface: honest state surfaces for every
    /// non-ready phase, and the SAME row/bubble rendering (ChatScreen
    /// reused, not forked) when content is live.
    @ViewBuilder
    private func brokerChatSurface(_ store: AgentChatStore) -> some View {
        switch store.phase {
        case .ready, .disconnected:
            ChatScreen(
                paneID: agent.agent.paneID,
                hostID: agent.hostID,
                agentName: agent.tabLabel ?? agent.agent.displayName,
                state: brokerAgentState,
                content: brokerContent,
                initialLevel: chatLevels.level(paneID: agent.agent.paneID),
                changeLevel: { [chatLevels] level, paneID in
                    chatLevels.setLevel(level, paneID: paneID)
                },
                hasOlder: store.hasOlder,
                isLoadingOlder: store.isLoadingOlder,
                loadOlder: { [weak store] in await store?.loadOlder() },
                router: chatRouter,
                deliver: { text in
                    // v3 submitted-draft stack: submit durably enqueues
                    // (the composer clears on LOCAL enqueue) — the wire
                    // outcome lands on the outbox entry as an honest
                    // status, never thrown at the composer. Only a
                    // failed LOCAL enqueue throws (the draft stays).
                    try await store.submit(text)
                },
                deliverStructured: { text, images in
                    // The attachment-bearing submission: text AND real
                    // image content ride one durable outbox entry.
                    try await store.submit(text, images: images)
                },
                pendingUnsupported: !store.askSupported,
                pendingMessages: store.outbox.map(ChatPendingEntry.init),
                onPendingRetry: { entryID in
                    Task { @MainActor in await store.retry(entryID: entryID) }
                },
                onPendingResend: { entryID in
                    Task {
                        @MainActor in await store
                            .resendAcknowledgingPossibleDuplicate(entryID: entryID)
                    }
                },
                onPendingHide: { entryID in
                    store.hideOutboxEntry(entryID: entryID)
                },
                onPendingShowHidden: {
                    store.showHiddenOutboxEntries()
                },
                onPendingEdit: { entry in
                    // The entry's text returns to the composer via
                    // ChatScreen's own draft edit; nothing store-side
                    // to mutate (the rejected entry stays for its own
                    // retry/copy/hide decision).
                    _ = entry
                },
                authorLabel: "Meadow · \(agent.agent.kind.lowercased())",
                attachments: chatAttachments,
                onAskAnswer: { interaction, payloads in
                    guard let store = brokerChat,
                          let matched = store.interactions.first(where: {
                              $0.requestId == interaction.id })
                    else {
                        // The card is stale (resolved elsewhere): the
                        // store's self-heal already dropped it and the
                        // resolved block renders in the transcript.
                        throw AgentChatError.wire(
                            code: "item_changed",
                            message: "This question is no longer pending — it may have been answered or cancelled elsewhere.",
                            retryable: false)
                    }
                    do {
                        try await store.answer(
                            matched,
                            answers: payloads.map { payload in
                                AgentChatAnswer(
                                    questionId: payload.questionId,
                                    optionIds: payload.optionIds,
                                    customText: payload.customText,
                                    note: payload.note)
                            })
                    } catch let error as AgentChatError {
                        // The broker's real stale codes (ask.ts
                        // claimEntry): the ask settled, expired with
                        // its generation, or never existed.
                        if case .wire(let code, _, _) = error,
                            code == "item_changed"
                                || code == "item_not_found"
                                || code == "stale_generation"
                        {
                            throw AgentChatError.wire(
                                code: code,
                                message: "This question is no longer pending — it may have been answered or cancelled elsewhere.",
                                retryable: false)
                        }
                        throw error
                    }
                },
                onAskCancel: { interaction in
                    guard let store = brokerChat else {
                        throw AgentChatError.wire(
                            code: "item_changed",
                            message: "This ask is no longer pending.",
                            retryable: false)
                    }
                    try await store.cancelInteraction(requestId: interaction.id)
                },
                imageFetcher: { ref in
                    guard let store = brokerChat else {
                        throw CocoaError(.fileNoSuchFile)
                    }
                    return try await store.readBlob(blobId: ref)
                },
                fetch: { path in
                    try await console.readRemoteFile(
                        at: path, on: agent.hostID)
                },
                // The v3 live-work spark: driven by the producer's
                // OWN working report (pane.agent_status_changed
                // applied to ConsoleAgent.status), never by the
                // transport phase — connection alone never implies
                // thinking. Nil (no fresh report) renders nothing.
                liveWork: liveWorkState)
                // The honest resolved-ask note (answered elsewhere /
                // cancelled / expired) now renders IN the transcript
                // flow as a quiet block (brokerContent.resolvedAsks),
                // not as a floating note above the composer.
                .overlay(alignment: .bottom) {
                    if case .disconnected(let reason) = store.phase {
                        AgentChatStateBanner(
                            icon: "wifi.exclamationmark",
                            title: "Reconnect to the chat broker",
                            detail: reason)
                    }
                }
        case .idle, .connecting, .loading:
            AgentChatStateBanner(
                icon: "hourglass", title: "Connecting to the chat broker…",
                detail: nil)
        case .unavailable(let reason):
            VStack(spacing: 12) {
                AgentChatStateBanner(
                    icon: "person.crop.circle.badge.xmark",
                    title: "No chat broker for this agent", detail: reason)
                // First-connect auto-provisioning: the "no broker"
                // surface offers the one-tap bring-up. The flow's own
                // confirmations gate every mutation.
                Button {
                    isShowingFirstConnectFlow = true
                } label: {
                    Label("Set up chat broker on this Host…", systemImage: "wand.and.stars")
                }
                .buttonStyle(.borderedProminent)
            }
        case .ambiguous:
            AgentChatStateBanner(
                icon: "arrow.triangle.branch",
                title: "Ambiguous agent mapping",
                detail: "More than one agent claims this session; Meadow will not guess.")
        case .failed(let reason):
            AgentChatStateBanner(
                icon: "exclamationmark.triangle",
                title: "The chat broker connection failed", detail: reason)
        }
    }

    /// The agent-chat store's content projection: the committed page's
    /// messages, then provisional stream tails (review gap 4 — the
    /// agent's streaming reply must render BELOW the user message it
    /// answers, never above), then the pending surface. The v3
    /// submitted-draft stack moved just-sent messages OUT of this
    /// projection: they render in the separate ChatPendingRegionView
    /// (between history and the composer), keyed by the outbox — one
    /// canonical display record per requestKey/recordId (no double
    /// bubble: the entry drops when its record lands in the page).
    private var brokerContent: ChatContent {
        var content = brokerChat?.content ?? ChatContent()
        // Provisional stream tails: the reply follows the user's
        // message (the pending region above or the committed record).
        // Deterministic per-stream ids (a fresh UUID per delta would
        // churn the bubble's identity every chunk and flicker the
        // whole row, item 20).
        for tail in brokerChat?.streamTails ?? [] where !tail.text.isEmpty {
            content.messages.append(
                ChatMessage(
                    id: AgentChatMapper.stableID(for: "stream:\(tail.streamId)"),
                    role: .assistant, blocks: [.text(tail.text)]))
        }
        // Real pending asks from the broker interactions map into the
        // chat content's pending surface (the redesigned question card).
        content.pending = brokerChat?.interactions.map { interaction in
            PendingInteraction(
                id: interaction.requestId,
                question: interaction.questions.first?.text ?? "",
                options: interaction.questions.first?.options.map { $0.label } ?? [],
                questions: interaction.questions.map { question in
                    PendingAskQuestion(
                        id: question.id, text: question.text,
                        multi: question.multi,
                        options: question.options.map { option in
                            PendingAskQuestion.Option(
                                id: option.id, label: option.label)
                        },
                        allowCustom: question.allowCustom)
                })
        } ?? []
        // Resolved asks render as Q/A cards in the transcript flow —
        // one card per interaction, one Q/A pair per question (the
        // v3 paired-card design). The projection is the single
        // `ResolvedAsk(resolution:)` factory: structured records for
        // this device's accepted answers, the honest outcome card for
        // terminal/remote/cancelled/expired/settled — identical
        // styling for all accepted answers; provenance is internal.
        // They persist across reconnects and reopen (the store keeps
        // them for the agent's chat life). PLACEMENT: each card
        // anchors to its question's own text — right after the
        // message that posed the question, BEFORE the agent's reply
        // that follows it; unanchored records park after the
        // transcript's rows, before any pending card.
        content.resolvedAsks = brokerChat?.interactionResolutions.map {
            ResolvedAsk(resolution: $0)
        } ?? []
        return content
    }

    /// The status-strip state for the agent-chat surface: Running while
    /// a stream is in flight, else the console's status.
    private var brokerAgentState: ChatAgentState {
        if !(brokerChat?.streamTails ?? []).isEmpty { return .running }
        return chatAgentState
    }

    var body: some View {
        Group {
            if let shell = openTerminal.shell {
                ShellTerminalView(
                    store: shell,
                    agentID: agent.id,
                    terminal: terminal,
                    activity: activity,
                    isReturning: openTerminal.isReturning,
                    isClosingTerminal: openTerminal.isClosingTerminal,
                    onCloseTerminal: { openTerminal.closeTerminal() }
                ) {
                    await openTerminal.returnToAgent()
                }
                .id(openTerminal.destination)
            } else if surface != .terminal {
                // Everything that is not EXPLICITLY the terminal renders the
                // chat surface — including the UNRESOLVED surface (nil) the
                // first body evaluation carries before its onChange sets the
                // initial value. The previous `surface == .chat` sent nil to
                // the terminal branch, which MOUNTED the terminal surface on
                // agent-open and eagerly attached (the fallback's grace
                // opened a PTY 1.5s later even after the surface flipped to
                // chat — the desktop's shared panel visibly resized). The
                // terminal mounts ONLY on the user's explicit icon tap.
                chatSurface
            } else {
                AgentTerminalView(
                    agent: agent,
                    console: console,
                    terminal: terminal,
                    inputMode: inputMode,
                    hosts: hosts,
                    activity: activity,
                    keyboardHandoff: keyboardHandoff,
                    keyboardInset: keyboardInset,
                    isOnStage: {
                        isOnStage() && openTerminal.shell == nil
                    },
                    // A detail that lost its Host channel to another window
                    // is still on screen, and its sheets still cover commands.
                    isCommandOnStage: {
                        isVisible() && openTerminal.shell == nil
                    },
                    onSwitch: onSwitch,
                    onClosed: onClosed,
                    canOpenTerminal: openTerminal.canOpen && terminalAccess == .holds,
                    isOpeningTerminal: openTerminal.isOpening,
                    openTerminal: { openTerminal.open() },
                    composer: composer,
                    attachStore: attach,
                    retention: terminalSurfaceRetention)
                .id(openTerminal.destination)
            }
        }
        .toolbar {
            // One header for both surfaces: state dot + title at principal,
            // the chat/terminal toggle trailing. The chat surface adds its
            // level switcher on top of this.
            ToolbarItem(placement: .principal) {
                HStack(spacing: 6) {
                    Circle()
                        .fill(chatStateColor)
                        .frame(width: 8, height: 8)
                        .accessibilityLabel(Text(chatAgentState.rawValue))
                    // The terminal surface keeps the nav bar transparent by
                    // design, so its header rides in a blur capsule instead
                    // of floating bare text over terminal output.
                    agentTitleMenu
                        .padding(.horizontal, surface == .terminal ? 10 : 0)
                        .padding(.vertical, surface == .terminal ? 5 : 0)
                        .background {
                            if surface == .terminal {
                                Capsule().fill(.ultraThinMaterial)
                            }
                        }
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                surfacePicker
            }
        }
        // The initial surface follows the agent's session shape; Chat is the
        // default whenever a transcript is readable, and a switch that lands
        // on an agent without one falls back to the Terminal without the
        // user picking anything.
        .onChange(of: AgentDetailSurface.initial(agent: agent), initial: true) {
            _, initial in
            if surface == nil { surface = initial }
        }
        .task(id: agent.id) {
            await buildChatIfPossible()
        }
        // A session path that arrives after first render (agents started
        // before the integration registered) must still build the store;
        // so must a manual switch to the chat surface.
        .onChange(of: agent.agent.agentSession?.value) { _, _ in
            Task { await buildChatIfPossible() }
        }
        .onChange(of: surface) { _, new in
            if new == .chat { Task { await buildChatIfPossible() } }
        }

        .onAppear {
            hasAppeared = true
            updateFocus()
        }
        .onChange(of: focusViewingState) {
            updateFocus()
        }
        .onDisappear {
            hasAppeared = false
            focus.leave()
            // The chat store's poll loop must not outlive the detail view.
            chatRouter = nil
            chatAttachments = nil
            // The retained UIKit surface belongs to THIS detail; a real
            // departure releases it (the chat↔terminal toggle never does).
            terminalSurfaceRetention.clear()
            // The DETAIL's real departure is the one teardown boundary that
            // works regardless of which surface is showing. The terminal
            // surface's own onDisappear preserves the pipeline across the
            // chat↔terminal toggle, and while CHAT is displayed the terminal
            // child is already unmounted — its deferred departure check can
            // never fire for this leave. Without a stop here, a two-step
            // departure (Terminal → Chat → Back) leaves the preserved attach
            // holding the Host's one terminal channel after the detail is
            // gone. The non-preserving teardown stops the pipeline and
            // releases the channel; ordinary toggles are unaffected (they
            // never fire the DETAIL's onDisappear).
            attach.leaveForTerminalHandoff()
        }
        .onChange(of: console.hostConnectionGenerations[agent.hostID]) { _, generation in
            openTerminal.transportGenerationDidChange(generation)
        }
        // The same-Host handoff between windows rides the Attach store's own
        // leave and rejoin, the path the Shell Terminal handoff already
        // uses: the window that loses the channel releases its Attach, and
        // the one that gains it rejoins behind that release through the
        // Host's terminal serialization. A Shell Terminal in this window
        // keeps the channel, so neither applies while one is open.
        .onChange(of: terminalAccess, initial: true) {
            applyTerminalAccess()
        }
        .onChange(of: openTerminal.shell != nil || openTerminal.isOpening, initial: true) {
            _, showsShellTerminal in
            sceneRouting?.shellTerminalDidChange(agent: showsShellTerminal ? agent.id : nil)
            // Access that changed while a Shell Terminal was opening applies
            // once the detail is back on the Agent.
            applyTerminalAccess()
        }
        .alert(
            "Couldn't Open Terminal",
            isPresented: Binding(
                get: { openTerminal.failure != nil },
                set: { if !$0 { openTerminal.dismissFailure() } })
        ) {
            Button("OK", role: .cancel) { openTerminal.dismissFailure() }
        } message: {
            Text(openTerminal.failure?.message ?? "")
        }
        .alert(
            "Couldn't Close Terminal",
            isPresented: Binding(
                get: { openTerminal.closeFailureMessage != nil },
                set: { if !$0 { openTerminal.dismissCloseFailure() } })
        ) {
            Button("OK", role: .cancel) { openTerminal.dismissCloseFailure() }
        } message: {
            Text(openTerminal.closeFailureMessage ?? "")
        }
        .sheet(isPresented: $isShowingFirstConnectFlow) {
            if let host = hosts.first(where: { $0.id == agent.hostID }) {
                MeadowFirstConnectFlowView(
                    host: host,
                    catalog: nil,
                    onProvisioned: {
                        // The Host record changed on disk; rebuild the
                        // chat store so the broker lane connects at the
                        // new path without a reopen.
                        brokerChat = nil
                        Task { await buildChatIfPossible() }
                    })
            }
        }
        // The Agent menu's New conversation entry: the same StartAgentView
        // sheet the Composer's New Agent uses, with this agent as the
        // launch origin (its Host, workspace, and working directory), so
        // the new conversation lands beside this one in the same place.
        .sheet(isPresented: $isStartingConversation) {
            StartAgentView(
                hosts: hosts,
                console: console,
                origin: StartAgentStore.LaunchOrigin(
                    hostID: agent.hostID,
                    workspaceID: agent.agent.workspaceID,
                    cwd: agent.agent.cwd),
                onStarted: { id in
                    isStartingConversation = false
                    onSwitch(id)
                })
            .modifier(ConsoleSheetPresentationModifier(
                presentation: ConsoleSheetPresentation(
                    horizontalSizeClass: horizontalSizeClass)))
        }
        .alert(
            "Couldn't Interrupt Turn",
            isPresented: Binding(
                get: { interruptionFailure != nil },
                set: { if !$0 { interruptionFailure = nil } })
        ) {
            Button("OK", role: .cancel) { interruptionFailure = nil }
        } message: {
            Text(interruptionFailure ?? "")
        }
        // The work inspector (Tasks/Subagents rows in the agent
        // menu): read-only. The snapshot derives from the SAME
        // ChatContent the chat surface renders, LINKED with the
        // live broker registrations the store observed — so child
        // runs registered right now show Running, and live children
        // no spawn row carries get their own rows. Re-derives on
        // every open (a fresh snapshot of what is provable NOW).
        .sheet(item: $showsWorkInspectorTab) { tab in
            WorkInspectorSheet(
                content: brokerChat?.content ?? ChatContent(),
                parentSessionFile: agent.agent.agentSession?.value ?? "",
                liveRegistrations: brokerChat?.liveRegistrations ?? [],
                initialTab: tab)
        }
        .modifier(ConsoleDetailPresentationRegistration(
            agentID: agent.id,
            isPresenting: openTerminal.failure != nil
                || openTerminal.closeFailureMessage != nil
                || interruptionFailure != nil))
    }
}
