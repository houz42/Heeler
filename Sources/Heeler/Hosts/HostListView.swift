import Observation
import SwiftUI

struct HostRemovalRequest: Equatable {
    let hosts: [Host]

    var title: String {
        if hosts.count == 1, let host = hosts.first {
            return "Remove \(host.displayAliasName)?"
        }
        return "Remove \(hosts.count) Hosts?"
    }

    var actionTitle: String {
        hosts.count == 1 ? "Remove Host" : "Remove Hosts"
    }

    let message =
        "This permanently deletes the Host configuration and any saved password "
        + "from the Keychain. This cannot be undone."
}

@MainActor
@Observable
final class HostRemovalStore {
    private(set) var errorMessage: String?
    private(set) var pendingRequest: HostRemovalRequest?

    @ObservationIgnored
    private let store: HostStore

    init(store: HostStore) {
        self.store = store
    }

    func requestRemoval(_ ids: [Host.ID]) {
        let requestedIDs = Set(ids)
        let hosts = store.hosts.filter { requestedIDs.contains($0.id) }
        guard !hosts.isEmpty else { return }
        pendingRequest = HostRemovalRequest(hosts: hosts)
    }

    func cancelRemoval() {
        pendingRequest = nil
    }

    func confirmRemoval(_ request: HostRemovalRequest) {
        pendingRequest = nil
        for host in request.hosts {
            do {
                try store.remove(host.id)
            } catch {
                errorMessage = "The Host could not be removed. Its saved credentials may still be in the Keychain."
                return
            }
        }
    }

    func dismissError() {
        errorMessage = nil
    }
}

/// Host management (#14): the catalog of Hosts with add/edit/remove, each
/// row leading into that Host's onboarding checklist.
struct HostListView: View {
    let store: HostStore
    private let initialHostID: Host.ID?
    private let connectionStatuses: [Host.ID: EventsSessionStatus]
    private let standingFailures: [Host.ID: TransportError]
    private let latencies: [Host.ID: Duration]
    /// Which candidate address each Host's live session is dialed through;
    /// the detail page marks exactly that row as in use.
    private let connectedAddresses: [Host.ID: String]
    /// Hosts whose Host-detail Reconnect request is in flight. Distinct from
    /// `EventsSessionStatus.reconnecting`.
    private let manualReconnectInFlightHostIDs: Set<Host.ID>
    private let retryConnection: (@MainActor @Sendable (Host.ID) async -> Void)?
    /// Sessions/Hosts blending (Phase 5): offers unclaimed sessions found
    /// on connected Hosts' machines. nil keeps the list discovery-free
    /// (previews, Hosts without a Console connection).
    private let discovery: SessionDiscoveryStore?
    @State private var removal: HostRemovalStore
    @State private var isAddingHost = false
    @State private var isScanningToPair = false
    @State private var manualFallbackRequested = false
    @State private var path: [Host.ID] = []
    /// The Host being edited from a card's scoped Edit action (§E 3):
    /// the host form sheet always targets exactly this Host.
    @State private var editingHost: Host?
    @State private var inspectedRoute: HostRouteInspection?
    /// Top-level destination selector (handoff §A): mounted by the app
    /// root; nil in sheets/tests keeps the plain "Hosts" title.
    @Environment(\.appDestination) private var appDestination
    @State private var quickAddError: String?

    init(
        store: HostStore,
        initialHostID: Host.ID? = nil,
        connectionStatuses: [Host.ID: EventsSessionStatus] = [:],
        standingFailures: [Host.ID: TransportError] = [:],
        latencies: [Host.ID: Duration] = [:],
        connectedAddresses: [Host.ID: String] = [:],
        manualReconnectInFlightHostIDs: Set<Host.ID> = [],
        retryConnection: (@MainActor @Sendable (Host.ID) async -> Void)? = nil,
        discovery: SessionDiscoveryStore? = nil
    ) {
        self.store = store
        self.initialHostID = initialHostID
        self.connectionStatuses = connectionStatuses
        self.standingFailures = standingFailures
        self.latencies = latencies
        self.connectedAddresses = connectedAddresses
        self.manualReconnectInFlightHostIDs = manualReconnectInFlightHostIDs
        self.retryConnection = retryConnection
        self.discovery = discovery
        _removal = State(initialValue: HostRemovalStore(store: store))
    }

