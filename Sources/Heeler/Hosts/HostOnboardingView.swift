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
    /// The Host's active route as the Console derives it (the same
    /// PreferredAddressStore the list card renders). nil keeps the
    /// store's own view (previews, lists without a Console). When the
    /// LIST switches the route out-of-band, this input changes and the
    /// open detail reconciles — both pages read one source of truth.
    let activeRouteInput: String?
    /// The unified route-switch action (persist + redial), shared with
    /// the Hosts list's rows — see the init doc for the contract.
    let switchRoute: (@MainActor @Sendable (String) async -> Void)?
    @State private var store: HostOnboardingStore
    @State private var isEditing = false
    @State private var isConfirmingHostKeyReplacement = false
    @State private var sessionSelectionError: String?
    @State private var routeStore: HostRouteStatusStore?
    @State private var routeError: String?
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.openURL) private var openURL
    @State private var isShowingBrokerProvisioning = false


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
        /// The Console-derived active route (single source of truth with
        /// the Hosts list); nil keeps the store's own read.
        activeRouteInput: String? = nil,
        /// The process-wide observable active-route store: the detail's
        /// taps broadcast through it so the Hosts list's marks re-render.
        activeRouteStore: HostActiveRouteStore? = nil,
        /// The SAME route-switch action the Hosts list's rows run
        /// (persist through the shared store + redial via the Console).
        /// A route tap on this page runs exactly that, so both entry
        /// points (root Hosts page, Console Hosts sheet) and both
        /// surfaces behave identically. nil keeps the page's own
        /// fallback (store persist + `retryConnection`, or persist-only
        /// where no Console exists: previews, demo compositions).
        switchRoute: (@MainActor @Sendable (String) async -> Void)? = nil,
        /// Pre-built store override for demo screenshots; nil builds the
        /// production store keyed to this Host.
        store: HostOnboardingStore? = nil,
        /// Pre-built route status store override for demo screenshots; nil
        /// builds the production store on first use. Explicit rather than
        /// an environment value so a scripted store cannot miss the view.
        routeStatusStore: HostRouteStatusStore? = nil
    ) {
        self.catalog = catalog
        self.connectionStatus = connectionStatus
        self.standingFailure = standingFailure
        self.isManualReconnectInFlight = isManualReconnectInFlight
        self.retryConnection = retryConnection
        self.connectedAddress = connectedAddress
        self.activeRouteInput = activeRouteInput
        self.switchRoute = switchRoute
        _store = State(
            initialValue: store ?? HostOnboardingStore(
                host: host,
                preferredAddresses: PreferredAddressStore(hostID: host.id),
                activeRouteBroadcaster: activeRouteStore))
        _routeStore = State(initialValue: routeStatusStore)
    }

    var body: some View {
        routeObservation(
            trustAndSessionChrome(
                navigationChrome(listContent)))
    }

    /// Navigation title, toolbar, and the Edit sheet — its own
    /// expression to keep the type-checker's budget small.
    private func navigationChrome(_ content: some View) -> some View {
        content
            .navigationTitle(store.host.displayName)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .primaryAction) {
                        Button("Edit") { isEditing = true }
                    }
                    ToolbarItem(placement: .primaryAction) {
                        Button("Chat Broker") { isShowingBrokerProvisioning = true }
                    }
                }
                .sheet(isPresented: $isEditing) {
                    HostFormView(store: catalog, editing: store.host)
                }
                .sheet(isPresented: $isShowingBrokerProvisioning) {
                    BrokerProvisioningView(host: store.host)
                }
    }

    /// The trust/session/route alerts and the host-key replacement
    /// dialog.
    private func trustAndSessionChrome(_ content: some View) -> some View {
        content
                .alert(
                    "Trust this Host?",
                    isPresented: fingerprintAlertPresented,
                    presenting: store.pendingFingerprint
                ) { _ in
                    Button("Trust") { store.confirmFingerprint(trusted: true) }
                    Button("Don't Trust", role: .cancel) { store.confirmFingerprint(trusted: false) }
                } message: { candidate in
                    Text(fingerprintMessageLine(candidate))
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
                        Text(hostKeyReplacementLine(replacement))
                    }
                }
                .alert(
                    "Could Not Select Session",
                    isPresented: sessionErrorPresented
                ) {
                    Button("OK", role: .cancel) {}
                } message: {
                    Text(sessionSelectionError ?? "")
                }
                .alert(
                    "Could Not Save Route Selection",
                    isPresented: routeErrorPresented
                ) {
                    Button("OK", role: .cancel) {}
                } message: {
                    Text(routeError ?? "")
                }
    }

    /// The route-surface lifecycle: arrival task, live connection sync,
    /// foreground recheck, and explicit observer teardown.
    private func routeObservation(_ content: some View) -> some View {
        content
                .task {
                    // The route surface renders its statuses from the
                    // store's probe results; build it on arrival, seed
                    // the live connection state, sync the CURRENT network
                    // hint, and observe the shared monitor's coalesced
                    // path changes (unconnected re-evaluation with the
                    // policy's cooldown — the recovery path for the
                    // all-ineligible off-Wi-Fi state).
                    let routeStore = ensureRouteStore()
                    routeStore.updateConnectionState(connectionStatus == .connected)
                    routeStore.syncNetworkFromMonitor()
                    routeStore.observePathChanges()
                    if store.phase == .idle {
                        await store.runChecks()
                    }
                }
                // Keep the store's LIVE connection state current: the
                // evaluation gates read it at call time, never a
                // snapshot captured at appearance.
                .onChange(of: connectionStatus) { _, status in
                    routeStore?.updateConnectionState(status == .connected)
                }
                // The design contract's recheck on foreground: when the
                // app returns, re-run one bounded evaluation — sweep,
                // cooldown backoff, and (when unconnected and a route
                // answers) a redial through the same dial plan every real
                // dial uses.
                .onChange(of: scenePhase, { previous, phase in
                    // A real foreground return only: the launch
                    // transition into active is not a recheck trigger.
                    guard previous != .active, phase == .active, let routeStore,
                        !routeStore.isProbing
                    else { return }
                    Task { await routeStore.evaluateAndMaybeRedial() }
                })
                // The list (or any other surface) switched this Host's
                // active route out-of-band; re-read the shared store so
                // this page's v1 address-list marks agree with the list.
                .onChange(of: activeRouteInput) { _, _ in
                    store.syncPreferredRoute()
                }
                // A status tick from the Console can accompany an
                // out-of-band route switch (the list's tap reconnects);
                // the persisted pick is cheap to re-read, so reconcile
                // here too.
                .onChange(of: connectionStatus) { _, _ in
                    store.syncPreferredRoute()
                }
                // The observer is explicitly cancelled on disappearance
                // (no strong cycle through the store); re-arrival re-arms.
                .onDisappear {
                    routeStore?.stopObservingPathChanges()
                }
    }

    /// The List itself, factored out so the body's modifier chain stays
    /// within the type-checker's budget.
    private var listContent: some View {
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
            // happens on the rows themselves. Shown for Hosts that have
            // NOT adopted v2 route settings — a v2 Host shows the v2
            // Routes section instead (one selection surface per Host).
            if !hostHasV2RouteSettings {
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
            }

            // The design contract's failure offer: on a connect failure
            // with more than one saved route, offer Try another route /
            // Return to automatic. A pinned Host offers both (the pin
            // is never silently overridden — the user must drop it
            // explicitly); an Automatic Host offers the alternates.
            // Placed ABOVE the Routes section: when a dial just failed,
            // the offer is the most important state on the page.
            if showsRouteFailureOffer {
                Section {
                    if liveRouteHost.isManuallyRouted {
                        Button {
                            returnToAutomatic()
                        } label: {
                            Label("Return to automatic", systemImage: "arrow.triangle.2.circlepath")
                        }
                    }
                    ForEach(tryAnotherRouteChoices, id: \.self) { address in
                        Button {
                            Task { await tryRoute(address) }
                        } label: {
                            Label(
                                "Try \(liveRouteHost.routeName(for: address))",
                                systemImage: "arrow.triangle.branch")
                        }
                    }
                } header: {
                    Text("Route failed")
                } footer: {
                    Text(routeFailedFooter)
                }
            }

            // MARK: Routes (v2 automatic route selection): the ONE
            // selection surface, shown when the Host carries v2 route
            // settings (eligibility gates or a pin). Route-less Hosts
            // keep the v1 selector above; the editor row below is how
            // they adopt the v2 surface.
            if hostHasV2RouteSettings {
                routesSection
            } else {
                Section {
                    NavigationLink {
                        HostRouteEditorView(host: store.host, catalog: catalog)
                    } label: {
                        Label("Route priority & eligibility", systemImage: "list.number")
                    }
                } footer: {
                    Text(
                        "Routes are dialed in saved order until one answers. "
                            + "Set priority or eligibility to choose routes automatically.")
                }
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
                    Text(preflightFooterLine(info))
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
    }

    /// Presentation tracks the pending candidate; dismissal is decided by
    /// the buttons (or the store's own timeout), never by the binding, so a
    /// dismiss-then-answer race cannot double-resolve the decision.

    /// The preflight footer: advisory when the Host is newer than this
    /// build was built against, plain version otherwise.
    private func preflightFooterLine(_ info: ServerInfo) -> String {
        guard info.exceedsGeneratedProtocol else {
            return "herdr \(info.version) · protocol \(info.protocolVersion)"
        }
        return
            "herdr \(info.version) · protocol \(info.protocolVersion) — "
            + "newer than this app was built against, so features added "
            + "after protocol \(HeelerSSHTransport.generatedProtocolVersion) "
            + "may be unavailable."
    }
    private var fingerprintAlertPresented: Binding<Bool> {
        Binding(
            get: { store.pendingFingerprint != nil },
            set: { _ in })
    }

    /// The replace-host-key dialog's message: trusted vs presented
    /// fingerprints, with the honest warning.
    private func hostKeyReplacementLine(_ replacement: HostKeyReplacement) -> String {
        "Trusted: \(replacement.known.displayString)\n\n"
            + "Presented: \(replacement.presented.displayString)\n\n"
            + "A changed key can indicate a reinstalled Host or an attack."
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

    /// The first-connect trust alert's message.
    private func fingerprintMessageLine(_ candidate: HostKeyCandidate) -> String {
        "First connection to \(candidate.host):\(String(candidate.port)).\n\n"
            + "Key fingerprint:\n\(candidate.fingerprint.displayString)\n\n"
            + "Verify it matches the Host's key before trusting."
    }

    private var sessionLine: String {
        if case .namedSession(let name) = store.host.socketLocation {
            return name
        }
        return "default"
    }

    /// The Route-failed offer's footer.
    private var routeFailedFooter: String {
        "The connection did not go through. "
            + "You can try one of this Host's other saved routes "
            + "or return to automatic selection."
    }

    /// Presentation of the route-save failure alert.
    private var routeErrorPresented: Binding<Bool> {
        Binding(
            get: { routeError != nil },
            set: { if !$0 { routeError = nil } })
    }

    /// Presentation of the session-selection failure alert.
    private var sessionErrorPresented: Binding<Bool> {
        Binding(
            get: { sessionSelectionError != nil },
            set: { if !$0 { sessionSelectionError = nil } })
    }

    /// One TAPPABLE row per route (user directive): the route's name
    /// (`routeLabels`, address as fallback), its exact address:port, a
    /// probe state icon, and the ACTIVE mark — a checkmark on the route
    /// the next dial leads with, a bolt on the route a live session is
    /// dialed through right now. Tapping ANY row makes it the active
    /// route, any time — instant, reversible, no confirmation; the
    /// switch takes effect on the next connect (a live session is never
    /// torn down by a tap). Reuses the card rows' quiet-dot + green
    /// accent language. Serves the v1 (route-less) surface only; the
    /// v2 Routes section renders its own rows.
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

    /// ONE route-row tap, the SAME action the Hosts list's rows run
    /// (review round 2: every entry point must behave identically —
    /// persist through the shared store, then redial via the Console).
    /// When the presenting list supplies `switchRoute` (both production
    /// entry points do), the tap runs exactly that closure — the very
    /// same code a list-card tap executes. With a pick pending (several
    /// paths just answered), the tap IS the pick and the onboarding
    /// connect plays that role. Without either (previews, demo), the
    /// fallback persists and redials through this page's own
    /// retryConnection, or persists only where no Console exists.
    private func tapRoute(_ address: String) {
        if store.pendingAddressChoice?.contains(address) == true {
            Task { await store.chooseAddress(address) }
        } else if let switchRoute {
            Task { @MainActor in
                await switchRoute(address)
            }
        } else {
            store.setActiveRoute(address)
            Task { @MainActor in
                await retryConnection?()
            }
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
            return "Tap a route to switch to it — the connection redials "
                + "through it now."
        }
        return ""
    }


    // MARK: Routes (v2)

    /// The route surface from the design contract: Route selection, the
    /// result line, the saved-priority list with honest per-route
    /// statuses, and the actions Check routes / Choose manually / Edit
    /// priority. Route names describe saved endpoints; the footer states
    /// plainly that the app cannot see which VPN client is active.
    @ViewBuilder
    private var routesSection: some View {
        Section {
            // The explicit selection control: Automatic, or the pinned
            // route with a visible way back to Automatic. A pin is a
            // first-class state the user can see and change — never a
            // hidden swipe.
            if liveRouteHost.isManuallyRouted {
                Button {
                    returnToAutomatic()
                } label: {
                    Label(
                        "Return to automatic (using \(routeSelectionTitle))",
                        systemImage: "arrow.triangle.2.circlepath")
                }
            } else {
                LabeledContent("Route selection", value: "Automatic")
            }
            Text(routeResultLine)
                .font(.subheadline)
                .foregroundStyle(.secondary)
            ForEach(routeAddresses, id: \.self) { address in
                v2RouteRow(address)
            }
            // The preflight sweep's own question, rendered here for v2
            // Hosts (the Addresses list is gone): when several paths
            // answered, the pick stays answerable on the route rows
            // themselves.
            if store.pendingAddressChoice != nil {
                Text(
                    "Several paths answered. Use the one you want — "
                        + "it becomes this Host's preferred path.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            // The all-ineligible waiting state: every route is gated
            // out under the CURRENT network hint (e.g. Wi-Fi-only
            // routes while off Wi-Fi) — nothing dials until the network
            // changes; the surface says so instead of failing silently.
            if routeAddresses.allSatisfy({ address in
                !HostRoutePolicy.isEligible(
                    liveRouteHost.routeEligibility(for: address),
                    network: routeNetwork)
            }) {
                Label(
                    "No route is eligible under the current network. "
                        + "Nothing dials until the network changes.",
                    systemImage: "wifi.slash")
                    .font(.footnote)
                    .foregroundStyle(.orange)
            }

            Button {
                Task { await checkRoutes() }
            } label: {
                HStack {
                    Label("Check routes", systemImage: "antenna.radiowaves.left.and.right")
                    if isRouteCheckInFlight {
                        Spacer()
                        ProgressView()
                            .controlSize(.small)
                    }
                }
            }
            .disabled(isRouteCheckInFlight)
            if let checkFailedExplanation {
                // A sweep that could not even start (credential failure
                // is about the Host, not the path) surfaces visibly —
                // the user's press must never appear to do nothing.
                Label(checkFailedExplanation, systemImage: "exclamationmark.triangle")
                    .font(.footnote)
                    .foregroundStyle(.orange)
            }
            NavigationLink {
                HostRouteEditorView(host: store.host, catalog: catalog)
            } label: {
                Label("Edit priority & eligibility", systemImage: "list.number")
            }
        } header: {
            Text("Routes")
        } footer: {
            Text(
                "Routes are dialed top to bottom until one answers. "
                    + "Names describe saved endpoints; the app cannot see "
                    + "which VPN client is active. Use a route to pin it; "
                    + "edit names and addresses on the Host form.")
        }
    }

    /// Whether this Host carries v2 route settings (eligibility gates or
    /// a manual pin) — the gate that decides which selection surface
    /// owns the page. Hosts saved before route settings existed keep
    /// the v1 selector, migration-honest.
    private var hostHasV2RouteSettings: Bool {
        !liveRouteHost.routeEligibility.isEmpty || liveRouteHost.isManuallyRouted
    }

    /// The CURRENT catalog host for route metadata: route selection,
    /// eligibility, and pinned state are catalog state — a pin or unpin
    /// saved through the catalog is visible on the very next render,
    /// without waiting for the view's host value to be rebuilt. Falls
    /// back to the view's own host for previews and hosts not in a
    /// catalog.
    private var liveRouteHost: Host {
        catalog.hosts.first(where: { $0.id == store.host.id }) ?? store.host
    }

    /// The saved routes in priority order: the Host's candidate addresses,
    /// presented under their labels.
    private var routeAddresses: [String] {
        liveRouteHost.candidateAddresses
    }

    private var routeSelectionTitle: String {
        if let pinned = liveRouteHost.pinnedRouteAddress {
            return liveRouteHost.routeName(for: pinned)
        }
        return "Automatic"
    }

    private var routeResultLine: String {
        HostRoutePolicy.resultLine(
            host: store.host,
            liveAddress: connectedAddress,
            probes: routeProbeResults,
            network: routeNetwork)
    }

    /// Whether the connect-failure offer shows: a failed/reconnecting
    /// status whose standing failure is reach-class, on a Host with
    /// more than one saved route OR a stale manual pin (a pinned Host
    /// must be able to return to automatic even when it has no
    /// alternates). Auth/trust failures are NOT route failures — they
    /// show as themselves and switching routes cannot truthfully fix
    /// them (the same key answers on every route).
    private var showsRouteFailureOffer: Bool {
        guard let standingFailure else { return false }
        switch connectionStatus {
        case .failed, .reconnecting:
            break
        default:
            return false
        }
        guard standingFailure.isReachFailure else { return false }
        let routeCount = routeAddresses.count
        return routeCount > 1 || (routeCount == 1 && liveRouteHost.isManuallyRouted)
    }

    /// The store's explanation when a check could not even start.
    private var checkFailedExplanation: String? {
        routeStore?.checkFailedExplanation
    }

    /// The routes "Try another" may switch to: everything except the
    /// route the failed dial went through (the pinned route, or the
    /// live/last-tried address), in priority order.
    private var tryAnotherRouteChoices: [String] {
        let failedAddress = liveRouteHost.pinnedRouteAddress ?? connectedAddress
        return routeAddresses.filter { $0 != failedAddress }
    }

    /// Try another route: pin the choice and retry the Host connection —
    /// the retry observes the pin through the dial plan.
    private func tryRoute(_ address: String) async {
        do {
            try await ensureRouteStore().tryRoute(address)
        } catch {
            routeError = "The route selection could not be saved."
        }
    }

    private var isRouteCheckInFlight: Bool {
        routeStore?.isProbing ?? false
    }

    private var routeProbeResults: [String: HostRouteProbeResult] {
        routeStore?.probes ?? [:]
    }

    private var routeNetwork: HostRouteNetworkState {
        routeStore?.network ?? .offline
    }

    /// One row of the v2 Routes section: the route's name and address,
    /// its honest per-route status (from the latest probe), and the pin
    /// control — a pin for the pinned row, a Use button on every other
    /// eligible row.
    private func v2RouteRow(_ address: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: routeIcon(address))
                .foregroundStyle(routeIconTint(address))
            VStack(alignment: .leading, spacing: 2) {
                Text(liveRouteHost.routeName(for: address))
                    .font(.subheadline)
                Text(address)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                // When this route's verdict was checked — the honest
                // freshness readout; absent until a probe runs.
                if let checkedAt = routeProbeResults[address]?.checkedAt {
                    Text("Checked \(checkedAt.formatted(date: .omitted, time: .shortened))")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
            Spacer()
            Text(routeStatus(for: address))
                .font(.caption)
                .foregroundStyle(.secondary)
            // The visible selection control (not swipe-only): Use pins
            // The pinned row shows its pin; the section-top control
            // owns unpin. (No Menu here: a menu's options surface as
            // buttons in the accessibility tree and would shadow the
            // section-top unpin control for UI tests and VoiceOver.)
            if liveRouteHost.pinnedRouteAddress == address {
                Image(systemName: "pin.fill")
                    .foregroundStyle(.blue)
                    .accessibilityLabel("Pinned to \(liveRouteHost.routeName(for: address))")
            } else {
                Button("Use") {
                    pinRoute(address)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }
    }

    private func routeIcon(_ address: String) -> String {
        if liveRouteHost.pinnedRouteAddress == address {
            return "pin.fill"
        }
        if connectedAddress == address {
            return "bolt.fill"
        }
        switch routeProbeResults[address]?.outcome {
        case .reachable: return "checkmark.circle.fill"
        case .unreachable: return "xmark.circle.fill"
        case .authenticationRejected, .hostKeyProblem: return "exclamationmark.triangle.fill"
        case .unknown, nil: return "questionmark.circle"
        }
    }

    private func routeIconTint(_ address: String) -> Color {
        if liveRouteHost.pinnedRouteAddress == address {
            return .blue
        }
        if connectedAddress == address {
            return .green
        }
        switch routeProbeResults[address]?.outcome {
        case .reachable: return .green
        case .unreachable: return .red
        case .authenticationRejected, .hostKeyProblem: return .orange
        case .unknown, nil: return .secondary
        }
    }

    private func routeStatus(for address: String) -> String {
        HostRoutePolicy.rowStatus(
            address: address,
            host: store.host,
            liveAddress: connectedAddress,
            probes: routeProbeResults,
            network: routeNetwork)
    }

    /// "Check routes": one bounded sweep of the configured routes. The
    /// probes run on the shared prober so the same results feed the
    /// failure offer's Try-another-route choices.
    private func checkRoutes() async {
        let store = ensureRouteStore()
        await store.checkRoutes()
    }

    private func ensureRouteStore() -> HostRouteStatusStore {
        // A scripted store (demo screenshots) arrives through the init;
        // production builds the real store here on first use, seeded
        // with the CURRENT network hint from the shared monitor — never
        // a stale .offline.
        if let routeStore { return routeStore }
        let built = HostRouteStatusStore(
            host: store.host,
            network: HostRouteNetworkSnapshot.current,
            prober: HostRouteProber(),
            monitor: HostRouteMonitor.shared,
            catalog: catalog,
            retryConnection: { [retryConnection] in await retryConnection?() })
        routeStore = built
        return built
    }

    /// "Choose manually": pins a route — the pin is never silently
    /// overridden; a pinned dial never fails over.
    private func pinRoute(_ address: String) {
        routeError = nil
        do {
            try ensureRouteStore().pin(address)
        } catch {
            routeError = "The route selection could not be saved."
        }
    }

    /// "Return to automatic": drops the pin.
    private func returnToAutomatic() {
        routeError = nil
        do {
            try ensureRouteStore().returnToAutomatic()
        } catch {
            routeError = "The route selection could not be saved. (\(error))"
        }
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
