import SwiftUI

/// Per-Host onboarding (#14): the preflight checklist with fix-it hints,
/// plus the TOFU fingerprint confirmation. Checks run automatically on
/// arrival; the goal is zero to green checkmarks without desktop docs.
struct HostOnboardingView: View {
    /// The Host catalog, for the Edit sheet.
    let catalog: HostStore
    let connectionStatus: EventsSessionStatus?
    let standingFailure: TransportError?
    /// True while Console is serving a Host-detail Reconnect press (the
    /// retry call plus the 1.2 s visual-feedback hold). Distinct from
    /// `EventsSessionStatus.reconnecting`.
    let isManualReconnectInFlight: Bool
    let retryConnection: (@MainActor @Sendable () async -> Void)?
    /// The address the live Console session is dialed through right now,
    /// nil while disconnected. Supplied by the Console's single-source map.
    let connectedAddress: String?
    @State private var store: HostOnboardingStore
    @State private var isEditing = false
    @State private var isConfirmingHostKeyReplacement = false
    @State private var sessionSelectionError: String?

    init(
        host: Host,
        catalog: HostStore,
        connectionStatus: EventsSessionStatus? = nil,
        standingFailure: TransportError? = nil,
        isManualReconnectInFlight: Bool = false,
        retryConnection: (@MainActor @Sendable () async -> Void)? = nil,
        /// Which address the Host's live Console session is dialed through
        /// right now, or nil while disconnected. The Console's single-source
        /// map (`ConsoleStore.hostConnectedAddresses`) supplies it: at most
        /// one candidate can ever carry the in-use mark.
        connectedAddress: String? = nil,
        /// Pre-built store override for demo screenshots; nil builds the
        /// production store keyed to this Host.
        store: HostOnboardingStore? = nil
    ) {
        self.catalog = catalog
        self.connectionStatus = connectionStatus
        self.standingFailure = standingFailure
        self.isManualReconnectInFlight = isManualReconnectInFlight
        self.retryConnection = retryConnection
        self.connectedAddress = connectedAddress
        _store = State(
            initialValue: store ?? HostOnboardingStore(
                host: host,
                preferredAddresses: PreferredAddressStore(hostID: host.id)))
    }