    var body: some View {
        NavigationStack(path: $path) {
            Group {
                if store.catalogLoadError != nil {
                    ContentUnavailableView {
                        Label("Hosts Unavailable", systemImage: "externaldrive.badge.exclamationmark")
                    } description: {
                        Text(
                            "The saved Host catalog could not be read. Its original data was preserved; "
                                + "reinstalling or adding a Host would risk losing it.")
                    }
                } else if store.hosts.isEmpty {
                    ContentUnavailableView {
                        Label("No Hosts", systemImage: "server.rack")
                    } description: {
                        Text("Add a machine that runs herdr to get started.")
                    } actions: {
                        // Scan to Pair is the primary add-Host action; the
                        // manual form is the fallback (ADR 0007).
                        Button("Scan to Pair", systemImage: "qrcode.viewfinder") {
                            isScanningToPair = true
                        }
                        .buttonStyle(.borderedProminent)
                        Button("Add Manually") { isAddingHost = true }
                    }
                } else {
                    List {
                        ForEach(store.hosts) { host in
                            hostCard(for: host)
                        }
                        .onDelete(perform: removeHosts)
                        quickAddSection
                    }
                    .listStyle(.insetGrouped)
                    .listSectionSpacing(12)
                }
            }
            .navigationTitle(appDestination == nil ? "Hosts" : "")
            .toolbar {
                // Handoff §A: the top-left compact destination selector
                // replaces the title when the app root mounts this page.
                if let appDestination {
                    ToolbarItem(placement: .topBarLeading) {
                        AppDestinationMenu(selection: appDestination)
                    }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button("Scan to Pair", systemImage: "qrcode.viewfinder") {
                        isScanningToPair = true
                    }
                    .disabled(store.catalogLoadError != nil)
                }
                ToolbarItem(placement: .primaryAction) {
                    Button("Add Host", systemImage: "plus") { isAddingHost = true }
                        .disabled(store.catalogLoadError != nil)
                }
            }
            .navigationDestination(for: Host.ID.self) { id in
                if let host = store.hosts.first(where: { $0.id == id }) {
                    // Keyed by the Host value: editing recreates the
                    // onboarding store so checks run against fresh settings.
                    HostOnboardingView(
                        host: host,
                        catalog: store,
                        connectionStatus: connectionStatuses[id],
                        standingFailure: standingFailures[id],
                        isManualReconnectInFlight: manualReconnectInFlightHostIDs.contains(id),
                        retryConnection: retryAction(for: id),
                        connectedAddress: connectedAddresses[id])
                        .id(host)
                } else {
                    ContentUnavailableView("Host removed", systemImage: "server.rack")
                }
            }
            .sheet(isPresented: $isAddingHost) {
                HostFormView(store: store) { saved in
                    path.append(saved.id)
                }
            }
            .sheet(item: $editingHost) { host in
                // A card's scoped Edit (§E 3): the form edits exactly the
                // Host the user tapped, keyed by that Host value.
                HostFormView(store: store, editing: host)
            }
            .sheet(item: $inspectedRoute) { inspection in
                // Tapping a route on a Host card: the inspector targets
                // THAT Host's THAT route, never a global connection.
                if let host = store.hosts.first(where: { $0.id == inspection.hostID }) {
                    HostRouteInspectorView(
                        host: host,
                        address: inspection.address,
                        connectedAddress: connectedAddresses[inspection.hostID],
                        // In-context naming (device finding): the SAME
                        // editor the form uses; the label persists to the
                        // catalog, so the list row and inspector both
                        // show the friendly name immediately.
                        onEditRoute: { updated in
                            var edited = host
                            let label = updated.label.trimmingCharacters(in: .whitespaces)
                            if label.isEmpty {
                                edited.routeLabels.removeValue(forKey: updated.address)
                            } else {
                                edited.routeLabels[updated.address] = label
                            }
                            if edited != host {
                                try? store.update(edited)
                            }
                        })
                }
            }
            .sheet(
                isPresented: $isScanningToPair,
                onDismiss: {
                    // The scan sheet's "Add Manually" fallback (camera denied
                    // or unsupported): present the form only once this sheet
                    // is fully gone, so the two sheets never overlap.
                    if manualFallbackRequested {
                        manualFallbackRequested = false
                        isAddingHost = true
                    }
                }
            ) {
                // A successful Pairing lands in the same onboarding preflight
                // a manually added Host enters (session discovery included).
                PairingScanView(catalog: store) { paired in
                    path.append(paired.id)
                } onAddManually: {
                    manualFallbackRequested = true
                }
            }
            .alert(
                removal.pendingRequest?.title ?? "Remove Host?",
                isPresented: removalConfirmationPresented,
                presenting: removal.pendingRequest
            ) { request in
                Button(request.actionTitle, role: .destructive) {
                    removal.confirmRemoval(request)
                }
                Button("Cancel", role: .cancel) {
                    removal.cancelRemoval()
                }
            } message: { request in
                Text(request.message)
            }
            .alert(
                "Could Not Remove Host",
                isPresented: Binding(
                    get: { removal.errorMessage != nil },
                    set: { isPresented in
                        if !isPresented {
                            removal.dismissError()
                        }
                    }
                )
            ) {
                Button("OK", role: .cancel) {
                    removal.dismissError()
                }
            } message: {
                Text(removal.errorMessage ?? "")
            }

            /// One refresh while the sheet is up: discovery rides the
            /// already-connected Hosts' live connections, so it runs once
            /// on appearance rather than polling.
            .task {
                await refreshDiscovery()
            }
            .alert(
                "Could Not Add Session",
                isPresented: Binding(
                    get: { quickAddError != nil },
                    set: { if !$0 { quickAddError = nil } })
            ) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(quickAddError ?? "")
            }
            .task(id: initialHostID) {
                guard
                    path.isEmpty,
                    let initialHostID,
                    store.hosts.contains(where: { $0.id == initialHostID })
                else { return }
                path.append(initialHostID)
            }
        }
    }

    private var removalConfirmationPresented: Binding<Bool> {
        Binding(
            get: { removal.pendingRequest != nil },
            set: { if !$0 { removal.cancelRemoval() } })
    }

    private func removeHosts(at offsets: IndexSet) {
        removal.requestRemoval(offsets.map { store.hosts[$0].id })
    }

    private func retryAction(
        for id: Host.ID
    ) -> (@MainActor @Sendable () async -> Void)? {
        guard let retryConnection else { return nil }
        return { await retryConnection(id) }
    }

    /// One Host card, split from `body` so the list stays type-checkable.
    private func hostCard(for host: Host) -> some View {
        HostCardSection(
            host: host,
            connectionStatus: connectionStatuses[host.id],
            standingFailure: standingFailures[host.id],
            latency: latencies[host.id],
            connectedAddress: connectedAddresses[host.id],
            isRetryInFlight: manualReconnectInFlightHostIDs.contains(host.id),
            retryConnection: retryConnection.map { retry in
                { await retry(host.id) }
            },
            openDetail: { path.append(host.id) },
            openEditor: { editingHost = host },
            openRouteInspector: { address in
                inspectedRoute = HostRouteInspection(hostID: host.id, address: address)
            })
    }

    @ViewBuilder
    private var quickAddSection: some View {
        if let discovery {
            let sections = store.hosts.compactMap { host -> (Host, [SessionDiscovery.Offer])? in
                guard let offers = discovery.offersByHost[host.id], !offers.isEmpty else {
                    return nil
                }
                return (host, offers)
            }
            ForEach(sections, id: \.0.id) { host, offers in
                Section {
                    ForEach(offers) { offer in
                        Button {
                            addQuickSession(offer, on: host)
                        } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("\(host.displayAliasName) · session \(offer.sessionName)")
                                    .font(.subheadline)
                                Text(offer.isRunning ? "Running" : "Stopped")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                } header: {
                    Text("Discovered Sessions")
                } footer: {
                    Text("Tap to add a session as its own Host, reusing \(host.displayAliasName)'s connection.")
                }
            }
        }
    }

    private func refreshDiscovery() async {
        guard let discovery else { return }
        for host in store.hosts where connectionStatuses[host.id] == .connected {
            await discovery.refresh(host: host, catalog: store.hosts)
        }
    }

    private func addQuickSession(_ offer: SessionDiscovery.Offer, on host: Host) {
        guard let discovery else { return }
        do {
            try discovery.add(offer, from: host, to: store)
        } catch {
            quickAddError = "The session could not be saved as a Host."
        }
    }
}

