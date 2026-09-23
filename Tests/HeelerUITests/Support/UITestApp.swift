import XCTest

/// Launch helpers: the one entry point for getting the app on screen in a
/// known state. Normal launches go through `launch()`; every demo mode
/// goes through `launchDemo(_:)`, which appends `--demo-screenshots` to
/// the route argument automatically (the demo root is inert without it).
@MainActor
enum UITestApp {
    private static func make() -> XCUIApplication {
        let app = XCUIApplication()
        // Tag the run; the app ignores unknown launch arguments, this is
        // for identification in the process list / logs.
        app.launchArguments += ["--uitest"]
        return app
    }

    /// Plain launch of the production UI (no demo fixtures). On a clean
    /// simulator this shows the empty-state Console; only use it for tests
    /// about the empty state itself.
    static func launch() -> XCUIApplication {
        let app = make()
        app.launch()
        return app
    }

    enum DemoRoute {
        /// The Console with the full agent/workspace fixtures: two Hosts,
        /// five Agents across every status. Agents-list and chat smoke
        /// tests use this.
        case console
        /// The Add/Edit Host form against the multipath demo Host.
        case hostForm
        /// The Hosts list page: host cards with named routes (Studio Mac
        /// card dialed through its primary address, Build Server's card
        /// honestly not-connected).
        case hostList
        /// The Hosts list wired to the real demo Console: live statuses,
        /// shared active-route store, route tap = persist + reconnect
        /// (the unified state-sync + switch-lifecycle proofs).
        case hostListConsole
        case hostDetailProbing
        /// The Host detail page stopped on the pick between two addresses.
        case hostDetailPick
        /// Console + Settings sheet presented on launch.
        case settings
        /// The chat surface with a pending multi-select ask (v2 accent
        /// proofs: Confirm + selected-option chip in both appearances).
        case chatPendingAsk
        /// The chat surface with the v3 Q/A cards (unanswered
        /// multi-question ask + answered cards of every answer shape)
        /// — the paired-card capture surface (v3 Q/A proofs).
        case chatQACards
        /// The chat surface with special sections in the transcript (v2
        /// special-sections proofs: chip / L0 hide / expansion).
        case chatSpecialSections
        /// The chat surface with own-message bubbles of every v3
        /// sizing case (one-word, emoji, multiline, long-prose wrap,
        /// fenced code) — the content-sized bubble capture surface
        /// (v3 width proofs).
        case chatBubbles

        /// The chat surface with markdown tables that stress the
        /// phone-width contract (long multi-column cells, code spans,
        /// links) — the wrapped-cell table capture surface (v3 table
        /// proofs).
        case chatTables
        /// The chat surface with the v3 live-work indicator: the state
        /// control drives Working/Idle/Blocked/Completed/Unknown/No
        /// report — the state→render mapping capture surface.
        case chatLiveWork
        /// The Scan-to-Pair sheet, camera-authorized, with the
        /// always-mounted paste entry — the remote-pairing paste path
        /// proof surface.
        case pairingPaste
        /// The v3 work inspector: the read-only Tasks/Subagents
        /// surface over the demo fixture transcript — the
        /// tasks-inspector proof surface.
        case tasksInspector

        /// The v3 work inspector over the same fixture LINKED with
        /// live child-run registrations (two scouts Running, one
        /// honestly Unknown, one broker-only child) — the child-run
        /// proof surface.
        case tasksInspectorChildRun


        /// The chat surface with an INTERACTIVE composer (v3
        /// Messages-style composer proofs: compact row, multiline
        /// growth, attachment tile, + menu, Send).
        case chatComposer
        /// The chat surface driven by the REAL AgentChatStore over a
        /// scripted in-memory broker pipe — the blank-viewport slice's
        /// transition-capture fixture.
        case chatLifecycle

        var launchArguments: [String] {
            switch self {
            case .console: return ["--demo-screenshots"]
            case .hostList: return ["--demo-screenshots", "--demo-host-list"]
            case .hostListConsole:
                return ["--demo-screenshots", "--demo-host-list-console"]
            case .hostForm: return ["--demo-screenshots", "--demo-host-form"]
            case .hostDetailProbing:
                return ["--demo-screenshots", "--demo-host-detail-probing"]
            case .hostDetailPick:
                return ["--demo-screenshots", "--demo-host-detail-pick"]
            case .settings:
                return ["--demo-screenshots", "--demo-screenshots-settings"]
            case .chatPendingAsk:
                return ["--demo-screenshots", "--demo-chat-pending-ask"]
            case .chatQACards:
                return ["--demo-screenshots", "--demo-chat-qa-cards"]
            case .chatLiveWork:
                return ["--demo-screenshots", "--demo-chat-live-work"]
            case .chatBubbles:
                return ["--demo-screenshots", "--demo-chat-bubbles"]
            case .chatTables:
                return ["--demo-screenshots", "--demo-chat-tables"]
            case .chatLifecycle:
                return ["--demo-screenshots", "--demo-chat-lifecycle"]
            case .chatSpecialSections:
                return ["--demo-screenshots", "--demo-chat-special-sections"]

            case .pairingPaste:
                return [
                    "--demo-screenshots", "--demo-pairing-paste",
                    "--uitest-pairing-authorized-camera",
                ]
            case .tasksInspector:
                return ["--demo-screenshots", "--demo-tasks-inspector"]

            case .tasksInspectorChildRun:
                return [
                    "--demo-screenshots",
                    "--demo-tasks-inspector-childrun",
                ]


            case .chatComposer:
                return ["--demo-screenshots", "--demo-chat-composer"]
            }
        }
    }

