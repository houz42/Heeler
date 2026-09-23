import SwiftUI

/// Pushed destinations under Settings › About.
///
/// Each case is the route identity *and* the concrete view type the
/// `NavigationLink` constructs. Tests bind the identity to
/// `destinationTypeName` so a decoy `LabeledContent` (or any other view) cannot
/// keep the route green while unlinking `AcknowledgementsView` (#161 / #135).
enum SettingsAboutDestination: String, Equatable, CaseIterable, Sendable {
    case acknowledgements = "settings.about.acknowledgements"

    /// Metatype of the view this route constructs. The only allowed
    /// destination for `.acknowledgements` is `AcknowledgementsView`.
    var destinationTypeName: String {
        switch self {
        case .acknowledgements:
            String(reflecting: AcknowledgementsView.self)
        }
    }

    @ViewBuilder
    var destinationView: some View {
        switch self {
        case .acknowledgements:
            AcknowledgementsView()
        }
    }
}
/// Uses the same identity/metatype/destination convention as About routes.
enum SettingsHeaderLayoutDestination: String, Sendable {
    case header = "settings.headerLayout"

    var destinationTypeName: String { String(reflecting: HeaderLayoutSettingsView.self) }

    @MainActor
    func destinationView(console: ConsoleStore, store: HeaderLayoutSettingsStore) -> HeaderLayoutSettingsView {
        HeaderLayoutSettingsView(console: console, store: store)
    }
}

/// Uses the same identity/metatype/destination convention as About routes.
enum SettingsAgentListDestination: String, Sendable {
    case fields = "settings.agentList.fields"

    var destinationTypeName: String { String(reflecting: AgentListFieldsSettingsView.self) }

    @MainActor
    func destinationView(console: ConsoleStore, hosts: [Host]) -> AgentListFieldsSettingsView {
        AgentListFieldsSettingsView(console: console, hosts: hosts)
    }
}

/// The settings sheet root: a shallow menu into Agent fields, appearance and notifications.
/// Keeping it a menu means the per-Host notification rows can grow without
/// pushing the appearance controls out of reach, and vice versa.
struct SettingsView: View {
    let terminal: TerminalSettings
    let appearance: AppAppearanceSettings
    let pushRegistration: PushRegistrationStore
    let notificationPreferences: NotificationPreferencesStore
    let relaySettings: NotificationRelaySettings
    let liveActivities: HostLiveActivityCoordinator
    let console: ConsoleStore
    let hosts: [Host]
    /// The root nav seam (#A revision): the heading trigger replaces the
    /// title-dropdown; sheets/tests without the app root keep the plain
    /// "Settings" title and Done button.
    @Environment(\.appDestination) private var appDestination
    @Environment(\.appDestinationMenuSuppressed) private var isMenuSuppressed
    /// Reading & appearance (#A settings revision): the SHARED text-size
    /// store (review finding 4: one observable store — the same
    /// instance the reading views consume, injected by the roots; the
    /// demo root injects its own) and the default detail level.
    let readingTextSize: ReadingTextSizeSettings
    @State private var defaultDetailLevel = DefaultDetailLevelSettings()
    /// Direct focus report to the root (see AppNavigationFocusReport):
    /// fired on path changes; the root suppresses ALL destination chrome
    /// while any page's sub-page is pushed.
    @Environment(\.appNavigationFocusReport) private var focusReport

    init(
        terminal: TerminalSettings,
        appearance: AppAppearanceSettings,
        pushRegistration: PushRegistrationStore,
        notificationPreferences: NotificationPreferencesStore,
        relaySettings: NotificationRelaySettings,
        liveActivities: HostLiveActivityCoordinator,
        console: ConsoleStore,
        hosts: [Host],
        readingTextSize: ReadingTextSizeSettings = .shared
    ) {
        self.terminal = terminal
        self.appearance = appearance
        self.pushRegistration = pushRegistration
        self.notificationPreferences = notificationPreferences
        self.relaySettings = relaySettings
        self.liveActivities = liveActivities
        self.console = console
        self.hosts = hosts
        self.readingTextSize = readingTextSize
    }

    static let agentListDestination = SettingsAgentListDestination.fields
    static let headerLayoutDestination = SettingsHeaderLayoutDestination.header
    @Environment(\.dismiss) private var dismiss

    static let repositoryURL = URL(string: "https://github.com/ZingerLittleBee/Heeler")

    /// Semantic identity of the About → Acknowledgements route.
    ///
    /// Equals `SettingsAboutDestination.acknowledgements.rawValue`. Tests assert
    /// the id, the destination mapping, and the source wiring together so a
    /// decoy row cannot stand in for the real screen (#161, same lesson as #135).
    static let acknowledgementsRouteID = SettingsAboutDestination.acknowledgements.rawValue