/// The sheet target for a tapped route: which Host and which of its
/// routes. Distinct from `HostRoutePresentation` (pure display) — this
/// carries identity only, resolved against the live catalog when the
/// sheet builds.
struct HostRouteInspection: Identifiable, Equatable {
    let hostID: Host.ID
    let address: String
    var id: String { "\(hostID.uuidString)|\(address)" }
}

/// One Host as a card (handoff §E): heading with name + connection chip
/// and an Edit button, then one row per NAMED route — exact address plus
/// honest in-use/alternate state — each tapping into the route
/// inspector. Chat service state belongs to the Host, not a route, so
/// its row targets the Host (provisioning integration point, below).
private struct HostCardSection: View {
    let host: Host
    let connectionStatus: EventsSessionStatus?
    let standingFailure: TransportError?
    let latency: Duration?
    let connectedAddress: String?
    let isRetryInFlight: Bool
    let retryConnection: (@MainActor @Sendable () async -> Void)?
    let openDetail: () -> Void
    /// Scoped Edit: opens the host form for THIS host, straight from the
    /// card (approved §E: host edit targets the selected host).
    let openEditor: () -> Void
    let openRouteInspector: (String) -> Void

    /// Terminal stopped-auto-retry state: failed, or connecting while a
    /// standing failure is being served. Retry offers exactly one dial.
    private var isRetryable: Bool {
        switch connectionStatus {
        case .failed: retryConnection != nil
        case .connecting: standingFailure != nil && retryConnection != nil
        default: false
        }
    }

