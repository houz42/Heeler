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
        /// The Host detail page mid address-probe.
        case hostDetailProbing
        /// The Host detail page stopped on the pick between two addresses.
        case hostDetailPick
        /// Console + Settings sheet presented on launch.
        case settings

        var launchArguments: [String] {
            switch self {
            case .console: return ["--demo-screenshots"]
            case .hostForm: return ["--demo-screenshots", "--demo-host-form"]
            case .hostDetailProbing:
                return ["--demo-screenshots", "--demo-host-detail-probing"]
            case .hostDetailPick:
                return ["--demo-screenshots", "--demo-host-detail-pick"]
            case .settings:
                return ["--demo-screenshots", "--demo-screenshots-settings"]
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
    static let agentRows = [
        "Checkout · reviewer",
        "Payments API · api-tests",
        "iOS App · ios-polish",
        "iOS App · accessibility",
        "Product Docs · docs-review",
    ]
    /// The chat-bearing agent's row (tap target for chat proofs).
    static let chatAgentRow = "iOS App · ios-polish"
    /// The multipath Host the form routes edit.
    static let hostFormTitle = "Edit Host"
    static let hostFormExistingAddress = "192.168.31.71"
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
    /// The chat composer's entry button: the input frame opens on tap
    /// ("Message the agent"); the UITextView itself only exists once the
    /// frame is presented, and its AX label is the placeholder.
    var chatComposerButton: XCUIElement {
        buttons["Message the agent"].firstMatch
    }

    /// The chat input's UITextView, once the input frame is presented.
    /// Its accessibility label IS the placeholder.
    var chatInput: XCUIElement {
        descendants(matching: .any).matching(
            NSPredicate(format: "label == %@", "Message — / # @ ! for commands")
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