    /// Launch into a deterministic demo fixture (Debug+simulator only).
    static func launchDemo(_ route: DemoRoute) -> XCUIApplication {
        let app = make()
        app.launchArguments += route.launchArguments
        app.launch()
        return app
    }
}
enum UITestFixtures {
    /// Agent row labels as the card renders them: workspace label · agent
    /// name (the seeded global default layout). Keep in sync with
    /// DemoScreenshotMode.swift's fixture.
    /// The union roster's row TITLE fragments (the redesigned agents
    /// list labels rows by terminal title; workspace/name ride the
    /// metadata line). Matched by CONTAINS.
    static let agentRows = [
        "Checkout review",
        "Harden webhook retries",
        "Polish the Attach experience",
        "Audit VoiceOver labels",
        "Refresh the setup guide",
    ]
    /// The chat-bearing agent's row (tap target for chat proofs).
    static let chatAgentRow = "Polish the Attach experience"

    /// The nav v2 heading trigger (hamburger) label.
    static let navigationTrigger = "Open navigation"

    /// A row-title static text, matched by CONTAINS (the redesigned
    /// row titles carry a "π > " terminal prefix).
    static func agentRowText(
        _ fragment: String, in app: XCUIApplication
    ) -> XCUIElement {
        app.staticTexts.matching(
            NSPredicate(format: "label CONTAINS %@", fragment)).firstMatch
    }
    /// The multipath Host the form routes edit.
    static let hostFormTitle = "Edit Host"
    static let hostFormExistingAddress = "192.168.31.71"
    /// The compact top-left destination selector on the Console (#A): the
    /// sheet-era Hosts/Settings toolbar buttons it replaced are gone.
    static let destinationSelector = "Agents, switch destination"
    /// The redesigned Host form's labelled fields (handoff §E): the
    /// display-name field's label, and the SSH username field's.
    static let hostFormNameField = "Display name"
    static let hostFormUserField = "SSH username"
    /// Hosts-list cards (handoff §E): the Studio Mac card's route rows,
    /// labelled by route name with exact address:port underneath.
    static let studioMacCard = "Studio Mac"
    static let studioMacPrimaryRoute = "Primary"
    static let studioMacPrimaryAddress = "studio.demo.invalid:22"
    static let studioMacLanRoute = "Local network"
    static let studioMacLanAddress = "studio.lan.demo.invalid:22"
    /// Toolbar buttons on the Console (labelled, not identified).
    static let consoleToolbarHosts = "Hosts"
    static let consoleToolbarSettings = "Settings"
}

/// Timeout budget: one shared set so tests stay snappy but not flaky.
enum UITestTimeouts {
    /// Standard UI waits: rows appearing, sheets, nav pushes.
    static let standard: TimeInterval = 10
    /// Keyboard animate/dismiss; slower on first-present on a fresh sim.
    static let keyboard: TimeInterval = 15
    /// App cold launch to first frame with data.
    static let launch: TimeInterval = 30
    /// Trust-alert tolerance: the alert can race the connecting state.
    static let trustAlert: TimeInterval = 20
}

// MARK: - App state helpers (category over XCUIApplication)

extension XCUIApplication {
    /// The chat composer: PERSISTENT since the conversation redesign —
    /// the bar (and its UITextView) is always mounted on interactive
    /// chats; there is no entry button anymore.
    var chatComposerButton: XCUIElement {
        // Kept under the old name (call sites read as "the composer
        // affordance"); resolves the field itself now.
        chatInput
    }

    /// The chat input's UITextView (always mounted on interactive
    /// chats). Its accessibility label IS the placeholder.
    var chatInput: XCUIElement {
        descendants(matching: .any).matching(
            NSPredicate(format: "label == %@", "Message")
        ).firstMatch
    }

    /// Whether the system keyboard is currently up on screen.
    var isKeyboardPresented: Bool {
        keyboards.firstMatch.exists
    }

    /// Waits for the keyboard to dismiss (after a tap outside / Cancel).
    @discardableResult
    func waitForKeyboardDismissal(timeout: TimeInterval = UITestTimeouts.keyboard) -> Bool {
        !keyboards.firstMatch.waitForExistence(timeout: timeout)
    }

    /// A Form/Settings-style sheet: SwiftUI sheets are `descendants(matching: .sheet)`.
    func waitForSheet(timeout: TimeInterval = UITestTimeouts.standard) -> Bool {
        descendants(matching: .sheet).firstMatch.waitForExistence(timeout: timeout)
    }

    /// A system alert (springboard, TOFU confirm, permission prompt).
    /// Use for alerts the app owns; use `Springboard`-style interception
    /// only for notifications-permission alerts.
    func waitForAlert(timeout: TimeInterval = UITestTimeouts.standard) -> Bool {
        alerts.firstMatch.waitForExistence(timeout: timeout)
    }


    /// Waits for an agent detail push to settle. iOS 27 hides the plain
    /// back-button label from the AX tree, so the reliable signal is the
    /// surface toggle ("Show Terminal" on the chat surface, "Show Chat"
    /// on the terminal surface) — only the pushed detail has one.
    @discardableResult
    func waitForPushedDetail(timeout: TimeInterval = UITestTimeouts.standard) -> Bool {
        let showTerminal = buttons["Show Terminal"].firstMatch
        let showChat = buttons["Show Chat"].firstMatch
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if showTerminal.exists || showChat.exists { return true }
            Thread.sleep(forTimeInterval: 0.25)
        }
        return false
    }
}