    /// Rows in the About section, in display order. The body iterates this
    /// list; the Acknowledgements entry is a navigation destination, not a
    /// static label, and its id is `acknowledgementsRouteID`.
    static var aboutRows: [AboutRow] {
        var rows: [AboutRow] = [.version, .acknowledgements]
        if repositoryURL != nil {
            rows.append(.repository)
        }
        if NotificationPrivacyCopy.privacyPolicyURL != nil {
            rows.append(.privacyPolicy)
        }
        return rows
    }

    /// One About-section row. Enum cases are identity: a decoy string label is
    /// not `.acknowledgements`.
    enum AboutRow: Equatable, Identifiable {
        case version
        case acknowledgements
        case repository
        case privacyPolicy

        var id: String {
            switch self {
            case .version: "settings.about.version"
            case .acknowledgements: SettingsView.acknowledgementsRouteID
            case .repository: "settings.about.repository"
            case .privacyPolicy: "settings.about.privacyPolicy"
            }
        }
    }

    /// Maps an About row to a pushed destination, or `nil` for rows that do
    /// not navigate (version, external links). The Acknowledgements
    /// `NavigationLink` is built only through this mapping.
    static func aboutDestination(for row: AboutRow) -> SettingsAboutDestination? {
        switch row {
        case .acknowledgements:
            .acknowledgements
        case .version, .repository, .privacyPolicy:
            nil
        }
    }

    var body: some View {
        NavigationStack(path: $path) {
            Form {
                // Reading & appearance (#A settings revision, device
                // feedback): ONE group for every appearance/readability
                // control — the designed rows (Appearance, Text Size,
                // Default Conversation Detail) plus the existing surface
                // appearance rows (Agent List Fields, In-Agent Header,
                // Terminal Appearance), in the approved order. No second
                // header; every existing item kept.
                Section {
                    appearancePicker
                    NavigationLink(value: "settings.textSize") {
                        Label("Text Size", systemImage: "textformat.size")
                    }
                    NavigationLink(value: "settings.defaultDetail") {
                        Label("Default Conversation Detail", systemImage: "list.bullet.indent")
                    }
                    NavigationLink(value: Self.agentListDestination.rawValue) {
                        Label("Agent List Fields", systemImage: "list.bullet.rectangle")
                    }
                    .accessibilityIdentifier(Self.agentListDestination.rawValue)
                    NavigationLink(value: Self.headerLayoutDestination.rawValue) {
                        Label("In-Agent Header", systemImage: "rectangle.topthird.inset.filled")
                    }
                    .accessibilityIdentifier(Self.headerLayoutDestination.rawValue)
                    NavigationLink(value: "settings.terminalAppearance") {
                        Label("Terminal Appearance", systemImage: "paintpalette")
                    }
                } header: {
                    Text("Reading & Appearance")
                }

                Section {
                    NavigationLink(value: "settings.notifications") {
                        Label("Notifications", systemImage: "bell.badge")
                    }
                }

                Section {
                    ForEach(Self.aboutRows) { row in
                        aboutRow(row)
                    }
                } header: {
                    Text("About")
                }
            }
            .navigationDestination(for: String.self) { route in
                switch route {
                case Self.agentListDestination.rawValue:
                    Self.agentListDestination.destinationView(console: console, hosts: hosts)
                case Self.headerLayoutDestination.rawValue:
                    Self.headerLayoutDestination.destinationView(
                        console: console, store: HeaderLayoutSettingsStore.shared)
                case "settings.notifications":
                    NotificationSettingsView(
                        pushRegistration: pushRegistration,
                        notificationPreferences: notificationPreferences,
                        relaySettings: relaySettings,
                        liveActivities: liveActivities)
                case "settings.terminalAppearance":
                    TerminalAppearanceSettingsView(terminal: terminal)
                case "settings.textSize":
                    ReadingTextSizeSettingsView(settings: readingTextSize)
                case "settings.defaultDetail":
                    DefaultDetailLevelSettingsView(settings: defaultDetailLevel)
                case SettingsAboutDestination.acknowledgements.rawValue:
                    // The Acknowledgements route resolves through the same
                    // enum the row builds its link from — identity by case.
                    AcknowledgementsView()
                default:
                    EmptyView()
                }
            }
            // As a top-level destination page the heading trigger + plain
            // title replace the title-dropdown (#A revision). Embedded in
            // a sheet (previews, Demo captures, in-Console presentation)
            // the plain "Settings" title and Done button keep the sheet
            // dismissable.
            .navigationTitle(appDestination == nil ? "Settings" : "")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                // Toolbar items can MISS environment updates (#A v2
                // lesson), so the heading's visibility is driven by the
                // page's OWN path state — root shows the trigger, a
                // pushed sub-page shows only its own back button.
                if appDestination != nil, path.isEmpty {
                    ToolbarItem(placement: .topBarLeading) {
                        AppDestinationHeading()
                    }
                } else if appDestination == nil {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") { dismiss() }
                    }
                }
            }
            // Report pushed-navigation state upward (#A): while a Settings
            // sub-page is pushed, the root's destination chrome steps
            // aside for this page too.
            .modifier(AppDestinationPageFocusModifier(
                destination: .settings, isContentPushed: !path.isEmpty))
            .onChange(of: path, initial: true) { _, newPath in
                focusReport?(.settings, !newPath.isEmpty)
            }
        }
    }

    /// The Settings stack's route ids, so pushed state reports upward.
    @State private var path: [String] = []

    @ViewBuilder
    private func aboutRow(_ row: AboutRow) -> some View {
        switch row {
        case .version:
            LabeledContent("Version", value: Self.versionString)
        case .acknowledgements:
            // Destination comes only from `aboutDestination(for:)` so the
            // route identity and `AcknowledgementsView` cannot drift apart.
            if let destination = Self.aboutDestination(for: row) {
                NavigationLink(value: destination.rawValue) {
                    Label("Acknowledgements", systemImage: "doc.text")
                }
                .accessibilityIdentifier(destination.rawValue)
            }
        case .repository:
            if let repositoryURL = Self.repositoryURL {
                Link(destination: repositoryURL) {
                    Label("GitHub", systemImage: "chevron.left.forwardslash.chevron.right")
                }
            }
        case .privacyPolicy:
            if let privacyURL = NotificationPrivacyCopy.privacyPolicyURL {
                Link(destination: privacyURL) {
                    Label("Privacy Policy", systemImage: "hand.raised")
                }
            }
        }
    }

    /// The app's own light/dark override. A menu picker, not a pushed screen:
    /// three options do not earn a navigation level.
    private var appearancePicker: some View {
        Picker(
            selection: Binding(
                get: { appearance.selection },
                set: { appearance.select($0) })
        ) {
            ForEach(AppAppearanceOption.allCases) { option in
                Text(option.title).tag(option)
            }
        } label: {
            Label("Appearance", systemImage: "circle.lefthalf.filled")
        }
    }

    /// "0.1.0 (1)": marketing version plus build number, the pair App Store
    /// Connect and TestFlight feedback identify a build by.
    private static var versionString: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "unknown"
        let build = info?["CFBundleVersion"] as? String
        return build.map { "\(version) (\($0))" } ?? version
    }
}

