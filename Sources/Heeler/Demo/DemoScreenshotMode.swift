#if DEBUG && targetEnvironment(simulator)
    import Foundation
    import SwiftUI
    import UserNotifications

    /// The only entry point for deterministic product screenshots. The
    /// entire implementation is excluded from device and Release builds.
    enum DemoScreenshotMode {
        static let launchArgument = "--demo-screenshots"

        /// Opens the Settings sheet on launch so a headless run can capture
        /// it without touch injection. Requires `launchArgument` too.
        static let settingsLaunchArgument = "--demo-screenshots-settings"

        static var isEnabled: Bool {
            isEnabled(arguments: ProcessInfo.processInfo.arguments)
        }

        static func isEnabled(arguments: [String]) -> Bool {
            arguments.contains(launchArgument)
        }

        static var presentsSettings: Bool {
            ProcessInfo.processInfo.arguments.contains(settingsLaunchArgument)
        }
        /// Which multi-path screenshot surface the demo run should show.
        enum Route: String {
            /// The ordinary Console (no route argument).
            case none
            /// The Add/Edit Host form with its additional-address rows.
            case hostForm
            /// The Hosts list page: host cards with named routes (the
            /// card-tap and route-inspector demo route).
            case hostList
            /// The Hosts list page wired to the REAL demo Console: live
            /// connection statuses, the shared active-route store, and a
            /// route tap that persists + reconnects — the unified
            /// state-sync and route-switch-lifecycle proof surface.
            case hostListConsole
            /// The Host detail page with its candidate list mid-probe.
            case hostDetailProbing
            /// The Host detail page stopped on the pick between two
            /// reachable addresses.
            case hostDetailPick
            /// The chat surface with a pending multi-select ask — the
            /// accent-bearing pending-card capture surface (Confirm
            /// button + selected-option chip). v2 accent proofs.
            case chatPendingAsk
            /// The chat surface with the v3 Q/A cards: an unanswered
            /// TWO-question ask (multi-select + single-choice-with-
            /// custom), answered cards covering every answer shape
            /// (labels, free text, selection+note, long collapsed
            /// text, cancelled/expired outcomes) — the paired-card
            /// capture surface (v3 Q/A proofs).
            case chatQACards
            /// The chat surface with special sections in the transcript
            /// (a `<system-notice>` and an `<irc>` block) — the
            /// v2 special-sections capture surface. The initial detail
            /// level rides `--demo-detail-level=<n>`.
            case chatSpecialSections
            /// The chat surface with own-message bubbles of every v3
            /// sizing case (one-word, emoji, multiline, long-prose
            /// wrap, fenced code) — the content-sized bubble capture
            /// surface (v3 width proofs).
            case chatBubbles
            /// The chat surface with markdown tables that stress the
            /// phone-width contract (long multi-column cells, code
            /// spans, links) — the wrapped-cell table capture
            /// surface (v3 table proofs).
            case chatTables

            static func fromArguments() -> Route {
                let arguments = ProcessInfo.processInfo.arguments
                if arguments.contains(chatQACardsLaunchArgument) { return .chatQACards }
                if arguments.contains(chatBubblesLaunchArgument) { return .chatBubbles }
                if arguments.contains(chatTablesLaunchArgument) { return .chatTables }
                if arguments.contains(chatSpecialSectionsLaunchArgument) { return .chatSpecialSections }
                if arguments.contains(hostListConsoleLaunchArgument) { return .hostListConsole }
                if arguments.contains(chatPendingAskLaunchArgument) { return .chatPendingAsk }
                if arguments.contains(hostListLaunchArgument) { return .hostList }
                if arguments.contains(hostDetailProbingLaunchArgument) { return .hostDetailProbing }
                if arguments.contains(hostDetailPickLaunchArgument) { return .hostDetailPick }
                if arguments.contains(hostFormLaunchArgument) { return .hostForm }
                return .none
            }
        }

        static let hostFormLaunchArgument = "--demo-host-form"
        static let hostListLaunchArgument = "--demo-host-list"
        static let hostListConsoleLaunchArgument = "--demo-host-list-console"
        static let hostDetailProbingLaunchArgument = "--demo-host-detail-probing"
        static let chatPendingAskLaunchArgument = "--demo-chat-pending-ask"
        static let chatSpecialSectionsLaunchArgument = "--demo-chat-special-sections"
        static let hostDetailPickLaunchArgument = "--demo-host-detail-pick"
        static let chatQACardsLaunchArgument = "--demo-chat-qa-cards"
        static let chatBubblesLaunchArgument = "--demo-chat-bubbles"
        static let chatTablesLaunchArgument = "--demo-chat-tables"

        /// The multi-path demo Host: the same machine over LAN and VPN.
        static let multipathHost = Host(
            name: "Studio Mac",
            address: "192.168.31.71",
            username: "developer",
            additionalAddresses: ["CMF79KM7YF.local", "studio.vpn.example"],
            routeLabels: [
                "192.168.31.71": "Local network",
                "CMF79KM7YF.local": "Bonjour",
                "studio.vpn.example": "VPN",
            ])
    }

    /// A safe composition root for screenshot runs. It reuses the production
    /// Console, EventsSession, Transport, and terminal surfaces while keeping
    /// Hosts, secrets, settings, notifications, and SSH fully process-local.
    @MainActor
    struct DemoScreenshotRootView: View {
        @State private var hosts: HostStore
        @State private var console: ConsoleStore
        @State private var terminalThemes: TerminalThemeSettings
        @State private var terminalZoom: TerminalZoomSettings
        @State private var terminalFonts: TerminalFontSettings
        @State private var snippets: SnippetStore
        @State private var appearance: AppAppearanceSettings
        @State private var inputMode: AgentInputModeSettings
        @State private var pushRegistration: PushRegistrationStore
        /// The demo's active-route store: the same observable instance
        /// the list and (navigated) detail share, so marks cannot
        /// disagree in captures. Standard defaults — persistence across
        /// relaunch is part of what the proofs show.
        @State private var activeRoutes = HostActiveRouteStore()
        @State private var notificationPreferences: NotificationPreferencesStore
        @State private var relaySettings: NotificationRelaySettings
        @State private var notificationRouter: AgentNotificationRouter
        @State private var bannerStore: AgentNotificationBannerStore
        @State private var liveActivities: HostLiveActivityCoordinator
        @State private var activity: AppActivityCoordinator

        private let route = DemoScreenshotMode.Route.fromArguments()

        init() {
            let composition = DemoScreenshotComposition.make()
            _hosts = State(initialValue: composition.hosts)
            _console = State(initialValue: composition.console)
            _terminalThemes = State(initialValue: composition.terminalThemes)
            _terminalZoom = State(initialValue: composition.terminalZoom)
            _terminalFonts = State(initialValue: composition.terminalFonts)
            _snippets = State(initialValue: composition.snippets)
            _appearance = State(initialValue: composition.appearance)
            _inputMode = State(initialValue: composition.inputMode)
            _pushRegistration = State(initialValue: composition.pushRegistration)
            _notificationPreferences = State(initialValue: composition.notificationPreferences)
            _relaySettings = State(initialValue: composition.relaySettings)
            _notificationRouter = State(initialValue: composition.notificationRouter)
            _bannerStore = State(initialValue: composition.bannerStore)
            _liveActivities = State(initialValue: composition.liveActivities)
            _activity = State(initialValue: composition.activity)
        }

        private var terminal: TerminalSettings {
            TerminalSettings(
                themes: terminalThemes, zoom: terminalZoom, fonts: terminalFonts,
                snippets: snippets)
        }

        var body: some View {
            switch route {
            case .none:
                consoleRoot
            case .hostForm:
                // The edit form against the multipath Host, so the rows are
                // populated.
                NavigationStack {
                    HostFormView(
                        store: hosts,
                        editing: DemoScreenshotMode.multipathHost)
                }
            case .hostList:
                // The Hosts list as the card redesign renders it: the
                // Studio Mac card is dialed through its primary route (in
                // use), its Local-network route is an honest unknown
                // alternate, and the Build Server card is not connected.
                NavigationStack {
                    HostListView(
                        store: hosts,
                        connectedAddresses: [
                            DemoScreenshotFixture.studioHostID:
                                "studio.demo.invalid",
                        ])
                }
            case .hostListConsole:
                hostListConsoleSurface
            case .hostDetailProbing:
                multipathDetail(midProbe: true)
            case .chatBubbles:
                chatBubblesSurface
            case .chatTables:
                chatTablesSurface
            case .hostDetailPick:
                multipathDetail(midProbe: false)
            case .chatPendingAsk:
                chatPendingAskSurface
            case .chatQACards:
                chatQACardsSurface
            case .chatSpecialSections:
                chatSpecialSectionsSurface
            }
        }

        /// The Hosts list wired to the REAL demo Console (the unified
        /// route-state proof surface): live statuses/failures/latencies
        /// from `console`, the shared observable active-route store, and
        /// a route tap that persists through the store then reconnects
        /// through the Console — so the list's marks, the connecting
        /// animation, and the failed dot are all the production
        /// lifecycle. Studio Mac + Build Server connect (profiles);
        /// Offline Server and Field Laptop fail (no profile), giving a
        /// deterministic tap → connecting → failed dot lifecycle.
        private var hostListConsoleSurface: some View {
            NavigationStack {
                HostListView(
                    store: hosts,
                    connectionStatuses: console.hostStatuses,
                    standingFailures: console.hostStandingFailures,
                    latencies: console.hostLatencies,
                    connectedAddresses: console.hostConnectedAddresses,
                    activeRouteStore: activeRoutes,
                    manualReconnectInFlightHostIDs: [],
                    retryConnection: { _ in },
                    switchRoute: { hostID, address in
                        let candidates =
                            hosts.hosts.first(where: { $0.id == hostID })?
                            .candidateAddresses ?? []
                        activeRoutes.setActiveRoute(
                            address, hostID: hostID, candidates: candidates)
                        await console.retryHost(hostID)
                    })
            }
            .task {
                console.setHosts(hosts.hosts)
                await console.resume()
            }
            .onDisappear {
                console.setHosts([])
            }
        }

        /// The pending-ask capture surface: ChatScreen with a blocked
        /// agent, one assistant article (the accent author line), and
        /// a multi-select pending interaction — the v2 accent
        /// proofs tap an option and capture Confirm + the selected
        /// chip in BOTH appearances. The composer's deliver/onAsk
        /// callbacks are wired so the surface is interactive (a tap
        /// really selects; Confirm really fires) without any backend.
        private var chatPendingAskSurface: some View {
            ChatScreen(
                paneID: "demo:pending",
                agentName: "ios-polish",
                state: .blocked,
                content: ChatContent(
                    messages: [
                        ChatMessage(
                            id: UUID(),
                            role: .assistant,
                            blocks: [
                                .text(
                                    """
                                    I found two candidate fixes for the \
                                    attach retry path. I need your call on \
                                    which risks to take before I continue.
                                    """)
                            ])
                    ],
                    pending: [
                        PendingInteraction(
                            id: "demo-ask",
                            question: "",
                            options: [],
                            questions: [
                                PendingAskQuestion(
                                    id: "q0",
                                    text: "Which checks should run before the retry lands?",
                                    multi: true,
                                    options: [
                                        PendingAskQuestion.Option(
                                            id: "o0", label: "Unit suite"),
                                        PendingAskQuestion.Option(
                                            id: "o1", label: "UI smoke"),
                                        PendingAskQuestion.Option(
                                            id: "o2", label: "Device build"),
                                    ])
                            ])
                    ]),
                initialLevel: .l0,
                changeLevel: { _, _ in },
                deliver: { _ in },
                authorLabel: "Meadow · omp",
                onAskAnswer: { _, _ in },
                onAskCancel: { _ in })
        }

        /// The v3 Q/A-card capture surface: ChatScreen with BOTH card
        /// states of the SAME family — an unanswered TWO-question ask
        /// (multi-select then single-choice-with-custom) at the live
        /// edge, and answered cards anchored in the transcript covering
        /// every answer shape the design names: producer-ordered label
        /// chips, free-text-only, selection plus note, a long answer
        /// collapsed to one line (tap to expand), and the honest
        /// non-answered outcomes (cancelled / answered remotely with
        /// missing details). The onAsk seams are wired so the proof
        /// suite can REALLY select, type custom text, submit, swipe
        /// between questions, and tap to expand — no backend.
        private var chatQACardsSurface: some View {
            ChatScreen(
                paneID: "demo:qa-cards",
                agentName: "ios-polish",
                state: .blocked,
                content: ChatContent(
                    messages: [
                        ChatMessage(role: .assistant, blocks: [
                            .text(
                                """
                                The export refactor is ready for a decision. \
                                Two questions below need your call before I can \
                                continue with the release prep.
                                """),
                        ]),
                        // The answered multi-question card: anchored to
                        // the turn that posed it (question → answer →
                        // reply order).
                        ChatMessage(role: .assistant, blocks: [
                            .text(
                                """
                                What should the export include for the \
                                review bundle? Pick the artifacts and, if you \
                                want footage, note the exact window.
                                """),
                        ]),
                        // (the resolved cards anchor by questionText)
                        ChatMessage(role: .assistant, blocks: [
                            .text(
                                """
                                Sounds good — the export now carries the \
                                video and the validation report with your \
                                ten-second window. Continuing with the \
                                release prep.
                                """),
                        ]),
                    ],
                    pending: [
                        PendingInteraction(
                            id: "demo-qa-ask",
                            question: "",
                            options: [],
                            questions: [
                                PendingAskQuestion(
                                    id: "q0",
                                    text: "Which checks should run before the retry lands?",
                                    multi: true,
                                    options: [
                                        .init(id: "o0", label: "Unit suite"),
                                        .init(id: "o1", label: "UI smoke"),
                                        .init(id: "o2", label: "Device build"),
                                    ]),
                                PendingAskQuestion(
                                    id: "q1",
                                    text: "Who reviews the pull request?",
                                    options: [
                                        .init(id: "o0", label: "You"),
                                        .init(id: "o1", label: "Me"),
                                        .init(id: "o2", label: "Both of us"),
                                    ],
                                    allowCustom: true),
                            ]),
                    ],
                    resolvedAsks: [
                        // Answered, multi-question with different answer
                        // shapes: labels + note, then free text.
                        ResolvedAsk(
                            id: "demo-qa-answered",
                            questions: [
                                ResolvedAskQuestion(
                                    id: "q0",
                                    question: "What should the export include?",
                                    selectedOptions: [
                                        .init(id: "o0", label: "Video"),
                                        .init(
                                            id: "o1",
                                            label: "Validation report"),
                                    ],
                                    note: "Include the first ten seconds only."),
                                ResolvedAskQuestion(
                                    id: "q1",
                                    question: "Any custom export options?",
                                    customAnswerText:
                                        "I'll take it after lunch"),
                            ],
                            outcome: .youAnswered,
                            questionText:
                                "What should the export include for the review bundle?"),
                        // Cancelled: honest outcome, no accepted styling.
                        ResolvedAsk(
                            id: "demo-qa-cancelled",
                            questions: [],
                            outcome: .cancelled,
                            questionText: "Ship the hotfix tonight?"),
                        // Answered remotely with missing details: the
                        // honest placeholder, never fabricated choices.
                        ResolvedAsk(
                            id: "demo-qa-remote-missing",
                            questions: [],
                            outcome: .answeredRemotely,
                            questionText: "Bump the dependency to v2?"),
                        // Long answer collapsed to ONE ellipsized line;
                        // tap expands the full text + note.
                        ResolvedAsk(
                            id: "demo-qa-long",
                            questions: [
                                ResolvedAskQuestion(
                                    id: "q0",
                                    question: "Summarize the rollout plan for the review.",
                                    customAnswerText:
                                        """
                                        Stage the rollout behind the config \
                                        flag, ship to the internal track on \
                                        Monday, watch the retry and payment \
                                        dashboards for two full days, then \
                                        widen to 50% of production traffic \
                                        once the error budget is intact, and \
                                        finally make the flag default-on next \
                                        Thursday if nothing regresses.
                                        """,
                                    note: "Keep the kill switch documented."),
                            ],
                            outcome: .youAnswered,
                            questionText: "Summarize the rollout plan for the review."),
                    ]),
                initialLevel: .l1,
                changeLevel: { _, _ in },
                deliver: { _ in },
                authorLabel: "Meadow · omp",
                onAskAnswer: { _, _ in },
                onAskCancel: { _ in })
        }

        /// The special-sections capture surface: ChatScreen with a
        /// realistic transcript carrying BOTH tags (a harness-injected
        /// `<system-notice>` mid-turn and an `<irc>` peer message
        /// near the end), so the capture suite pins the chip render,
        /// the L0 hide, and the tap-through expansion without a
        /// backend. The initial detail level rides
        /// `--demo-detail-level=<n>` (default L1 — the chip level).
        private var chatSpecialSectionsSurface: some View {
            ChatScreen(
                paneID: "demo:special-sections",
                agentName: "checkout",
                state: .idle,
                content: ChatContent(
                    messages: [
                        ChatMessage(role: .user, blocks: [
                            .text("Ship the checkout fix — run the **targeted** tests first."),
                        ]),
                        ChatMessage(role: .assistant, blocks: [
                            .text(
                                """
                                I extracted the retry logic into `PaymentCoordinator` \
                                so the cart survives a failed attempt.

                                <system-notice>Skill "shell-qa" is now active for this \
                                session. Commands run through the dev-box shell QA \
                                profile.
                                Exit code semantics: step logs record their own \
                                status.</system-notice>

                                While validating the fix, a peer weighed in:

                                <irc><Main> The retry fix looks good from my side — \
                                go ahead and ship it when tests pass.</irc>

                                All 18 targeted tests pass. Ready to commit when \
                                you are.
                                """),
                        ]),
                    ]),
                initialLevel: Self.demoDetailLevel,
                changeLevel: { _, _ in },
                deliver: { _ in },
                authorLabel: "Meadow · omp")
        }

        /// The v3 content-sized-bubble capture surface: a transcript of
        /// OWN messages covering every sizing case the design doc
        /// names — one-word, emoji, multiline (soft breaks), long
        /// prose (wraps at the 0.85×/560pt cap), and fenced code —
        /// plus an agent turn (unchanged fill presentation) for
        /// contrast. Read-only (no deliver) so the captures are
        /// purely visual.
        private var chatBubblesSurface: some View {
            ChatScreen(
                paneID: "demo:bubbles",
                agentName: "omp",
                state: .idle,
                content: ChatContent(
                    messages: [
                        ChatMessage(role: .user, blocks: [
                            .text("Ship it."),
                        ]),
                        ChatMessage(role: .user, blocks: [
                            .text("🚀"),
                        ]),
                        ChatMessage(role: .user, blocks: [
                            .text("line one\nline two\nline three"),
                        ]),
                        ChatMessage(role: .user, blocks: [
                            .text("```\nfunc greet() {\n    print(\"hi\")\n}\n```"),
                        ]),
                        ChatMessage(role: .user, blocks: [
                            .text(
                                """
                                Before you commit the checkout fix, please \
                                re-run the targeted suite and paste the summary — \
                                I want to confirm the retry regression is \
                                actually gone and that the cart survives a \
                                failed payment attempt end to end.
                                """),
                        ]),
                        ChatMessage(role: .assistant, blocks: [
                            .text(
                                """
                                All 18 targeted tests pass and the retry \
                                regression is gone — the cart now survives a \
                                failed payment attempt end to end. Ready to \
                                commit when you are.
                                """),
                        ]),
                    ]),
                initialLevel: .l2,
                changeLevel: { _, _ in },
                deliver: { _ in },
                authorLabel: "Meadow · omp")
        }

        /// The v3 wrapped-table capture surface: a transcript of agent
        /// turns whose markdown tables stress the phone-width
        /// contract — a three-column table with long wrapping cells
        /// (the reported regression case), a compact two-column table
        /// that fits without folding, and a table carrying code spans
        /// and a link inside cells. Read-only (no deliver) so the
        /// captures are purely visual; every long cell must WRAP and
        /// the whole table must stay inside the reading width.
        private var chatTablesSurface: some View {
            ChatScreen(
                paneID: "demo:tables",
                agentName: "omp",
                state: .idle,
                content: ChatContent(
                    messages: [
                        ChatMessage(role: .assistant, blocks: [
                            .text(
                                """
                                Here is the retry matrix for the release \
                                blocks — every row keeps its full text \
                                inside the phone's reading width:

                                | Stage | Owner | Notes |
                                | --- | --- | --- |
                                | build | platform | Full clean build with \
                                the new linker flags; green on both runners |
                                | unit tests | payments | The 34-case suite \
                                passes and the retry regression stays fixed |
                                | integration | checkout | Long-path harness \
                                needs a re-run after the cert rotation lands \
                                later this week |
                                """)
                        ]),
                        ChatMessage(role: .assistant, blocks: [
                            .text(
                                """
                                Fit check — this compact table needs no \
                                wrapping at all:

                                | Stage | Files |
                                | --- | --- |
                                | build | 12 |
                                | test | 34 |
                                """)
                        ]),
                        ChatMessage(role: .assistant, blocks: [
                            .text(
                                """
                                And the inline-markup case — code spans \
                                and a link survive the wrap:

                                | Command | Effect |
                                | --- | --- |
                                | `herdr agent attach` | Attaches the \
                                interactive TUI to the agent pane over \
                                the client bridge |
                                | see [the guide](https://herdr.dev) | \
                                Opens the tap-to-open link routing the \
                                chat already uses |
                                """)
                        ]),
                    ]),
                initialLevel: .l2,
                changeLevel: { _, _ in },
                deliver: { _ in },
                authorLabel: "Meadow · omp")
        }

        /// The `--demo-detail-level=<n>` argument's value (0–3);
        /// defaults to L1 so an unspecified run still shows chips.
        private static var demoDetailLevel: DetailLevel {
            for argument in ProcessInfo.processInfo.arguments {
                guard argument.hasPrefix("--demo-detail-level="),
                    let raw = Int(argument.dropFirst("--demo-detail-level=".count)),
                    let level = DetailLevel(rawValue: raw)
                else { continue }
                return level
            }
            return .l1
        }

        private var consoleRoot: some View {
            // The production navigation surface (#A v2): the demo root
            // mounts the AppRootView so captures and UI proofs exercise
            // the real destination chrome — trigger + plain title,
            // drawer on phone, reserved sidebar on wide.
            AppRootView(
                agents: ConsoleView(
                    hosts: hosts,
                    console: console,
                    terminal: terminal,
                    inputMode: inputMode,
                    appearance: appearance,
                    pushRegistration: pushRegistration,
                    notificationPreferences: notificationPreferences,
                    relaySettings: relaySettings,
                    notificationRouter: notificationRouter,
                    bannerStore: bannerStore,
                    presentsSettingsOnAppear: DemoScreenshotMode.presentsSettings,
                    liveActivities: liveActivities,
                    activity: activity
                ),
                hosts: HostListView(
                    store: hosts,
                    connectionStatuses: console.hostStatuses,
                    standingFailures: console.hostStandingFailures,
                    latencies: console.hostLatencies,
                    connectedAddresses: console.hostConnectedAddresses,
                    manualReconnectInFlightHostIDs: [],
                    retryConnection: { _ in },
                    discovery: SessionDiscoveryStore(
                        listSessions: { hostID in
                            try await console.listSessions(on: hostID)
                        })),
                settings: SettingsView(
                    terminal: terminal,
                    appearance: appearance,
                    pushRegistration: pushRegistration,
                    notificationPreferences: notificationPreferences,
                    relaySettings: relaySettings,
                    liveActivities: liveActivities,
                    console: console,
                    hosts: hosts.hosts),
                // Same focus gating as the production root (#A): the
                // destination chrome hides while a detail is pushed.
                isPageContentFocused: { notificationRouter.path.isEmpty }
            )
            // The shared reading-size store for the demo's chat reading
            // text (#A settings revision).
            .environment(\.appReadingTextSize, ReadingTextSizeSettings.shared)
            .preferredColorScheme(appearance.preferredColorScheme)
            .task {
                console.setHosts(hosts.hosts)
                notificationPreferences.setHosts(hosts.hosts)
                await console.resume()
            }
        }
        private func multipathDetail(midProbe: Bool) -> some View {
            let store = HostOnboardingStore(
                host: DemoScreenshotMode.multipathHost,
                connector: DemoMultipathConnector(),
                preferredAddresses: PreferredAddressStore(
                    defaults: DemoScreenshotFixture.makeDefaults(),
                    hostID: DemoScreenshotMode.multipathHost.id))
            if midProbe {
                store.scriptProbeStatesForDemo([
                    "192.168.31.71": .reachable,
                    "CMF79KM7YF.local": .unreachable,
                    "studio.vpn.example": .probing,
                ])
            } else {
                store.scriptProbeStatesForDemo([
                    "192.168.31.71": .reachable,
                    "CMF79KM7YF.local": .unreachable,
                    "studio.vpn.example": .reachable,
                ])
                store.scriptAddressChoiceForDemo([
                    "192.168.31.71", "studio.vpn.example"])
            }
            return NavigationStack {
                HostOnboardingView(
                    host: DemoScreenshotMode.multipathHost,
                    catalog: hosts,
                    store: store)
            }
        }
    }

    private struct DemoMultipathConnector: TransportConnector {
        func connect(settings: SSHTransportSettings) async throws -> any Transport {
            throw TransportError.sshUnreachable(detail: "Demo route never dials.")
        }
    }

    @MainActor
    struct DemoScreenshotComposition {
        let hosts: HostStore
        let console: ConsoleStore
        let terminalThemes: TerminalThemeSettings
        let terminalZoom: TerminalZoomSettings
        let terminalFonts: TerminalFontSettings
        let snippets: SnippetStore
        let appearance: AppAppearanceSettings
        let inputMode: AgentInputModeSettings
        let pushRegistration: PushRegistrationStore
        let notificationPreferences: NotificationPreferencesStore
        let relaySettings: NotificationRelaySettings
        let notificationRouter: AgentNotificationRouter
        let bannerStore: AgentNotificationBannerStore
        let liveActivities: HostLiveActivityCoordinator
        let activity: AppActivityCoordinator

        static func make() -> DemoScreenshotComposition {
            let defaults = DemoScreenshotFixture.makeDefaults()
            let console = DemoScreenshotFixture.makeConsoleStore()
            let pushRegistration = PushRegistrationStore(client: DemoPushRegistrationClient())
            let relaySettings = NotificationRelaySettings(defaults: defaults)
            let notificationRouter = AgentNotificationRouter()
            let notificationPreferences = NotificationPreferencesStore(
                transports: console,
                deviceToken: { nil },
                relayBaseURL: { nil })
            return DemoScreenshotComposition(
                hosts: HostStore(volatileHosts: DemoScreenshotFixture.hosts),
                console: console,
                terminalThemes: TerminalThemeSettings(defaults: defaults),
                terminalZoom: TerminalZoomSettings(defaults: defaults),
                terminalFonts: TerminalFontSettings(defaults: defaults),
                snippets: SnippetStore(defaults: defaults),
                appearance: AppAppearanceSettings(defaults: defaults),
                inputMode: AgentInputModeSettings(defaults: defaults),
                pushRegistration: pushRegistration,
                notificationPreferences: notificationPreferences,
                relaySettings: relaySettings,
                notificationRouter: notificationRouter,
                bannerStore: AgentNotificationBannerStore(
                    presentedAgent: { notificationRouter.path.last },
                    triggers: { _ in nil },
                    playSound: {}),
                liveActivities: HostLiveActivityCoordinator(
                    controller: ActivityKitLiveActivityController(),
                    preferences: LiveActivityPreferences(defaults: defaults),
                    transports: console,
                    deviceToken: { nil },
                    knownHostIDs: { Set(DemoScreenshotFixture.hosts.map(\.id)) },
                    hostDisplayName: { id in
                        DemoScreenshotFixture.hosts.first(where: { $0.id == id })?.displayName
                            ?? ""
                    },
                    isAwaitingSnapshot: { _ in false },
                    connectionStatus: { _ in .connected }),
                activity: AppActivityCoordinator())
        }
    }

    enum DemoScreenshotFixture {
        static let studioHostID = UUID(
            uuid: (
                0x11, 0x11, 0x11, 0x11, 0x11, 0x11, 0x41, 0x11,
                0x81, 0x11, 0x11, 0x11, 0x11, 0x11, 0x11, 0x11
            ))
        static let buildHostID = UUID(
            uuid: (
                0x22, 0x22, 0x22, 0x22, 0x22, 0x22, 0x42, 0x22,
                0x82, 0x22, 0x22, 0x22, 0x22, 0x22, 0x22, 0x22
            ))

        static let hosts = [
            Host(
                id: studioHostID,
                name: "Studio Mac",
                address: "studio.demo.invalid",
                username: "developer",
                sessionName: "main",
                additionalAddresses: ["studio.lan.demo.invalid"],
                routeLabels: [
                    "studio.demo.invalid": "Primary",
                    "studio.lan.demo.invalid": "Local network",
                ]),
            Host(
                id: buildHostID,
                name: "Build Server",
                address: "build.demo.invalid",
                username: "builder",
                sessionName: "ci"),
            // A third machine that fails to connect (no demo profile):
            // the Console's deterministic host-issue row — the flat and
            // grouped lists both navigate it to the same Hosts handler.
            Host(
                id: offlineHostID,
                name: "Offline Server",
                address: "offline.demo.invalid",
                username: "developer",
                sessionName: "main"),
            // A multi-route machine with no demo profile: every dial
            // fails, so a route-switch tap shows the full lifecycle —
            // connecting animation, then the honest failed dot — through
            // the real Console pipeline (the route-switch proofs).
            Host(
                id: fieldHostID,
                name: "Field Laptop",
                address: "field.lan.demo.invalid",
                username: "field",
                sessionName: "main",
                additionalAddresses: ["field.vpn.demo.invalid"],
                routeLabels: [
                    "field.lan.demo.invalid": "Home LAN",
                    "field.vpn.demo.invalid": "VPN tunnel",
                ]),
        ]

        static let fieldHostID = UUID(
            uuid: (
                0x44, 0x44, 0x44, 0x44, 0x44, 0x44, 0x44, 0x44,
                0x84, 0x44, 0x44, 0x44, 0x44, 0x44, 0x44, 0x44
            ))

        static let offlineHostID = UUID(
            uuid: (
                0x33, 0x33, 0x33, 0x33, 0x33, 0x33, 0x43, 0x33,
                0x83, 0x33, 0x33, 0x33, 0x33, 0x33, 0x33, 0x33
            ))

        static let profiles: [Host.ID: DemoHostProfile] = [
            studioHostID: DemoHostProfile(
                snapshot: snapshot(
                    agents: [
                        agent(
                            paneID: "mobile:p1", status: .working,
                            workspaceID: "mobile", kind: "codex",
                            name: "ios-polish", title: "Polish the Attach experience",
                            cwd: "/workspace/meadow",
                            transcriptPath: chatTranscriptPath),
                        agent(
                            paneID: "docs:p2", status: .idle,
                            workspaceID: "docs", kind: "claude",
                            name: "docs-review", title: "Refresh the setup guide",
                            cwd: "/workspace/product-docs"),
                        agent(
                            paneID: "mobile:p4", status: .done,
                            workspaceID: "mobile", kind: "gemini",
                            name: "accessibility", title: "Audit VoiceOver labels",
                            cwd: "/workspace/meadow",
                            transcriptPath: chatTranscriptPath),
                    ],
                    workspaces: [
                        workspace(
                            id: "mobile", label: "iOS App", repo: "meadow",
                            isLinkedWorktree: true),
                        workspace(id: "docs", label: "Product Docs", repo: "docs-site"),
                    ],
                    // Producer geometry (v3 Herdr order proofs): the iOS
                    // App workspace's tab holds p1 ABOVE p4 (a vertical
                    // split), so herdr order renders Polish, Audit, then
                    // the Product Docs workspace's Refresh — visibly
                    // different from A–Z (Audit first) and from status
                    // order (done Audit first).
                    layouts: [
                        layout(workspaceID: "mobile", panes: [
                            ("mobile:p1", x: 0, y: 0, width: 80, height: 12),
                            ("mobile:p4", x: 0, y: 12, width: 80, height: 12),
                        ]),
                        layout(workspaceID: "docs", panes: [
                            ("docs:p2", x: 0, y: 0, width: 80, height: 24),
                        ]),
                    ]),
                paneSnippets: [
                    "mobile:p1": "Running AttachViewTests… 24 passed",
                    "docs:p2": "Ready when you are.",
                    "mobile:p4": "VoiceOver audit complete. 0 blockers.",
                ],
                terminalOutputs: [
                    "mobile:p1": terminalOutput,
                    "docs:p2": terminalOutput,
                    "mobile:p4": terminalOutput,
                ],
                transcripts: [
                    chatTranscriptPath: chatTranscript,
                    "/home/demo/.local/share/omp/shot-1.png": demoImagePNG,
                    "/home/demo/.local/share/omp/shot-2.png": demoImagePNG,
                    "/home/demo/.local/share/omp/shot-3.png": demoImagePNG,
                    "/home/demo/.local/share/omp/shot-4.png": demoImagePNG,
                    "/home/demo/.local/share/omp/shot-5.png": demoImagePNG,
                    "/home/demo/.local/share/omp/shot-6.png": demoImagePNG,
                ]),
            buildHostID: DemoHostProfile(
                snapshot: snapshot(
                    agents: [
                        agent(
                            paneID: "checkout:p3", status: .blocked,
                            workspaceID: "checkout", kind: "claude",
                            name: "reviewer", title: "Checkout review",
                            cwd: "/workspace/storefront",
                            transcriptPath: chatTranscriptPath),
                        agent(
                            paneID: "api:p7", status: .working,
                            workspaceID: "api", kind: "opencode",
                            name: "api-tests", title: "Harden webhook retries",
                            cwd: "/workspace/payments-api"),
                    ],
                    workspaces: [
                        workspace(id: "checkout", label: "Checkout", repo: "storefront"),
                        workspace(id: "api", label: "Payments API", repo: "payments-api"),
                    ]),
                paneSnippets: [
                    "checkout:p3": "Run the targeted UI test before commit?",
                    "api:p7": "Retry matrix: 12 of 16 cases passing",
                ],
                terminalOutputs: [
                    "checkout:p3": terminalOutput,
                    "api:p7": terminalOutput,
                ],
                transcripts: [
                    chatTranscriptPath: chatTranscript,
                    "/home/demo/.local/share/omp/shot-1.png": demoImagePNG,
                    "/home/demo/.local/share/omp/shot-2.png": demoImagePNG,
                    "/home/demo/.local/share/omp/shot-3.png": demoImagePNG,
                    "/home/demo/.local/share/omp/shot-4.png": demoImagePNG,
                    "/home/demo/.local/share/omp/shot-5.png": demoImagePNG,
                    "/home/demo/.local/share/omp/shot-6.png": demoImagePNG,
                ]),
        ]

        /// The absolute path every demo agent's `.path` session points at;
        /// the demo transport serves `chatTranscript` for it.
        static let chatTranscriptPath = "/home/demo/.local/share/omp/session.jsonl"

        /// A small omp JSONL transcript: a user turn, an assistant turn
        /// with thinking + a tool call + text, a paired tool result, a
        /// closing assistant round of two messages, and one very long
        /// assistant message (taller than the viewport) — so the bubble
        /// grouping shows per-message bubbles AND the focus overlay's
        /// pill/menu clamping can be screenshot-verified against an
        /// over-tall bubble (the pending card stays preview-only until
        /// a transcript record feeds it).
        private static let chatTranscriptJSON = """
            {"type":"message","id":"demo-1","timestamp":1789292098261,"message":{"role":"user","content":[{"type":"text","text":"Ship the checkout fix — run the targeted tests first."}],"timestamp":1789292098261}}
            {"type":"message","id":"demo-2","timestamp":1789292105000,"message":{"role":"assistant","content":[{"type":"thinking","thinking":"The user wants the fix shipped. Read the failing test first, then run the suite."},{"type":"toolCall","id":"demo-call-1","name":"read","arguments":{"path":"CheckoutView.swift"}},{"type":"text","text":"The retry logic drops the cart because `PaymentCoordinator` resets state on the first attempt. I'll preserve the cart across retries and re-run `CheckoutFlowTests`."}],"timestamp":1789292105000}}
            {"type":"message","id":"demo-3","timestamp":1789292110000,"message":{"role":"toolResult","toolCallId":"demo-call-1","toolName":"read","content":[{"type":"text","text":"struct CheckoutView: View {\\n    var body: some View {\\n        Text(\\"Checkout\\")\\n    }\\n}"}],"timestamp":1789292110000}}
            {"type":"message","id":"demo-4","timestamp":1789292115000,"message":{"role":"assistant","content":[{"type":"text","text":"Re-ran the suite: 18 of 18 passing, no flake in the retry path."}],"timestamp":1789292115000}}
            {"type":"message","id":"demo-images","timestamp":1789292118000,"message":{"role":"assistant","content":[{"type":"image","mimeType":"image/png","ref":"/home/demo/.local/share/omp/shot-1.png","byteLength":90},{"type":"image","mimeType":"image/png","ref":"/home/demo/.local/share/omp/shot-2.png","byteLength":90},{"type":"image","mimeType":"image/png","ref":"/home/demo/.local/share/omp/shot-3.png","byteLength":90},{"type":"image","mimeType":"image/png","ref":"/home/demo/.local/share/omp/shot-4.png","byteLength":90},{"type":"image","mimeType":"image/png","ref":"/home/demo/.local/share/omp/shot-5.png","byteLength":90},{"type":"image","mimeType":"image/png","ref":"/home/demo/.local/share/omp/shot-6.png","byteLength":90},{"type":"text","text":"Six verification captures from the run."}],"timestamp":1789292118000}}
            {"type":"message","id":"demo-5","timestamp":1789292120000,"message":{"role":"assistant","content":[{"type":"text","text":"All 18 tests pass. Ready to commit when you are."}],"timestamp":1789292120000}}
            {"type":"message","id":"demo-6","timestamp":1789292130000,"message":{"role":"assistant","content":[{"type":"text","text":"Long-run verification notes. Step 1: reproduce the failure on a clean checkout — clone the repo, apply no local patches, and run the failing test exactly as CI does, because a passing local run with uncommitted changes proves nothing about the shipped build. Step 2: capture the failure signature — the first error line, the file and line it names, and the full stack if one prints — so a fix can be matched to the failure later rather than to a guess. Step 3: form one hypothesis at a time. Change exactly one thing, re-run, and record the result; changing two things at once means a passing run cannot say which change mattered. Step 4: keep the reproduction as the regression test. If the fix cannot be shown to flip the repro from red to green, the fix is not verified — it is a hope. Step 5: when the cause is found, write the root cause down before writing the fix, because a fix written against a misread cause silently moves the bug somewhere else. Step 6: re-run the full suite before declaring done, since narrow tests pass happily while neighbors break. Step 7: note the environment — simulator version, OS build, device family — because a failure that only reproduces on one runtime is an environment bug wearing a code bug's clothes. Step 8: if two people are debugging, say out loud what you believe and why before acting; a wrong belief shared is corrected in seconds, a wrong belief private can burn an afternoon. Step 9: when the same failure appears in three places, stop patching and look for the shared seam — the bug lives in the seam, not the call sites. Step 10: after the fix ships, watch the next few CI runs for the same signature elsewhere; regressions rarely travel alone."}],"timestamp":1789292130000}}
            """

        static let chatTranscript = Data(chatTranscriptJSON.utf8)

        /// A real 64x64 PNG the demo console serves for image-block
        /// refs — so the gallery tiles and reader prove the actual
        /// load path in demo screenshots (not unavailable placeholders).
        static let demoImagePNG: Data = {
            let renderer = UIGraphicsImageRenderer(size: CGSize(width: 64, height: 64))
            let image = renderer.image { context in
                let colors = [
                    UIColor(red: 0.13, green: 0.39, blue: 0.30, alpha: 1).cgColor,
                    UIColor(red: 0.85, green: 0.92, blue: 0.88, alpha: 1).cgColor,
                ] as CFArray
                let gradient = CGGradient(
                    colorsSpace: CGColorSpaceCreateDeviceRGB(),
                    colors: colors, locations: [0, 1])!
                context.cgContext.drawLinearGradient(
                    gradient,
                    start: .zero, end: CGPoint(x: 64, y: 64),
                    options: [])
            }
            return image.pngData() ?? Data()
        }()

        static let terminalOutput = """
            \u{001B}[2J\u{001B}[H\u{001B}[1;36mHERDR  •  CLAUDE CODE\u{001B}[0m\r
            \r
            \u{001B}[1mCheckout flow review\u{001B}[0m\r
            \u{001B}[2mstorefront  •  checkout:p3\u{001B}[0m\r
            \r
            \u{001B}[32m●\u{001B}[0m Read CheckoutView.swift\r
              and PaymentCoordinator.swift\r
            \u{001B}[32m●\u{001B}[0m Ran CheckoutFlowTests\r
              \u{001B}[32m✓ 18 tests passed in 4.2s\u{001B}[0m\r
            \u{001B}[32m●\u{001B}[0m Preserved cart on payment retry\r
            \r
            Result:\r
              • cart survives retry\r
              • errors stay inline\r
              • no customer data is logged\r
            \r
            \u{001B}[33m────────────────────────────\u{001B}[0m\r
            \u{001B}[1;33m› Run the UI test before commit?\u{001B}[0m
            """

        static func makeDefaults() -> UserDefaults {
            let suiteName = "dev.bybee.heeler.demo-screenshots.\(UUID().uuidString)"
            return UserDefaults(suiteName: suiteName) ?? UserDefaults()
        }

        static let sidebarLayoutData = Data(
            #"{"v":1,"agent_panel_sort":"priority","sidebar":{"agents":{"rows":[[{"token":"workspace"}],[{"token":"terminal_title_stripped"}],[{"token":"agent"}]]}}}"#.utf8)

        @MainActor
        static func makeConsoleStore() -> ConsoleStore {
            let defaults = makeDefaults()
            let layouts = AgentRowLayoutStore(defaults: defaults)
            // One seeded pin (v3 Pinned-section proofs): the capture
            // shows the optional Pinned bookmark section ABOVE the
            // canonical herdr-ordered rows, the pinned row duplicated
            // in both places.
            let pins = PinnedAgentsStore(defaults: defaults)
            pins.togglePin(hostID: studioHostID, paneID: "mobile:p1")
            // Both demo Hosts follow the seeded global default so the
            // Agents list screenshots exercise the All Hosts (default) path.
            let console = ConsoleStore(
                snapshotRetryDelay: .seconds(30),
                pins: pins,
                rowLayouts: layouts
            ) { host, subscriptions in
                EventsSession(
                    subscriptions: subscriptions,
                    connect: {
                        guard let profile = profiles[host.id] else {
                            // A short, deterministic dial window so the
                            // route-switch proof can capture the
                            // connecting state before the honest failure
                            // lands (a real unreachable dial takes
                            // seconds; the fixture bounds it).
                            try? await Task.sleep(for: .milliseconds(6_000))
                            throw TransportError.sshUnreachable(
                                detail: "No demo profile for Host.")
                        }
                        return DemoScreenshotTransport(profile: profile)
                    },
                    reconnectPolicy: ReconnectPolicy(
                        initialDelay: .seconds(30), multiplier: 1, maxDelay: .seconds(30)),
                    keepalive: nil)
            }
            try? layouts.setGlobalLayout(globalLayout)
            return console
        }

        /// The demo's global default layout: workspace + agent + directory
        /// in one dense Row 1, so a card reads at a glance and the seeded
        /// All Hosts (default) choice is visibly different from the
        /// per-Host herdr rows.
        static let globalLayout = AgentRowLayout(rows: [
            [.init(.workspace), .init(.agent), .init(.tab)],
            [.init(.directory, dim: true)],
        ])

        /// The snapshot builder for demo profiles. `layouts` carries the
        /// pane geometry the v3 Herdr order's proofs capture: panes with
        /// layouts place in the producer's arrangement; panes without
        /// any layout (none in the current fixtures) would render the
        /// honest "Order unavailable" mark.
        private static func snapshot(
            agents: [AgentInfo],
            workspaces: [WorkspaceInfo],
            layouts: [PaneLayoutSnapshot] = []
        ) -> SessionSnapshot {
            SessionSnapshot(
                agents: agents,
                layouts: layouts,
                panes: [],
                protocolVersion: 17,
                tabs: workspaces.map { workspace in
                    // A manually named tab per workspace, so the redesigned
                    // row's fourth location value renders in proofs.
                    TabInfo(
                        agentStatus: .unknown,
                        focused: false,
                        label: "work",
                        number: 1,
                        paneCount: 1,
                        tabID: "\(workspace.workspaceID):t1",
                        workspaceID: workspace.workspaceID)
                },
                version: "0.7.5-demo",
                workspaces: workspaces)
        }

        /// One demo layout: a vertical split's pane rects, rows then
        /// columns — the same geometry contract the projection's
        /// reading order consumes.
        private static func layout(
            workspaceID: String,
            panes: [(paneID: String, x: Int, y: Int, width: Int, height: Int)]
        ) -> PaneLayoutSnapshot {
            PaneLayoutSnapshot(
                area: PaneLayoutRect(height: 24, width: 80, x: 0, y: 0),
                focusedPaneID: panes.first?.paneID ?? "",
                panes: panes.map { pane in
                    PaneLayoutPane(
                        focused: false,
                        paneID: pane.paneID,
                        rect: PaneLayoutRect(
                            height: pane.height, width: pane.width,
                            x: pane.x, y: pane.y))
                },
                splits: [],
                tabID: "\(workspaceID):t1",
                workspaceID: workspaceID,
                zoomed: false)
        }

        private static func agent(
            paneID: String,
            status: AgentStatus,
            workspaceID: String,
            kind: String,
            name: String,
            title: String,
            cwd: String,
            transcriptPath: String? = nil
        ) -> AgentInfo {
            AgentInfo(
                agentStatus: status,
                focused: false,
                paneID: paneID,
                revision: 1,
                tabID: "\(workspaceID):t1",
                terminalID: "terminal:\(paneID)",
                workspaceID: workspaceID,
                agent: kind,
                agentSession: transcriptPath.map { path in
                    AgentSessionInfo(
                        agent: name, kind: .path, source: "demo", value: path)
                },
                cwd: cwd,
                name: name,
                terminalTitleStripped: title)
        }

        private static func workspace(
            id: String,
            label: String,
            repo: String,
            isLinkedWorktree: Bool = false
        ) -> WorkspaceInfo {
            let repoRoot = isLinkedWorktree ? "/source/\(repo)" : "/workspace/\(repo)"
            return WorkspaceInfo(
                activeTabID: "\(id):t1",
                agentStatus: .unknown,
                focused: false,
                label: label,
                number: 1,
                paneCount: 1,
                tabCount: 1,
                workspaceID: id,
                worktree: WorkspaceWorktreeInfo(
                    checkoutPath: "/workspace/\(repo)",
                    isLinkedWorktree: isLinkedWorktree,
                    repoKey: "\(repoRoot)/.git",
                    repoName: repo,
                    repoRoot: repoRoot))
        }
    }

    struct DemoHostProfile: Sendable {
        let snapshot: SessionSnapshot
        let paneSnippets: [String: String]
        let terminalOutputs: [String: String]
        /// Demo transcripts served for `.path` agent sessions, keyed by the
        /// absolute session path (the chat surface's initial read + polling).
        let transcripts: [String: Data]
    }

    private actor DemoScreenshotTransport: Transport {
        private let profile: DemoHostProfile
        private var isClosed = false
        private var eventContinuation: AsyncThrowingStream<HerdrEvent, any Error>.Continuation?
        private var terminalContinuation: AsyncThrowingStream<Data, any Error>.Continuation?

        init(profile: DemoHostProfile) {
            self.profile = profile
        }

        func ping() async throws -> ServerInfo {
            ServerInfo(version: profile.snapshot.version, protocolVersion: 17)
        }

        func listAgents() async throws -> [Agent] {
            profile.snapshot.agents.map(Agent.init)
        }

        func availableAgentKinds() async throws -> [SupportedAgentKind] {
            [.claude, .codex, .gemini, .opencode]
        }

        func readSidebarLayout() async throws -> Data? {
            DemoScreenshotFixture.sidebarLayoutData
        }

        func sessionSnapshot() async throws -> SessionSnapshot {
            profile.snapshot
        }

        func readTranscriptFile(atPath path: String) async throws -> Data {
            profile.transcripts[path]
                ?? Data()  // An absent file reads as empty, per the transport contract.
        }

        func readTranscriptFileChunk(
            atPath path: String, offset: UInt64, length: Int
        ) async throws -> Data {
            let data = profile.transcripts[path] ?? Data()
            let start = Int(offset)
            guard start < data.count else { return Data() }
            return data[start..<min(start + max(length, 0), data.count)]
        }

        func readPane(_ params: PaneReadParams) async throws -> PaneReadResult {
            let agent = profile.snapshot.agents.first(where: { $0.paneID == params.paneID })
            return PaneReadResult(
                format: .text,
                paneID: params.paneID,
                revision: 1,
                source: params.source,
                tabID: agent?.tabID ?? "demo:t1",
                text: profile.paneSnippets[params.paneID] ?? "Ready.",
                truncated: false,
                workspaceID: agent?.workspaceID ?? "demo")
        }

        func readAgent(_ params: AgentReadParams) async throws -> PaneReadResult {
            let agent = profile.snapshot.agents.first(where: { $0.paneID == params.target })
            return PaneReadResult(
                format: params.format ?? .text,
                paneID: params.target,
                revision: 1,
                source: params.source,
                tabID: agent?.tabID ?? "demo:t1",
                text: profile.terminalOutputs[params.target]
                    ?? DemoScreenshotFixture.terminalOutput,
                truncated: false,
                workspaceID: agent?.workspaceID ?? "demo")
        }

        func promptAgent(_ params: AgentPromptParams) async throws -> Agent {
            guard let agent = profile.snapshot.agents.first(where: { $0.paneID == params.target })
            else {
                throw TransportError.malformedResponse("Demo profile has no matching Agent.")
            }
            return Agent(agent)
        }

        func sendAgentKeys(_ params: AgentSendKeysParams) async throws {}

        func startAgent(_ request: AgentLaunchRequest) async throws -> Agent {
            guard let first = profile.snapshot.agents.first else {
                throw TransportError.malformedResponse("Demo profile has no Agents.")
            }
            return Agent(first)
        }

        func startAgentInNewWorktree(
            _ request: AgentLaunchRequest, worktree: WorktreeSpec
        ) async throws -> Agent {
            try await startAgent(request)
        }

        func startAgentInNewWorkspace(
            _ request: AgentLaunchRequest, workspace: NewWorkspaceSpec
        ) async throws -> Agent {
            try await startAgent(request)
        }

        func closePane(_ params: PaneTarget) async throws {}
        func focusAgent(_ target: AgentTarget) async throws {}
        func renameAgent(_ params: AgentRenameParams) async throws {}
        func renameWorkspace(_ params: WorkspaceRenameParams) async throws {}

        func subscribeToEvents(
            _ subscriptions: [EventSubscription]
        ) async throws -> HerdrEventStream {
            guard eventContinuation == nil else {
                throw TransportError.eventsChannelAlreadyOpen
            }
            let (events, continuation) = AsyncThrowingStream<HerdrEvent, any Error>.makeStream()
            eventContinuation = continuation
            return HerdrEventStream(events: events) { await self.endEvents() }
        }

        func attachTerminal(
            _ request: TerminalAttachRequest
        ) async throws -> TerminalAttachSession {
            guard terminalContinuation == nil else {
                throw TransportError.terminalChannelAlreadyOpen
            }
            let (output, continuation) = AsyncThrowingStream<Data, any Error>.makeStream()
            let input = TerminalAttachInputQueue()
            terminalContinuation = continuation
            continuation.yield(
                Data(
                    (profile.terminalOutputs[request.target.identifier]
                        ?? DemoScreenshotFixture.terminalOutput)
                        .utf8)
            )
            return TerminalAttachSession(output: { output }, input: input) {
                await self.endTerminal()
            }
        }

        var isConnected: Bool { !isClosed }

        func close() async throws {
            isClosed = true
            endEvents()
            endTerminal()
        }

        private func endEvents() {
            eventContinuation?.finish()
            eventContinuation = nil
        }

        private func endTerminal() {
            terminalContinuation?.finish()
            terminalContinuation = nil
        }
    }

    private struct DemoPushRegistrationClient: PushRegistrationClient {
        func authorizationStatus() async -> UNAuthorizationStatus { .denied }
        func requestAuthorization() async throws -> Bool { false }
        @MainActor func registerForRemoteNotifications() {}
    }
#endif