    private var connectionPresentation: HostConnectionPresentation {
        HostConnectionPresentation(
            status: connectionStatus,
            standingFailure: standingFailure,
            latency: latency)
    }

    var body: some View {
        Section {
            // The heading row: tapping the name area opens the Host
            // detail (onboarding/preflight); the scoped Edit button sits
            // BESIDE it as a sibling (a Button nested inside another
            // Button's label never fires its own action). Both target
            // THIS host.
            HStack(spacing: 12) {
                Button {
                    openDetail()
                } label: {
                    HStack(spacing: 12) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(host.displayAliasName)
                                .font(.headline)
                                .foregroundStyle(.primary)
                            HostConnectionIndicator(presentation: connectionPresentation)
                        }
                        Spacer(minLength: 0)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(
                    "Open details for \(host.displayAliasName), "
                        + connectionPresentation.accessibilityLabel)
                if isRetryable {
                    Button {
                        Task { await retryConnection?() }
                    } label: {
                        if isRetryInFlight {
                            ProgressView()
                        } else {
                            Image(systemName: "arrow.clockwise")
                        }
                    }
                    .buttonStyle(.bordered)
                    .tint(.orange)
                    .disabled(isRetryInFlight)
                    .accessibilityLabel("Retry connecting to \(host.displayAliasName)")
                }
                // Scoped Edit for THIS host, directly on the card
                // (§E requirement 3): opens the host form editing
                // exactly this Host, never a hardcoded one.
                Button("Edit") { openEditor() }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .accessibilityLabel("Edit \(host.displayAliasName)")
                    .accessibilityIdentifier("host-card-edit")
                Image(systemName: "chevron.right")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }

            // One row per named route: exact address and honest
            // in-use/alternate state; tap inspects THAT route.
            ForEach(host.candidateAddresses, id: \.self) { address in
                let route = HostRoutePresentation(
                    host: host, address: address, connectedAddress: connectedAddress)
                Button {
                    openRouteInspector(address)
                } label: {
                    HStack(spacing: 10) {
                        // The dot IS the in-use signal (user decision:
                        // the row stays quiet — no 'In use'/'Alternate'
                        // text; the inspector keeps the words).
                        Image(systemName: "circle.fill")
                            .font(.system(size: 7))
                            .foregroundStyle(
                                route.usage == .inUse ? Color.green : Color.secondary)
                            .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(route.name)
                                .font(.subheadline.weight(.medium))
                                .foregroundStyle(.primary)
                            Text("\(route.address):\(String(host.port))")
                                .font(.caption)
                                .monospaced()
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                }
                .buttonStyle(.plain)
                .accessibilityLabel(
                    "Route \(route.name), \(route.address):\(String(host.port)), "
                        + (route.usage == .inUse
                            ? "currently in use"
                            : "alternate route, reachability unknown until checked"))
                .accessibilityIdentifier("host-route-\(route.address)")
            }
        }
    }
}

/// The status chip on a Host row. Chips render Host Connection Status, never
/// a Transport Error Presentation — even on `.failed`, where they say
/// "Unavailable". See Transport Error Presentation in `CONTEXT.md`.
struct HostConnectionPresentation: Equatable {
    enum Tone: Equatable {
        case connected
        case pending
        case warning
        case unavailable
    }