/// Text Size (#A settings revision): System (default — follows Dynamic
/// Type, no override) plus explicit reading-size choices. The choice is
/// applied at the app root as `.dynamicTypeSize` — a READING size, never a
/// chrome rescale.
struct ReadingTextSizeSettingsView: View {
    @Bindable var settings: ReadingTextSizeSettings

    var body: some View {
        Form {
            Section {
                Picker("Text Size", selection: Binding(
                    get: { settings.selection },
                    set: { settings.select($0) })
                ) {
                    ForEach(ReadingTextSize.allCases) { size in
                        Text(size.title).tag(size)
                    }
                }
                .pickerStyle(.inline)
                .labelsHidden()
            } footer: {
                Text(
                    "System follows your device’s text size. An explicit "
                        + "choice applies to reading text across the app.")
            }
        }
        .navigationTitle("Text Size")
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// Default Conversation Detail (#A settings revision): the level new
/// conversations start at. Persists through the EXISTING
/// ChatDetailLevelStore (its "default" pseudo-pane key) — the same store
/// the per-agent level switcher writes to, so formats and location cannot
/// drift.
struct DefaultDetailLevelSettingsView: View {
    @Bindable var settings: DefaultDetailLevelSettings

    var body: some View {
        Form {
            Section {
                Picker("Default Detail Level", selection: Binding(
                    get: { settings.level },
                    set: { settings.level = $0 })
                ) {
                    ForEach(DetailLevel.allCases, id: \.rawValue) { level in
                        Text(Self.labels[level] ?? "Level \(level.rawValue)")
                            .tag(level)
                    }
                }
                .pickerStyle(.inline)
                .labelsHidden()
            } footer: {
                Text(
                    "The detail level conversations open at. Per-conversation "
                        + "changes still take precedence.")
            }
        }
        .navigationTitle("Default Conversation Detail")
        .navigationBarTitleDisplayMode(.inline)
    }

    private static let labels: [DetailLevel: String] = [
        .l0: "L0 — Conversation",
        .l1: "L1 — Work Summary",
        .l2: "L2 — Tool Results & Diffs",
        .l3: "L3 — Everything",
    ]
}