    var body: some View {
        List {
            Section {
                LabeledContent("Address", value: addressLine)
                LabeledContent("Session", value: sessionLine)
                LabeledContent(
                    "Auth",
                    value: store.host.authMethod == .deviceKey ? "Device Key" : "Password")
            }

            // Every way this Host can be reached — one TAPPABLE row per
            // route (user directive: tap a route to use it). Tapping
            // makes that route the Host's active route — the path the
            // next dial leads with, persisted per Host. A live session
            // keeps its dialed route marked (bolt); the active route
            // carries the checkmark. No separate pick card: switching
            // happens on the rows themselves.
            Section {
                if store.host.usesJumpHost {
                    jumpHopRow
                }
                ForEach(store.orderedCandidates, id: \.self) { address in
                    routeRow(address)
                }
                if store.pendingAddressChoice != nil {
                    Text(
                        "Several paths answered. Use the one you want — "
                            + "it becomes this Host's preferred path.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text("Routes")
            } footer: {
                Text(routeSectionFooter)
            }

            if retryConnection != nil {
                Section {
                    Button {
                        retry()
                    } label: {
                        ZStack(alignment: .leading) {
                            Label("Reconnect", systemImage: "arrow.clockwise")
                                .opacity(isManualReconnectInFlight ? 0 : 1)
                            HStack {
                                ProgressView()
                                Text("Connecting…")
                            }
                            .opacity(isManualReconnectInFlight ? 1 : 0)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .animation(.smooth(duration: 0.25), value: isManualReconnectInFlight)
                    }
                    .disabled(isManualReconnectInFlight)
                } footer: {
                    if let footerMessage = connectionPresentation.footerMessage {
                        Text(footerMessage)
                            .foregroundStyle(.red)
                            .transition(.opacity.combined(with: .move(edge: .top)))
                    }
                }
                .animation(
                    .smooth(duration: 0.25),
                    value: connectionPresentation.connectionErrorMessage)
            }

            Section {
                ForEach(PreflightCheck.allCases, id: \.self) { check in
                    PreflightCheckRow(check: check, status: status(for: check))
                }
            } header: {
                HStack {
                    Text("Preflight")
                    if store.phase == .running {
                        ProgressView()
                            .controlSize(.mini)
                            .padding(.leading, 4)
                    }
                }
            } footer: {
                if let info = store.serverInfo {
                    // The notice is advisory and the checks still pass: a Host
                    // newer than this build is usable, just not fully known.
                    Text(
                        info.exceedsGeneratedProtocol
                            ? "herdr \(info.version) · protocol \(info.protocolVersion) — "
                                + "newer than this app was built against, so features added "
                                + "after protocol \(HeelerSSHTransport.generatedProtocolVersion) "
                                + "may be unavailable."
                            : "herdr \(info.version) · protocol \(info.protocolVersion)")
                }
            }

            availableSessionsSection

            Section {
                Button {
                    Task { await store.runChecks() }
                } label: {
                    Label("Run Checks Again", systemImage: "arrow.clockwise")
                }
                .disabled(store.phase == .running)
            }

            if store.pendingHostKeyReplacement != nil {
                Section {
                    Button("Trust New Host Key", systemImage: "key.horizontal", role: .destructive) {
                        isConfirmingHostKeyReplacement = true
                    }
                } footer: {
                    Text("Only continue after verifying the new fingerprint with the Host owner.")
                }
            }
        }
        .navigationTitle(store.host.displayName)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("Edit") { isEditing = true }
            }
        }
        .sheet(isPresented: $isEditing) {
            HostFormView(store: catalog, editing: store.host)
        }
        .alert(
            "Trust this Host?",
            isPresented: fingerprintAlertPresented,
            presenting: store.pendingFingerprint
        ) { _ in
            Button("Trust") { store.confirmFingerprint(trusted: true) }
            Button("Don't Trust", role: .cancel) { store.confirmFingerprint(trusted: false) }
        } message: { candidate in
            Text(
                "First connection to \(candidate.host):\(String(candidate.port)).\n\n"
                    + "Key fingerprint:\n\(candidate.fingerprint.displayString)\n\n"
                    + "Verify it matches the Host's key before trusting.")
        }
        .confirmationDialog(
            "Replace the trusted Host key?",
            isPresented: $isConfirmingHostKeyReplacement,
            titleVisibility: .visible
        ) {
            Button("Trust New Key", role: .destructive) {
                Task { await store.trustPresentedHostKey() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            if let replacement = store.pendingHostKeyReplacement {
                Text(
                    "Trusted: \(replacement.known.displayString)\n\n"
                        + "Presented: \(replacement.presented.displayString)\n\n"
                        + "A changed key can indicate a reinstalled Host or an attack.")
            }
        }
        .alert(
            "Could Not Select Session",
            isPresented: Binding(
                get: { sessionSelectionError != nil },
                set: { if !$0 { sessionSelectionError = nil } })
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(sessionSelectionError ?? "")
        }
        .task {
            if store.phase == .idle {
                await store.runChecks()
            }
        }
    }

    /// Presentation tracks the pending candidate; dismissal is decided by
    /// the buttons (or the store's own timeout), never by the binding, so a
    /// dismiss-then-answer race cannot double-resolve the decision.
    private var fingerprintAlertPresented: Binding<Bool> {
        Binding(
            get: { store.pendingFingerprint != nil },
            set: { _ in })
    }

    /// The summary line: user@primary:port, plus a count hint when more
    /// paths exist so a multi-path Host is legible without scrolling.
    private var addressLine: String {
        var line = "\(store.host.username)@\(store.host.address):\(String(store.host.port))"
        let extra = store.host.candidateAddresses.count - 1
        if extra > 0 {
            line += "  +\(extra) more"
        }
        return line
    }

    private var sessionLine: String {
        if case .namedSession(let name) = store.host.socketLocation {
            return name
        }
        return "default"
    }

    /// One TAPPABLE row per route (user directive): the route's name
    /// (`routeLabels`, address as fallback), its exact address:port, a
    /// probe state icon, and the ACTIVE mark — a checkmark on the route
    /// the next dial leads with, a bolt on the route a live session is
    /// dialed through right now. Tapping ANY row makes it the active
    /// route, any time — instant, reversible, no confirmation; the
    /// switch takes effect on the next connect (a live session is never
    /// torn down by a tap). Reuses the card rows' quiet-dot + green
    /// accent language.
    private func routeRow(_ address: String) -> some View {
        let state = store.candidateStates[address] ?? .unknown
        let isActive = store.preferredRoute == address
        let isInUse = connectedAddress == address
        let routeName = store.host.routeName(for: address)
        return Button {
            tapRoute(address)
        } label: {
            HStack(spacing: 10) {
                // The leading icon: probe state while unknown/checking,
                // the in-use bolt on the live route, else the state glyph.
                if isInUse {
                    Image(systemName: "bolt.fill")
                        .foregroundStyle(Color.accentColor)
                        .accessibilityHidden(true)
                } else {
                    switch state {
                    case .unknown:
                        Image(systemName: "circle.dashed")
                            .foregroundStyle(.secondary)
                            .accessibilityHidden(true)
                    case .probing:
                        ProgressView()
                            .controlSize(.small)
                    case .reachable:
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                            .accessibilityHidden(true)
                    case .unreachable:
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.red)
                            .accessibilityHidden(true)
                    }
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(routeName)
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.primary)
                    Text("\(address):\(String(store.host.port))")
                        .font(.caption)
                        .monospaced()
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer()
                if isActive {
                    Image(systemName: "checkmark")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Color.accentColor)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(
            "Route \(routeName), \(address):\(String(store.host.port)), "
                + (isInUse
                    ? (isActive
                        ? "currently in use and the active route"
                        : "currently in use")
                    : (isActive
                        ? "active route"
                        : "alternate route"))
                + ". Double tap to switch to this route.")
        .accessibilityHint(
            "Sets this route as the dial path for the next connection to "
                + store.host.displayAliasName)
        .accessibilityIdentifier("host-detail-route-\(address)")
    }

    /// One route-row tap, two honest meanings: with a pick pending
    /// (several paths just answered), the tap IS the pick — persist AND
    /// connect now through it, like `Use` always did. Otherwise the tap
    /// switches the active route for the NEXT connect — instant,
    /// reversible, and never tears down a live session.
    private func tapRoute(_ address: String) {
        if store.pendingAddressChoice?.contains(address) == true {
            Task { await store.chooseAddress(address) }
        } else {
            store.setActiveRoute(address)
        }
    }

    /// The jump hop all routes share, when the Host is reached through a
    /// Jump Host: informational (the hop is a Host-level setting, edited
    /// on the form — no per-route meaning), shown as a quiet non-tappable
    /// row so the route list stays the honest picture of the dial path:
    /// jump → route address.
    private var jumpHopRow: some View {
        HStack(spacing: 10) {
            Image(systemName: "arrow.triangle.branch")
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text("via Jump Host")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.primary)
                Text(
                    "\(store.host.jumpAddress):\(String(store.host.jumpPort)) · "
                        + store.host.resolvedJumpUsername)
                    .font(.caption)
                    .monospaced()
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer()
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            "All routes dial through jump host \(store.host.jumpAddress):"
                + String(store.host.jumpPort))
    }

    private var routeSectionFooter: String {
        if store.pendingAddressChoice != nil {
            return "Several paths answered — pick the one to connect through."
        }
        if store.host.candidateAddresses.count > 1 {
            return "Tap a route to make it the one the next connection "
                + "dials. A live connection keeps using its current route "
                + "until it reconnects."
        }
        return ""
    }

    private func retry() {
        guard !isManualReconnectInFlight, let retryConnection else { return }
        Task { @MainActor in
            await retryConnection()
        }
    }

    private var connectionPresentation: HostOnboardingConnectionPresentation {
        HostOnboardingConnectionPresentation(
            status: connectionStatus,
            standingFailure: standingFailure,
            isManualReconnectInFlight: isManualReconnectInFlight)
    }

    private func status(for check: PreflightCheck) -> PreflightCheckStatus? {
        store.report?[check]
    }

    @ViewBuilder
    private var availableSessionsSection: some View {
        if !store.availableSessions.isEmpty || store.sessionDiscoveryError != nil {
            Section {
                ForEach(store.availableSessions, id: \.name) { session in
                    Button {
                        select(session)
                    } label: {
                        HStack {
                            VStack(alignment: .leading) {
                                Text(session.name)
                                Text(session.isRunning ? "Running" : "Stopped")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            if isSelected(session) {
                                Image(systemName: "checkmark")
                            }
                        }
                    }
                    .disabled(isSelected(session) || (!session.isDefault && !session.isRunning))
                }
                if let error = store.sessionDiscoveryError {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text("Available Sessions")
            } footer: {
                Text("Stopped named sessions must be started on the Host before selection.")
            }
        }
    }

    private func isSelected(_ session: HerdrSession) -> Bool {
        session.isDefault ? store.host.sessionName.isEmpty : store.host.sessionName == session.name
    }

    private func select(_ session: HerdrSession) {
        do {
            try store.selectSession(session, in: catalog)
        } catch {
            sessionSelectionError = "The selected session could not be saved."
        }
    }
}

/// Host detail footer copy, derived from Host Connection Status.
///
/// Automatic recovery shows the Explanation only — Summary and Detail, no
/// Recovery Suggestion. A stopped Host shows the whole presentation. See
/// Transport Error Presentation in `CONTEXT.md`.
///
/// `isManualReconnectInFlight` is a Console-owned Reconnect press (the
/// retry call plus its 1.2 s hold), not `EventsSessionStatus.reconnecting`.
/// A press hides the footer for both arms — recorded, not endorsed, in #160.
/// The animation value stays `connectionErrorMessage` so a press does not
/// drive the footer's 0.25 s transition.
struct HostOnboardingConnectionPresentation: Equatable {
    /// Status-derived footer text. The footer animation observes this; a
    /// manual Reconnect request does not change it.
    let connectionErrorMessage: String?
    let footerMessage: String?

    init(
        status: EventsSessionStatus?,
        standingFailure: TransportError? = nil,
        isManualReconnectInFlight: Bool
    ) {
        switch status {
        case .connecting:
            connectionErrorMessage = standingFailure?.presentation.message
        case .reconnecting(_, _, let failure):
            connectionErrorMessage = failure.presentation.explanation
        case .failed(let failure):
            connectionErrorMessage = failure.presentation.message
        case .connected, .suspended, .ended, nil:
            connectionErrorMessage = nil
        }
        footerMessage = isManualReconnectInFlight ? nil : connectionErrorMessage
    }
}

private struct PreflightCheckRow: View {
    let check: PreflightCheck
    /// nil while no report exists yet (first run still in flight).
    let status: PreflightCheckStatus?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                statusIcon
                Text(check.title)
            }
            if case .failed(let hint) = status {
                Text(hint)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder
    private var statusIcon: some View {
        switch status {
        case .passed:
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
        case .failed:
            Image(systemName: "xmark.circle.fill")
                .foregroundStyle(.red)
        case .blocked:
            Image(systemName: "minus.circle")
                .foregroundStyle(.secondary)
        case nil:
            Image(systemName: "circle.dotted")
                .foregroundStyle(.secondary)
        }
    }
}