    let title: String
    let accessibilityLabel: String
    let tone: Tone

    init(
        status: EventsSessionStatus?,
        standingFailure: TransportError? = nil,
        latency: Duration?
    ) {
        switch status {
        case .connected:
            if let latency {
                let formattedLatency = HostLatencyFormatting.formatted(latency)
                title = formattedLatency
                accessibilityLabel = "Connected, latency \(formattedLatency)"
            } else {
                title = "Measuring…"
                accessibilityLabel = "Connected, measuring latency"
            }
            tone = .connected
        case .reconnecting:
            title = "Reconnecting…"
            accessibilityLabel = "Reconnecting"
            tone = .warning
        case .connecting:
            if standingFailure != nil {
                title = "Unavailable"
                accessibilityLabel = "Unavailable"
                tone = .unavailable
            } else {
                title = "Connecting…"
                accessibilityLabel = "Connecting"
                tone = .pending
            }
        case .failed, .ended:
            title = "Unavailable"
            accessibilityLabel = "Unavailable"
            tone = .unavailable
        case .suspended:
            title = "Paused"
            accessibilityLabel = "Connection paused"
            tone = .pending
        case nil:
            title = "Connecting…"
            accessibilityLabel = "Connecting"
            tone = .pending
        }
    }
}

private struct HostConnectionIndicator: View {
    let presentation: HostConnectionPresentation

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: "circle.fill")
                .font(.system(size: 7))
                .foregroundStyle(tint)
                .accessibilityHidden(true)
            Text(presentation.title)
                .font(.caption)
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(presentation.accessibilityLabel)
    }

    private var tint: Color {
        switch presentation.tone {
        case .connected: .green
        case .pending: .secondary
        case .warning: .orange
        case .unavailable: .red
        }
    }
}

#Preview {
    HostListView(store: HostStore(secrets: PreviewSecretStore()))
}

/// Keeps previews out of the real Keychain.
private final class PreviewSecretStore: SecretStore {
    func read(account: String) throws -> Data? { nil }
    func readAll() throws -> [String: Data] { [:] }
    func write(_ secret: Data, account: String) throws {}
    func removeSecret(account: String) throws {}
}
