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
    /// The chat surface's live-data store, one per (host, pane). Created
    /// alongside attach: both surfaces stay mounted-capable across switches.
    @State private var chat: ChatStore?
    /// Which surface the detail shows. Set on first appearance from the
    /// agent's session shape; the picker is the only other writer.
    @State private var surface: AgentDetailSurface?
    /// The chat pane's rendered rows' detail level persistence.
    @State private var chatLevels = ChatDetailLevelStore.shared
    @State private var openTerminal: AgentOpenTerminalStore
    /// Which window holds this Host's terminal channel; nil outside a scene
    /// root, where this detail always holds it.
    @Environment(\.agentSceneRouting) private var sceneRouting

    init(
        agent: ConsoleAgent,
        console: ConsoleStore,
        terminal: TerminalSettings,
        inputMode: AgentInputModeSettings,
        hosts: [Host],
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
    private var chatAgentState: ChatAgentState {
        switch console.agents.first(where: { $0.id == agent.id })?.agent.status {
        case .working: .running
        case .blocked: .blocked
        case .done, .idle, nil: .idle
        default: .idle
        }
    }

    /// The minimal surface switcher: one compact menu, Chat above Terminal,
    /// matching the Presentation menu pattern the Console list already uses.
    private var surfacePicker: some View {
        Menu {
            Picker("Surface", selection: Binding(
                get: { surface ?? .terminal },
                set: { surface = $0 })) {
                Text("Chat").tag(AgentDetailSurface.chat)
                Text("Terminal").tag(AgentDetailSurface.terminal)
            }
        } label: {
            Label(
                "Surface",
                systemImage: surface == .chat
                    ? "bubble.left.and.bubble.right" : "terminal")
        }
        .hoverEffect(.highlight)
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

    /// Builds (once per agent identity) and starts the chat store, then
    /// renders the chat surface.
    @ViewBuilder
    private var chatSurface: some View {
        if let chat {
            ChatScreen(
                paneID: agent.agent.paneID,
                agentName: agent.agent.displayName,
                state: chatAgentState,
                badge: agent.workspaceContext,
                content: chat.content,
                initialLevel: chatLevels.level(paneID: agent.agent.paneID),
                changeLevel: { [chatLevels] level, paneID in
                    chatLevels.setLevel(level, paneID: paneID)
                })
        } else {
            ChatUnavailablePlaceholder()
        }
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
            } else if surface == .chat {
                chatSurface
                    // The surface picker rides the chat's status strip level;
                    // the terminal keeps its own toolbar, so only Chat shows
                    // the switcher. Kept in one place both surfaces share.
                    .overlay(alignment: .topTrailing) {
                        surfacePicker
                            .padding(.top, 8)
                            .padding(.trailing, 12)
                    }
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
                    attachStore: attach)
                .id(openTerminal.destination)
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
            // The chat store follows the selected agent identity: a switch
            // rebuilds it (and drops the previous transcript window), the
            // same way attach is replaced on a switch.
            if AgentDetailSurface.initial(agent: agent) == .chat {
                let store = ChatStore(
                    hostID: agent.hostID,
                    paneID: agent.agent.paneID,
                    reader: .console(console, hostID: agent.hostID))
                chat = store
                await store.start(
                    agentSession: agent.agent.agentSession,
                    statusUpdates: console.agentStatusUpdates(for: agent.id))
            } else {
                chat = nil
            }
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
        .modifier(ConsoleDetailPresentationRegistration(
            agentID: agent.id,
            isPresenting: openTerminal.failure != nil || openTerminal.closeFailureMessage != nil))
    }
}
